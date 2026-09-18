#import "ViewController.h"
#import "CameraBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate, UITextFieldDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) CFTimeInterval lastPreviewTime;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.context = [CIContext contextWithOptions:nil];

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"Camera Bridge 测试 App";
    titleLabel.font = [UIFont boldSystemFontOfSize:21];

    self.urlField = [UITextField new];
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.placeholder = @"http://电脑IP:8888/obs/index.m3u8";
    self.urlField.text = [NSUserDefaults.standardUserDefaults stringForKey:CBStreamURLKey];
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.delegate = self;

    UILabel *switchLabel = [UILabel new];
    switchLabel.text = @"替换摄像头画面";
    self.enabledSwitch = [UISwitch new];
    self.enabledSwitch.on = [NSUserDefaults.standardUserDefaults boolForKey:CBEnabledKey];
    [self.enabledSwitch addTarget:self action:@selector(saveSettings) forControlEvents:UIControlEventValueChanged];
    UIStackView *switchRow = [[UIStackView alloc] initWithArrangedSubviews:@[switchLabel, self.enabledSwitch]];
    switchRow.axis = UILayoutConstraintAxisHorizontal;
    switchRow.distribution = UIStackViewDistributionEqualSpacing;

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"等待相机权限…";
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.numberOfLines = 0;

    self.imageView = [UIImageView new];
    self.imageView.backgroundColor = UIColor.blackColor;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.imageView.heightAnchor constraintEqualToConstant:420].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, self.urlField, switchRow, self.statusLabel, self.imageView]];
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

- (void)saveSettings {
    [NSUserDefaults.standardUserDefaults setObject:self.urlField.text ?: @"" forKey:CBStreamURLKey];
    [NSUserDefaults.standardUserDefaults setBool:self.enabledSwitch.isOn forKey:CBEnabledKey];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self saveSettings];
    return YES;
}

- (void)updateStatus {
    NSDictionary *status = CBStatusSnapshot();
    self.statusLabel.text = [NSString stringWithFormat:@"状态：%@\n相机回调：%@（%@）  已替换帧：%@",
                             status[@"state"], status[@"cameraFrames"], status[@"pixelFormat"], status[@"frames"]];
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
