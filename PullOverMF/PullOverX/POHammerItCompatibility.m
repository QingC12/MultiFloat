#import "POXWindow.h"

@interface PullOverWindow : NSObject {
    NSString *pinnedBundleId;
}
+ (instancetype)sharedWindow;
- (instancetype)controller;
- (BOOL)isOpened;
@end

@implementation PullOverWindow

+ (instancetype)sharedWindow {
    PullOverWindow *snapshot = [[self alloc] init];
    void (^capture)(void) = ^{
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if ([window isKindOfClass:[POXWindow class]]) {
                snapshot->pinnedBundleId = [((POXWindow *)window).controller.hammerItTargetBundleId copy];
                break;
            }
        }
    };
    if ([NSThread isMainThread]) {
        capture();
    } else {
        dispatch_sync(dispatch_get_main_queue(), capture);
    }
    return snapshot;
}

- (instancetype)controller {
    return self;
}

- (BOOL)isOpened {
    return pinnedBundleId.length > 0;
}

@end
