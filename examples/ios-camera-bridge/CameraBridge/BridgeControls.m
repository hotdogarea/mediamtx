#import "CameraBridge.h"
#import "BolemeLicense.h"
#import "BolemeDiagnostics.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSInteger const CBBubbleTag = 902174;

@interface CBLevelIconView : UIView
@property (nonatomic, copy) NSString *outlineSymbol;
@property (nonatomic, copy) NSString *filledSymbol;
@property (nonatomic, assign) CGFloat level;
@property (nonatomic, strong) UIColor *activeColor;
- (instancetype)initWithOutline:(NSString *)outline filled:(NSString *)filled;
@end

@implementation CBLevelIconView

- (instancetype)initWithOutline:(NSString *)outline filled:(NSString *)filled {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _outlineSymbol = [outline copy];
        _filledSymbol = [filled copy];
        _activeColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1];
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.isAccessibilityElement = YES;
    }
    return self;
}

- (void)setLevel:(CGFloat)level {
    CGFloat normalized = MAX(0, MIN(1, level));
    if (fabs(_level - normalized) < 0.003) return;
    _level = normalized;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGFloat pointSize = MAX(11, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) - 4);
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                                  weight:UIImageSymbolWeightSemibold];
    UIImage *outline = [[UIImage systemImageNamed:self.outlineSymbol withConfiguration:configuration]
        imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.52] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *filled = [[UIImage systemImageNamed:self.filledSymbol withConfiguration:configuration]
        imageWithTintColor:self.activeColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGSize imageSize = outline.size;
    CGFloat scale = MIN(CGRectGetWidth(rect) / MAX(1, imageSize.width),
                        CGRectGetHeight(rect) / MAX(1, imageSize.height));
    CGSize fitted = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    CGRect imageRect = CGRectMake(CGRectGetMidX(rect) - fitted.width / 2,
                                  CGRectGetMidY(rect) - fitted.height / 2,
                                  fitted.width, fitted.height);
    [outline drawInRect:imageRect];
    if (self.level <= 0) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGFloat fillHeight = CGRectGetHeight(imageRect) * self.level;
    CGContextClipToRect(context, CGRectMake(CGRectGetMinX(imageRect), CGRectGetMaxY(imageRect) - fillHeight,
                                            CGRectGetWidth(imageRect), fillHeight));
    [filled drawInRect:imageRect];
    CGContextRestoreGState(context);
}

@end

@interface CBControls : NSObject <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, weak) UIButton *bubble;
@property (nonatomic, weak) UIView *statusDot;
@property (nonatomic, strong) CBLevelIconView *bubbleSpeakerIcon;
@property (nonatomic, strong) CBLevelIconView *bubbleMicrophoneIcon;
@property (nonatomic, strong) CBLevelIconView *headerSpeakerIcon;
@property (nonatomic, strong) CBLevelIconView *headerMicrophoneIcon;
@property (nonatomic, strong) UIView *shade;
@property (nonatomic, weak) UIView *card;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISegmentedControl *rotationControl;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *metricsLabel;
@property (nonatomic, strong) UILabel *videoSummaryLabel;
@property (nonatomic, strong) UILabel *audioLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UIStackView *videoPanel;
@property (nonatomic, strong) UIStackView *audioPanel;
@property (nonatomic, strong) UIStackView *licensePanel;
@property (nonatomic, strong) UILabel *licenseStateLabel;
@property (nonatomic, strong) UILabel *licenseDetailLabel;
@property (nonatomic, strong) UILabel *licenseMessageLabel;
@property (nonatomic, strong) UITextField *licenseCodeField;
@property (nonatomic, strong) UIButton *licenseButton;
@property (nonatomic, strong) UISegmentedControl *audioModeControl;
@property (nonatomic, strong) UILabel *audioModeLabel;
@property (nonatomic, strong) UILabel *audioRouteLabel;
@property (nonatomic, strong) UILabel *audioWarningLabel;
@property (nonatomic, strong) CBLevelIconView *speakerIcon;
@property (nonatomic, strong) CBLevelIconView *microphoneIcon;
@property (nonatomic, strong) UILabel *speakerTitleLabel;
@property (nonatomic, strong) UILabel *speakerDetailLabel;
@property (nonatomic, strong) UILabel *microphoneTitleLabel;
@property (nonatomic, strong) UILabel *microphoneDetailLabel;
@property (nonatomic, strong) UIProgressView *speakerMeter;
@property (nonatomic, strong) UIProgressView *microphoneMeter;
@property (nonatomic, strong) UIButton *diagnosticsDisclosureButton;
@property (nonatomic, strong) UIStackView *diagnosticsPanel;
@property (nonatomic, strong) UITextView *diagnosticsTextView;
@property (nonatomic, strong) UIButton *copyDiagnosticsButton;
@property (nonatomic, assign) BOOL diagnosticsExpanded;
@property (nonatomic, strong) NSTimer *meterTimer;
+ (instancetype)shared;
- (void)installIfNeeded;
@end

@implementation CBControls

+ (instancetype)shared {
    static CBControls *controls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controls = [CBControls new]; });
    return controls;
}

- (BOOL)isUsableHostWindow:(UIWindow *)window {
    if (!window || window.hidden || window.alpha <= 0.01 || !window.rootViewController || CGRectIsEmpty(window.bounds)) {
        return NO;
    }

    // Never attach controls to transient UIKit-owned input/status windows. Douyin can
    // create another application window for the live page, which is intentionally kept.
    NSString *className = NSStringFromClass(window.class);
    NSArray<NSString *> *excludedFragments = @[
        @"Keyboard", @"TextEffects", @"InputSet", @"StatusBar", @"RemoteKeyboard"
    ];
    for (NSString *fragment in excludedFragments) {
        if ([className rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return NO;
        }
    }
    return YES;
}

- (UIWindow *)frontmostWindow:(NSArray<UIWindow *> *)windows {
    UIWindow *frontmost = nil;
    for (UIWindow *window in windows) {
        if (![self isUsableHostWindow:window]) continue;

        // UIKit keeps windows ordered back-to-front. Taking the last window at the
        // highest level follows full-screen live/recording pages even when they are
        // not marked as the key window yet.
        if (!frontmost || window.windowLevel >= frontmost.windowLevel) {
            frontmost = window;
        }
    }
    return frontmost;
}

- (UIWindow *)activeWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindow *window = [self frontmostWindow:((UIWindowScene *)scene).windows];
        if (window) return window;
    }
    return [self frontmostWindow:UIApplication.sharedApplication.windows];
}

