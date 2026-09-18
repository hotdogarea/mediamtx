#import "CameraBridge.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSInteger const CBBubbleTag = 902174;

@interface CBControls : NSObject <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, weak) UIButton *bubble;
@property (nonatomic, weak) UIView *statusDot;
@property (nonatomic, strong) UIView *shade;
@property (nonatomic, weak) UIView *card;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISegmentedControl *rotationControl;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *metricsLabel;
@property (nonatomic, strong) UILabel *hintLabel;
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

- (UIWindow *)activeWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.rootViewController && window.windowLevel == UIWindowLevelNormal) return window;
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.rootViewController && window.windowLevel == UIWindowLevelNormal) return window;
    }
    return nil;
}

- (void)installIfNeeded {
    UIWindow *window = [self activeWindow];
    if (!window) return;
    if (window != self.hostWindow || !self.bubble) {
        [self.shade removeFromSuperview];
        self.shade = nil;
        [self.bubble removeFromSuperview];
        self.hostWindow = window;

        UIButton *bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        bubble.tag = CBBubbleTag;
        bubble.frame = CGRectMake(0, 0, 72, 48);
        bubble.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.14 alpha:0.95];
        bubble.layer.cornerRadius = 24;
        bubble.layer.borderWidth = 1;
        bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.20].CGColor;
        [bubble setTitle:@"OBS" forState:UIControlStateNormal];
        [bubble setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        bubble.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        bubble.accessibilityLabel = @"OBS 画面输入设置，可拖动位置";
        [bubble addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
        [bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBubble:)]];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(56, 10, 7, 7)];
        dot.layer.cornerRadius = 3.5;
        dot.backgroundColor = UIColor.systemGrayColor;
        dot.userInteractionEnabled = NO;
        [bubble addSubview:dot];
        self.statusDot = dot;
        BOOL left = [NSUserDefaults.standardUserDefaults boolForKey:@"CameraBridge.BubbleLeft"];
        CGFloat fraction = [NSUserDefaults.standardUserDefaults objectForKey:@"CameraBridge.BubbleY"]
            ? [NSUserDefaults.standardUserDefaults doubleForKey:@"CameraBridge.BubbleY"] : 0.72;
        CGFloat centerY = MAX(window.safeAreaInsets.top + 36,
                              MIN(window.bounds.size.height - window.safeAreaInsets.bottom - 36,
                                  window.bounds.size.height * fraction));
        bubble.center = CGPointMake(left ? 52 : window.bounds.size.width - 52, centerY);
        [window addSubview:bubble];
        self.bubble = bubble;
    }
    [self refreshStatus];
}

- (void)dragBubble:(UIPanGestureRecognizer *)gesture {
    UIButton *bubble = self.bubble;
    UIWindow *window = self.hostWindow;
    if (!bubble || !window) return;
    CGPoint movement = [gesture translationInView:window];
    bubble.center = CGPointMake(MAX(52, MIN(window.bounds.size.width - 52, bubble.center.x + movement.x)),
                                MAX(window.safeAreaInsets.top + 36,
                                    MIN(window.bounds.size.height - window.safeAreaInsets.bottom - 36,
                                        bubble.center.y + movement.y)));
    [gesture setTranslation:CGPointZero inView:window];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        BOOL left = bubble.center.x < window.bounds.size.width / 2;
        [UIView animateWithDuration:0.18 animations:^{
            bubble.center = CGPointMake(left ? 52 : window.bounds.size.width - 52, bubble.center.y);
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

- (void)openPanel {
    UIWindow *window = self.hostWindow;
    if (!window || self.shade) return;
    UIView *shade = [[UIView alloc] initWithFrame:window.bounds];
    shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
    UITapGestureRecognizer *outsideTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePanel)];
    outsideTap.delegate = self;
    [shade addGestureRecognizer:outsideTap];
    [window addSubview:shade];
    self.shade = shade;

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.14 alpha:1];
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.13].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [shade addSubview:card];
    self.card = card;

    UILabel *title = [self label:@"画面输入" size:21 color:UIColor.whiteColor];
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightSemibold];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"完成" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:0.32 green:0.85 blue:0.70 alpha:1] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    close.accessibilityLabel = @"保存并关闭画面输入设置";
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, close]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.distribution = UIStackViewDistributionEqualSpacing;
    [header.heightAnchor constraintEqualToConstant:40].active = YES;

    self.stateLabel = [self label:@"等待画面…" size:14 color:UIColor.systemGrayColor];
    self.stateLabel.numberOfLines = 2;
    [self.stateLabel.heightAnchor constraintEqualToConstant:38].active = YES;

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
    [self.metricsLabel.heightAnchor constraintEqualToConstant:68].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, self.stateLabel, inputRow, self.hintLabel, switchRow, rotationRow, self.metricsLabel
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
    self.hintLabel = nil;
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
        self.enabledSwitch.on = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:CBEnabledKey];
        [self.addressField resignFirstResponder];
    }
}

