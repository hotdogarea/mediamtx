#import "BolemeLicense.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <float.h>
#import <stdbool.h>

NSString * const BolemeLicenseDidChangeNotification = @"BolemeLicenseDidChangeNotification";

static NSString * const BLServerBaseURL = @"https://license.zltik.top";
static NSString * const BLFallbackServerBaseURL = @"http://124.221.87.28";
static NSString * const BLProductType = @"streaming_assistant";
static NSString * const BLKeychainService = @"com.boleme.streaming-assistant";
static NSString * const BLStateAccount = @"license-state-v1";
static NSString * const BLDeviceAccount = @"device-id-v1";
static NSString * const BLPublicKeyBase64 = @"wNCP+CPWiTYmrUzWsSLfHsz1yuBJL/XcsOFXE8m/8rg=";
static NSTimeInterval const BLValidationInterval = 6 * 60 * 60;
static NSTimeInterval const BLOfflineGraceInterval = 72 * 60 * 60;

extern bool BolemeVerifyEd25519(const uint8_t *message, NSInteger messageLength,
                                const uint8_t *signature, NSInteger signatureLength,
                                const uint8_t *publicKey, NSInteger publicKeyLength);

@interface BolemeLicenseManager ()
@property (atomic, readwrite, getter=isAuthorized) BOOL authorized;
@property (atomic, readwrite, getter=isChecking) BOOL checking;
@property (atomic, copy, readwrite) NSString *statusText;
@property (atomic, copy, readwrite) NSString *detailText;
@property (atomic, copy, readwrite, nullable) NSString *activationCode;
@property (atomic, copy, readwrite, nullable) NSString *expirationText;
@property (nonatomic, copy) NSString *deviceID;
@property (nonatomic, strong, nullable) NSDate *expiresAt;
@property (nonatomic, strong, nullable) NSDate *lastValidatedAt;
@property (nonatomic, assign) BOOL permanent;
@property (nonatomic, assign) BOOL started;
@end

@implementation BolemeLicenseManager

+ (instancetype)shared {
    static BolemeLicenseManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [BolemeLicenseManager new]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusText = @"未激活";
        _detailText = @"输入推流助手激活码后才能替换摄像头画面";
        _deviceID = [self loadOrCreateDeviceID];
        [self loadCachedState];
    }
    return self;
}

- (void)start {
    @synchronized (self) {
        if (self.started) return;
        self.started = YES;
    }
    if (!self.activationCode.length) return;
    NSTimeInterval age = self.lastValidatedAt ? -self.lastValidatedAt.timeIntervalSinceNow : DBL_MAX;
    if (age >= BLValidationInterval) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self validateNowWithCompletion:nil]; });
    }
}

- (NSDictionary *)keychainQueryForAccount:(NSString *)account {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: BLKeychainService,
             (__bridge id)kSecAttrAccount: account};
}

