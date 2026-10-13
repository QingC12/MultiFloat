#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Project-owned bridge surface. It intentionally exposes no private SpringBoard types.
FOUNDATION_EXPORT void MFCoreInitialize(void);
FOUNDATION_EXPORT void MFCoreNotifyEvent(NSString *eventName);

NS_ASSUME_NONNULL_END