- (void)toggleReplacement {
    if (self.enabledSwitch.isOn && ![self saveAddress]) {
        self.enabledSwitch.on = NO;
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:self.enabledSwitch.isOn forKey:CBEnabledKey];
    [self refreshStatus];
}

- (void)changeRotation {
    [NSUserDefaults.standardUserDefaults setInteger:self.rotationControl.selectedSegmentIndex * 90 forKey:CBRotationKey];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self saveAddress];
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return !self.card || ![touch.view isDescendantOfView:self.card];
}

- (void)refreshStatus {
    NSDictionary *snapshot = CBStatusSnapshot();
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:CBEnabledKey];
    double age = [snapshot[@"frameAge"] doubleValue];
    BOOL cameraSeen = [snapshot[@"cameraFrames"] unsignedIntegerValue] > 0;
    BOOL fresh = enabled && cameraSeen && age >= 0 && age < 2.0;
    UIColor *green = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1];
    UIColor *amber = UIColor.systemOrangeColor;
    self.statusDot.backgroundColor = fresh ? green : (enabled ? amber : UIColor.systemGrayColor);
    if (!self.shade) return;
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
        detail = @"正在连接服务器";
    } else if ([state isEqualToString:@"HLS stalled; reconnecting"]) {
        detail = @"视频暂停，正在重连";
    } else if ([state isEqualToString:@"invalid URL"]) {
        detail = @"请检查电脑 IP 或播放地址";
    } else if (age >= 0) {
        detail = [NSString stringWithFormat:@"%.1f 秒前收到新帧", age];
    }
    self.stateLabel.text = [NSString stringWithFormat:@"%@  ·  %@", headline, detail];
    self.stateLabel.textColor = fresh ? green : (enabled ? amber : [UIColor colorWithWhite:1 alpha:0.60]);
    double network = [snapshot[@"networkBitrate"] doubleValue];
    double video = [snapshot[@"videoBitrate"] doubleValue];
    NSString *networkText = network > 0 ? [NSString stringWithFormat:@"%.1f Mb/s", network / 1000000.0] : @"暂无数据";
    NSString *videoText = video > 0 ? [NSString stringWithFormat:@"%.1f Mb/s", video / 1000000.0] : @"暂无数据";
    NSInteger stalls = [snapshot[@"playerStalls"] integerValue];
    NSString *stallText = stalls >= 0 ? [NSString stringWithFormat:@"%ld", (long)stalls] : @"--";
    self.metricsLabel.text = [NSString stringWithFormat:
        @"解码 %.1f 帧/秒  ·  替换 %.1f 帧/秒\n视频码率 %@  ·  下载 %@\n重连 %@ 次  ·  播放卡顿 %@ 次\n累计解码 %@ 帧  ·  黑帧 %@",
        [snapshot[@"receivedFPS"] doubleValue], [snapshot[@"replacedFPS"] doubleValue],
        videoText, networkText, snapshot[@"reconnects"], stallText,
        snapshot[@"receivedFrames"], snapshot[@"blackFrames"]];
}

@end

void CBInstallControlsIfNeeded(void) {
    NSCAssert([NSThread isMainThread], @"Controls must be updated on the main thread");
    [[CBControls shared] installIfNeeded];
}