- (void)installIfNeeded {
    UIWindow *window = [self activeWindow];
    if (!window) return;
    if (window != self.hostWindow || !self.bubble) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
        [self.shade removeFromSuperview];
        self.shade = nil;
        [self.bubble removeFromSuperview];
        self.hostWindow = window;

        UIButton *bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        bubble.tag = CBBubbleTag;
        bubble.frame = CGRectMake(0, 0, 116, 48);
        bubble.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.14 alpha:0.82];
        bubble.layer.cornerRadius = 24;
        bubble.layer.borderWidth = 1;
        bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.20].CGColor;
        [bubble setTitle:@"播了么" forState:UIControlStateNormal];
        [bubble setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        bubble.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        bubble.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        bubble.contentEdgeInsets = UIEdgeInsetsMake(0, 13, 0, 48);
        bubble.accessibilityLabel = @"播了么推流助手，可拖动位置";
        [bubble addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
        [bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBubble:)]];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(67, 9, 6, 6)];
        dot.layer.cornerRadius = 3.5;
        dot.backgroundColor = UIColor.systemGrayColor;
        dot.userInteractionEnabled = NO;
        [bubble addSubview:dot];
        self.statusDot = dot;
        CBLevelIconView *speaker = [[CBLevelIconView alloc] initWithOutline:@"speaker.wave.2" filled:@"speaker.wave.2.fill"];
        speaker.frame = CGRectMake(76, 16, 16, 16);
        speaker.userInteractionEnabled = NO;
        [bubble addSubview:speaker];
        self.bubbleSpeakerIcon = speaker;
        CBLevelIconView *microphone = [[CBLevelIconView alloc] initWithOutline:@"mic" filled:@"mic.fill"];
        microphone.frame = CGRectMake(96, 16, 14, 16);
        microphone.userInteractionEnabled = NO;
        [bubble addSubview:microphone];
        self.bubbleMicrophoneIcon = microphone;
        BOOL left = [NSUserDefaults.standardUserDefaults boolForKey:@"CameraBridge.BubbleLeft"];
        CGFloat fraction = [NSUserDefaults.standardUserDefaults objectForKey:@"CameraBridge.BubbleY"]
            ? [NSUserDefaults.standardUserDefaults doubleForKey:@"CameraBridge.BubbleY"] : 0.72;
        CGFloat centerY = MAX(window.safeAreaInsets.top + 36,
                              MIN(window.bounds.size.height - window.safeAreaInsets.bottom - 36,
                                  window.bounds.size.height * fraction));
        bubble.center = CGPointMake(left ? 68 : window.bounds.size.width - 68, centerY);
        [window addSubview:bubble];
        self.bubble = bubble;
    }
    if (!self.meterTimer) {
        self.meterTimer = [NSTimer timerWithTimeInterval:0.08 target:self selector:@selector(refreshMeters)
                                                userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
    }

    // A live page can cover the existing controls with a newly-added full-screen
    // view without replacing its UIWindow. Restore our z-order on every health tick.
    if (self.shade && self.shade.superview == window) {
        [window bringSubviewToFront:self.shade];
    } else if (self.bubble && self.bubble.superview == window) {
        [window bringSubviewToFront:self.bubble];
    }
    [self refreshStatus];
}

- (void)dragBubble:(UIPanGestureRecognizer *)gesture {
    UIButton *bubble = self.bubble;
    UIWindow *window = self.hostWindow;
    if (!bubble || !window) return;
    CGPoint movement = [gesture translationInView:window];
    bubble.center = CGPointMake(MAX(68, MIN(window.bounds.size.width - 68, bubble.center.x + movement.x)),
                                MAX(window.safeAreaInsets.top + 36,
                                    MIN(window.bounds.size.height - window.safeAreaInsets.bottom - 36,
                                        bubble.center.y + movement.y)));
    [gesture setTranslation:CGPointZero inView:window];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        BOOL left = bubble.center.x < window.bounds.size.width / 2;
        [UIView animateWithDuration:0.18 animations:^{
            bubble.center = CGPointMake(left ? 68 : window.bounds.size.width - 68, bubble.center.y);
        }];
        [NSUserDefaults.standardUserDefaults setBool:left forKey:@"CameraBridge.BubbleLeft"];
        [NSUserDefaults.standardUserDefaults setDouble:bubble.center.y / window.bounds.size.height forKey:@"CameraBridge.BubbleY"];
    }
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = color;
    label.font = [UIFont systemFontOfSize:size];
    return label;
}

- (void)dragPanel:(UIPanGestureRecognizer *)gesture {
    if (!self.card || !self.shade || !self.hostWindow) return;
    CGPoint movement = [gesture translationInView:self.shade];
    CGFloat top = self.hostWindow.safeAreaInsets.top + 8;
    CGFloat bottom = self.shade.bounds.size.height - self.hostWindow.safeAreaInsets.bottom - 8;
    CGFloat maximumTop = MAX(top, bottom - CGRectGetHeight(self.card.bounds));
    CGFloat currentTop = CGRectGetMinY(self.card.frame);
    CGFloat nextTop = MAX(top, MIN(maximumTop, currentTop + movement.y));
    self.card.transform = CGAffineTransformTranslate(self.card.transform, 0, nextTop - currentTop);
    [gesture setTranslation:CGPointZero inView:self.shade];
}