- (nullable NSData *)keychainDataForAccount:(NSString *)account {
    NSMutableDictionary *query = [[self keychainQueryForAccount:account] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    return CFBridgingRelease(result);
}

- (BOOL)saveKeychainData:(NSData *)data account:(NSString *)account {
    NSDictionary *query = [self keychainQueryForAccount:account];
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data,
                                 (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [query mutableCopy];
        [insert addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    return status == errSecSuccess;
}

- (NSString *)loadOrCreateDeviceID {
    NSData *stored = [self keychainDataForAccount:BLDeviceAccount];
    NSString *raw = stored ? [[NSString alloc] initWithData:stored encoding:NSUTF8StringEncoding] : nil;
    if (!raw.length) {
        raw = UIDevice.currentDevice.identifierForVendor.UUIDString ?: NSUUID.UUID.UUIDString;
        [self saveKeychainData:[raw dataUsingEncoding:NSUTF8StringEncoding] account:BLDeviceAccount];
    }
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

- (nullable NSDate *)dateFromServerString:(NSString *)value {
    if (!value.length) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [iso dateFromString:value];
    if (!date) {
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [iso dateFromString:value];
    }
    if (date) return date;
    NSArray<NSString *> *formats = @[@"yyyy-MM-dd'T'HH:mm:ss.SSSSSS", @"yyyy-MM-dd'T'HH:mm:ss"];
    for (NSString *format in formats) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
        formatter.dateFormat = format;
        date = [formatter dateFromString:value];
        if (date) return date;
    }
    return nil;
}

- (NSString *)displayExpirationForDate:(nullable NSDate *)date permanent:(BOOL)permanent {
    if (permanent) return @"永久有效";
    if (!date) return @"有效期未知";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    formatter.dateFormat = @"yyyy年M月d日 HH:mm 到期";
    return [formatter stringFromDate:date];
}

- (void)loadCachedState {
    NSData *data = [self keychainDataForAccount:BLStateAccount];
    if (!data) return;
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:NSDictionary.class]) return;
    self.activationCode = [state[@"activation_code"] isKindOfClass:NSString.class] ? state[@"activation_code"] : nil;
    NSString *expires = [state[@"expires_at"] isKindOfClass:NSString.class] ? state[@"expires_at"] : nil;
    NSString *lastValidated = [state[@"last_validated_at"] isKindOfClass:NSString.class] ? state[@"last_validated_at"] : nil;
    self.permanent = [state[@"permanent"] boolValue];
    self.expiresAt = [self dateFromServerString:expires];
    self.lastValidatedAt = [self dateFromServerString:lastValidated];
    self.expirationText = [self displayExpirationForDate:self.expiresAt permanent:self.permanent];
    [self evaluateCachedAuthorization];
}

- (void)evaluateCachedAuthorization {
    BOOL notExpired = self.permanent || (self.expiresAt && self.expiresAt.timeIntervalSinceNow > 0);
    BOOL withinGrace = self.lastValidatedAt && -self.lastValidatedAt.timeIntervalSinceNow <= BLOfflineGraceInterval;
    self.authorized = self.activationCode.length && notExpired && withinGrace;
    if (self.authorized) {
        self.statusText = @"已激活";
        self.detailText = self.expirationText ?: @"授权有效";
    } else if (self.activationCode.length && !notExpired) {
        self.statusText = @"授权已到期";
        self.detailText = @"请购买新激活码后重新激活";
    }
}

- (void)persistSuccessfulResponse:(NSDictionary *)data activationCode:(NSString *)activationCode {
    NSString *expires = [data[@"expires_at"] isKindOfClass:NSString.class] ? data[@"expires_at"] : nil;
    NSString *codeType = [data[@"activated_code_type"] isKindOfClass:NSString.class] ? data[@"activated_code_type"] : @"";
    BOOL permanent = [codeType isEqualToString:@"permanent"] || !expires.length;
    NSString *validated = [NSISO8601DateFormatter stringFromDate:NSDate.date
                                                         timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]
                                                    formatOptions:NSISO8601DateFormatWithInternetDateTime];
    NSDictionary *state = @{ @"activation_code": activationCode,
                             @"expires_at": expires ?: @"",
                             @"last_validated_at": validated,
                             @"permanent": @(permanent) };
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (encoded) [self saveKeychainData:encoded account:BLStateAccount];
    self.activationCode = activationCode;
    self.expiresAt = [self dateFromServerString:expires];
    self.lastValidatedAt = NSDate.date;
    self.permanent = permanent;
    self.expirationText = [self displayExpirationForDate:self.expiresAt permanent:permanent];
    self.authorized = YES;
    self.statusText = @"已激活";
    self.detailText = self.expirationText ?: @"授权有效";
}

- (BOOL)verifySignedResponse:(NSDictionary *)response
              activationCode:(NSString *)activationCode
                         data:(NSDictionary * _Nullable * _Nullable)dataOut {
    NSString *signatureText = [response[@"signature"] isKindOfClass:NSString.class] ? response[@"signature"] : nil;
    NSString *version = [response[@"signature_version"] isKindOfClass:NSString.class] ? response[@"signature_version"] : nil;
    id serverTime = response[@"server_time"];
    id responseData = response[@"data"];
    if (!signatureText.length || ![version isEqualToString:@"ed25519-v1"] || !serverTime || !responseData) return NO;
    NSDictionary *signedPayload = @{ @"status": response[@"status"] ?: NSNull.null,
                                     @"message": response[@"message"] ?: NSNull.null,
                                     @"data": responseData,
                                     @"server_time": serverTime,
                                     @"signature_version": version };
    NSJSONWritingOptions options = NSJSONWritingSortedKeys;
    if (@available(iOS 13.0, *)) options |= NSJSONWritingWithoutEscapingSlashes;
    NSData *message = [NSJSONSerialization dataWithJSONObject:signedPayload options:options error:nil];
    NSData *signature = [[NSData alloc] initWithBase64EncodedString:signatureText options:0];
    NSData *publicKey = [[NSData alloc] initWithBase64EncodedString:BLPublicKeyBase64 options:0];
    if (!message || !signature || !publicKey ||
        !BolemeVerifyEd25519(message.bytes, message.length, signature.bytes, signature.length,
                            publicKey.bytes, publicKey.length)) return NO;
    if (![responseData isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *data = responseData;
    if (![data[@"activation_code"] isEqual:activationCode] ||
        ![data[@"device_id"] isEqual:self.deviceID] ||
        ![data[@"product_type"] isEqual:BLProductType]) return NO;
    if (dataOut) *dataOut = data;
    return YES;
}

- (void)postPath:(NSString *)path activationCode:(NSString *)activationCode completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable, BOOL))completion {
    [self postPath:path activationCode:activationCode
          baseURLs:@[BLServerBaseURL, BLFallbackServerBaseURL] index:0 completion:completion];
}

