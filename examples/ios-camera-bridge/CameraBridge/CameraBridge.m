#import "CameraBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString * const CBStreamURLKey = @"CameraBridge.StreamURL";
NSString * const CBEnabledKey = @"CameraBridge.Enabled";

@interface CBReceiver : NSObject
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, copy) NSString *currentURL;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, assign) CVPixelBufferRef latestPixelBuffer;
@property (nonatomic, assign) CFAbsoluteTime latestFrameTime;
@property (nonatomic, assign) NSUInteger replacedCount;
@property (nonatomic, assign) NSUInteger cameraCallbackCount;
@property (nonatomic, assign) OSType cameraPixelFormat;
@property (nonatomic, assign) CFTimeInterval lastButtonCheck;
@property (nonatomic, assign) CFAbsoluteTime lastConnectTime;
@property (nonatomic, assign) CFAbsoluteTime retryAfter;
@property (nonatomic, copy) NSString *state;
+ (instancetype)shared;
- (void)startOnMainThread;
- (CVPixelBufferRef)copyFreshFrame CF_RETURNS_RETAINED;
- (CMSampleBufferRef)copyReplacementForSample:(CMSampleBufferRef)sample CF_RETURNS_RETAINED;
- (void)installButtonIfNeeded;
@end

@implementation CBReceiver

+ (instancetype)shared {
    static CBReceiver *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [CBReceiver new]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _context = [CIContext contextWithOptions:nil];
        _state = @"waiting for camera";
    }
    return self;
}

- (void)dealloc {
    if (_latestPixelBuffer) CVPixelBufferRelease(_latestPixelBuffer);
}

- (void)startOnMainThread {
    NSAssert([NSThread isMainThread], @"UI/player setup must run on main thread");
    if (self.displayLink) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self installButtonIfNeeded];
}

- (void)clearFrame {
    @synchronized (self) {
        if (_latestPixelBuffer) {
            CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = NULL;
        }
        _latestFrameTime = 0;
    }
}

- (void)tick:(CADisplayLink *)link {
    if (link.timestamp - self.lastButtonCheck > 1.0) {
        self.lastButtonCheck = link.timestamp;
        [self installButtonIfNeeded];
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *urlString = [[defaults stringForKey:CBStreamURLKey] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL enabled = [defaults boolForKey:CBEnabledKey];
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    BOOL validURL = [url.scheme.lowercaseString isEqualToString:@"http"] || [url.scheme.lowercaseString isEqualToString:@"https"];
    validURL = validURL && [url.pathExtension.lowercaseString isEqualToString:@"m3u8"];

    if (!enabled || !validURL) {
        if (self.player) [self.player pause];
        self.player = nil;
        self.videoOutput = nil;
        self.currentURL = nil;
        self.state = enabled ? @"enter an HTTP(S) HLS .m3u8 URL" : @"disabled";
        [self clearFrame];
        return;
    }

    if (![self.currentURL isEqualToString:urlString]) {
        if (CFAbsoluteTimeGetCurrent() < self.retryAfter) return;
        [self clearFrame];
        self.currentURL = urlString;
        self.lastConnectTime = CFAbsoluteTimeGetCurrent();
        NSDictionary *attributes = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        [item addOutput:self.videoOutput];
        item.preferredForwardBufferDuration = 0;
        self.player = [AVPlayer playerWithPlayerItem:item];
        self.player.muted = YES; // Only video frames are replaced; the microphone is untouched.
        self.player.automaticallyWaitsToMinimizeStalling = NO;
        [self.player play];
        self.state = @"connecting to HLS";
    }

    if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
        self.state = self.player.currentItem.error.localizedDescription ?: @"HLS playback failed";
        [self.player pause];
        self.currentURL = nil; // Allow a later retry when OBS comes back.
        self.retryAfter = CFAbsoluteTimeGetCurrent() + 2.0;
        return;
    }

    CFAbsoluteTime mostRecentFrame;
    @synchronized (self) { mostRecentFrame = self.latestFrameTime; }
    if (CFAbsoluteTimeGetCurrent() - MAX(self.lastConnectTime, mostRecentFrame) > 8.0) {
        self.state = @"HLS stalled; reconnecting";
        [self.player pause];
        self.currentURL = nil;
        self.retryAfter = CFAbsoluteTimeGetCurrent() + 2.0;
        [self clearFrame];
        return;
    }

    CMTime itemTime = [self.videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (![self.videoOutput hasNewPixelBufferForItemTime:itemTime]) return;
    CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (!pixelBuffer) return;
    @synchronized (self) {
        if (_latestPixelBuffer) CVPixelBufferRelease(_latestPixelBuffer);
        _latestPixelBuffer = pixelBuffer; // copyPixelBuffer already returned +1.
        _latestFrameTime = CFAbsoluteTimeGetCurrent();
        _state = @"receiving video frames";
    }
}

- (CVPixelBufferRef)copyFreshFrame {
    @synchronized (self) {
        if (!_latestPixelBuffer || CFAbsoluteTimeGetCurrent() - _latestFrameTime > 2.0) return NULL;
        return CVPixelBufferRetain(_latestPixelBuffer);
    }
}

- (CMSampleBufferRef)copyReplacementForSample:(CMSampleBufferRef)sample CF_RETURNS_RETAINED {
    CVPixelBufferRef source = [self copyFreshFrame];
    if (!source) return NULL;
    CVPixelBufferRef original = CMSampleBufferGetImageBuffer(sample);
    if (!original || CVPixelBufferGetPixelFormatType(original) != kCVPixelFormatType_32BGRA) {
        CVPixelBufferRelease(source);
        @synchronized (self) { _state = @"camera output is not BGRA; passing through"; }
        return NULL;
    }

    size_t width = CVPixelBufferGetWidth(original), height = CVPixelBufferGetHeight(original);
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef target = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attributes, &target);
    if (result != kCVReturnSuccess || !target) {
        CVPixelBufferRelease(source);
        return NULL;
    }

    // Aspect-fill the OBS picture into the camera's dimensions, preserving orientation.
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    CGRect extent = image.extent;
    if (CGRectGetWidth(extent) <= 0 || CGRectGetHeight(extent) <= 0) {
        CVPixelBufferRelease(source);
        CVPixelBufferRelease(target);
        return NULL;
    }
    CGFloat scale = MAX((CGFloat)width / CGRectGetWidth(extent), (CGFloat)height / CGRectGetHeight(extent));
    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGFloat dx = (CGFloat)width / 2 - CGRectGetMidX(scaled.extent);
    CGFloat dy = (CGFloat)height / 2 - CGRectGetMidY(scaled.extent);
    CIImage *centered = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [self.context render:centered toCVPixelBuffer:target bounds:CGRectMake(0, 0, width, height) colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferRelease(source);

    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef replacement = NULL;
    CMSampleTimingInfo timing = {0};
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, target, &format);
    if (status == noErr) status = CMSampleBufferGetSampleTimingInfo(sample, 0, &timing);
    if (status == noErr) {
        status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, target, format, &timing, &replacement);
    }
    if (format) CFRelease(format);
    CVPixelBufferRelease(target);
    if (status != noErr) return NULL;
    @synchronized (self) { _replacedCount++; }
    return replacement;
}

