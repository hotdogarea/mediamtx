#import "CameraBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

NSString * const CBStreamURLKey = @"CameraBridge.StreamURL";
NSString * const CBEnabledKey = @"CameraBridge.Enabled";
NSString * const CBRotationKey = @"CameraBridge.Rotation";

NSString *CBNormalizedStreamURL(NSString *input) {
    NSString *value = [input ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return nil;
    if (![value containsString:@"://"]) {
        // The common case needs only the PC's LAN IP, not a 40-character URL.
        if ([value containsString:@"/"] || [value containsString:@"?"] || [value containsString:@"#"]) return nil;
        value = [NSString stringWithFormat:@"http://%@%@/obs/index.m3u8", value,
                 [value containsString:@":"] ? @"" : @":8888"];
    }
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if ([parts.path isEqualToString:@"/obs"] || [parts.path isEqualToString:@"/obs/"]) {
        parts.path = @"/obs/index.m3u8";
    }
    NSURL *url = parts.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if ((! [scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) ||
        !url.host.length || ![url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) return nil;
    return url.absoluteString;
}

static uint8_t CBClampByte(int value) {
    return (uint8_t)MAX(0, MIN(255, value));
}

static void CBFillBlack(CVPixelBufferRef buffer, OSType format) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    if (format == kCVPixelFormatType_32BGRA) {
        uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        for (size_t y = 0; y < height; y++) {
            uint8_t *row = base + y * stride;
            for (size_t x = 0; x < width; x++) {
                row[x * 4] = row[x * 4 + 1] = row[x * 4 + 2] = 0;
                row[x * 4 + 3] = 255;
            }
        }
    } else {
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        memset(luma, format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0, yStride * height);
        memset(chroma, 128, uvStride * CVPixelBufferGetHeightOfPlane(buffer, 1));
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

static void CBConvertBGRAtoNV12(CVPixelBufferRef bgra, CVPixelBufferRef nv12, BOOL videoRange) {
    CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(nv12, 0);
    const uint8_t *source = CVPixelBufferGetBaseAddress(bgra);
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(nv12, 0);
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(nv12, 1);
    size_t width = CVPixelBufferGetWidth(nv12), height = CVPixelBufferGetHeight(nv12);
    size_t sourceStride = CVPixelBufferGetBytesPerRow(bgra);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1);
    for (size_t y = 0; y < height; y += 2) {
        for (size_t x = 0; x < width; x += 2) {
            int red = 0, green = 0, blue = 0, samples = 0;
            for (size_t dy = 0; dy < 2 && y + dy < height; dy++) {
                for (size_t dx = 0; dx < 2 && x + dx < width; dx++) {
                    const uint8_t *pixel = source + (y + dy) * sourceStride + (x + dx) * 4;
                    int b = pixel[0], g = pixel[1], r = pixel[2];
                    luma[(y + dy) * yStride + x + dx] = videoRange
                        ? CBClampByte(16 + ((66 * r + 129 * g + 25 * b + 128) >> 8))
                        : CBClampByte((77 * r + 150 * g + 29 * b + 128) >> 8);
                    red += r; green += g; blue += b; samples++;
                }
            }
            int r = red / samples, g = green / samples, b = blue / samples;
            size_t uvIndex = (y / 2) * uvStride + x;
            chroma[uvIndex] = CBClampByte(128 + ((-38 * r - 74 * g + 112 * b + 128) >> 8));
            if (x + 1 < uvStride) chroma[uvIndex + 1] = CBClampByte(128 + ((112 * r - 94 * g - 18 * b + 128) >> 8));
        }
    }
    CVPixelBufferUnlockBaseAddress(nv12, 0);
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
}

@interface CBReceiver : NSObject
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, copy) NSString *currentURL;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, assign) CVPixelBufferRef latestPixelBuffer;
@property (nonatomic, assign) CFAbsoluteTime latestFrameTime;
@property (nonatomic, assign) NSUInteger replacedCount;
@property (nonatomic, assign) NSUInteger receivedCount;
@property (nonatomic, assign) NSUInteger cameraCallbackCount;
@property (nonatomic, assign) OSType cameraPixelFormat;
@property (nonatomic, assign) NSUInteger reconnectCount;
@property (nonatomic, assign) NSUInteger placeholderCount;
@property (nonatomic, assign) NSUInteger previousReceivedCount;
@property (nonatomic, assign) NSUInteger previousReplacedCount;
@property (nonatomic, assign) CFTimeInterval lastMetricsTime;
@property (nonatomic, assign) double receivedFPS;
@property (nonatomic, assign) double replacedFPS;
@property (nonatomic, assign) double networkBitrate;
@property (nonatomic, assign) double videoBitrate;
@property (nonatomic, assign) double audioBitrate;
@property (nonatomic, assign) BOOL audioTrackDetected;
@property (nonatomic, assign) BOOL audioTrackChecked;
@property (nonatomic, assign) double liveEdgeLag;
@property (nonatomic, assign) double peakLiveEdgeLag;
@property (nonatomic, assign) NSInteger playerStalls;
@property (nonatomic, assign) NSInteger droppedFrames;
@property (nonatomic, assign) CFTimeInterval lastControlCheck;
@property (nonatomic, assign) CFAbsoluteTime lastConnectTime;
@property (nonatomic, assign) CFAbsoluteTime retryAfter;
@property (nonatomic, copy) NSString *state;
+ (instancetype)shared;
- (void)startOnMainThread;
- (CVPixelBufferRef)copyFreshFrame CF_RETURNS_RETAINED;
- (CMSampleBufferRef)copyReplacementForSample:(CMSampleBufferRef)sample placeholder:(BOOL *)placeholder CF_RETURNS_RETAINED;
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
        _networkBitrate = -1;
        _videoBitrate = -1;
        _audioBitrate = -1;
        _liveEdgeLag = -1;
        _peakLiveEdgeLag = -1;
        _playerStalls = -1;
        _droppedFrames = -1;
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
    CBInstallControlsIfNeeded();
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
    if (link.timestamp - self.lastControlCheck > 1.0) {
        self.lastControlCheck = link.timestamp;
        CBInstallControlsIfNeeded();
    }
    if (link.timestamp - self.lastMetricsTime >= 1.0) {
        @synchronized (self) {
            CFTimeInterval elapsed = self.lastMetricsTime > 0 ? link.timestamp - self.lastMetricsTime : 1.0;
            self.receivedFPS = (self.receivedCount - self.previousReceivedCount) / elapsed;
            self.replacedFPS = (self.replacedCount - self.previousReplacedCount) / elapsed;
            self.previousReceivedCount = self.receivedCount;
            self.previousReplacedCount = self.replacedCount;
            self.lastMetricsTime = link.timestamp;
        }
        AVPlayerItem *item = self.player.currentItem;
        AVPlayerItemAccessLogEvent *event = item.accessLog.events.lastObject;
        self.networkBitrate = event ? event.observedBitrate : -1;
        self.videoBitrate = event ? event.averageVideoBitrate : -1;
        self.audioBitrate = event ? event.averageAudioBitrate : -1;
        self.playerStalls = event ? event.numberOfStalls : -1;
        self.droppedFrames = event ? event.numberOfDroppedVideoFrames : -1;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            BOOL hasAudioTrack = NO;
            for (AVPlayerItemTrack *track in item.tracks) {
                if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeAudio]) {
                    hasAudioTrack = YES;
                    break;
                }
            }
            self.audioTrackDetected = hasAudioTrack || self.audioBitrate > 0;
            self.audioTrackChecked = item.tracks.count > 0 || self.audioBitrate > 0;
        }
        NSValue *lastRange = item.seekableTimeRanges.lastObject;
        double liveEdge = NAN;
        if (lastRange) liveEdge = CMTimeGetSeconds(CMTimeRangeGetEnd(lastRange.CMTimeRangeValue));
        double playhead = item ? CMTimeGetSeconds(item.currentTime) : NAN;
        if (isfinite(liveEdge) && isfinite(playhead) && liveEdge >= playhead && liveEdge - playhead < 3600) {
            self.liveEdgeLag = liveEdge - playhead;
            self.peakLiveEdgeLag = MAX(self.peakLiveEdgeLag, self.liveEdgeLag);
        } else {
            self.liveEdgeLag = -1;
        }
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *urlString = CBNormalizedStreamURL([defaults stringForKey:CBStreamURLKey]);
    BOOL enabled = [defaults boolForKey:CBEnabledKey];

    if (!enabled || !urlString) {
        if (self.player) [self.player pause];
        self.player = nil;
        self.videoOutput = nil;
        self.currentURL = nil;
        self.state = enabled ? @"invalid URL" : @"disabled";
        [self clearFrame];
        return;
    }

    if (![self.currentURL isEqualToString:urlString]) {
        if (CFAbsoluteTimeGetCurrent() < self.retryAfter) return;
        [self clearFrame];
        self.currentURL = urlString;
        self.lastConnectTime = CFAbsoluteTimeGetCurrent();
        self.audioTrackChecked = NO;
        self.audioTrackDetected = NO;
        self.audioBitrate = -1;
        self.liveEdgeLag = -1;
        self.peakLiveEdgeLag = -1;
        NSURL *url = [NSURL URLWithString:urlString];
        NSDictionary *attributes = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        [item addOutput:self.videoOutput];
        item.preferredForwardBufferDuration = 0;
        self.player = [AVPlayer playerWithPlayerItem:item];
        self.player.muted = YES; // Only video frames are replaced; the microphone is untouched.
        self.player.automaticallyWaitsToMinimizeStalling = YES;
        [self.player play];
        self.state = @"connecting to HLS";
    }

    if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
        self.state = self.player.currentItem.error.localizedDescription ?: @"HLS playback failed";
        self.reconnectCount++;
        [self.player pause];
        self.currentURL = nil; // Allow a later retry when OBS comes back.
        self.retryAfter = CFAbsoluteTimeGetCurrent() + 2.0;
        return;
    }

    CFAbsoluteTime mostRecentFrame;
    @synchronized (self) { mostRecentFrame = self.latestFrameTime; }
    CFTimeInterval frameTimeout = 12.0;
    if (CFAbsoluteTimeGetCurrent() - MAX(self.lastConnectTime, mostRecentFrame) > frameTimeout) {
        self.state = @"HLS stalled; reconnecting";
        self.reconnectCount++;
        [self.player pause];
        self.currentURL = nil;
        self.retryAfter = CFAbsoluteTimeGetCurrent() + 1.0;
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
        _receivedCount++;
        _state = @"receiving video frames";
    }
}

