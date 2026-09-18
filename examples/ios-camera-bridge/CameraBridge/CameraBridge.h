#import <Foundation/Foundation.h>

// The host app uses these for its test UI. An injected app does not need to link them.
FOUNDATION_EXPORT NSString * const CBStreamURLKey;
FOUNDATION_EXPORT NSString * const CBEnabledKey;
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CBStatusSnapshot(void);
