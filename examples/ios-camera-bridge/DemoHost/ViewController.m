#import "ViewController.h"
#import "CameraBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) CFTimeInterval lastPreviewTime;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.context = [CIContext contextWithOptions:nil];

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"Camera Bridge";
    titleLabel.font = [UIFont boldSystemFontOfSize:21];

    UILabel *hint = [UILabel new];
    hint.text = @"点右侧 OBS 设置画面源；可拖动按钮避开预览。";
    hint.textColor = UIColor.secondaryLabelColor;
    hint.font = [UIFont systemFontOfSize:13];
    hint.numberOfLines = 2;

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"等待相机权限…";
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.numberOfLines = 0;

    self.imageView = [UIImageView new];
    self.imageView.backgroundColor = UIColor.blackColor;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.imageView.heightAnchor constraintEqualToConstant:420].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, hint, self.statusLabel, self.imageView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];

    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateStatus) userInfo:nil repeats:YES];
    [self requestCamera];
}

- (void)updateStatus {
    NSDictionary *status = CBStatusSnapshot();
    self.statusLabel.text = [NSString stringWithFormat:
        @"状态：%@\n接收 %.1f 帧/秒 · 替换 %.1f 帧/秒\n相机 %@ · 累计替换 %@ 帧 · 黑帧 %@",
        status[@"state"], [status[@"receivedFPS"] doubleValue], [status[@"replacedFPS"] doubleValue],
        status[@"pixelFormat"], status[@"frames"], status[@"blackFrames"]];
}

- (void)requestCamera {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self configureCamera];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            if (granted) [self configureCamera];
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = @"请在系统设置中允许此 App 使用摄像头"; });
    }
}

- (void)configureCamera {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!device) return;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL];
        if (!input) return;
        AVCaptureSession *session = [AVCaptureSession new];
        session.sessionPreset = AVCaptureSessionPreset1280x720;
        if ([session canAddInput:input]) [session addInput:input];
        AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
        output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        output.alwaysDiscardsLateVideoFrames = YES;
        if ([session canAddOutput:output]) [session addOutput:output];
        AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
        if (connection.isVideoOrientationSupported) connection.videoOrientation = AVCaptureVideoOrientationPortrait;
        dispatch_queue_t queue = dispatch_queue_create("camera-bridge.preview", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:self queue:queue];
        self.session = session;
        [session startRunning];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastPreviewTime < 0.10) return; // Avoid UI work on every camera frame.
    self.lastPreviewTime = now;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    if (!buffer) return;
    CIImage *image = [CIImage imageWithCVPixelBuffer:buffer];
    CGImageRef cgImage = [self.context createCGImage:image fromRect:image.extent];
    if (!cgImage) return;
    UIImage *uiImage = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    dispatch_async(dispatch_get_main_queue(), ^{ self.imageView.image = uiImage; });
}

@end