- (CVPixelBufferRef)copyFreshFrame {
    @synchronized (self) {
        if (!_latestPixelBuffer || CFAbsoluteTimeGetCurrent() - _latestFrameTime > 5.0) return NULL;
        return CVPixelBufferRetain(_latestPixelBuffer);
    }
}

- (CMSampleBufferRef)copyReplacementForSample:(CMSampleBufferRef)sample placeholder:(BOOL *)placeholder CF_RETURNS_RETAINED {
    if (placeholder) *placeholder = NO;
    CVPixelBufferRef original = CMSampleBufferGetImageBuffer(sample);
    if (!original) return NULL;
    OSType formatType = CVPixelBufferGetPixelFormatType(original);
    if (formatType != kCVPixelFormatType_32BGRA &&
        formatType != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        formatType != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        @synchronized (self) { _state = @"unsupported camera pixel format"; }
        return NULL;
    }

    size_t width = CVPixelBufferGetWidth(original), height = CVPixelBufferGetHeight(original);
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(formatType),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef target = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, formatType,
                                          (__bridge CFDictionaryRef)attributes, &target);
    if (result != kCVReturnSuccess || !target) return NULL;
    CVBufferPropagateAttachments(original, target);

    CVPixelBufferRef source = [self copyFreshFrame];
    if (source) {
        BOOL rendered = NO;
        CIImage *image = [CIImage imageWithCVPixelBuffer:source];
        NSInteger degrees = [NSUserDefaults.standardUserDefaults integerForKey:CBRotationKey];
        if (degrees == 90 || degrees == 180 || degrees == 270) {
            image = [image imageByApplyingTransform:CGAffineTransformMakeRotation((CGFloat)degrees * (CGFloat)M_PI / 180.0)];
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
        }
        CGRect extent = image.extent;
        if (CGRectGetWidth(extent) > 0 && CGRectGetHeight(extent) > 0) {
            CGFloat scale = MAX((CGFloat)width / CGRectGetWidth(extent), (CGFloat)height / CGRectGetHeight(extent));
            CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
            CGFloat dx = (CGFloat)width / 2 - CGRectGetMidX(scaled.extent);
            CGFloat dy = (CGFloat)height / 2 - CGRectGetMidY(scaled.extent);
            CIImage *centered = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
            CVPixelBufferRef renderTarget = target;
            if (formatType != kCVPixelFormatType_32BGRA) {
                NSDictionary *bgraAttributes = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferWidthKey: @(width),
                    (id)kCVPixelBufferHeightKey: @(height),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
                };
                if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)bgraAttributes, &renderTarget) != kCVReturnSuccess) {
                    renderTarget = NULL;
                }
            }
            if (renderTarget) {
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                [self.context render:centered toCVPixelBuffer:renderTarget bounds:CGRectMake(0, 0, width, height) colorSpace:colorSpace];
                CGColorSpaceRelease(colorSpace);
                if (renderTarget != target) {
                    CBConvertBGRAtoNV12(renderTarget, target, formatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
                    CVPixelBufferRelease(renderTarget);
                }
                rendered = YES;
            } else {
                CVPixelBufferRelease(source);
                CVPixelBufferRelease(target);
                return NULL;
            }
        }
        CVPixelBufferRelease(source);
        if (!rendered) {
            CBFillBlack(target, formatType);
            if (placeholder) *placeholder = YES;
            @synchronized (self) { _placeholderCount++; }
        }
    } else {
        // Never reveal the physical camera during a network interruption.
        CBFillBlack(target, formatType);
        if (placeholder) *placeholder = YES;
        @synchronized (self) { _placeholderCount++; }
    }

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
    @synchronized (self) { if (!placeholder || !*placeholder) _replacedCount++; }
    return replacement;
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
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:CBEnabledKey];
    BOOL placeholder = NO;
    CMSampleBufferRef replacement = enabled ? [receiver copyReplacementForSample:sample placeholder:&placeholder] : NULL;
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.original;
    // Fail closed: do not pass the real camera through when replacement is enabled.
    if ((!enabled || replacement) && [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
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
        CFTimeInterval age = receiver.latestFrameTime > 0 ? CFAbsoluteTimeGetCurrent() - receiver.latestFrameTime : -1;
        OSType pixelFormat = receiver.cameraPixelFormat;
        BOOL supportedFormat = pixelFormat == kCVPixelFormatType_32BGRA ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        NSString *pixelFormatLabel = pixelFormat == kCVPixelFormatType_32BGRA ? @"BGRA" :
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? @"NV12 full" :
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? @"NV12 video" :
            [NSString stringWithFormat:@"0x%08x", (unsigned int)pixelFormat]));
        return @{ @"state": receiver.state ?: @"unknown",
                  @"frames": @(receiver.replacedCount),
                  @"receivedFrames": @(receiver.receivedCount),
                  @"receivedFPS": @(receiver.receivedFPS),
                  @"replacedFPS": @(receiver.replacedFPS),
                  @"frameAge": @(age),
                  @"blackFrames": @(receiver.placeholderCount),
                  @"reconnects": @(receiver.reconnectCount),
                  @"networkBitrate": @(receiver.networkBitrate),
                  @"videoBitrate": @(receiver.videoBitrate),
                  @"audioBitrate": @(receiver.audioBitrate),
                  @"audioTrackDetected": @(receiver.audioTrackDetected),
                  @"audioTrackChecked": @(receiver.audioTrackChecked),
                  @"liveEdgeLag": @(receiver.liveEdgeLag),
                  @"peakLiveEdgeLag": @(receiver.peakLiveEdgeLag),
                  @"playerStalls": @(receiver.playerStalls),
                  @"droppedFrames": @(receiver.droppedFrames),
                  @"cameraFrames": @(receiver.cameraCallbackCount),
                  @"supportedCameraFormat": @(supportedFormat),
                  @"pixelFormat": pixelFormatLabel,
                  @"url": receiver.currentURL ?: @"" };
    }
}

__attribute__((constructor)) static void CBInstallHook(void) {
    Method method = class_getInstanceMethod(AVCaptureVideoDataOutput.class, @selector(setSampleBufferDelegate:queue:));
    if (!method) return;
    CBOriginalSetDelegate = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)CBSetDelegate);
    dispatch_async(dispatch_get_main_queue(), ^{ [[CBReceiver shared] startOnMainThread]; });
}
