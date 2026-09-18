#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const BolemePluginVersion;

FOUNDATION_EXPORT void BolemeLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *BolemeDiagnosticReport(void);

NS_ASSUME_NONNULL_END
