//
//  POSceneSession.h
//  PullOverMF
//
//  【M1 / S1】会话作用域状态容器 —— 单窗托管状态「对象化」
//
//  背景：ContextHostManager 原先把「当前托管窗口」的全部状态（托管场景 / 前台租约 /
//  进程断言 / 已发布呈现栈 / 方向权威 / 自有场景判定 / 系统托管快照 / 恢复标记 …）
//  都挂在自己的 ivar 上，因此天然只能承载 **一个** 浮窗。
//  M2（多浮窗）要求这些状态「每窗一份」，所以先在本步把它们集中到本对象：
//    · 状态搬家到 POSceneSession；
//    · ContextHostManager 对外接口 **一字未改**（全部转发访问器）；
//    · 本步仍只创建 **一个** 会话（primarySession）⇒ 行为零变化。
//  多会话注册表 + 按会话路由 delegate 见下一步 S2（本文件届时不变）。
//
//  ⚠️ 跨会话共享的「多片保活槽位表」pinnedLive* 与 bootstrappedProcessPIDs 不搬，
//     仍留在 ContextHostManager（它们是 key=bundleId 的多片表，天然跨会话）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "ContextInterfaces.h"

@interface POSceneSession : NSObject

// ---- 托管组 ----
@property (nonatomic, strong) FBScene *hostedScene;
@property (nonatomic, strong) FBSceneLayerManager *hostedLayerManager;
@property (nonatomic, strong) FBSceneHostManager *hostedFallbackHostManager;
@property (nonatomic, copy) NSString *hostedBundleId;
@property (nonatomic, assign) BOOL observingLayers;
@property (nonatomic, weak) FBScene *observedClientSettingsScene;
@property (nonatomic, weak) FBScene *observedContentStateScene;

// ---- 租约与进程断言组 ----
@property (nonatomic, assign, getter=isForegroundLeaseActive) BOOL foregroundLeaseActive;
@property (nonatomic, assign) NSUInteger activeLeaseGeneration;
@property (nonatomic, strong) id processAssertion;

// ---- 发布（呈现栈）组 ----
@property (nonatomic, strong) FBScene *publishedScene;
@property (nonatomic, strong) UIView *publishedSceneStack;
@property (nonatomic, strong) id ios26PresentationContext;
@property (nonatomic, weak) UIView *ios26PresentationContainer;
@property (nonatomic, copy) NSArray<FBSceneLayer *> *publishedMainLayers;
@property (nonatomic, assign) CGSize publishedSceneStackSize;
@property (nonatomic, assign) UIInterfaceOrientation publishedSceneStackOrientation;
@property (nonatomic, assign) BOOL forceNextPublishedSceneStackRebuild;

// ---- 自有场景组 ----
@property (nonatomic, strong) FBScene *ownedHostedScene;
@property (nonatomic, copy) NSString *ownedHostedBundleId;
@property (nonatomic, assign) int ownedHostedProcessPID;
@property (nonatomic, assign) BOOL ownedHostedSceneServerFrameCanonicalized;
@property (nonatomic, assign) BOOL ownedHostedSceneCapabilityProven;

// ---- 系统托管快照组 ----
@property (nonatomic, weak) FBScene *systemHostedSnapshotScene;
@property (nonatomic, strong) id systemHostedOriginalSettings;
@property (nonatomic, assign) CGRect systemHostedOriginalFrame;
@property (nonatomic, assign) BOOL systemHostedInitialFrameApplied;
@property (nonatomic, assign) BOOL systemHostedServerFrameCanonicalized;

// ---- 方向权威组 ----
@property (nonatomic, assign) UIInterfaceOrientation hostedInterfaceOrientation;
@property (nonatomic, assign) UIInterfaceOrientation activeSurfaceSourceOrientation;
@property (nonatomic, assign) BOOL runtimeHostedOrientationAuthorityActive;
@property (nonatomic, assign) BOOL runtimeClientOrientationBaselineEstablished;
@property (nonatomic, assign) BOOL retainedRuntimeSourceRebasePending;
@property (nonatomic, assign) BOOL applyingHostedSettingsInternally;
@property (nonatomic, assign) UIInterfaceOrientation pendingRuntimeOrientationNotification;
@property (nonatomic, assign) NSUInteger pendingRuntimeOrientationNotificationGeneration;
@property (nonatomic, assign) UIInterfaceOrientation presentationInterfaceOrientation;

// ---- 重连与 iOS26 恢复组 ----
@property (nonatomic, copy) NSString *pendingRemnantReconnectBundleId;
@property (nonatomic, copy) NSString *remnantReconnectClaimBundleId;
@property (nonatomic, copy) NSString *ownedCanonicalSceneAwaitingLeaseBundleId;
@property (nonatomic, assign) BOOL ios26HostedContentRecoveryPending;
@property (nonatomic, assign) NSUInteger ios26HostedContentRecoveryToken;
@property (nonatomic, assign) BOOL ios26HostedContentAwaitingInvalidation;
@property (nonatomic, assign) BOOL ios26HostedContentUnavailableNotified;
@property (nonatomic, assign) CFTimeInterval ios26HostedContentStableSince;

@end
