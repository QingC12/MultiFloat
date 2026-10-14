#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, POXOpenOutcome) {
    POXOpenOutcomeHostedVisible,
    POXOpenOutcomeUnavailable,
    POXOpenOutcomeUnsupported,
    POXOpenOutcomeBusy,
    POXOpenOutcomeFailed,
    POXOpenOutcomeTimedOut,
};

typedef void (^POXOpenCompletion)(POXOpenOutcome outcome);

@interface POXExternalAPI : NSObject

+ (NSUInteger)apiVersion;
+ (void)openApplication:(NSString *)bundleID completion:(POXOpenCompletion)completion;
+ (void)activateShortcutForApplication:(NSString *)bundleID
                                   type:(NSString *)type
                               userInfo:(NSDictionary * _Nullable)userInfo
                             completion:(POXOpenCompletion)completion;

@end

NS_ASSUME_NONNULL_END
