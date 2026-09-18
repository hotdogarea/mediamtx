#import "BolemeDiagnostics.h"

#import "BolemeLicense.h"
#import "CameraBridge.h"

#import <UIKit/UIKit.h>
#import <stdarg.h>

NSString * const BolemePluginVersion = @"1.0";

static NSString *BolemeLogFilePath(void);

static NSMutableArray<NSString *> *BolemeLogEntries(void) {
    static NSMutableArray<NSString *> *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = [NSMutableArray array];
        NSString *saved = [NSString stringWithContentsOfFile:BolemeLogFilePath()
                                                    encoding:NSUTF8StringEncoding error:nil];
        if (saved.length) {
            NSArray<NSString *> *lines = [saved componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
            NSUInteger start = lines.count > 160 ? lines.count - 160 : 0;
            for (NSUInteger index = start; index < lines.count; index++) {
                if (lines[index].length) [entries addObject:lines[index]];
            }
        }
    });
    return entries;
}

static NSString *BolemeLogFilePath(void) {
    NSArray<NSString *> *directories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *directory = [[directories firstObject] stringByAppendingPathComponent:@"Boleme"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"diagnostics.log"];
}

static NSString *BolemeTimestamp(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"MM-dd HH:mm:ss";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:date];
    }
}

void BolemeLog(NSString *format, ...) {
    if (!format.length) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSString *entry = [NSString stringWithFormat:@"[%@] %@", BolemeTimestamp(NSDate.date), message];
    NSMutableArray<NSString *> *entries = BolemeLogEntries();
    @synchronized (entries) {
        [entries addObject:entry];
        while (entries.count > 160) [entries removeObjectAtIndex:0];
        NSString *contents = [[entries componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        [contents writeToFile:BolemeLogFilePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSString *BolemeEndpointSummary(void) {
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:CBStreamURLKey];
    NSURLComponents *parts = stored.length ? [NSURLComponents componentsWithString:stored] : nil;
    if (!parts.host.length) return @"未设置";
    NSString *port = parts.port ? [NSString stringWithFormat:@":%@", parts.port] : @"";
    return [NSString stringWithFormat:@"%@%@%@", parts.host, port, parts.path ?: @""];
}

static NSString *BolemeNumber(id value, NSString *suffix) {
    if (![value respondsToSelector:@selector(doubleValue)] || [value doubleValue] < 0) return @"--";
    return [NSString stringWithFormat:@"%.1f%@", [value doubleValue], suffix ?: @""];
}

NSString *BolemeDiagnosticReport(void) {
    NSDictionary<NSString *, id> *status = CBStatusSnapshot();
    BolemeLicenseManager *license = [BolemeLicenseManager shared];
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *appName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
        ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"未知 App";
    NSString *appVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"--";
    NSInteger audioMode = [status[@"audioMode"] integerValue];
    NSString *audioModeText = audioMode == 2 ? @"硬件内录" : (audioMode == 1 ? @"外放" : @"关闭");
    NSString *resolution = [status[@"sourceWidth"] unsignedIntegerValue] && [status[@"sourceHeight"] unsignedIntegerValue]
        ? [NSString stringWithFormat:@"%@×%@", status[@"sourceWidth"], status[@"sourceHeight"]] : @"--";
    NSString *licenseText = license.isAuthorized ? @"已激活" : (license.statusText ?: @"未激活");

    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"播了么推流助手 v%@\n", BolemePluginVersion];
    [report appendFormat:@"生成时间：%@\n", BolemeTimestamp(NSDate.date)];
    [report appendFormat:@"设备：%@ · iOS %@\n", UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion];
    [report appendFormat:@"宿主：%@ %@ · %@\n", appName, appVersion, bundle.bundleIdentifier ?: @"--"];
    [report appendFormat:@"授权：%@\n", licenseText];
    [report appendFormat:@"地址：%@\n\n", BolemeEndpointSummary()];
    [report appendString:@"【画面】\n"];
    [report appendFormat:@"状态：%@\n", status[@"state"] ?: @"--"];
    [report appendFormat:@"输入：%@ · %@ 帧/秒 · %@ Mb/s\n", resolution,
        BolemeNumber(status[@"receivedFPS"], @""),
        [status[@"videoBitrate"] doubleValue] > 0
            ? [NSString stringWithFormat:@"%.2f", [status[@"videoBitrate"] doubleValue] / 1000000.0] : @"--"];
    [report appendFormat:@"送出：%@ 帧/秒 · 累计 %@ 帧 · 黑帧 %@\n",
        BolemeNumber(status[@"replacedFPS"], @""), status[@"frames"] ?: @0, status[@"blackFrames"] ?: @0];
    [report appendFormat:@"延迟：%@ · 重连 %@ · 卡顿 %@ · 丢帧 %@\n",
        BolemeNumber(status[@"liveEdgeLag"], @" 秒"), status[@"reconnects"] ?: @0,
        status[@"playerStalls"] ?: @"--", status[@"droppedFrames"] ?: @"--"];
    [report appendFormat:@"相机：%@ · %@\n\n", status[@"pixelFormat"] ?: @"--",
        [status[@"supportedCameraFormat"] boolValue] ? @"支持" : @"不支持"];
    [report appendString:@"【声音】\n"];
    [report appendFormat:@"模式：%@ · OBS 音轨 %@\n", audioModeText,
        [status[@"audioTrackDetected"] boolValue] ? @"正常" : @"未检测到"];
    [report appendFormat:@"输出：%@ · %@\n", status[@"audioOutputName"] ?: @"--",
        [status[@"audioActuallyPlaying"] boolValue] ? @"正在送出" : @"未送出"];
    NSString *microphoneDB = [status[@"microphoneAge"] doubleValue] >= 0
        ? [NSString stringWithFormat:@"%.0f", [status[@"microphoneDB"] doubleValue]] : @"--";
    [report appendFormat:@"输入：%@ · 麦克风 %@ dB · %@\n", status[@"audioInputName"] ?: @"--",
        microphoneDB, status[@"microphoneFormat"] ?: @"--"];

    NSMutableArray<NSString *> *entries = BolemeLogEntries();
    @synchronized (entries) {
        [report appendString:@"\n【最近运行记录】\n"];
        if (entries.count) [report appendString:[entries componentsJoinedByString:@"\n"]];
        else [report appendString:@"暂无记录"];
    }
    return report;
}