- (void)openPanel {
    UIWindow *window = self.hostWindow;
    if (!window || self.shade) return;
    UIView *shade = [[UIView alloc] initWithFrame:window.bounds];
    shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    UITapGestureRecognizer *outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePanel)];
    outsideTap.delegate = self;
    [shade addGestureRecognizer:outsideTap];
    [window addSubview:shade];
    self.shade = shade;

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.12 alpha:0.84];
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.13].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [shade addSubview:card];
    self.card = card;

    UILabel *title = [self label:[NSString stringWithFormat:@"播了么推流助手  v%@", BolemePluginVersion]
                              size:19 color:UIColor.whiteColor];
    title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    UILabel *dragHint = [self label:@"按住这里上下移动" size:11
                                  color:[UIColor colorWithWhite:1 alpha:0.55]];
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[title, dragHint]];
    heading.axis = UILayoutConstraintAxisVertical;
    heading.spacing = 0;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"完成" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:0.32 green:0.85 blue:0.70 alpha:1] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    close.accessibilityLabel = @"保存并关闭画面输入设置";
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    self.headerSpeakerIcon = [[CBLevelIconView alloc] initWithOutline:@"speaker.wave.2" filled:@"speaker.wave.2.fill"];
    self.headerSpeakerIcon.accessibilityLabel = @"当前声音输出通道";
    [self.headerSpeakerIcon.widthAnchor constraintEqualToConstant:24].active = YES;
    [self.headerSpeakerIcon.heightAnchor constraintEqualToConstant:24].active = YES;
    self.headerMicrophoneIcon = [[CBLevelIconView alloc] initWithOutline:@"mic" filled:@"mic.fill"];
    self.headerMicrophoneIcon.accessibilityLabel = @"当前麦克风输入通道";
    [self.headerMicrophoneIcon.widthAnchor constraintEqualToConstant:22].active = YES;
    [self.headerMicrophoneIcon.heightAnchor constraintEqualToConstant:24].active = YES;
    UIStackView *headerActions = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.headerSpeakerIcon, self.headerMicrophoneIcon, close
    ]];
    headerActions.axis = UILayoutConstraintAxisHorizontal;
    headerActions.alignment = UIStackViewAlignmentCenter;
    headerActions.spacing = 8;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[heading, headerActions]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.distribution = UIStackViewDistributionEqualSpacing;
    header.alignment = UIStackViewAlignmentCenter;
    [header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)]];
    [header.heightAnchor constraintEqualToConstant:40].active = YES;

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"画面", @"声音", @"授权"]];
    self.tabControl.selectedSegmentIndex = [BolemeLicenseManager shared].isAuthorized ? 0 : 2;
    self.tabControl.accessibilityLabel = @"切换画面、音频或授权设置";
    [self.tabControl addTarget:self action:@selector(changeTab) forControlEvents:UIControlEventValueChanged];
    [self.tabControl.heightAnchor constraintEqualToConstant:34].active = YES;

    self.stateLabel = [self label:@"等待画面…" size:14 color:UIColor.systemGrayColor];
    self.stateLabel.numberOfLines = 2;
    [self.stateLabel.heightAnchor constraintEqualToConstant:38].active = YES;
    self.videoSummaryLabel = [self label:@"分辨率：等待连接" size:13
                                        color:[UIColor colorWithWhite:1 alpha:0.82]];
    self.videoSummaryLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.videoSummaryLabel.heightAnchor constraintEqualToConstant:22].active = YES;

    self.addressField = [UITextField new];
    self.addressField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    self.addressField.textColor = UIColor.whiteColor;
    self.addressField.font = [UIFont systemFontOfSize:15];
    self.addressField.layer.cornerRadius = 10;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.addressField.returnKeyType = UIReturnKeyDone;
    self.addressField.delegate = self;
    self.addressField.accessibilityLabel = @"电脑 IP 或 HLS 播放地址";
    self.addressField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"电脑 IP 或 HLS 地址"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    UIView *leftPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    self.addressField.leftView = leftPadding;
    self.addressField.leftViewMode = UITextFieldViewModeAlways;
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:CBStreamURLKey] ?: @"";
    NSURL *savedURL = [NSURL URLWithString:saved];
    self.addressField.text = [savedURL.path isEqualToString:@"/obs/index.m3u8"] &&
        [savedURL.scheme isEqualToString:@"http"] && savedURL.port.integerValue == 8888 ? savedURL.host : saved;
    [self.addressField.heightAnchor constraintEqualToConstant:44].active = YES;

    UIButton *paste = [UIButton buttonWithType:UIButtonTypeSystem];
    [paste setTitle:@"粘贴" forState:UIControlStateNormal];
    [paste setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    paste.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    paste.layer.cornerRadius = 10;
    paste.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    paste.accessibilityLabel = @"从剪贴板粘贴播放地址";
    [paste addTarget:self action:@selector(pasteAddress) forControlEvents:UIControlEventTouchUpInside];
    [paste.widthAnchor constraintEqualToConstant:64].active = YES;
    UIStackView *inputRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.addressField, paste]];
    inputRow.axis = UILayoutConstraintAxisHorizontal;
    inputRow.spacing = 8;

    self.hintLabel = [self label:@"只填电脑 IP 即可；地址会自动保存" size:12
                                color:[UIColor colorWithWhite:1 alpha:0.52]];
    [self.hintLabel.heightAnchor constraintEqualToConstant:18].active = YES;

    UILabel *switchLabel = [self label:@"替换摄像头画面" size:15 color:UIColor.whiteColor];
    self.enabledSwitch = [UISwitch new];
    self.enabledSwitch.onTintColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1];
    self.enabledSwitch.on = [NSUserDefaults.standardUserDefaults boolForKey:CBEnabledKey];
    self.enabledSwitch.accessibilityLabel = @"启用或暂停 OBS 画面替换";
    [self.enabledSwitch addTarget:self action:@selector(toggleReplacement) forControlEvents:UIControlEventValueChanged];
    UIStackView *switchRow = [[UIStackView alloc] initWithArrangedSubviews:@[switchLabel, self.enabledSwitch]];
    switchRow.axis = UILayoutConstraintAxisHorizontal;
    switchRow.distribution = UIStackViewDistributionEqualSpacing;
    switchRow.alignment = UIStackViewAlignmentCenter;
    [switchRow.heightAnchor constraintEqualToConstant:44].active = YES;

    UILabel *rotationLabel = [self label:@"旋转" size:15 color:UIColor.whiteColor];
    self.rotationControl = [[UISegmentedControl alloc] initWithItems:@[@"0°", @"90°", @"180°", @"270°"]];
    self.rotationControl.selectedSegmentIndex = ([NSUserDefaults.standardUserDefaults integerForKey:CBRotationKey] / 90) % 4;
    self.rotationControl.accessibilityLabel = @"OBS 画面旋转角度";
    [self.rotationControl addTarget:self action:@selector(changeRotation) forControlEvents:UIControlEventValueChanged];
    [self.rotationControl.widthAnchor constraintEqualToConstant:212].active = YES;
    UIStackView *rotationRow = [[UIStackView alloc] initWithArrangedSubviews:@[rotationLabel, self.rotationControl]];
    rotationRow.axis = UILayoutConstraintAxisHorizontal;
    rotationRow.distribution = UIStackViewDistributionEqualSpacing;
    rotationRow.alignment = UIStackViewAlignmentCenter;
    [rotationRow.heightAnchor constraintEqualToConstant:42].active = YES;

    self.metricsLabel = [self label:@"接收 --  ·  输出 --" size:12 color:[UIColor colorWithWhite:1 alpha:0.66]];
    self.metricsLabel.numberOfLines = 4;
    [self.metricsLabel.heightAnchor constraintEqualToConstant:70].active = YES;
    self.videoPanel = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.stateLabel, self.videoSummaryLabel, inputRow, self.hintLabel, switchRow, rotationRow, self.metricsLabel
    ]];
    self.videoPanel.axis = UILayoutConstraintAxisVertical;
    self.videoPanel.spacing = 8;

    self.audioLabel = [self label:@"电脑声音：等待连接" size:14 color:UIColor.whiteColor];
    self.audioLabel.numberOfLines = 2;
    [self.audioLabel.heightAnchor constraintEqualToConstant:42].active = YES;

    UIColor *accent = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1];
    self.speakerIcon = [[CBLevelIconView alloc] initWithOutline:@"speaker.wave.2" filled:@"speaker.wave.2.fill"];
    self.speakerIcon.accessibilityLabel = @"OBS 音频输出";
    [self.speakerIcon.widthAnchor constraintEqualToConstant:34].active = YES;
    [self.speakerIcon.heightAnchor constraintEqualToConstant:34].active = YES;
    self.speakerTitleLabel = [self label:@"声音输出 · 未检测到" size:13 color:UIColor.whiteColor];
    self.speakerTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.speakerDetailLabel = [self label:@"等待音轨" size:11 color:[UIColor colorWithWhite:1 alpha:0.58]];
    self.speakerMeter = [UIProgressView new];
    self.speakerMeter.trackTintColor = [UIColor colorWithWhite:1 alpha:0.10];
    self.speakerMeter.progressTintColor = accent;
    self.speakerMeter.transform = CGAffineTransformMakeScale(1, 1.8);
    self.speakerMeter.accessibilityLabel = @"电脑声音传输状态";
    UIStackView *speakerInfo = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.speakerTitleLabel, self.speakerDetailLabel, self.speakerMeter
    ]];
    speakerInfo.axis = UILayoutConstraintAxisVertical;
    speakerInfo.spacing = 3;
    UIStackView *speakerRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.speakerIcon, speakerInfo]];
    speakerRow.axis = UILayoutConstraintAxisHorizontal;
    speakerRow.alignment = UIStackViewAlignmentCenter;
    speakerRow.spacing = 10;
    [speakerRow.heightAnchor constraintEqualToConstant:56].active = YES;

    self.microphoneIcon = [[CBLevelIconView alloc] initWithOutline:@"mic" filled:@"mic.fill"];
    self.microphoneIcon.accessibilityLabel = @"直播 App 麦克风输入";
    [self.microphoneIcon.widthAnchor constraintEqualToConstant:34].active = YES;
    [self.microphoneIcon.heightAnchor constraintEqualToConstant:34].active = YES;
    self.microphoneTitleLabel = [self label:@"麦克风输入 · 未检测到" size:13 color:UIColor.whiteColor];
    self.microphoneTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.microphoneDetailLabel = [self label:@"等待 App 麦克风采样" size:11 color:[UIColor colorWithWhite:1 alpha:0.58]];
    self.microphoneMeter = [UIProgressView new];
    self.microphoneMeter.trackTintColor = [UIColor colorWithWhite:1 alpha:0.10];
    self.microphoneMeter.progressTintColor = accent;
    self.microphoneMeter.transform = CGAffineTransformMakeScale(1, 1.8);
    self.microphoneMeter.accessibilityLabel = @"麦克风实时输入电平";
    UIStackView *microphoneInfo = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.microphoneTitleLabel, self.microphoneDetailLabel, self.microphoneMeter
    ]];
    microphoneInfo.axis = UILayoutConstraintAxisVertical;
    microphoneInfo.spacing = 3;
    UIStackView *microphoneRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.microphoneIcon, microphoneInfo]];
    microphoneRow.axis = UILayoutConstraintAxisHorizontal;
    microphoneRow.alignment = UIStackViewAlignmentCenter;
    microphoneRow.spacing = 10;
    [microphoneRow.heightAnchor constraintEqualToConstant:56].active = YES;

    UILabel *audioModeTitle = [self label:@"选择声音怎么走" size:13
                                      color:[UIColor colorWithWhite:1 alpha:0.62]];
    [audioModeTitle.heightAnchor constraintEqualToConstant:20].active = YES;
    self.audioModeControl = [[UISegmentedControl alloc] initWithItems:@[@"外放", @"硬件内录"]];
    NSInteger audioMode = [NSUserDefaults.standardUserDefaults integerForKey:CBAudioModeKey];
    self.audioModeControl.selectedSegmentIndex = audioMode == 2 ? 1 : 0;
    self.audioModeControl.accessibilityLabel = @"OBS 音频输出方式";
    [self.audioModeControl addTarget:self action:@selector(changeAudioMode) forControlEvents:UIControlEventValueChanged];
    [self.audioModeControl.heightAnchor constraintEqualToConstant:36].active = YES;

    self.audioModeLabel = [self label:@"默认外放；直播 App 继续使用真实麦克风" size:12
                                     color:[UIColor colorWithWhite:1 alpha:0.68]];
    self.audioModeLabel.numberOfLines = 3;
    [self.audioModeLabel.heightAnchor constraintEqualToConstant:52].active = YES;
    self.audioWarningLabel = [self label:@"这里控制的是音轨播放，不是软件麦克风注入。" size:11
                                        color:UIColor.systemOrangeColor];
    self.audioWarningLabel.numberOfLines = 3;
    [self.audioWarningLabel.heightAnchor constraintEqualToConstant:48].active = YES;

    self.audioPanel = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.audioLabel, speakerRow, microphoneRow, audioModeTitle, self.audioModeControl,
        self.audioModeLabel, self.audioWarningLabel
    ]];
    self.audioPanel.axis = UILayoutConstraintAxisVertical;
    self.audioPanel.spacing = 8;
    self.audioPanel.hidden = YES;

    self.licenseStateLabel = [self label:@"推流助手未激活" size:18 color:UIColor.whiteColor];
    self.licenseStateLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.licenseStateLabel.heightAnchor constraintEqualToConstant:28].active = YES;
    self.licenseDetailLabel = [self label:@"购买激活码后，在这里完成本机授权。" size:13
                                            color:[UIColor colorWithWhite:1 alpha:0.70]];
    self.licenseDetailLabel.numberOfLines = 3;
    [self.licenseDetailLabel.heightAnchor constraintEqualToConstant:54].active = YES;

    self.licenseCodeField = [UITextField new];
    self.licenseCodeField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    self.licenseCodeField.textColor = UIColor.whiteColor;
    self.licenseCodeField.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.licenseCodeField.layer.cornerRadius = 10;
    self.licenseCodeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.licenseCodeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.licenseCodeField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.licenseCodeField.returnKeyType = UIReturnKeyGo;
    self.licenseCodeField.delegate = self;
    self.licenseCodeField.accessibilityLabel = @"推流助手激活码";
    self.licenseCodeField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"输入激活码"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    UIView *licensePadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    self.licenseCodeField.leftView = licensePadding;
    self.licenseCodeField.leftViewMode = UITextFieldViewModeAlways;
    self.licenseCodeField.text = [BolemeLicenseManager shared].activationCode ?: @"";
    [self.licenseCodeField.heightAnchor constraintEqualToConstant:44].active = YES;

    self.licenseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.licenseButton setTitle:@"立即激活" forState:UIControlStateNormal];
    [self.licenseButton setTitleColor:[UIColor colorWithRed:0.04 green:0.16 blue:0.13 alpha:1] forState:UIControlStateNormal];
    self.licenseButton.backgroundColor = accent;
    self.licenseButton.layer.cornerRadius = 10;
    self.licenseButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.licenseButton.accessibilityLabel = @"激活或重新验证推流助手";
    [self.licenseButton addTarget:self action:@selector(activateLicense) forControlEvents:UIControlEventTouchUpInside];
    [self.licenseButton.widthAnchor constraintEqualToConstant:92].active = YES;
    UIStackView *licenseInputRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.licenseCodeField, self.licenseButton]];
    licenseInputRow.axis = UILayoutConstraintAxisHorizontal;
    licenseInputRow.spacing = 8;

    self.licenseMessageLabel = [self label:@"激活码只绑定当前手机；更换手机请先联系管理员解绑。" size:12
                                             color:[UIColor colorWithWhite:1 alpha:0.55]];
    self.licenseMessageLabel.numberOfLines = 3;
    [self.licenseMessageLabel.heightAnchor constraintEqualToConstant:54].active = YES;
    self.licensePanel = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.licenseStateLabel, self.licenseDetailLabel, licenseInputRow, self.licenseMessageLabel
    ]];
    self.licensePanel.axis = UILayoutConstraintAxisVertical;
    self.licensePanel.spacing = 10;
    self.licensePanel.hidden = self.tabControl.selectedSegmentIndex != 2;
    self.videoPanel.hidden = self.tabControl.selectedSegmentIndex != 0;
    self.audioPanel.hidden = self.tabControl.selectedSegmentIndex != 1;

    self.diagnosticsDisclosureButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticsDisclosureButton setTitle:@"查看运行诊断日志  ⌄" forState:UIControlStateNormal];
    [self.diagnosticsDisclosureButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.64]
                                           forState:UIControlStateNormal];
    self.diagnosticsDisclosureButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.diagnosticsDisclosureButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.diagnosticsDisclosureButton.accessibilityLabel = @"展开运行诊断日志";
    [self.diagnosticsDisclosureButton addTarget:self action:@selector(toggleDiagnostics)
                              forControlEvents:UIControlEventTouchUpInside];
    [self.diagnosticsDisclosureButton.heightAnchor constraintEqualToConstant:30].active = YES;

    UILabel *diagnosticsHint = [self label:@"出现卡顿、断流或闪退后，把这份日志发给技术支持。"
                                         size:11 color:[UIColor colorWithWhite:1 alpha:0.58]];
    diagnosticsHint.numberOfLines = 2;
    [diagnosticsHint.heightAnchor constraintEqualToConstant:34].active = YES;
    self.diagnosticsTextView = [UITextView new];
    self.diagnosticsTextView.editable = NO;
    self.diagnosticsTextView.selectable = YES;
    self.diagnosticsTextView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22];
    self.diagnosticsTextView.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    self.diagnosticsTextView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.diagnosticsTextView.layer.cornerRadius = 10;
    self.diagnosticsTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.diagnosticsTextView.accessibilityLabel = @"播了么运行诊断日志";
    [self.diagnosticsTextView.heightAnchor constraintEqualToConstant:250].active = YES;
    self.copyDiagnosticsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.copyDiagnosticsButton setTitle:@"复制全部日志" forState:UIControlStateNormal];
    [self.copyDiagnosticsButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.copyDiagnosticsButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.copyDiagnosticsButton.layer.cornerRadius = 10;
    self.copyDiagnosticsButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.copyDiagnosticsButton.accessibilityLabel = @"复制全部诊断日志到剪贴板";
    [self.copyDiagnosticsButton addTarget:self action:@selector(copyDiagnostics)
                             forControlEvents:UIControlEventTouchUpInside];
    [self.copyDiagnosticsButton.heightAnchor constraintEqualToConstant:40].active = YES;
    self.diagnosticsPanel = [[UIStackView alloc] initWithArrangedSubviews:@[
        diagnosticsHint, self.diagnosticsTextView, self.copyDiagnosticsButton
    ]];
    self.diagnosticsPanel.axis = UILayoutConstraintAxisVertical;
    self.diagnosticsPanel.spacing = 8;
    self.diagnosticsPanel.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, self.tabControl, self.videoPanel, self.audioPanel, self.licensePanel,
        self.diagnosticsDisclosureButton, self.diagnosticsPanel
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:shade.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:shade.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:12],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14]
    ]];
    [self refreshStatus];
}