- (UIWindow *)activeWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)installButtonIfNeeded {
    UIWindow *window = [self activeWindow];
    if (!window || [window viewWithTag:902174]) return;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = 902174;
    button.frame = CGRectMake(window.bounds.size.width - 64, 130, 52, 52);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    button.backgroundColor = [UIColor colorWithRed:0.12 green:0.18 blue:0.25 alpha:0.85];
    button.layer.cornerRadius = 26;
    [button setTitle:@"OBS" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:button];
}

- (void)showSettings {
    UIWindow *window = [self activeWindow];
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if (!controller) return;
    NSDictionary *status = CBStatusSnapshot();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Camera Bridge"
        message:[NSString stringWithFormat:@"状态：%@\n相机回调：%@（%@）\n替换帧数：%@",
                 status[@"state"], status[@"cameraFrames"], status[@"pixelFormat"], status[@"frames"]]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"http://电脑IP:8888/obs/index.m3u8";
        field.text = [NSUserDefaults.standardUserDefaults stringForKey:CBStreamURLKey];
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *url = alert.textFields.firstObject.text ?: @"";
        [NSUserDefaults.standardUserDefaults setObject:url forKey:CBStreamURLKey];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:CBEnabledKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:CBEnabledKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@end

@interface CBDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id<AVCaptureVideoDataOutputSampleBufferDelegate> original;
@end

@implementation CBDelegateProxy

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    CBReceiver *receiver = [CBReceiver shared];
    CVPixelBufferRef originalBuffer = CMSampleBufferGetImageBuffer(sample);
    @synchronized (receiver) {
        receiver.cameraCallbackCount++;
        if (originalBuffer) receiver.cameraPixelFormat = CVPixelBufferGetPixelFormatType(originalBuffer);
    }
    CMSampleBufferRef replacement = NULL;
    if ([NSUserDefaults.standardUserDefaults boolForKey:CBEnabledKey]) {
        replacement = [receiver copyReplacementForSample:sample];
    }
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.original;
    if ([delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [delegate captureOutput:output didOutputSampleBuffer:(replacement ?: sample) fromConnection:connection];
    }
    if (replacement) CFRelease(replacement);
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.original;
    if ([delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [delegate captureOutput:output didDropSampleBuffer:sample fromConnection:connection];
    }
}

@end

static char CBProxyAssociation;
static void (*CBOriginalSetDelegate)(id, SEL, id, dispatch_queue_t);

static void CBSetDelegate(id output, SEL selector, id delegate, dispatch_queue_t queue) {
    if (!delegate) {
        objc_setAssociatedObject(output, &CBProxyAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CBOriginalSetDelegate(output, selector, nil, queue);
        return;
    }
    CBDelegateProxy *proxy = [CBDelegateProxy new];
    proxy.original = delegate;
    objc_setAssociatedObject(output, &CBProxyAssociation, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CBOriginalSetDelegate(output, selector, proxy, queue);
    dispatch_async(dispatch_get_main_queue(), ^{ [[CBReceiver shared] startOnMainThread]; });
}

NSDictionary<NSString *, id> *CBStatusSnapshot(void) {
    CBReceiver *receiver = [CBReceiver shared];
    @synchronized (receiver) {
        return @{ @"state": receiver.state ?: @"unknown",
                  @"frames": @(receiver.replacedCount),
                  @"cameraFrames": @(receiver.cameraCallbackCount),
                  @"pixelFormat": receiver.cameraPixelFormat == kCVPixelFormatType_32BGRA ? @"BGRA" : [NSString stringWithFormat:@"0x%08x", (unsigned int)receiver.cameraPixelFormat],
                  @"url": receiver.currentURL ?: @"" };
    }
}

__attribute__((constructor)) static void CBInstallHook(void) {
    Method method = class_getInstanceMethod(AVCaptureVideoDataOutput.class, @selector(setSampleBufferDelegate:queue:));
    if (!method) return;
    CBOriginalSetDelegate = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)CBSetDelegate);
}
