#import <Foundation/Foundation.h>
#import "ContextInterfaces.h"
#import "headers.h"

@class ContextHostManager;

@protocol ContextHostManagerExternalSceneDelegate <NSObject>
@optional
-(void)contextManager:(id)manager
                scene:(FBScene *)scene
  sceneStackDidChange:(UIView *)sceneStack
       hostGeneration:(NSUInteger)generation;
-(void)contextManager:(id)manager
                scene:(FBScene *)scene
externalSceneStackDidChange:(UIView *)sceneStack
   containsKeyboardLayer:(BOOL)containsKeyboardLayer
       hostGeneration:(NSUInteger)generation;
-(CGSize)contextManagerPreferredSceneStackSize:(id)manager;
-(CGSize)contextManagerPreferredSystemSceneStackSize:(id)manager;
-(UIInterfaceOrientation)contextManagerPreferredHostedInterfaceOrientation:(id)manager;
-(void)contextManager:(id)manager
                scene:(FBScene *)scene
hostedInterfaceOrientationDidChange:(UIInterfaceOrientation)orientation
systemAnimationParameters:(id)animationParameters
       hostGeneration:(NSUInteger)generation;
-(void)contextManager:(id)manager
 sceneDidBecomeInvalid:(FBScene *)scene
       hostGeneration:(NSUInteger)generation;
-(void)contextManager:(id)manager
                scene:(FBScene *)scene
hostedPresentationContentDidBecomeUnavailableForBundleId:(NSString *)bundleId
       hostGeneration:(NSUInteger)generation;
@end

@interface ContextHostManager : NSObject
@property (nonatomic, weak) id <ContextHostManagerExternalSceneDelegate> sceneDelegate;
@property (nonatomic, copy, readonly) NSString *activeHostedBundleId;
@property (nonatomic, readonly) NSUInteger activeLeaseGeneration;
@property (nonatomic, readonly, getter=isForegroundLeaseActive) BOOL foregroundLeaseActive;
@property (nonatomic, readonly) UIInterfaceOrientation hostedInterfaceOrientation;
@property (nonatomic, assign) UIInterfaceOrientation presentationInterfaceOrientation;
+ (instancetype)sharedInstance;

+ (NSString *)sceneIdentityStringFromSettings:(id)settings;
+ (NSString *)privateSceneIdentityStringFromSettings:(id)settings;
+ (BOOL)shouldKeepForegroundForIdentifier:(NSString *)identifier;
+ (BOOL)shouldKeepForegroundForScene:(FBScene *)scene;
+ (NSString *)activeHostedBundleId;
+ (void)reconcileHostedInterfaceOrientationInSettings:(id)settings forScene:(FBScene *)scene;
+ (id)prepareNativeSceneSettingsIfNeeded:(id)settings forScene:(FBScene *)scene;
+ (id)primePendingSceneRemnantSettings:(id)settings remnant:(id)remnant;
+ (void)completePendingSceneRemnantReconnect:(FBScene *)scene;
-(FBScene *)probeSceneForBundleId:(NSString *)bundleId;
-(BOOL)isProcessRunningForBundleId:(NSString *)bundleId;
-(int)processIdentifierForBundleId:(NSString *)bundleId;
-(UIInterfaceOrientation)preferredHostedInterfaceOrientationForBundleId:(NSString *)bundleId;
-(BOOL)requiresCrossOrientationHostingForBundleId:(NSString *)bundleId;
-(BOOL)requiresOwnedHostedSceneForBundleId:(NSString *)bundleId;
-(void)requestPreparationForBundleId:(NSString *)bundleId;
-(void)requestSystemDefaultScenePreparationForBundleId:(NSString *)bundleId;
-(void)requestCrossOrientationSystemDefaultScenePreparationForBundleId:(NSString *)bundleId;
-(void)prepareHostingIntentForBundleId:(NSString *)bundleId;
-(void)prepareSystemDefaultSceneForHosting:(FBScene *)scene bundleId:(NSString *)bundleId;
-(FBScene *)createHostedSceneForBundleId:(NSString *)bundleId;
-(BOOL)isOwnedHostedScene:(FBScene *)scene bundleId:(NSString *)bundleId;
-(BOOL)sceneHasRenderableMainLayer:(FBScene *)scene;
-(BOOL)isHostedPresentationContentStableForBundleId:(NSString *)bundleId
                                    minimumDuration:(NSTimeInterval)minimumDuration;
-(UIImage *)captureSnapshotImageForActiveBundleId:(NSString *)bundleId;
-(UIImage *)captureSnapshotImageForActiveBundleId:(NSString *)bundleId
                                 sourceOrientation:(UIInterfaceOrientation)sourceOrientation;
-(BOOL)isOwnedHostedSceneCapabilityProven:(FBScene *)scene bundleId:(NSString *)bundleId;
-(UIInterfaceOrientation)publishedSourceOrientationForScene:(FBScene *)scene;
-(CGSize)publishedSourceCanvasSizeForScene:(FBScene *)scene;
-(UIInterfaceOrientation)currentHostedPresentationSourceOrientation;
-(UIInterfaceOrientation)currentSystemInterfaceOrientation;
-(BOOL)canonicalizeHostedSourceForCurrentOrientationWithGeneration:(NSUInteger)generation;
-(BOOL)hasPendingRuntimeOrientationHandoffForScene:(FBScene *)scene
                                        generation:(NSUInteger)generation;
-(void)abandonOwnedHostedSceneForBundleId:(NSString *)bundleId;

-(void)activateScene:(FBScene *)scene
         forBundleId:(NSString *)bundleId
          generation:(NSUInteger)generation;
-(void)releaseForegroundLease;
-(void)releaseForegroundLeaseDiscardingOwnedScene;
-(void)releaseForegroundLeaseForTargetSwitch;
-(void)invalidateIOS26PresentationContainersInSceneStack:(UIView *)sceneStack;
-(void)refreshPresentationForCurrentOrientation;
/// 【0.4.18】胖屏画布：把宿主 scene frame 真实改成 size（App 按新比例重排，Stheno 同款）；
/// size 为零 = 还原为全屏画布。返回是否成功下发。
-(BOOL)applyHostedSceneFrameSize:(CGSize)size forBundleId:(NSString *)bundleId;
-(void)recoverIOS26HostedContentAfterOrientationChange;
-(BOOL)isForegroundLeaseActiveForScene:(FBScene *)scene
                              bundleId:(NSString *)bundleId
                            generation:(NSUInteger)generation;
@end