- (void)closePanel {
    [self saveAddress];
    [self.addressField resignFirstResponder];
    [self.shade removeFromSuperview];
    self.shade = nil;
    self.card = nil;
    self.addressField = nil;
    self.enabledSwitch = nil;
    self.rotationControl = nil;
    self.stateLabel = nil;
    self.metricsLabel = nil;
    self.videoSummaryLabel = nil;
    self.audioLabel = nil;
    self.hintLabel = nil;
    self.tabControl = nil;
    self.videoPanel = nil;
    self.audioPanel = nil;
    self.licensePanel = nil;
    self.licenseStateLabel = nil;
    self.licenseDetailLabel = nil;
    self.licenseMessageLabel = nil;
    self.licenseCodeField = nil;
    self.licenseButton = nil;
    self.audioModeControl = nil;
    self.audioModeLabel = nil;
    self.audioRouteLabel = nil;
    self.audioWarningLabel = nil;
    self.speakerIcon = nil;
    self.microphoneIcon = nil;
    self.speakerTitleLabel = nil;
    self.speakerDetailLabel = nil;
    self.microphoneTitleLabel = nil;
    self.microphoneDetailLabel = nil;
    self.speakerMeter = nil;
    self.microphoneMeter = nil;
    self.headerSpeakerIcon = nil;
    self.headerMicrophoneIcon = nil;
    self.diagnosticsDisclosureButton = nil;
    self.diagnosticsPanel = nil;
    self.diagnosticsTextView = nil;
    self.copyDiagnosticsButton = nil;
    self.diagnosticsExpanded = NO;
}

