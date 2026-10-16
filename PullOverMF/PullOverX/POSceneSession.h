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

// ---- 【M1/S3】会话身份与「窗口认领账本」----
// S1 让状态可以「每窗一份」；S2 让会话可以「按 bundleId 找到」；本步补上第三件：
//   会话的「身份 / 认领 / 回收」在 manager 侧有一份**显式账本**（一片窗口 = 一次认领）。
//   · sessionBundleId   —— 该会话当前代表的窗口 bundleId（长度 0 = 尚未认领具体 App）
//   · mf_claimWindow:   —— 认领一个窗口槽（**幂等**：同一 key 重复认领只算一次）
//   · mf_releaseWindow: —— 释放窗口槽，返回剩余认领数
//   · mf_claimedWindowKeys —— 当前认领的槽位清单（探测日志用）
//   ⚠️ 账本**只用于**「生命周期可观测 + 无泄漏判定」，不参与任何业务判定
//      ⇒ 单窗阶段行为零变化；M2 起「一片 = 一会话」时才用它做归属判定。
@property (nonatomic, copy) NSString *sessionBundleId;
@property (nonatomic, assign, readonly) NSTimeInterval sessionCreatedAt;
@property (nonatomic, assign, readonly) NSUInteger windowClaimCount;
- (NSUInteger)mf_claimWindow:(NSString *)windowKey;
- (NSUInteger)mf_releaseWindow:(NSString *)windowKey;
- (void)mf_releaseAllWindows;
- (NSArray<NSString *> *)mf_claimedWindowKeys;

@end
