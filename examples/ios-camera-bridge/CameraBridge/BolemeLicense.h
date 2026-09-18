#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BolemeLicenseDidChangeNotification;

@interface BolemeLicenseManager : NSObject

@property (atomic, readonly, getter=isAuthorized) BOOL authorized;
@property (atomic, readonly, getter=isChecking) BOOL checking;
@property (atomic, copy, readonly) NSString *statusText;
@property (atomic, copy, readonly) NSString *detailText;
@property (atomic, copy, readonly, nullable) NSString *activationCode;
@property (atomic, copy, readonly, nullable) NSString *expirationText;

+ (instancetype)shared;
- (void)start;
- (void)activateCode:(NSString *)activationCode
          completion:(void (^)(BOOL success, NSString *message))completion;
- (void)validateNowWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion;

@end

NS_ASSUME_NONNULL_END