- (BOOL)saveAddress {
    NSString *normalized = CBNormalizedStreamURL(self.addressField.text);
    if (!normalized) {
        self.hintLabel.text = @"请输入电脑 IP，或以 .m3u8 结尾的播放地址";
        self.hintLabel.textColor = UIColor.systemOrangeColor;
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setObject:normalized forKey:CBStreamURLKey];
    self.hintLabel.text = @"已保存；断流时不会露出真实摄像头";
    self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.52];
    return YES;
}

- (void)pasteAddress {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (text.length) self.addressField.text = text;
    if ([self saveAddress]) {
        BOOL authorized = [BolemeLicenseManager shared].isAuthorized;
        self.enabledSwitch.on = authorized;
        [NSUserDefaults.standardUserDefaults setBool:authorized forKey:CBEnabledKey];
        if (!authorized) {
            self.hintLabel.text = @"地址已保存；激活推流助手后即可开启替换";
            self.hintLabel.textColor = UIColor.systemOrangeColor;
        }
        [self.addressField resignFirstResponder];
    }
}

- (void)toggleReplacement {
    if (self.enabledSwitch.isOn && ![BolemeLicenseManager shared].isAuthorized) {
        self.enabledSwitch.on = NO;
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:CBEnabledKey];
        self.tabControl.selectedSegmentIndex = 2;
        [self changeTab];
        self.licenseMessageLabel.text = @"请先输入推流助手激活码，激活后才能替换摄像头画面。";
        self.licenseMessageLabel.textColor = UIColor.systemOrangeColor;
        return;
    }
    if (self.enabledSwitch.isOn && ![self saveAddress]) {
        self.enabledSwitch.on = NO;
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:self.enabledSwitch.isOn forKey:CBEnabledKey];
    BolemeLog(@"用户%@画面替换", self.enabledSwitch.isOn ? @"开启" : @"暂停");
    [self refreshStatus];
}