- (void)postPath:(NSString *)path
   activationCode:(NSString *)activationCode
         baseURLs:(NSArray<NSString *> *)baseURLs
            index:(NSUInteger)index
       completion:(void (^)(NSDictionary * _Nullable, NSString * _Nullable, BOOL))completion {
    NSURL *url = [NSURL URLWithString:[baseURLs[index] stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"boleme-ios/1.0" forHTTPHeaderField:@"User-Agent"];
    NSDictionary *payload = @{ @"activation_code": activationCode,
                               @"device_id": self.deviceID,
                               @"product_type": BLProductType };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (index + 1 < baseURLs.count) {
                [self postPath:path activationCode:activationCode baseURLs:baseURLs index:index + 1 completion:completion];
                return;
            }
            completion(nil, @"无法连接激活服务器，请检查网络", YES);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            completion(nil, @"激活服务器返回的数据无法识别", NO);
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *message = [json[@"detail"] isKindOfClass:NSString.class] ? json[@"detail"] : @"激活失败，请检查激活码";
            completion(json, message, NO);
            return;
        }
        completion(json, nil, NO);
    }];
    [task resume];
}

- (void)finishCheckingWithSuccess:(BOOL)success message:(NSString *)message completion:(void (^ _Nullable)(BOOL, NSString *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.checking = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:BolemeLicenseDidChangeNotification object:self];
        if (completion) completion(success, message);
    });
}

- (void)activateCode:(NSString *)activationCode completion:(void (^)(BOOL, NSString *))completion {
    NSString *code = [activationCode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (code.length < 6) {
        if (completion) completion(NO, @"请输入完整的激活码");
        return;
    }
    if (self.checking) return;
    self.checking = YES;
    self.statusText = @"正在激活…";
    self.detailText = @"正在连接授权服务器";
    [self postPath:@"/api/v1/activate" activationCode:code completion:^(NSDictionary *response, NSString *errorMessage, BOOL networkError) {
        NSDictionary *data = nil;
        if (!errorMessage && [self verifySignedResponse:response activationCode:code data:&data] &&
            [response[@"status"] isEqual:@"success"]) {
            [self persistSuccessfulResponse:data activationCode:code];
            [self finishCheckingWithSuccess:YES message:@"激活成功" completion:completion];
            return;
        }
        self.authorized = NO;
        self.statusText = @"激活失败";
        self.detailText = errorMessage ?: @"服务器签名校验失败，请联系技术支持";
        [self finishCheckingWithSuccess:NO message:self.detailText completion:completion];
    }];
}

- (void)validateNowWithCompletion:(void (^ _Nullable)(BOOL, NSString *))completion {
    NSString *code = self.activationCode;
    if (!code.length) {
        if (completion) completion(NO, @"尚未输入激活码");
        return;
    }
    if (self.checking) return;
    self.checking = YES;
    self.statusText = @"正在验证…";
    self.detailText = @"正在检查授权状态";
    [self postPath:@"/api/v1/validate-activation" activationCode:code completion:^(NSDictionary *response, NSString *errorMessage, BOOL networkError) {
        NSDictionary *data = nil;
        BOOL signatureValid = !errorMessage && [self verifySignedResponse:response activationCode:code data:&data];
        BOOL valid = signatureValid && [response[@"status"] isEqual:@"success"] && [data[@"is_valid"] boolValue];
        if (valid) {
            [self persistSuccessfulResponse:data activationCode:code];
            [self finishCheckingWithSuccess:YES message:@"授权有效" completion:completion];
            return;
        }
        if (networkError) {
            [self evaluateCachedAuthorization];
            if (self.authorized) {
                self.statusText = @"离线可用";
                self.detailText = @"暂时无法连接服务器，将在网络恢复后重新验证";
                [self finishCheckingWithSuccess:YES message:self.detailText completion:completion];
                return;
            }
        }
        self.authorized = NO;
        self.statusText = @"授权无效";
        self.detailText = errorMessage ?: ([response[@"message"] isKindOfClass:NSString.class] ? response[@"message"] : @"授权已失效，请联系技术支持");
        [self finishCheckingWithSuccess:NO message:self.detailText completion:completion];
    }];
}

@end
