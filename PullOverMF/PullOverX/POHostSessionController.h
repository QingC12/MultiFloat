#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "ContextHostManager.h"

@class POHostSessionController;

typedef NS_ENUM(NSUInteger, POHostSessionState) {
    POHostSessionStateIdle,
    POHostSessionStatePreparing,
    POHostSessionStateWaitingForScene,
    POHostSessionStatePrepared,
    POHostSessionStateActivating,
    POHostSessionStateLive,
    POHostSessionStateReleasing,
};

@protocol POHostSessionControllerDelegate <NSObject>
- (void)hostSessionController:(POHostSessionController *)controller
                didPublishScene:(FBScene *)scene
                    sceneStack:(UIView *)sceneStack
                      bundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation;
- (void)hostSessionController:(POHostSessionController *)controller
                didPublishScene:(FBScene *)scene
             externalSceneStack:(UIView *)sceneStack
          containsKeyboardLayer:(BOOL)containsKeyboardLayer
                      bundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation;
- (void)hostSessionController:(POHostSessionController *)controller
       cannotHostFrontmostBundleId:(NSString *)bundleId
                         generation:(NSUInteger)generation;
- (void)hostSessionController:(POHostSessionController *)controller
hostedInterfaceOrientationDidChange:(UIInterfaceOrientation)orientation
   systemAnimationParameters:(id)animationParameters
                      bundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation;
@optional
- (void)hostSessionController:(POHostSessionController *)controller
hostedPresentationContentDidBecomeUnavailableForBundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation;
- (CGSize)hostSessionPreferredSceneStackSize:(POHostSessionController *)controller;
- (CGSize)hostSessionPreferredSystemSceneStackSize:(POHostSessionController *)controller;
- (UIInterfaceOrientation)hostSessionPreferredHostedInterfaceOrientation:(POHostSessionController *)controller;
@end

@interface POHostSessionController : NSObject <ContextHostManagerExternalSceneDelegate>
@property (nonatomic, weak) id<POHostSessionControllerDelegate> delegate;
@property (nonatomic, readonly) POHostSessionState state;
@property (nonatomic, readonly) NSUInteger currentGeneration;
@property (nonatomic, copy, readonly) NSString *requestedBundleId;
@property (nonatomic, copy, readonly) NSString *activeBundleId;

- (instancetype)initWithManager:(ContextHostManager *)manager;

- (void)prepareBundleId:(NSString *)bundleId;

- (void)prewarmBundleId:(NSString *)bundleId;

- (void)activateBundleId:(NSString *)bundleId;

/// 【0.6.1】把当前活跃会话转成实时贴片（scene 保活 + 进程断言转移）。
/// 须在释放租约/切换目标**之前**调用；成功后随后的租约释放会保活渲染。失败退快照路径。
- (BOOL)preserveActiveSessionAsLiveTile;

- (void)beginClosingPreservingActiveLease;

- (void)releaseActiveSessionPreservingPresentation;

- (void)releaseActiveSessionForExternalTakeoverPreservingPresentation;

- (void)invalidate;
@end