- (void)changeRotation {
    [NSUserDefaults.standardUserDefaults setInteger:self.rotationControl.selectedSegmentIndex * 90 forKey:CBRotationKey];
}

- (void)changeTab {
    if (self.diagnosticsExpanded) return;
    NSInteger selected = self.tabControl.selectedSegmentIndex;
    self.videoPanel.hidden = selected != 0;
    self.audioPanel.hidden = selected != 1;
    self.licensePanel.hidden = selected != 2;
    [UIView animateWithDuration:0.16 animations:^{
        [self.card.superview layoutIfNeeded];
    }];
}

- (void)activateLicense {
    [self.licenseCodeField resignFirstResponder];
    BolemeLicenseManager *manager = [BolemeLicenseManager shared];
    NSString *entered = [self.licenseCodeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.licenseButton.enabled = NO;
    [self.licenseButton setTitle:@"请稍候" forState:UIControlStateNormal];
    void (^completion)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        self.licenseButton.enabled = YES;
        [self refreshLicenseUI];
        self.licenseMessageLabel.text = message;
        self.licenseMessageLabel.textColor = success
            ? [UIColor colorWithRed:0.32 green:0.85 blue:0.70 alpha:1]
            : UIColor.systemOrangeColor;
        if (success) {
            self.enabledSwitch.enabled = YES;
        }
    };
    if (entered.length && ![entered isEqualToString:manager.activationCode]) {
        [manager activateCode:entered completion:completion];
    } else if (entered.length && !manager.isAuthorized) {
        [manager activateCode:entered completion:completion];
    } else {
        [manager validateNowWithCompletion:completion];
    }
}

- (void)changeAudioMode {
    NSInteger audioMode = self.audioModeControl.selectedSegmentIndex == 1 ? 2 : 1;
    [NSUserDefaults.standardUserDefaults setInteger:audioMode forKey:CBAudioModeKey];
    BolemeLog(@"用户切换声音模式：%@", audioMode == 2 ? @"硬件内录" : @"外放");
    [self refreshStatus];
}

- (void)toggleDiagnostics {
    self.diagnosticsExpanded = !self.diagnosticsExpanded;
    self.tabControl.enabled = !self.diagnosticsExpanded;
    if (self.diagnosticsExpanded) {
        self.videoPanel.hidden = YES;
        self.audioPanel.hidden = YES;
        self.licensePanel.hidden = YES;
        self.diagnosticsPanel.hidden = NO;
        BolemeLog(@"用户打开诊断日志");
        self.diagnosticsTextView.text = BolemeDiagnosticReport();
        [self.diagnosticsDisclosureButton setTitle:@"收起运行诊断日志  ^" forState:UIControlStateNormal];
        self.diagnosticsDisclosureButton.accessibilityLabel = @"收起运行诊断日志";
    } else {
        self.diagnosticsPanel.hidden = YES;
        self.tabControl.enabled = YES;
        [self.diagnosticsDisclosureButton setTitle:@"查看运行诊断日志  ⌄" forState:UIControlStateNormal];
        self.diagnosticsDisclosureButton.accessibilityLabel = @"展开运行诊断日志";
        [self changeTab];
    }
    [UIView animateWithDuration:0.16 animations:^{
        [self.card.superview layoutIfNeeded];
    }];
}

- (void)copyDiagnostics {
    NSString *report = BolemeDiagnosticReport();
    UIPasteboard.generalPasteboard.string = report;
    self.diagnosticsTextView.text = report;
    [self.copyDiagnosticsButton setTitle:@"已复制，可以直接发给技术支持" forState:UIControlStateNormal];
    self.copyDiagnosticsButton.accessibilityLabel = @"诊断日志已复制";
    BolemeLog(@"用户复制诊断日志");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.copyDiagnosticsButton setTitle:@"复制全部日志" forState:UIControlStateNormal];
        self.copyDiagnosticsButton.accessibilityLabel = @"复制全部诊断日志到剪贴板";
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.licenseCodeField) {
        [self activateLicense];
        return YES;
    }
    [self saveAddress];
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return !self.card || ![touch.view isDescendantOfView:self.card];
}

