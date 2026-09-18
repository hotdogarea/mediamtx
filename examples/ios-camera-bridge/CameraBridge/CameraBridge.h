#import <Foundation/Foundation.h>

// The host app uses these for its test UI. An injected app does not need to link them.
FOUNDATION_EXPORT NSString * const CBStreamURLKey;
FOUNDATION_EXPORT NSString * const CBEnabledKey;
FOUNDATION_EXPORT NSString * const CBRotationKey;
FOUNDATION_EXPORT NSString * _Nullable CBNormalizedStreamURL(NSString * _Nullable input);
FOUNDATION_EXPORT void CBInstallControlsIfNeeded(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CBStatusSnapshot(void);