- (void)refreshLicenseUI {
    BolemeLicenseManager *manager = [BolemeLicenseManager shared];
    UIColor *green = [UIColor colorWithRed:0.32 green:0.85 blue:0.70 alpha:1];
    UIColor *amber = UIColor.systemOrangeColor;
    self.licenseStateLabel.text = [NSString stringWithFormat:@"推流助手%@", manager.statusText ?: @"未激活"];
    self.licenseStateLabel.textColor = manager.isAuthorized ? green : amber;
    self.licenseDetailLabel.text = manager.detailText ?: @"输入激活码后才能替换摄像头画面";
    self.licenseButton.enabled = !manager.isChecking;
    [self.licenseButton setTitle:(manager.isChecking ? @"请稍候" : (manager.isAuthorized ? @"验证授权" : @"立即激活"))
                         forState:UIControlStateNormal];
    if (!self.licenseCodeField.isFirstResponder && !self.licenseCodeField.text.length && manager.activationCode.length) {
        self.licenseCodeField.text = manager.activationCode;
    }
    self.enabledSwitch.enabled = manager.isAuthorized && !manager.isChecking;
    self.enabledSwitch.alpha = manager.isAuthorized ? 1.0 : 0.48;
}

- (void)refreshStatus {
    NSDictionary *snapshot = CBStatusSnapshot();
    BolemeLicenseManager *license = [BolemeLicenseManager shared];
    BOOL requestedEnabled = [NSUserDefaults.standardUserDefaults boolForKey:CBEnabledKey];
    BOOL enabled = requestedEnabled && license.isAuthorized;
    if (requestedEnabled && !license.isAuthorized) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:CBEnabledKey];
        self.enabledSwitch.on = NO;
    }
    double age = [snapshot[@"frameAge"] doubleValue];
    BOOL cameraSeen = [snapshot[@"cameraFrames"] unsignedIntegerValue] > 0;
    BOOL fresh = enabled && cameraSeen && age >= 0 && age < 2.0;
    UIColor *green = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1];
    UIColor *amber = UIColor.systemOrangeColor;
    self.statusDot.backgroundColor = !license.isAuthorized ? amber : (fresh ? green : (enabled ? amber : UIColor.systemGrayColor));
    self.bubble.accessibilityValue = license.isAuthorized ? self.bubble.accessibilityValue : @"推流助手尚未激活";
    if (!self.shade) return;
    if (self.diagnosticsExpanded) self.diagnosticsTextView.text = BolemeDiagnosticReport();
    [self refreshLicenseUI];
    NSString *state = snapshot[@"state"];
    NSString *headline = !enabled ? @"已暂停" : (fresh ? @"画面稳定" : @"正在缓冲 / 重连");
    NSString *detail = @"等待视频";
    if (cameraSeen && ![snapshot[@"supportedCameraFormat"] boolValue]) {
        headline = @"相机格式需适配";
        detail = snapshot[@"pixelFormat"];
    } else if (!cameraSeen) {
        headline = @"等待 App 打开摄像头";
        detail = age >= 0 ? @"OBS 画面已收到" : @"先打开摄像头预览";
    } else if ([state isEqualToString:@"connecting to HLS"]) {
        detail = @"正在连接电脑画面";
    } else if ([state isEqualToString:@"HLS stalled; reconnecting"]) {
        detail = @"画面中断，正在自动重试";
    } else if ([state isEqualToString:@"invalid URL"]) {
        detail = @"请检查电脑 IP 或播放地址";
    } else if (age >= 0) {
        detail = [NSString stringWithFormat:@"%.1f 秒前收到新帧", age];
    }
    self.stateLabel.text = [NSString stringWithFormat:@"%@  ·  %@", headline, detail];
    self.stateLabel.textColor = fresh ? green : (enabled ? amber : [UIColor colorWithWhite:1 alpha:0.60]);
    double video = [snapshot[@"videoBitrate"] doubleValue];
    NSString *videoText = video > 0 ? [NSString stringWithFormat:@"%.1f Mb/s", video / 1000000.0] : @"读取中";
    NSUInteger sourceWidth = [snapshot[@"sourceWidth"] unsignedIntegerValue];
    NSUInteger sourceHeight = [snapshot[@"sourceHeight"] unsignedIntegerValue];
    NSString *resolutionText = sourceWidth && sourceHeight
        ? [NSString stringWithFormat:@"%lu × %lu", (unsigned long)sourceWidth, (unsigned long)sourceHeight]
        : @"等待画面";
    self.videoSummaryLabel.text = [NSString stringWithFormat:@"分辨率 %@  ·  码率 %@", resolutionText, videoText];
    double lag = [snapshot[@"liveEdgeLag"] doubleValue];
    double peakLag = [snapshot[@"peakLiveEdgeLag"] doubleValue];
    NSString *lagText = lag >= 0 ? [NSString stringWithFormat:@"%.1f 秒", lag] : @"暂无数据";
    NSString *peakText = peakLag >= 0 ? [NSString stringWithFormat:@"%.1f 秒", peakLag] : @"暂无数据";
    NSInteger stalls = [snapshot[@"playerStalls"] integerValue];
    NSString *stallText = stalls >= 0 ? [NSString stringWithFormat:@"%ld", (long)stalls] : @"--";
    NSInteger dropped = [snapshot[@"droppedFrames"] integerValue];
    NSString *droppedText = dropped >= 0 ? [NSString stringWithFormat:@"%ld", (long)dropped] : @"--";
    self.metricsLabel.text = [NSString stringWithFormat:
        @"接收 %.1f 帧/秒  ·  送出 %.1f 帧/秒\n当前延迟 %@  ·  最高 %@\n异常：重试 %@  ·  卡顿 %@  ·  丢帧 %@\n累计送出 %@ 帧  ·  保护黑帧 %@",
        [snapshot[@"receivedFPS"] doubleValue], [snapshot[@"replacedFPS"] doubleValue],
        lagText, peakText, snapshot[@"reconnects"], stallText, droppedText,
        snapshot[@"frames"], snapshot[@"blackFrames"]];
    NSInteger audioMode = [snapshot[@"audioMode"] integerValue];
    BOOL routeReady = [snapshot[@"audioRouteReady"] boolValue];
    BOOL trackDetected = [snapshot[@"audioTrackDetected"] boolValue];
    NSString *inputName = snapshot[@"audioInputName"] ?: @"未检测到";
    NSString *outputName = snapshot[@"audioOutputName"] ?: @"未检测到";
    if (audioMode == 2) {
        self.audioLabel.text = trackDetected
            ? [NSString stringWithFormat:@"声音路线：电脑 → %@ → %@ → 直播\n喇叭和麦克风同时亮才正常", outputName, inputName]
            : @"还没有收到电脑声音\n请先检查电脑推流";
    } else if (audioMode == 1) {
        self.audioLabel.text = [NSString stringWithFormat:@"电脑声音送到：%@\n直播正在从 %@ 收音", outputName, inputName];
    } else {
        self.audioLabel.text = [NSString stringWithFormat:@"电脑声音：已关闭\n直播正在从 %@ 收音", inputName];
    }
    [self refreshMetersWithSnapshot:snapshot];
    if (audioMode == 1) {
        self.audioModeLabel.text = @"把电脑声音放到当前耳机或扬声器里；直播仍然从麦克风收音。";
        self.audioModeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.68];
        self.audioWarningLabel.text = @"适合试听。用手机扬声器时可能会有回声。";
    } else if (audioMode == 2) {
        self.audioModeLabel.text = routeReady
            ? @"内录设备已连接，电脑声音正在送进直播。"
            : @"请先插入内录设备；没有检测到设备时不会外放。";
        self.audioModeLabel.textColor = routeReady ? green : amber;
        self.audioWarningLabel.text = @"适合正式直播。确认麦克风绿色电平会跳动后再开播。";
    } else {
        self.audioModeLabel.text = @"不播放电脑声音，只使用手机或外接麦克风。";
        self.audioModeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.68];
        self.audioWarningLabel.text = @"适合只讲解、不需要电脑声音的直播。";
    }
}

- (void)refreshMeters {
    [self refreshMetersWithSnapshot:CBStatusSnapshot()];
}

- (void)refreshMetersWithSnapshot:(NSDictionary<NSString *, id> *)snapshot {
    BOOL trackDetected = [snapshot[@"audioTrackDetected"] boolValue];
    BOOL audioPlaying = [snapshot[@"audioActuallyPlaying"] boolValue];
    double audioBitrate = [snapshot[@"audioBitrate"] doubleValue];
    NSString *outputName = snapshot[@"audioOutputName"] ?: @"未检测到";
    NSString *inputName = snapshot[@"audioInputName"] ?: @"未检测到";
    double microphoneAge = [snapshot[@"microphoneAge"] doubleValue];
    BOOL capturing = [snapshot[@"microphoneSamples"] unsignedIntegerValue] > 0 &&
        microphoneAge >= 0 && microphoneAge < 0.5;
    float level = capturing ? [snapshot[@"microphoneLevel"] floatValue] : 0;
    float decibels = [snapshot[@"microphoneDB"] floatValue];
    BOOL signalPresent = capturing && level > 0.01f && decibels > -58.0f;
    BOOL outputActive = audioPlaying && trackDetected;
    NSInteger audioMode = [snapshot[@"audioMode"] integerValue];
    BOOL routeReady = [snapshot[@"audioRouteReady"] boolValue];
    // AVPlayer does not expose HLS output PCM. In external-loopback mode the microphone sample is
    // the end-to-end signal after the USB device, so it is the only honest real-time output level.
    CGFloat microphoneLevel = signalPresent ? level : 0;
    CGFloat speakerLevel = outputActive && audioMode == 2 && routeReady && signalPresent ? level : 0;
    self.bubbleSpeakerIcon.level = speakerLevel;
    self.bubbleMicrophoneIcon.level = microphoneLevel;
    self.headerSpeakerIcon.level = speakerLevel;
    self.headerMicrophoneIcon.level = microphoneLevel;
    self.headerSpeakerIcon.accessibilityValue = speakerLevel > 0
        ? [NSString stringWithFormat:@"%@ 检测到声音", outputName]
        : (outputActive ? @"输出已打开，但没有测到声音" : @"电脑声音没有送出");
    self.headerMicrophoneIcon.accessibilityValue = microphoneLevel > 0
        ? [NSString stringWithFormat:@"%@ 有声音", inputName]
        : (capturing ? @"麦克风正在采集，但没有声音" : @"没有检测到麦克风收音");
    self.bubble.accessibilityValue = [BolemeLicenseManager shared].isAuthorized
        ? [NSString stringWithFormat:@"%@；%@",
            speakerLevel > 0 ? @"检测到电脑声音" : (outputActive ? @"输出已打开但未测到声音" : @"电脑声音未送出"),
            microphoneLevel > 0 ? @"麦克风有声音" : (capturing ? @"麦克风正在采集但没有声音" : @"麦克风未收音")]
        : @"推流助手尚未激活";

    if (!self.speakerMeter || !self.microphoneMeter) return;
    self.speakerTitleLabel.text = [NSString stringWithFormat:@"声音输出 · %@", outputName];
    if (!trackDetected) {
        self.speakerDetailLabel.text = @"没有收到电脑声音";
    } else if (!audioPlaying) {
        self.speakerDetailLabel.text = @"电脑有声音 · 当前没有送出";
    } else if (audioMode == 2 && routeReady && signalPresent) {
        self.speakerDetailLabel.text = [NSString stringWithFormat:@"内录返回有声音 · %.0f dB", decibels];
    } else if (audioMode == 2 && routeReady) {
        self.speakerDetailLabel.text = @"输出已打开 · 暂时没有测到声音";
    } else if (audioBitrate > 0) {
        self.speakerDetailLabel.text = @"正在送出 · 本机播放音量暂不能读取";
    } else {
        self.speakerDetailLabel.text = @"正在送出电脑声音";
    }
    [self.speakerMeter setProgress:speakerLevel animated:NO];
    self.speakerIcon.level = speakerLevel;
    self.speakerMeter.accessibilityValue = self.speakerDetailLabel.text;

    self.microphoneTitleLabel.text = [NSString stringWithFormat:@"麦克风输入 · %@", inputName];
    NSString *formatText = snapshot[@"microphoneFormat"] ?: @"未知格式";
    if (!capturing) {
        self.microphoneDetailLabel.text = @"直播 App 还没有开始收音";
    } else if (!signalPresent) {
        self.microphoneDetailLabel.text = [NSString stringWithFormat:@"正在采集，但没有检测到声音 · %@", formatText];
    } else if (decibels > -12.0f) {
        self.microphoneDetailLabel.text = [NSString stringWithFormat:@"有声音，音量较大 · %.0f dB", decibels];
    } else if (decibels > -38.0f) {
        self.microphoneDetailLabel.text = [NSString stringWithFormat:@"有声音，音量正常 · %.0f dB", decibels];
    } else {
        self.microphoneDetailLabel.text = [NSString stringWithFormat:@"有声音，但音量较小 · %.0f dB", decibels];
    }
    [self.microphoneMeter setProgress:microphoneLevel animated:NO];
    self.microphoneIcon.level = microphoneLevel;
    self.microphoneMeter.accessibilityValue = self.microphoneDetailLabel.text;
}

@end

void CBInstallControlsIfNeeded(void) {
    NSCAssert([NSThread isMainThread], @"Controls must be updated on the main thread");
    [[CBControls shared] installIfNeeded];
}
