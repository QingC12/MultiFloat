//
//  PullOverViewController.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//
//  ============================ 0.3.13 核心改动（log22 + 用户指定新手势方案）============================
//  【log22 实证】0.3.12 四边热区全通（top/bottom/left/right 热区 frame 正常、edge=1/3 均按下），
//  但体验差：①移动只能直上直下（卡片 727 高占屏 932，Y 钳制区间仅 ~48pt）；②左右 22pt 窄条
//  缩放映射太缓（拖 1% 就被吸回），用户感知"无法触发"。用户指定手势方案整体重做：
//  ① **底部中间热区**（宽 50%）= pan 自由移动（X+Y 跟手，松手不吸附——取代上/下边移动）；
//  ② **右下角热区**（64x64）= pan 对角线缩放（向左上滑=缩小、向右下滑=放大，松手吸 50/75/100%）；
//  ③ **左右侧热区** = 改点击：点哪侧停靠哪侧（已停靠该侧再点=还原满尺寸），弹簧动画；
//  ④ 上边热区删除；Y 端点吸附（mfSnapCardVertically）随旧交互一并移除。
//  圆盘侧（MFRingPicker.m）：触发条默认长度 300 → 屏高 30%（减少与抖音左滑/iOS 右缘返回
//  的重叠冲突；跨进程手势无法互斥，缩窄触发带是系统限制下唯一有效缓解）。
//
//  ============================ 0.3.12 核心改动（log21 修复）============================
//  【log21 血泪】0.3.11 四周热区"无法触发"真凶 = 自己的门：
//    Began 用 canMovePortraitHostedLandscapeCardVertically 当总开关，而它要求
//    currentQuickSwitchLayoutMode == HorizontalBottom（横壳竖载场景），
//    竖屏 iPhone 上返回 VerticalSide → 恒 NO → 四条热区 Began 全部静默失效（零日志）。
//    且跟随走的 applyPortraitHostedLandscapeVerticalHandleAnchorY: 内部还有同一道门
//    （handlePanIntent 未设时拒绝）——就算过了 Began 也动不了。
//    教训：**复用别人的链路前先确认它的前置条件在目标场景下成立，静默失效必须打日志**。
//  0.3.12 修复（圆盘/动画零改动）：
//  ① 新增布局无关总开关 mfCanDragCardEdgeNow（面板打开 + baseFrame 有效 + 非滚动/过渡）；
//  ② 跟随移动改走自管 mfApplyCardBottomY:（直接改 keyboardZoomBaseFrame.origin.y +
//     同一套钳制 + 手柄横条锚同步），绕开 PortraitHostedLandscape 专属链路；
//  ③ Began 无条件打 [card] 热区按下 日志 + 安装后回打热区 frame（下轮日志可判别
//     "触摸没到热区"还是"门挡了"）。
//  吸附（位置/缩放）0.3.11 实现本身无门，保持不动。
//
#import "PullOverViewController.h"
#import "POHostSessionController.h"
#import "POQuickSwitchDragCoordinator.h"
#import "POQuickSwitchMetrics.h"
#import "POSplitSessionController.h"
#import "QuickSwitchHorizontalBarView.h"
#import "../POPPath.h"
#import "../POLocalization.h"
#import <objc/message.h>
#include <stdlib.h>
#define HANDLE_EDGE_GAP 5
// 【0.3.13】浮窗手势区：底部整条边=自由移动 / 左右侧=点击停靠；【0.3.21】底带右端=滑动缩放
#define MF_CARD_EDGE_HOTZONE_WIDTH 20.0     // 【0.3.19】卡外热区带宽度（pt，用户指定 20）
#define MF_CARD_EDGE_SCALE_MIN 0.5          // 手动缩放下限
#define MF_CARD_EDGE_SCALE_MAX 1.0          // 手动缩放上限
#define MF_CARD_EDGE_SCALE_SNAP_A 0.5       // 【0.3.21】滑动缩放松手吸附档（用户档位不变）
#define MF_CARD_EDGE_SCALE_SNAP_B 0.75
#define MF_CARD_EDGE_FLICK_CLOSE_VELOCITY 600.0  // 【0.3.19】甩边关闭的最小右滑速度（pt/s）
#define MF_CARD_EDGE_FLICK_CLOSE_MARGIN 44.0     // 【0.3.19】卡片右缘距屏幕右缘小于此值才可甩边关闭
#define MF_CARD_EDGE_CORNER_SCALE_WIDTH 84.0     // 【0.3.21】右下角"滑动缩放"热区宽度（pt）
#define MF_CARD_EDGE_CORNER_SCALE_INSIDE 40.0    // 【0.3.22】热区向卡片**内侧**压入的高度（pt）
#define MF_CARD_EDGE_SCALE_DRAG_SPAN 220.0       // 【0.3.21】对角位移 220pt ≈ 缩放一整个档位
#define MF_CARD_EDGE_TAP_SLOP 16.0               // 【0.3.22】停靠小窗上"点"的位移容差（小于它=还原）
#define MF_CARD_DOCK_ASPECT (16.0 / 9.0)         // 【0.3.22】停靠小窗固定 16:9（用户 log31 指定）
#define MF_CARD_DOCK_HEIGHT_RATIO 0.145          // 小窗高 ≈ 屏高 14.5%（本机 932 → 135，宽 240）
#define MF_CARD_DOCK_MIN_HEIGHT 108.0
#define MF_CARD_DOCK_MAX_WIDTH_RATIO 0.66        // 小窗最宽不超过屏宽 66%
#define MF_CARD_EDGE_HOTZONE_TAG_BOTTOM 11  // 底部移动热区带
#define MF_CARD_EDGE_HOTZONE_TAG_LEFT 12    // 左侧点击热区带
#define MF_CARD_EDGE_HOTZONE_TAG_RIGHT 13   // 右侧点击热区带
#define MF_CARD_EDGE_HOTZONE_TAG_TOP 14     // 【0.3.19】顶部点击关闭热区带
#define CONTENT_EDGE_GAP 5
#define CONTENT_CORNER_RADIUS 20   // 上游默认值（本 fork 改用 MFPanelCornerRadius()，见下）

// ===== 【MF 0.1.1】Stheno 风格面板几何 =====
// 上游行为：卡片宽 ≈ 整屏宽（scale 上限 1.0）且贴右缘滑入 —— 视觉上"非常大、紧贴屏幕边缘"。
// 本 fork 改为：面板按屏宽比例缩小 → 打开后**停在屏幕正中**；圆角加大（默认 44，上游 20）。
// 两个参数都可在 /var/mobile/Library/Preferences/com.mlgm.pulloverx.plist 里直接调整，
// 改完 respring 生效（无需重新编译）：
//     mfPanelWidthRatio   0.30 ~ 1.00   面板宽度占屏幕比例（默认 0.663）
//     mfPanelCornerRadius 0    ~ 80     面板圆角（默认 44）
// 【0.3.22 用户 log31】"悬浮窗默认打开的尺寸有点大" ⇒ 默认比例 0.78 → 0.663（= 原来默认的 85%，
// 本机 335x727 → 285x618）。scale 语义不变（1.0 = 新默认尺寸），四边手势的档位全部跟着变。
#define MF_PANEL_WIDTH_RATIO_KEY      @"mfPanelWidthRatio"
#define MF_PANEL_CORNER_RADIUS_KEY    @"mfPanelCornerRadius"
#define MF_DEFAULT_PANEL_WIDTH_RATIO  0.663
#define MF_LEGACY_PANEL_WIDTH_RATIO   0.78      // 【0.3.22】旧默认值 → 视为"没改过"，用新默认
#define MF_DEFAULT_PANEL_CORNER_RADIUS 44.0

static NSUserDefaults *MFGeometryDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverx"];
        if (defaults == nil) {
            defaults = [NSUserDefaults standardUserDefaults];
        }
    });
    return defaults;
}

static CGFloat MFGeometryNumber(NSString *key, CGFloat fallback) {
    id value = [MFGeometryDefaults() objectForKey:key];
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double number = [value doubleValue];
        if (isfinite(number) && number > 0.0) {
            return (CGFloat)number;
        }
    }
    return fallback;
}

/// 面板宽度占屏幕（画布）比例，钳制在 0.30 ~ 1.00
/// 【0.3.22】plist 里若还是旧的 0.78（= 从没手动改过、只是老默认写进去过），
/// 按新默认 0.663 处理，否则用户会觉得"新版本没生效"。
static CGFloat MFPanelWidthRatio(void) {
    CGFloat ratio = MFGeometryNumber(MF_PANEL_WIDTH_RATIO_KEY, MF_DEFAULT_PANEL_WIDTH_RATIO);
    if (fabs(ratio - MF_LEGACY_PANEL_WIDTH_RATIO) < 0.0005) {
        return MF_DEFAULT_PANEL_WIDTH_RATIO;
    }
    return MIN(MAX(ratio, 0.30), 1.00);
}

/// 面板圆角（默认 44，比上游 20 明显更圆），钳制在 0 ~ 80
static CGFloat MFPanelCornerRadius(void) {
    CGFloat radius = MFGeometryNumber(MF_PANEL_CORNER_RADIUS_KEY, MF_DEFAULT_PANEL_CORNER_RADIUS);
    return MIN(MAX(radius, 0.0), 80.0);
}

// 【MF 0.1.2】面板打开后，手柄（nub）与卡片右边缘之间的间距，默认 6pt
#define MF_PANEL_HANDLE_GAP_KEY @"mfPanelHandleGap"

static CGFloat MFPanelHandleEdgeGap(void) {
    CGFloat gap = MFGeometryNumber(MF_PANEL_HANDLE_GAP_KEY, 6.0);
    return MIN(MAX(gap, 0.0), 40.0);
}
#define CONTENT_SHADOW_OPACITY 0.28
#define CONTENT_SHADOW_FADE_DISTANCE 12.0
#define CLOSED_CONTENT_OFFSET_EPSILON 0.5
#define PO_KEYBOARD_ZOOM_REQUESTED_SCALE 1.60
#define PO_KEYBOARD_ZOOM_MINIMUM_USEFUL_SCALE 1.12
#define PO_CARD_SCALE_EPSILON 0.001
#define PO_HANDLE_CARD_SCALE_ANIMATION_DURATION 0.25
#define PO_SCALED_PROGRAMMATIC_CLOSE_DURATION 0.28
#define PO_SCALED_CLOSE_POST_COMMIT_CLEANUP_DELAY 0.035
#define PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION 2.0

typedef NS_OPTIONS(NSUInteger, POKeyboardZoomSuspensionReason) {
    POKeyboardZoomSuspensionNone     = 0,
    POKeyboardZoomSuspensionDragging = 1 << 0,
    POKeyboardZoomSuspensionRotation = 1 << 1,
    POKeyboardZoomSuspensionClosing  = 1 << 2,
};

typedef NS_ENUM(NSInteger, POKeyboardNotificationState) {
    POKeyboardNotificationStateUnknown = 0,
    POKeyboardNotificationStateHidden,
    POKeyboardNotificationStateVisible,
};

typedef NS_ENUM(NSUInteger, POCardScaleContext) {
    POCardScaleContextNone,
    POCardScaleContextLandscapeShellPortraitHosted,
};

typedef NS_ENUM(NSUInteger, POCardScaleTransitionSource) {
    POCardScaleTransitionSourceKeyboard,
    POCardScaleTransitionSourceHandle,
    POCardScaleTransitionSourceReconcile,
};

typedef NS_ENUM(NSUInteger, POPanelState) {
    POPanelStateClosed,
    POPanelStateOpening,
    POPanelStateInteractive,
    POPanelStateOpen,
    POPanelStateClosing,
};

typedef NS_ENUM(NSUInteger, POQuickSwitchLayoutMode) {
    POQuickSwitchLayoutModeVerticalSide,
    POQuickSwitchLayoutModeHorizontalBottom,
};

typedef NS_ENUM(NSUInteger, POInteractionMode) {
    POInteractionModeSplitPassthrough,
    POInteractionModeDrawerModal,
    POInteractionModeQuickSwitchModal,
};

typedef NS_ENUM(NSUInteger, POHandlePanIntent) {
    POHandlePanIntentNone,
    POHandlePanIntentRevealHandle,
    POHandlePanIntentNubHandle,
    POHandlePanIntentOpenPanel,
    POHandlePanIntentClosePanel,
    POHandlePanIntentVerticalCardMove,
};

static BOOL POIsConcretePresentationOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static CGFloat POPresentationAngleForOrientation(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return (CGFloat)M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return (CGFloat)-M_PI_2;
        case UIInterfaceOrientationPortraitUpsideDown:
            return (CGFloat)M_PI;
        case UIInterfaceOrientationPortrait:
        default:
            return 0;
    }
}

/// 【0.3.19】卡外热区带宿主：frame 是"卡片矩形外扩一圈"的大区域，但**只有 20pt 带子可点**——
/// 点在中间空隙（=卡片本体）必须透传给 App 内容，否则浮窗内 App 全都点不了。
/// hitTest 返回 nil = 继续让下层（scrollView 内容 / backdrop）接管。
@interface MFEdgeBandHostView : UIView
@end

@implementation MFEdgeBandHostView
-(UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event{
    UIView *result = [super hitTest:point withEvent:event];
    return result == self ? nil : result;   // 命中带子（子视图）→ 返回带子；命中自身空隙 → 透传
}
@end

@interface PullOverViewController ()<POHostSessionControllerDelegate, UIGestureRecognizerDelegate>{
    NSString *pinnedBundleId;
    UIView *contextView;
    UIView *externalSceneStack;
    
    UIView *mirrorZoneView;
    CAShapeLayer *mirrorZoneBorder;
    UIImageView *mirrorZoneIconView;
    BOOL mirrorZoneHighlighted;
    UIView *panelBackdropView;
    UIView *quickSwitchBackdropView;
    UITapGestureRecognizer *panelBackdropTapGestureRecognizer;
    UIPanGestureRecognizer *panelBackdropPanGestureRecognizer;
    UIView *shadowView;
    UIView *keyboardZoomContainer;
    UIView *cantHostCanvas;
    UIImageView *cantHostIconView;
    UILabel *cantHostLabel;
    
    POHostSessionController *hostSession;
    POPanelState panelState;
    BOOL interactiveHostIntentIssued;
    BOOL interactiveHostResumeRequired;
    NSString *presentationBundleId;
    FBScene *presentationSceneIdentity;
    CGSize presentationCanvasSize;
    UIInterfaceOrientation presentationOrientation;
    CGSize presentationSourceCanvasSize;
    UIInterfaceOrientation presentationSourceOrientation;
    UIView *presentationSnapshotView;
    NSString *presentationSnapshotBundleId;
    FBScene *presentationSnapshotSceneIdentity;
    BOOL presentationSnapshotIsTargetPlaceholder;
    BOOL presentationSnapshotCapturedLeftHanded;
    BOOL runtimeCategoryTransitionSnapshotActive;
    BOOL runtimeCategoryTransitionSnapshotFallbackArmed;
    BOOL runtimeCategoryTransitionSnapshotFading;
    CGSize presentationSnapshotSize;
    UIInterfaceOrientation presentationSnapshotOrientation;
    UIInterfaceOrientation presentationSnapshotRenderSourceOrientation;
    NSMutableDictionary<NSString *, NSDictionary *> *presentationSnapshotCache;
    NSMutableArray<NSString *> *presentationSnapshotCacheOrder;
    CADisplayLink *presentationHandoffDisplayLink;
    NSUInteger presentationHandoffGeneration;
    NSUInteger presentationHandoffStableFrames;
    NSString *presentationHandoffBundleId;
    BOOL presentationRetainedAfterRelease;
    int retainedPresentationProcessPID;
    CGPoint handlePoint;
    CGFloat chromeScale;
    CGFloat scale;
    CGFloat contentLayoutWidth;
    CGFloat contentLayoutHeight;   // 【0.3.22】卡片基准高度（与 contentLayoutWidth 同源；停靠还原/关闭复位要用，故必须是 ivar）
    UIInterfaceOrientation hostedLayoutOrientation;
    BOOL pendingOpenState;
    CGFloat panelPanStartOffsetX;
    POHandlePanIntent handlePanIntent;
    BOOL handlePanStartedNubbed;
    CGFloat panelVerticalMoveStartAnchorY;
    BOOL scrollSnapAnimationInProgress;
    BOOL quickSwitchOpeningApp;
    QuickSwitchHorizontalBarView *quickSwitchHorizontalBarView;
    UIView *quickSwitchInteractionOverlayView;
    UIView<POQuickSwitchMenuPresenting> *presentedQuickSwitchMenu;
    POQuickSwitchDragCoordinator *quickSwitchDragCoordinator;
    NSUInteger quickSwitchPrewarmGeneration;
    NSString *quickSwitchPrewarmBundleId;
    NSUInteger deferredOpenGeneration;
    NSString *externallyActivatedBundleId;
    NSUInteger externallyActivatedGeneration;
    NSUInteger handleIconRefreshGeneration;
    BOOL showingCantHost;
    BOOL quickSwitchYieldActive;
    CGRect quickSwitchSavedContainerFrame;
    CGRect keyboardZoomBaseFrame;
    // 【0.3.19】卡外热区带（用户指令 log28：所有手势都在浮窗外紧贴边缘，20pt；
    // 0.3.13~0.3.19 的卡内热区被 App 内容视图整层压死——`移动热区按下`全程只触发过 1 次、
    // 捏合 0 次，所有"生效"的功能全是 backdrop 点击，实证卡内触摸根本到不了热区）。
    UIView *mfEdgeBandHost;             // 热区带宿主（frame=卡rect外扩20，hitTest 只认带子、空隙透传）
    UIView *mfEdgeBandLeft;             // 左带：点击=停靠左
    UIView *mfEdgeBandRight;            // 右带：点击=停靠右
    UIView *mfEdgeBandBottom;           // 底带：pan=自由移动（左段）
    UIView *mfEdgeBandBottomRight;      // 【0.3.21】底带右端：pan=滑动缩放（替代双指捏合）
    UIView *mfEdgeBandTop;              // 顶带：点击=关闭
    UIView *mfDockedTapView;            // 【0.3.21】停靠态盖在小窗上的透明层：单击=还原停靠前尺寸，拖动=移动小窗
    NSInteger mfEdgeDragMode;           // 0=无 1=自由移动 2=滑动缩放
    NSInteger mfDockedSide;             // 【0.3.20】停靠边：0=未停靠 −1=停靠左 1=停靠右（"再点同侧=还原"只认它）
    BOOL mfEdgeDragLoggedChanged;       // 【0.3.20】本次拖动是否已打过"跟手首帧"日志
    BOOL mfUserCardPositionPinned;      // 【0.3.20】用户拖过/停靠过 → 布局 passe 不得把卡片拉回标准打开位
    CGFloat mfEdgeDragStartBottomY;     // 【0.3.13】自由移动起点（卡片底边 Y）
    CGFloat mfEdgeDragStartX;           // 【0.3.13】自由移动起点（卡片 origin.x）
    CGFloat mfEdgeDragStartScale;       // 滑动缩放/捏合缩放起点
    CGFloat mfUserCardScaleOverride;    // >0 = 用户手动缩放档位（键盘弹出/面板关闭时清除）
    CGFloat mfPreDockScale;             // 【0.3.21】停靠前缩放档位（点小窗还原用；1.0=满尺寸）
    CGRect mfPreDockFrame;              // 【0.3.21】停靠前内容坐标 frame（点小窗还原用）
    CGRect mfDockedCardFrame;           // 【0.3.22】停靠小窗的 16:9 内容坐标 frame（停靠的"真身"）
    BOOL mfEdgeDragFromDocked;          // 【0.3.22】本次拖动起手自"停靠小窗盖层"（小位移=还原）
    BOOL mfManualScaleAnchorRight;      // 【0.3.19】手动缩放锚点：NO=左上角（默认，用户指定） YES=右上角（右侧停靠）
    UIView *handleVisualHandoffSnapshotView;
    NSUInteger handleVisualHandoffGeneration;
    BOOL runtimeHostedCategoryTransitionAnimating;
    NSUInteger runtimeHostedCategoryTransitionGeneration;
    BOOL hostedCategoryTransitionPending;
    FBScene *deferredRuntimePublishedScene;
    UIView *deferredRuntimePublishedSceneStack;
    NSString *deferredRuntimePublishedBundleId;
    NSUInteger deferredRuntimePublishedGeneration;
    BOOL runtimeDeferredPublicationStageScheduled;
    BOOL runtimeScenePublicationStaging;
    CGFloat portraitHostedLandscapeHandleAnchorY;
    POKeyboardNotificationState keyboardNotificationState;
    BOOL hostedKeyboardLayerPresent;
    BOOL keyboardHideAnimationInFlight;
    NSUInteger keyboardStateHostGeneration;
    BOOL keyboardZoomApplied;
    POKeyboardZoomSuspensionReason keyboardZoomSuspensionReasons;
    NSUInteger keyboardZoomGeneration;
    BOOL keyboardZoomSuppressedForCurrentSession;
    CGFloat appliedCardScale;
    CGFloat closingFrozenCardScale;
    BOOL scaledProgrammaticCloseAnimating;
    BOOL scaledProgrammaticCloseNeedsLayout;
    BOOL deferScaledCloseSessionCleanup;
    NSTimeInterval lastKeyboardAnimationDuration;
    UIViewAnimationOptions lastKeyboardAnimationOptions;
    NSNumber *origOffset;
    CGSize lastLaidOutSize;
}

-(void)retainPresentationAfterReleaseIfPossible;
-(BOOL)hasLiveRetainedPresentationForBundleId:(NSString *)bundleId;
-(UIInterfaceOrientation)cachedPresentationOrientationForBundleId:(NSString *)bundleId;
-(UIInterfaceOrientation)resolvedHostedOrientationForBundleId:(NSString *)bundleId
                                                     manager:(ContextHostManager *)manager;
-(void)flushDeferredRuntimeScenePublicationIfNeeded;
-(void)scheduleRuntimeScenePublicationStagingIfNeeded;
-(BOOL)prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:(UIInterfaceOrientation)sourceOrientation;
-(void)prewarmRuntimeCategoryTransitionSnapshot;
-(void)retargetRuntimeCategoryTransitionSnapshotForOrientation:(UIInterfaceOrientation)orientation;
-(void)beginQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu;
-(void)finishQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu;
-(void)dismissPresentedQuickSwitchMenuImmediately;
-(void)hideQuickSwitchBackdropImmediately;
-(void)refreshHandleIconIfNeeded;
-(void)resetAutoNubTimerWithMinimumDelay:(NSTimeInterval)minimumDelay;

@end

@implementation PullOverViewController
@synthesize scrollView, handleScrollView;

- (void)viewDidLoad {
    [super viewDidLoad];
    MFLog(@"[ui] 面板视图就绪（PullOverMF 已加载，日志见 /var/mobile/PullOverMF.log）");
    panelBackdropView = [[UIView alloc] initWithFrame:self.view.bounds];
    panelBackdropView.backgroundColor = UIColor.blackColor;
    panelBackdropView.alpha = 0;
    panelBackdropView.userInteractionEnabled = YES;
    [self.view addSubview:panelBackdropView];

    panelBackdropTapGestureRecognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(panelBackdropDidTap:)];
    panelBackdropTapGestureRecognizer.delegate = self;
    [panelBackdropView addGestureRecognizer:panelBackdropTapGestureRecognizer];

    panelBackdropPanGestureRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(panelBackdropDidPan:)];
    panelBackdropPanGestureRecognizer.delegate = self;
    [panelBackdropView addGestureRecognizer:panelBackdropPanGestureRecognizer];

    mirrorZoneView = [[UIView alloc] initWithFrame:CGRectZero];
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneView.layer.cornerCurve = kCACornerCurveContinuous;
    mirrorZoneView.alpha = 0;
    [self.view addSubview:mirrorZoneView];

    mirrorZoneBorder = [CAShapeLayer layer];
    mirrorZoneBorder.strokeColor = UIColor.whiteColor.CGColor;
    mirrorZoneBorder.fillColor = nil;
    mirrorZoneBorder.lineWidth = PO_QUICKSWITCH_DROP_BORDER_WIDTH;
    mirrorZoneBorder.lineDashPattern = PO_QUICKSWITCH_DROP_DASH_PATTERN;
    mirrorZoneBorder.lineCap = kCALineCapRound;
    [mirrorZoneView.layer addSublayer:mirrorZoneBorder];

    mirrorZoneIconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    mirrorZoneIconView.image = [[UIImage systemImageNamed:@"arrow.left.arrow.right"]
                                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    mirrorZoneIconView.tintColor = UIColor.whiteColor;
    mirrorZoneIconView.contentMode = UIViewContentModeScaleAspectFit;
    [mirrorZoneView addSubview:mirrorZoneIconView];

    scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [scrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    [scrollView setBackgroundColor:[UIColor clearColor]];
    [scrollView setShowsHorizontalScrollIndicator:NO];
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [scrollView setPagingEnabled:NO];
    scrollView.bounces = YES;
    scrollView.alwaysBounceHorizontal = YES;
    scrollView.scrollEnabled = NO;
    [scrollView setDelegate:self];
    [self.view addSubview:scrollView];
    
    handleScrollView = [[BaseScrollView alloc] initWithFrame:CGRectZero];
    [handleScrollView setShowsVerticalScrollIndicator:NO];
    [handleScrollView setBackgroundColor:[UIColor clearColor]];
    [handleScrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    [handleScrollView setClipsToBounds:NO];
    handleScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [handleScrollView setDelegate:self];
    [scrollView addSubview:handleScrollView];

    
    self.handle = [[POHandle alloc] initWithController:self];
    [self.handle setDelegate:self];
    [handleScrollView addSubview:self.handle];
    // 【0.3.19】移除手柄按钮（用户指令：浮窗操作全手势，像 Stheno/TrollOpen 一样不再依靠手柄）：
    // 手柄视图永久隐藏 + 禁交互。POHandle 自身与管理代码从不改 hidden（只动 alpha，
    // 对 hidden 视图无效），故设一次即永久生效；内部布局/开合动画机器照常运行但不可见不可触。
    // 打开浮窗 = 圆盘呼出选 App；关闭浮窗 = 点浮窗外空白。手势：底边拖移动 / 右下角缩放 / 左右点击停靠。
    self.handle.hidden = YES;
    self.handle.userInteractionEnabled = NO;
    
    self.quickSwitchTableView = [[QuickSwitchTableView alloc] init];
    self.quickSwitchTableView.selectionDelegate = self;
    [handleScrollView addSubview:self.quickSwitchTableView];

    quickSwitchInteractionOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    quickSwitchInteractionOverlayView.backgroundColor = [UIColor clearColor];
    quickSwitchInteractionOverlayView.clipsToBounds = NO;
    quickSwitchInteractionOverlayView.userInteractionEnabled = NO;
    quickSwitchInteractionOverlayView.hidden = YES;
    [self.view addSubview:quickSwitchInteractionOverlayView];

    quickSwitchDragCoordinator = [[POQuickSwitchDragCoordinator alloc]
        initWithOverlayView:quickSwitchInteractionOverlayView];
    [mirrorZoneView removeFromSuperview];
    [quickSwitchInteractionOverlayView addSubview:mirrorZoneView];

    quickSwitchHorizontalBarView = [[QuickSwitchHorizontalBarView alloc] init];
    quickSwitchHorizontalBarView.selectionDelegate = self;
    [quickSwitchInteractionOverlayView addSubview:quickSwitchHorizontalBarView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.contentView.layer.cornerRadius = MFPanelCornerRadius();   // 【MF】更大更圆
    if (@available(iOS 13.0, *)) {
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.contentView.clipsToBounds = YES;

    keyboardZoomContainer = [[UIView alloc] initWithFrame:CGRectZero];
    keyboardZoomContainer.backgroundColor = [UIColor clearColor];
    keyboardZoomContainer.clipsToBounds = NO;    keyboardZoomContainer.hidden = YES;
    [scrollView addSubview:keyboardZoomContainer];

    quickSwitchBackdropView = [[UIView alloc] initWithFrame:scrollView.bounds];
    quickSwitchBackdropView.backgroundColor = UIColor.blackColor;
    quickSwitchBackdropView.alpha = 0;
    quickSwitchBackdropView.userInteractionEnabled = YES;
    [scrollView addSubview:quickSwitchBackdropView];
    [scrollView bringSubviewToFront:handleScrollView];
    
    shadowView = [[UIView alloc] initWithFrame:keyboardZoomContainer.bounds];
    shadowView.backgroundColor = [UIColor clearColor];
    shadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowView.layer.shadowOffset = CGSizeMake(0, 1);
    shadowView.layer.shadowRadius = 8;
    shadowView.layer.shadowOpacity = 0;
    shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds cornerRadius:MFPanelCornerRadius()].CGPath;
    [keyboardZoomContainer addSubview:shadowView];

    [keyboardZoomContainer addSubview:self.contentView];

    // 【0.3.19】卡外热区带：所有手势都在卡片外 20pt 环带（卡内触摸全归 App 内容）。
    [self mfInstallCardEdgeBands];

    NSString *savedPinnedBundleId = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastPinnedBundleId"];
    if ([POApplicationHelper isUserFacingApplicationBundleId:savedPinnedBundleId]) {
        pinnedBundleId = savedPinnedBundleId;
    } else {
        if (savedPinnedBundleId.length > 0) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"lastPinnedBundleId"];
        }
        pinnedBundleId = @"com.apple.MobileSMS";
    }
    [self refreshHandleIconIfNeeded];
    
    panelState = POPanelStateClosed;
    interactiveHostIntentIssued = NO;
    interactiveHostResumeRequired = NO;
    hostSession = [[POHostSessionController alloc] initWithManager:[ContextHostManager sharedInstance]];
    hostSession.delegate = self;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidChangeFrame:) name:UIKeyboardDidChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];

    lastKeyboardAnimationDuration = 0.25;
    lastKeyboardAnimationOptions = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction |
        (UIViewAnimationOptionCurveEaseInOut << 16);
    keyboardZoomSuppressedForCurrentSession = NO;
    appliedCardScale = 1.0;
    closingFrozenCardScale = 1.0;
    scaledProgrammaticCloseAnimating = NO;
    scaledProgrammaticCloseNeedsLayout = NO;
    deferScaledCloseSessionCleanup = NO;

    [self applyCurrentSettings];
}

-(void)applyCurrentSettings{
    if (!self.isViewLoaded) {
        return;
    }
    if (scaledProgrammaticCloseAnimating) {
        scaledProgrammaticCloseNeedsLayout = YES;
        return;
    }
    [self dismissPresentedQuickSwitchMenuImmediately];
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGAffineTransform contentTransform = isLeftHanded
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
    self.handle.imageView.transform = contentTransform;
    [self.quickSwitchTableView refreshLayoutDirection];
    [quickSwitchHorizontalBarView refreshLayoutDirection];
    [quickSwitchDragCoordinator refreshLayoutDirection];

    if (![[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] && origOffset) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:YES];
        origOffset = nil;
    }

    [self.handle refreshHandleSizeAnimated:NO];
    [self applyLayoutPreservingHandlePosition:YES];
    [self.handle refreshNubbedPositionAnimated:NO];
    [self reevaluateKeyboardZoomAnimated:YES];
    if (self.view.window && self.view.window.userInteractionEnabled && self.view.alpha > 0.01) {
        [self resetAutoNubTimer];
    } else {
        [self cancelAutoNubTimer];
    }
}

-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)refreshHandleIconIfNeeded{
    NSUInteger generation = ++handleIconRefreshGeneration;
    NSString *bundleId = [pinnedBundleId copy];
    if (bundleId.length == 0) {
        self.handle.imageView.image = nil;
        return;
    }

    UIImage *image = [POApplicationHelper imageForBundleId:bundleId];
    if (image) {
        self.handle.imageView.image = image;
        return;
    }

    for (NSNumber *delay in @[@0.15, @0.5, @1.5, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != self->handleIconRefreshGeneration ||
                ![self->pinnedBundleId isEqualToString:bundleId]) {
                return;
            }
            UIImage *retryImage = [POApplicationHelper imageForBundleId:bundleId];
            if (retryImage) {
                self.handle.imageView.image = retryImage;
            }
        });
    }
}

-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];

    if (!CGSizeEqualToSize(lastLaidOutSize, self.view.bounds.size)) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    [self reconcilePresentedContainerGeometry];
    [self mfUpdateEdgeBands];   // 【0.3.19】布局 passe 保险：带子始终包住卡片当前屏幕矩形
}

-(void)viewSafeAreaInsetsDidChange{
    [super viewSafeAreaInsetsDidChange];
    [self applyLayoutPreservingHandlePosition:YES];
}

-(void)reconcilePresentedContainerGeometry{
    if (panelState == POPanelStateClosed || keyboardZoomContainer.hidden ||
        quickSwitchYieldActive || keyboardZoomApplied ||
        runtimeHostedCategoryTransitionAnimating ||
        !CGAffineTransformEqualToTransform(keyboardZoomContainer.transform,
                                            CGAffineTransformIdentity) ||
        CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return;
    }

    CGRect currentFrame = keyboardZoomContainer.frame;
    if (fabs(CGRectGetMinX(currentFrame) - CGRectGetMinX(keyboardZoomBaseFrame)) <= 0.25 &&
        fabs(CGRectGetMinY(currentFrame) - CGRectGetMinY(keyboardZoomBaseFrame)) <= 0.25 &&
        fabs(CGRectGetWidth(currentFrame) - CGRectGetWidth(keyboardZoomBaseFrame)) <= 0.25 &&
        fabs(CGRectGetHeight(currentFrame) - CGRectGetHeight(keyboardZoomBaseFrame)) <= 0.25) {
        return;
    }

    [keyboardZoomContainer.layer removeAllAnimations];
    keyboardZoomContainer.frame = keyboardZoomBaseFrame;
    shadowView.frame = keyboardZoomContainer.bounds;
    self.contentView.frame = keyboardZoomContainer.bounds;
    shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds
                                                              cornerRadius:MFPanelCornerRadius()].CGPath;
    [self layoutContextView];
}

#pragma mark - Geometry

-(CGFloat)trailingSafeAreaInset{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGFloat viewTrailingInset = isLeftHanded ? viewInsets.left : viewInsets.right;
    CGFloat windowTrailingInset = isLeftHanded ? windowInsets.left : windowInsets.right;    return MAX(0, MAX(viewTrailingInset, windowTrailingInset));
}

-(CGFloat)leadingSafeAreaInset{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGFloat viewLeadingInset = isLeftHanded ? viewInsets.right : viewInsets.left;
    CGFloat windowLeadingInset = isLeftHanded ? windowInsets.right : windowInsets.left;
    return MAX(0, MAX(viewLeadingInset, windowLeadingInset));
}

-(BOOL)isPanelActive{
    return panelState != POPanelStateClosed;
}

-(NSString *)hammerItTargetBundleId{
    UIView *view = self.viewIfLoaded;
    UIWindow *window = view.window;
    NSString *bundleId = hostSession.activeBundleId;
    if (!window || window.hidden || window.alpha <= 0.01 || view.hidden || view.alpha <= 0.01 ||
        ![self isPanelActive] || hostSession.state != POHostSessionStateLive ||
        !contextView || contextView.hidden || contextView.alpha <= 0.01 ||
        contextView.superview != self.contentView || self.contentView.hidden ||
        bundleId.length == 0 || ![presentationBundleId isEqualToString:bundleId]) {
        return nil;
    }
    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0 || scrollView.contentOffset.x / maximumOffset < 0.02) {
        return nil;
    }
    return [bundleId copy];
}

-(POInteractionMode)baseInteractionModeForHostedOrientation:(UIInterfaceOrientation)hostedOrientation{
    if (!POIsConcretePresentationOrientation(hostedOrientation)) {
        return POInteractionModeSplitPassthrough;
    }
    CGRect bounds = self.view.bounds;
    BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    BOOL hostedIsLandscape = UIInterfaceOrientationIsLandscape(hostedOrientation);
    return shellIsLandscape == hostedIsLandscape
        ? POInteractionModeDrawerModal
        : POInteractionModeSplitPassthrough;
}

-(POInteractionMode)currentInteractionMode{
    if (presentedQuickSwitchMenu) {
        return POInteractionModeQuickSwitchModal;
    }
    if (panelState == POPanelStateClosed) {
        return POInteractionModeSplitPassthrough;
    }
    if (hostedCategoryTransitionPending || runtimeHostedCategoryTransitionAnimating) {
        return POInteractionModeSplitPassthrough;
    }
    return [self baseInteractionModeForHostedOrientation:[self resolvedHostedLayoutOrientation]];
}

-(UIInterfaceOrientation)resolvedHostedLayoutOrientation{
    if (POIsConcretePresentationOrientation(hostedLayoutOrientation)) {
        return hostedLayoutOrientation;
    }

    UIInterfaceOrientation orientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (POIsConcretePresentationOrientation(orientation)) {
        hostedLayoutOrientation = orientation;
    }
    return orientation;
}

-(void)updateInteractionBackdropsAnimated:(BOOL)animated{
    if (!panelBackdropView || !quickSwitchBackdropView || !scrollView) {
        return;
    }
    panelBackdropView.frame = self.view.bounds;
    quickSwitchBackdropView.frame = scrollView.bounds;

    POInteractionMode mode = [self currentInteractionMode];
    CGFloat panelTargetAlpha = scaledProgrammaticCloseAnimating
        ? 0
        : (mode == POInteractionModeDrawerModal ? 0.5 * [self horizontalOpenProgress] : 0);
    CGFloat quickSwitchTargetAlpha = scaledProgrammaticCloseAnimating
        ? 0
        : (mode == POInteractionModeQuickSwitchModal ? 0.5 : 0);

    if (mode == POInteractionModeQuickSwitchModal) {
        [scrollView bringSubviewToFront:quickSwitchBackdropView];
        [scrollView bringSubviewToFront:handleScrollView];
    }

    void (^changes)(void) = ^{
        self->panelBackdropView.alpha = panelTargetAlpha;
        self->quickSwitchBackdropView.alpha = quickSwitchTargetAlpha;
    };
    if (animated) {
        [UIView animateWithDuration:0.20
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:changes
                         completion:nil];
    } else {
        [panelBackdropView.layer removeAllAnimations];
        [quickSwitchBackdropView.layer removeAllAnimations];
        [UIView performWithoutAnimation:changes];
    }
}

-(void)panelBackdropDidTap:(UITapGestureRecognizer *)recognizer{
    if (recognizer.state != UIGestureRecognizerStateEnded ||
        [self currentInteractionMode] != POInteractionModeDrawerModal ||
        panelState != POPanelStateOpen || [self isPanelTransitioning]) {
        return;
    }
    // 【0.3.19 重做（log27 用户指令"尝试修改或者阻断"）】原生"点浮窗外空白=关闭"误伤严重：
    // 卡片近乎满宽（屏 47..382），用户点的"左右边缘"多半落在卡外空白 → 浮窗直接向右收走；
    // 底部中间点击也误关。新语义：
    //   · 点卡片左缘外 → 停靠左侧；右缘外 → 停靠右侧（与卡内 22pt 侧热区同语义，双保险）
    //   · 点卡片上方空白 → 关闭浮窗（保留的关闭途径之一）
    //   · 点卡片下方空白 → 忽略（防误关；底部是移动手势区，指尖经常落在卡外）
    //   · 关闭途径汇总：上方空白点击 / 拖卡片向右甩边 / 圆盘换 App
    CGPoint p = [recognizer locationInView:self.view];
    CGFloat offsetX = [self mfCardScrollOffsetX];
    CGFloat cardWidth = CGRectGetWidth(keyboardZoomBaseFrame);
    if (cardWidth <= 0) {
        return;
    }
    CGFloat cardLeft = CGRectGetMinX(keyboardZoomBaseFrame) - offsetX;
    CGFloat cardRight = cardLeft + cardWidth;
    CGFloat cardTop = CGRectGetMinY(keyboardZoomBaseFrame);
    CGFloat cardBottom = CGRectGetMaxY(keyboardZoomBaseFrame);
    if (p.y > cardBottom - 4.0) {
        MFLog(@"[card] 下方空白点击（屏 %.0f,%.0f）→ 忽略（0.3.19 防误关）", p.x, p.y);
        return;
    }
    if (p.y < cardTop + 4.0) {
        MFLog(@"[card] 上方空白点击（屏 %.0f,%.0f）→ 关闭浮窗", p.x, p.y);
        [self close];
        return;
    }
    if (p.x < cardLeft - 4.0) {
        MFLog(@"[card] 左缘外点击（屏 %.0f）→ 停靠左侧", p.x);
        [self mfSnapCardToSide:NO];
        return;
    }
    if (p.x > cardRight + 4.0) {
        MFLog(@"[card] 右缘外点击（屏 %.0f）→ 停靠右侧", p.x);
        [self mfSnapCardToSide:YES];
        return;
    }
    MFLog(@"[card] 空白点击（屏 %.0f,%.0f）→ 未分类，忽略", p.x, p.y);
}

-(void)panelBackdropDidPan:(UIPanGestureRecognizer *)recognizer{
    if ([self currentInteractionMode] != POInteractionModeDrawerModal &&
        recognizer.state == UIGestureRecognizerStateBegan) {
        return;
    }
    [self handle:self.handle didPanPanel:recognizer];
}

-(BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer{
    if (gestureRecognizer == panelBackdropTapGestureRecognizer) {
        return [self currentInteractionMode] == POInteractionModeDrawerModal &&
            panelState == POPanelStateOpen && ![self isPanelTransitioning];
    }
    if (gestureRecognizer == panelBackdropPanGestureRecognizer) {
        if ([self currentInteractionMode] != POInteractionModeDrawerModal ||
            panelState != POPanelStateOpen || [self isPanelTransitioning]) {
            return NO;
        }
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.view];
        return fabs(velocity.x) > fabs(velocity.y) && fabs(velocity.x) > 20.0;
    }
    return YES;
}

-(UIView *)interactiveViewForWindowPoint:(CGPoint)point event:(UIEvent *)event{
    if (!self.isViewLoaded || self.view.hidden || self.view.alpha <= 0.01) {
        return nil;
    }

    CGPoint pointInView = [self.view convertPoint:point fromView:self.view.window];
    CGPoint handlePointInHandle = [self.handle convertPoint:point fromView:self.view.window];
    if (!self.handle.hidden && self.handle.alpha > 0.01 &&
        [self.handle pointInside:handlePointInHandle withEvent:event]) {
        return self.handle;
    }

    UIView *candidate = [self.view hitTest:pointInView withEvent:event];
    if (candidate && candidate != self.view && candidate != scrollView &&
        candidate != quickSwitchInteractionOverlayView && candidate != panelBackdropView &&
        candidate != quickSwitchBackdropView) {
        for (UIView *view = candidate; view; view = view.superview) {
            if (view == keyboardZoomContainer || view == self.contentView ||
                view == self.quickSwitchTableView || view == quickSwitchHorizontalBarView ||
                view == mfEdgeBandHost) {   // 【0.3.19】卡外热区带也算"我们的交互视图"
                return candidate;
            }
            if (view == self.view) {
                break;
            }
        }
    }

    switch ([self currentInteractionMode]) {
        case POInteractionModeQuickSwitchModal:
            return quickSwitchBackdropView;
        case POInteractionModeDrawerModal:
            return panelBackdropView;
        case POInteractionModeSplitPassthrough:
        default:
            return nil;
    }
}

-(BOOL)shouldUsePortraitHostedLandscapeOptimizationForOrientation:(UIInterfaceOrientation)orientation{
    CGRect bounds = self.view.bounds;
    BOOL shellIsPortrait = CGRectGetHeight(bounds) > CGRectGetWidth(bounds);
    return shellIsPortrait && UIInterfaceOrientationIsLandscape(orientation);
}

-(BOOL)isPortraitHostedLandscapeOptimizationActiveForOrientation:(UIInterfaceOrientation)orientation{
    return panelState != POPanelStateClosed &&
        [self shouldUsePortraitHostedLandscapeOptimizationForOrientation:orientation];
}

-(POQuickSwitchLayoutMode)currentQuickSwitchLayoutMode{
    UIInterfaceOrientation orientation = [self resolvedHostedLayoutOrientation];
    return [self isPortraitHostedLandscapeOptimizationActiveForOrientation:orientation]
        ? POQuickSwitchLayoutModeHorizontalBottom
        : POQuickSwitchLayoutModeVerticalSide;
}

-(BOOL)isHorizontalQuickSwitchLayoutMode{
    return [self currentQuickSwitchLayoutMode] == POQuickSwitchLayoutModeHorizontalBottom;
}

-(UIView<POQuickSwitchMenuPresenting> *)quickSwitchMenuForLayoutMode:(POQuickSwitchLayoutMode)mode{
    return mode == POQuickSwitchLayoutModeHorizontalBottom
        ? (UIView<POQuickSwitchMenuPresenting> *)quickSwitchHorizontalBarView
        : (UIView<POQuickSwitchMenuPresenting> *)self.quickSwitchTableView;
}

-(BOOL)isHorizontalQuickSwitchMenu:(UIView<POQuickSwitchMenuPresenting> *)menu{
    return menu == (UIView<POQuickSwitchMenuPresenting> *)quickSwitchHorizontalBarView;
}

-(BOOL)isPanelFullyOpen{
    return panelState == POPanelStateOpen &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        fabs(scrollView.contentOffset.x - [self maximumContentOffsetX]) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(BOOL)isPanelTransitioning{
    return panelState == POPanelStateOpening || panelState == POPanelStateClosing ||
        panelState == POPanelStateInteractive || scrollSnapAnimationInProgress;
}

-(BOOL)isHandleVisiblyNubbed{
    return self.handle.layoutMode == POHandleLayoutModeVerticalRail && self.handle.isNubbed;
}

-(BOOL)isHandleActivationGuardActive{
    return panelState == POPanelStateClosed && [self isHandleVisiblyNubbed] &&
        [[POApplicationHelper settings][@"handleActivationGuard"] boolValue];
}

-(POHandlePanIntent)horizontalHandlePanIntentForVelocityX:(CGFloat)velocityX{
    if (panelState == POPanelStateClosed) {
        if (velocityX < 0) {
            return [self isHandleActivationGuardActive]
                ? POHandlePanIntentRevealHandle
                : POHandlePanIntentOpenPanel;
        }
        if (velocityX > 0 && self.handle.layoutMode == POHandleLayoutModeVerticalRail &&
            !self.handle.isNubbed) {
            return POHandlePanIntentNubHandle;
        }
        return POHandlePanIntentNone;
    }
    if (panelState == POPanelStateOpen && velocityX > 0) {
        return POHandlePanIntentClosePanel;
    }
    return POHandlePanIntentNone;
}

-(void)cancelPresentationHandoff{
    [presentationHandoffDisplayLink invalidate];
    presentationHandoffDisplayLink = nil;
    presentationHandoffGeneration = 0;
    presentationHandoffStableFrames = 0;
    presentationHandoffBundleId = nil;
}

-(void)clearPresentationSnapshot{
    [self cancelPresentationHandoff];
    [presentationSnapshotView removeFromSuperview];
    presentationSnapshotView = nil;
    presentationSnapshotBundleId = nil;
    presentationSnapshotSceneIdentity = nil;
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = NO;
    runtimeCategoryTransitionSnapshotActive = NO;
    runtimeCategoryTransitionSnapshotFallbackArmed = NO;
    runtimeCategoryTransitionSnapshotFading = NO;
    presentationSnapshotSize = CGSizeZero;
    presentationSnapshotOrientation = UIInterfaceOrientationUnknown;
    presentationSnapshotRenderSourceOrientation = UIInterfaceOrientationUnknown;
}

-(void)showRuntimeCategoryTransitionSnapshotFallback{
    if (!runtimeCategoryTransitionSnapshotFallbackArmed ||
        !presentationSnapshotView || presentationSnapshotIsTargetPlaceholder) {
        return;
    }
    [presentationSnapshotView.layer removeAllAnimations];
    presentationSnapshotView.alpha = 1;
    presentationSnapshotView.hidden = NO;
    runtimeCategoryTransitionSnapshotFading = NO;
    runtimeCategoryTransitionSnapshotActive = YES;
    UIInterfaceOrientation targetOrientation =
        [self contextManagerPreferredHostedInterfaceOrientation:nil];
    [self retargetRuntimeCategoryTransitionSnapshotForOrientation:targetOrientation];
    [presentationSnapshotView layoutIfNeeded];
    [presentationSnapshotView.layer setNeedsDisplay];
    [presentationSnapshotView.layer displayIfNeeded];
    UIView *sourceView = presentationSnapshotView.subviews.firstObject;
    [sourceView layoutIfNeeded];
    [sourceView.layer setNeedsDisplay];
    [sourceView.layer displayIfNeeded];
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)prewarmRuntimeCategoryTransitionSnapshot{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        !presentationSnapshotView || presentationSnapshotIsTargetPlaceholder ||
        runtimeCategoryTransitionSnapshotActive || runtimeCategoryTransitionSnapshotFading) {
        return;
    }
    presentationSnapshotView.hidden = NO;
    presentationSnapshotView.alpha = 1.0;
    [self layoutPresentationSnapshotView];
    [presentationSnapshotView layoutIfNeeded];
    [presentationSnapshotView.layer setNeedsDisplay];
    [presentationSnapshotView.layer displayIfNeeded];
    UIView *sourceView = presentationSnapshotView.subviews.firstObject;
    [sourceView layoutIfNeeded];
    [sourceView.layer setNeedsDisplay];
    [sourceView.layer displayIfNeeded];
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)schedulePresentationSnapshotRetirementForBundleId:(NSString *)bundleId
                                               generation:(NSUInteger)generation{
    if (bundleId.length == 0 || generation == 0 || !presentationSnapshotView ||
        presentationSnapshotView.hidden || !contextView || contextView.hidden) {
        return;
    }
    presentationHandoffGeneration = generation;
    presentationHandoffBundleId = [bundleId copy];
    presentationHandoffStableFrames = 0;
    if (!presentationHandoffDisplayLink) {
        presentationHandoffDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                                     selector:@selector(handlePresentationHandoffDisplayLink:)];
        [presentationHandoffDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

-(void)handlePresentationHandoffDisplayLink:(CADisplayLink *)__unused displayLink{
    if (!presentationSnapshotView || presentationSnapshotView.hidden ||
        presentationHandoffGeneration == 0 ||
        presentationHandoffGeneration != hostSession.currentGeneration ||
        ![presentationHandoffBundleId isEqualToString:hostSession.requestedBundleId]) {
        [self cancelPresentationHandoff];
        return;
    }
    if (panelState != POPanelStateOpen || scrollSnapAnimationInProgress ||
        hostSession.state != POHostSessionStateLive || !contextView || contextView.hidden ||
        contextView.superview != self.contentView) {
        presentationHandoffStableFrames = 0;
        return;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    BOOL requiresStableContentHandoff = runtimeCategoryTransitionSnapshotActive ||
        runtimeCategoryTransitionSnapshotFallbackArmed;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        requiresStableContentHandoff &&
        ![manager isHostedPresentationContentStableForBundleId:presentationHandoffBundleId
                                               minimumDuration:0.15]) {
        presentationHandoffStableFrames = 0;
        return;
    }

    presentationHandoffStableFrames += 1;
    if (presentationHandoffStableFrames < 3) {
        return;
    }

    if (runtimeCategoryTransitionSnapshotActive) {
        UIView *snapshot = presentationSnapshotView;
        NSUInteger generation = presentationHandoffGeneration;
        NSString *bundleId = [presentationHandoffBundleId copy];
        runtimeCategoryTransitionSnapshotActive = NO;
        runtimeCategoryTransitionSnapshotFading = NO;
        [self cancelPresentationHandoff];
        [UIView performWithoutAnimation:^{
            snapshot.alpha = 0;
            snapshot.hidden = YES;
        }];
        if (snapshot == self->presentationSnapshotView &&
            generation == self->hostSession.currentGeneration &&
            [bundleId isEqualToString:self->hostSession.requestedBundleId]) {
            [self clearPresentationSnapshot];
        }
        return;
    }

    [self clearPresentationSnapshot];
}

-(void)layoutPresentationSnapshotView{
    if (!presentationSnapshotView) {
        return;
    }

    BOOL currentLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    BOOL shouldMirrorLocally = presentationSnapshotIsTargetPlaceholder
        ? currentLeftHanded
        : (presentationSnapshotCapturedLeftHanded != currentLeftHanded);
    [UIView performWithoutAnimation:^{
        presentationSnapshotView.transform = CGAffineTransformIdentity;
        presentationSnapshotView.bounds = (CGRect){CGPointZero, self.contentView.bounds.size};
        presentationSnapshotView.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                                       CGRectGetMidY(self.contentView.bounds));
        presentationSnapshotView.transform = shouldMirrorLocally
            ? CGAffineTransformMakeScale(-1.0, 1.0)
            : CGAffineTransformIdentity;

        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
            !presentationSnapshotIsTargetPlaceholder && self->contextView) {
            UIView *sourceView = presentationSnapshotView.subviews.firstObject;
            if ([sourceView isKindOfClass:[UIImageView class]]) {
                UIInterfaceOrientation sourceOrientation = presentationSnapshotRenderSourceOrientation;
                UIInterfaceOrientation targetOrientation = presentationSnapshotOrientation;
                if (!POIsConcretePresentationOrientation(sourceOrientation)) {
                    sourceOrientation = targetOrientation;
                }
                if (!POIsConcretePresentationOrientation(targetOrientation)) {
                    targetOrientation = hostedLayoutOrientation;
                }
                CGSize sourceCanvas = sourceView.bounds.size;
                BOOL sourceAndTargetCategoriesDiffer =
                    POIsConcretePresentationOrientation(sourceOrientation) &&
                    POIsConcretePresentationOrientation(targetOrientation) &&
                    UIInterfaceOrientationIsLandscape(sourceOrientation) !=
                        UIInterfaceOrientationIsLandscape(targetOrientation);
                BOOL targetMatchesShell =
                    POIsConcretePresentationOrientation(targetOrientation) &&
                    UIInterfaceOrientationIsLandscape(targetOrientation) ==
                        (CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds));
                if (!sourceAndTargetCategoriesDiffer || !targetMatchesShell) {
                    sourceView.bounds = self->contextView.bounds;
                    sourceView.center = self->contextView.center;
                    sourceView.transform = self->contextView.transform;
                    return;
                }

                UIImage *image = ((UIImageView *)sourceView).image;
                if (image.size.width > 0 && image.size.height > 0) {
                    sourceCanvas = image.size;
                }
                if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
                    sourceCanvas = self->contextView.bounds.size;
                }
                sourceView.bounds = (CGRect){CGPointZero, sourceCanvas};
                sourceView.center = self->contextView.center;

                CGAffineTransform contextTransform = self->contextView.transform;
                CGFloat scaleX = hypot(contextTransform.a, contextTransform.b);
                CGFloat scaleY = hypot(contextTransform.c, contextTransform.d);
                if (!isfinite(scaleX) || scaleX <= 0) {
                    scaleX = 1;
                }
                if (!isfinite(scaleY) || scaleY <= 0) {
                    scaleY = 1;
                }
                CGFloat rotationAngle = 0;
                if (POIsConcretePresentationOrientation(sourceOrientation) &&
                    POIsConcretePresentationOrientation(targetOrientation)) {
                    rotationAngle = POPresentationAngleForOrientation(targetOrientation) -
                        POPresentationAngleForOrientation(sourceOrientation);
                }
                CGAffineTransform sourceTransform = CGAffineTransformMakeRotation(rotationAngle);
                sourceTransform = CGAffineTransformScale(sourceTransform, scaleX, scaleY);
                if (contextTransform.a * contextTransform.d -
                    contextTransform.b * contextTransform.c < 0) {
                    sourceTransform = CGAffineTransformConcat(
                        sourceTransform, CGAffineTransformMakeScale(-1.0, 1.0));
                }
                sourceView.transform = sourceTransform;
            }
        }
    }];
}

-(void)cachePresentationSnapshotView:(UIView *)snapshotView
                            bundleId:(NSString *)bundleId
                               scene:(FBScene *)scene
                                size:(CGSize)size
                         orientation:(UIInterfaceOrientation)orientation
                  capturedLeftHanded:(BOOL)capturedLeftHanded{
    if (!snapshotView || bundleId.length == 0) {
        return;
    }
    if (!presentationSnapshotCache) {
        presentationSnapshotCache = [NSMutableDictionary dictionary];
        presentationSnapshotCacheOrder = [NSMutableArray array];
    }
    int processPID = [[ContextHostManager sharedInstance] processIdentifierForBundleId:bundleId];
    presentationSnapshotCache[bundleId] = @{
        @"view": snapshotView,
        @"scene": scene ?: (id)NSNull.null,
        @"pid": @(processPID),
        @"size": [NSValue valueWithCGSize:size],
        @"orientation": @(orientation),
        @"leftHanded": @(capturedLeftHanded)
    };
    [presentationSnapshotCacheOrder removeObject:bundleId];
    [presentationSnapshotCacheOrder addObject:bundleId];
    while (presentationSnapshotCacheOrder.count > 6) {
        NSString *oldestBundleId = presentationSnapshotCacheOrder.firstObject;
        [presentationSnapshotCacheOrder removeObjectAtIndex:0];
        [presentationSnapshotCache removeObjectForKey:oldestBundleId];
    }
}

-(UIInterfaceOrientation)cachedPresentationOrientationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return UIInterfaceOrientationUnknown;
    }
    NSDictionary *entry = presentationSnapshotCache[bundleId];
    if (!entry) {
        return UIInterfaceOrientationUnknown;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    int currentPID = [manager processIdentifierForBundleId:bundleId];
    int cachedPID = [entry[@"pid"] intValue];
    FBScene *cachedScene = entry[@"scene"] == NSNull.null ? nil : entry[@"scene"];
    FBScene *currentScene = currentPID > 0 ? [manager probeSceneForBundleId:bundleId] : nil;
    if (currentPID <= 0 || cachedPID <= 0 || currentPID != cachedPID ||
        !currentScene || (cachedScene && currentScene != cachedScene)) {
        [presentationSnapshotCache removeObjectForKey:bundleId];
        [presentationSnapshotCacheOrder removeObject:bundleId];
        return UIInterfaceOrientationUnknown;
    }

    UIInterfaceOrientation orientation = [entry[@"orientation"] integerValue];
    return POIsConcretePresentationOrientation(orientation)
        ? orientation
        : UIInterfaceOrientationUnknown;
}

-(UIInterfaceOrientation)resolvedHostedOrientationForBundleId:(NSString *)bundleId
                                                     manager:(ContextHostManager *)manager{
    ContextHostManager *hostManager = manager ?: [ContextHostManager sharedInstance];
    UIInterfaceOrientation liveOrientation = hostManager.hostedInterfaceOrientation;
    if (hostManager.isForegroundLeaseActive &&
        [hostManager.activeHostedBundleId isEqualToString:bundleId] &&
        POIsConcretePresentationOrientation(liveOrientation)) {
        return liveOrientation;
    }
    if (!hostManager.isForegroundLeaseActive &&
        [self hasLiveRetainedPresentationForBundleId:bundleId] &&
        POIsConcretePresentationOrientation(presentationOrientation)) {
        return presentationOrientation;
    }
    UIInterfaceOrientation cachedOrientation = [self cachedPresentationOrientationForBundleId:bundleId];
    if (POIsConcretePresentationOrientation(cachedOrientation)) {
        return cachedOrientation;
    }
    return [hostManager preferredHostedInterfaceOrientationForBundleId:bundleId];
}

-(NSDictionary *)validCachedPresentationSnapshotForBundleId:(NSString *)bundleId{
    NSDictionary *entry = presentationSnapshotCache[bundleId];
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 && [frontId isEqualToString:bundleId]) {
        return nil;
    }
    UIInterfaceOrientation cachedOrientation = [self cachedPresentationOrientationForBundleId:bundleId];
    entry = presentationSnapshotCache[bundleId];
    if (!entry || !POIsConcretePresentationOrientation(cachedOrientation)) {
        return nil;
    }
    CGSize cachedSize = [entry[@"size"] CGSizeValue];
    CGSize expectedSize = self.contentView.bounds.size;
    UIInterfaceOrientation expectedOrientation =
        [self resolvedHostedOrientationForBundleId:bundleId manager:nil];
    if (fabs(cachedSize.width - expectedSize.width) > CLOSED_CONTENT_OFFSET_EPSILON ||
        fabs(cachedSize.height - expectedSize.height) > CLOSED_CONTENT_OFFSET_EPSILON ||
        cachedOrientation != expectedOrientation) {
        return nil;
    }
    return entry;
}

-(BOOL)revealCachedPresentationSnapshotForBundleId:(NSString *)bundleId{
    NSDictionary *entry = [self validCachedPresentationSnapshotForBundleId:bundleId];
    UIView *snapshotView = entry[@"view"];
    if (!snapshotView) {
        return NO;
    }
    [self clearPresentationSnapshot];
    presentationSnapshotView = snapshotView;
    presentationSnapshotBundleId = [bundleId copy];
    presentationSnapshotSceneIdentity = entry[@"scene"] == NSNull.null ? nil : entry[@"scene"];
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = [entry[@"leftHanded"] boolValue];
    presentationSnapshotSize = [entry[@"size"] CGSizeValue];
    presentationSnapshotOrientation = [entry[@"orientation"] integerValue];
    presentationSnapshotRenderSourceOrientation = presentationSnapshotOrientation;
    [self layoutPresentationSnapshotView];
    presentationSnapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    presentationSnapshotView.hidden = NO;
    if (presentationSnapshotView.superview != self.contentView) {
        [self.contentView addSubview:presentationSnapshotView];
    }
    [self.contentView bringSubviewToFront:presentationSnapshotView];
    [presentationSnapshotCacheOrder removeObject:bundleId];
    [presentationSnapshotCacheOrder addObject:bundleId];
    return YES;
}

-(void)showTargetTransitionPresentationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    [self clearPresentationSnapshot];

    UIView *placeholder = [[UIView alloc] initWithFrame:self.contentView.bounds];
    placeholder.backgroundColor = [UIColor systemGray6Color];
    placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[POApplicationHelper imageForBundleId:bundleId]];
    CGFloat iconSide = MIN(72.0, MIN(CGRectGetWidth(placeholder.bounds), CGRectGetHeight(placeholder.bounds)) * 0.24);
    iconView.bounds = CGRectMake(0, 0, iconSide, iconSide);
    iconView.center = CGPointMake(CGRectGetMidX(placeholder.bounds), CGRectGetMidY(placeholder.bounds));
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [placeholder addSubview:iconView];

    presentationSnapshotView = placeholder;
    presentationSnapshotBundleId = [bundleId copy];
    presentationSnapshotSceneIdentity = [[ContextHostManager sharedInstance] probeSceneForBundleId:bundleId];
    presentationSnapshotIsTargetPlaceholder = YES;
    presentationSnapshotCapturedLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    presentationSnapshotSize = self.contentView.bounds.size;
    presentationSnapshotOrientation =
        [self resolvedHostedOrientationForBundleId:bundleId manager:nil];
    presentationSnapshotRenderSourceOrientation = presentationSnapshotOrientation;
    [self.contentView addSubview:presentationSnapshotView];
    [self layoutPresentationSnapshotView];
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)retainPresentationAfterReleaseIfPossible{
    BOOL canRetain = contextView != nil && presentationBundleId.length > 0;
    presentationRetainedAfterRelease = canRetain;
    retainedPresentationProcessPID = canRetain
        ? [[ContextHostManager sharedInstance] processIdentifierForBundleId:presentationBundleId]
        : 0;
    if (retainedPresentationProcessPID <= 0) {
        presentationRetainedAfterRelease = NO;
        retainedPresentationProcessPID = 0;
    }
}

-(BOOL)hasLiveRetainedPresentationForBundleId:(NSString *)bundleId{
    if (!presentationRetainedAfterRelease || retainedPresentationProcessPID <= 0 ||
        bundleId.length == 0 || ![presentationBundleId isEqualToString:bundleId]) {
        return NO;
    }
    int currentPID = [[ContextHostManager sharedInstance] processIdentifierForBundleId:bundleId];
    if (currentPID != retainedPresentationProcessPID) {
        presentationRetainedAfterRelease = NO;
        retainedPresentationProcessPID = 0;
        return NO;
    }
    return YES;
}

-(void)flushDeferredRuntimeScenePublicationIfNeeded{
    FBScene *scene = deferredRuntimePublishedScene;
    UIView *sceneStack = deferredRuntimePublishedSceneStack;
    NSString *bundleId = [deferredRuntimePublishedBundleId copy];
    NSUInteger generation = deferredRuntimePublishedGeneration;

    deferredRuntimePublishedScene = nil;
    deferredRuntimePublishedSceneStack = nil;
    deferredRuntimePublishedBundleId = nil;
    deferredRuntimePublishedGeneration = 0;

    if (!scene || !sceneStack || bundleId.length == 0 || generation == 0 ||
        generation != hostSession.currentGeneration ||
        ![bundleId isEqualToString:hostSession.requestedBundleId] ||
        panelState == POPanelStateClosed || panelState == POPanelStateClosing) {
        return;
    }
    [self hostSessionController:hostSession
               didPublishScene:scene
                    sceneStack:sceneStack
                          bundleId:bundleId
                        generation:generation];
}

-(void)scheduleRuntimeScenePublicationStagingIfNeeded{
    if (runtimeDeferredPublicationStageScheduled || !runtimeHostedCategoryTransitionAnimating ||
        !runtimeCategoryTransitionSnapshotActive || !presentationSnapshotView ||
        presentationSnapshotView.hidden) {
        return;
    }

    runtimeDeferredPublicationStageScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->runtimeDeferredPublicationStageScheduled = NO;
        if (!self->runtimeHostedCategoryTransitionAnimating ||
            !self->runtimeCategoryTransitionSnapshotActive ||
            !self->presentationSnapshotView || self->presentationSnapshotView.hidden) {
            return;
        }

        FBScene *scene = self->deferredRuntimePublishedScene;
        UIView *sceneStack = self->deferredRuntimePublishedSceneStack;
        NSString *bundleId = [self->deferredRuntimePublishedBundleId copy];
        NSUInteger generation = self->deferredRuntimePublishedGeneration;
        if (!scene || !sceneStack || bundleId.length == 0 || generation == 0 ||
            generation != self->hostSession.currentGeneration ||
            ![bundleId isEqualToString:self->hostSession.requestedBundleId]) {
            return;
        }

        self->runtimeScenePublicationStaging = YES;
        [self hostSessionController:self->hostSession
                   didPublishScene:scene
                        sceneStack:sceneStack
                          bundleId:bundleId
                        generation:generation];
        self->runtimeScenePublicationStaging = NO;

        if (self->deferredRuntimePublishedSceneStack == sceneStack &&
            self->deferredRuntimePublishedGeneration == generation) {
            self->deferredRuntimePublishedScene = nil;
            self->deferredRuntimePublishedSceneStack = nil;
            self->deferredRuntimePublishedBundleId = nil;
            self->deferredRuntimePublishedGeneration = 0;
        }
    });
}

-(BOOL)hasCompatiblePresentationSnapshotForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 || !presentationSnapshotView ||
        ![presentationSnapshotBundleId isEqualToString:bundleId]) {
        return NO;
    }
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 && [frontId isEqualToString:bundleId]) {
        return NO;
    }
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    if (![manager isProcessRunningForBundleId:bundleId]) {
        return NO;
    }
    FBScene *currentScene = [manager probeSceneForBundleId:bundleId];
    if (!currentScene || (presentationSnapshotSceneIdentity && currentScene != presentationSnapshotSceneIdentity)) {
        return NO;
    }
    CGSize expectedSize = self.contentView.bounds.size;
    UIInterfaceOrientation expectedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    return fabs(presentationSnapshotSize.width - expectedSize.width) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(presentationSnapshotSize.height - expectedSize.height) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        presentationSnapshotOrientation == expectedOrientation;
}

-(BOOL)prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:(UIInterfaceOrientation)sourceOrientation{
    if (!contextView || contextView.hidden || presentationBundleId.length == 0 ||
        !POIsConcretePresentationOrientation(sourceOrientation) ||
        ![presentationBundleId isEqualToString:hostSession.activeBundleId]) {
        return NO;
    }

    UIImage *snapshotImage = [[ContextHostManager sharedInstance]
        captureSnapshotImageForActiveBundleId:presentationBundleId
                             sourceOrientation:sourceOrientation];
    if (!snapshotImage) {
        return NO;
    }

    [self clearPresentationSnapshot];
    UIView *snapshotView = [[UIView alloc] initWithFrame:self.contentView.bounds];
    snapshotView.backgroundColor = UIColor.clearColor;
    snapshotView.userInteractionEnabled = NO;
    snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *sourceImageView = [[UIImageView alloc] initWithImage:snapshotImage];
    sourceImageView.contentMode = UIViewContentModeScaleToFill;
    sourceImageView.bounds = contextView.bounds;
    sourceImageView.center = contextView.center;
    sourceImageView.transform = contextView.transform;
    [snapshotView addSubview:sourceImageView];

    presentationSnapshotView = snapshotView;
    presentationSnapshotBundleId = [presentationBundleId copy];
    presentationSnapshotSceneIdentity = presentationSceneIdentity;
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    runtimeCategoryTransitionSnapshotActive = YES;
    presentationSnapshotSize = self.contentView.bounds.size;
    presentationSnapshotOrientation = sourceOrientation;
    presentationSnapshotRenderSourceOrientation = sourceOrientation;
    [self.contentView addSubview:presentationSnapshotView];
    presentationSnapshotView.hidden = NO;
    [self.contentView bringSubviewToFront:presentationSnapshotView];
    return YES;
}

-(void)retargetRuntimeCategoryTransitionSnapshotForOrientation:(UIInterfaceOrientation)orientation{
    if (!presentationSnapshotView || presentationSnapshotIsTargetPlaceholder ||
        !POIsConcretePresentationOrientation(orientation) || !contextView) {
        return;
    }
    UIView *sourceView = presentationSnapshotView.subviews.firstObject;
    if (![sourceView isKindOfClass:[UIImageView class]]) {
        return;
    }

    if (!POIsConcretePresentationOrientation(presentationSnapshotRenderSourceOrientation)) {
        presentationSnapshotRenderSourceOrientation = presentationSnapshotOrientation;
    }
    presentationSnapshotOrientation = orientation;
    [self layoutPresentationSnapshotView];
    presentationSnapshotSize = self.contentView.bounds.size;
    [self cachePresentationSnapshotView:presentationSnapshotView
                               bundleId:presentationSnapshotBundleId
                                  scene:presentationSnapshotSceneIdentity
                                   size:presentationSnapshotSize
                            orientation:presentationSnapshotOrientation
                     capturedLeftHanded:presentationSnapshotCapturedLeftHanded];
    presentationSnapshotView.hidden = NO;
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)capturePresentationSnapshotIfPossible{
    if (!contextView || contextView.hidden || showingCantHost || self.contentView.bounds.size.width <= 0 ||
        self.contentView.bounds.size.height <= 0 ||
        ![presentationBundleId isEqualToString:hostSession.activeBundleId]) {
        return;
    }

    CGSize expectedCanvasSize = [self contextManagerPreferredSceneStackSize:nil];
    UIInterfaceOrientation expectedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    BOOL presentationContractMatches = presentationOrientation == expectedOrientation &&
        fabs(presentationCanvasSize.width - expectedCanvasSize.width) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(presentationCanvasSize.height - expectedCanvasSize.height) <= CLOSED_CONTENT_OFFSET_EPSILON;
    if (!presentationContractMatches) {
        return;
    }

    CGSize size = self.contentView.bounds.size;
    UIImage *snapshotImage = [[ContextHostManager sharedInstance]
        captureSnapshotImageForActiveBundleId:presentationBundleId];
    if (!snapshotImage) {
        return;
    }
    UIView *snapshotView = [[UIView alloc] initWithFrame:self.contentView.bounds];
    snapshotView.backgroundColor = UIColor.clearColor;
    snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIImageView *sourceImageView = [[UIImageView alloc] initWithImage:snapshotImage];
    sourceImageView.contentMode = UIViewContentModeScaleToFill;
    sourceImageView.bounds = contextView.bounds;
    sourceImageView.center = contextView.center;
    sourceImageView.transform = contextView.transform;
    [snapshotView addSubview:sourceImageView];

    [self clearPresentationSnapshot];
    presentationSnapshotView = snapshotView;
    presentationSnapshotView.hidden = YES;
    [self.contentView addSubview:presentationSnapshotView];
    presentationSnapshotBundleId = [presentationBundleId copy];
    presentationSnapshotSceneIdentity = presentationSceneIdentity;
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    presentationSnapshotSize = size;
    presentationSnapshotOrientation = presentationOrientation;
    presentationSnapshotRenderSourceOrientation = presentationOrientation;
    [self cachePresentationSnapshotView:snapshotView
                               bundleId:presentationSnapshotBundleId
                                  scene:presentationSnapshotSceneIdentity
                               size:presentationSnapshotSize
                            orientation:presentationSnapshotOrientation
                     capturedLeftHanded:presentationSnapshotCapturedLeftHanded];
}

-(BOOL)isPresentationCompatibleForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 || !contextView || ![presentationBundleId isEqualToString:bundleId]) {
        return NO;
    }
    if (presentationRetainedAfterRelease &&
        ![self hasLiveRetainedPresentationForBundleId:bundleId]) {
        return NO;
    }
    if (presentationSceneIdentity &&
        [presentationSceneIdentity respondsToSelector:@selector(isValid)] &&
        ![(id)presentationSceneIdentity isValid]) {
        return NO;
    }
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 && [frontId isEqualToString:bundleId]) {
        return NO;
    }
    CGSize expectedSize = [self contextManagerPreferredSceneStackSize:nil];
    UIInterfaceOrientation expectedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    return fabs(presentationCanvasSize.width - expectedSize.width) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(presentationCanvasSize.height - expectedSize.height) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        presentationOrientation == expectedOrientation;
}

-(BOOL)revealPresentationForBundleIdIfCompatible:(NSString *)bundleId{
    keyboardZoomContainer.hidden = NO;
    if (cantHostCanvas) {
        cantHostCanvas.hidden = YES;
    }
    BOOL compatible = [self isPresentationCompatibleForBundleId:bundleId];
    BOOL snapshotCompatible = [self hasCompatiblePresentationSnapshotForBundleId:bundleId];
    if (compatible && presentationRetainedAfterRelease) {
        presentationRetainedAfterRelease = NO;
        retainedPresentationProcessPID = 0;
    }
    if (contextView) {
        contextView.hidden = !compatible;
        if (compatible) {
            [self.contentView bringSubviewToFront:contextView];
        }
    }
    if (presentationSnapshotView) {
        presentationSnapshotView.hidden = !snapshotCompatible;
        if (snapshotCompatible) {
            [self layoutPresentationSnapshotView];
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }
    return compatible || snapshotCompatible;
}

-(void)hidePresentationContainer{
    keyboardZoomContainer.hidden = YES;
    if (contextView) {
        contextView.hidden = NO;
    }
}

-(void)issueInteractiveHostIntentIfNeeded{
    if (interactiveHostIntentIssued || pinnedBundleId.length == 0) {
        return;
    }
    interactiveHostIntentIssued = YES;
    BOOL revealed = [self revealPresentationForBundleIdIfCompatible:pinnedBundleId];
    if (!revealed) {
        [self showTargetTransitionPresentationForBundleId:pinnedBundleId];
    }
    [hostSession activateBundleId:pinnedBundleId];
}

-(void)beginSplitSessionIfNeeded{
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive) {
        return;
    }
    NSString *baseBundleId = [POApplicationHelper frontMostBundleId];
    if (baseBundleId.length > 0 && [baseBundleId isEqualToString:pinnedBundleId]) {
        return;
    }
    id baseScene = nil;
    if (baseBundleId.length > 0) {
        baseScene = [[ContextHostManager sharedInstance] probeSceneForBundleId:baseBundleId];
    } else {
        baseBundleId = @"com.apple.springboard";
        SEL mainDisplaySceneSelector = NSSelectorFromString(@"_mainDisplayWindowScene");
        if ([UIApplication.sharedApplication respondsToSelector:mainDisplaySceneSelector]) {
            baseScene = ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication,
                                                       mainDisplaySceneSelector);
        }
        if (!baseScene) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] &&
                    [scene.session.persistentIdentifier isEqualToString:baseBundleId]) {
                    baseScene = scene;
                    break;
                }
            }
        }
    }
    [splitSession beginWithBaseBundleIdentifier:baseBundleId scene:baseScene];
}

-(BOOL)isLandscapePanelFullyOpenAndIdle{
    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= CGRectGetHeight(bounds) || ![self isPanelFullyOpen]) {
        return NO;
    }
    if (scrollSnapAnimationInProgress || scrollView.dragging || scrollView.decelerating) {
        return NO;
    }
    return fabs(scrollView.contentOffset.x - [self maximumContentOffsetX]) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(POCardScaleContext)currentCardScaleContext{
    UIInterfaceOrientation hostedOrientation = [self resolvedHostedLayoutOrientation];
    if (!POIsConcretePresentationOrientation(hostedOrientation)) {
        return POCardScaleContextNone;
    }
    CGRect bounds = self.view.bounds;
    BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    BOOL hostedIsLandscape = UIInterfaceOrientationIsLandscape(hostedOrientation);
    if (shellIsLandscape && !hostedIsLandscape) {
        return POCardScaleContextLandscapeShellPortraitHosted;
    }
    return POCardScaleContextNone;
}

-(CGFloat)effectiveLandscapePortraitKeyboardZoomScale{
    if (CGRectGetWidth(keyboardZoomBaseFrame) <= 0 || CGRectGetHeight(keyboardZoomBaseFrame) <= 0) {
        return 1.0;
    }
    CGRect baseFrameInView = [scrollView convertRect:keyboardZoomBaseFrame toView:self.view];
    CGFloat leadingLimit = [self leadingSafeAreaInset] + CONTENT_EDGE_GAP +
        CGRectGetWidth(self.handle.bounds) + HANDLE_EDGE_GAP;
    CGFloat availableWidth = CGRectGetMaxX(baseFrameInView) - leadingLimit;
    CGFloat maxZoomByWidth = availableWidth / CGRectGetWidth(keyboardZoomBaseFrame);
    if (!isfinite(maxZoomByWidth)) {
        return 1.0;
    }
    CGFloat zoom = MIN((CGFloat)PO_KEYBOARD_ZOOM_REQUESTED_SCALE, maxZoomByWidth);
    return MAX(1.0, MIN(PO_KEYBOARD_ZOOM_REQUESTED_SCALE, zoom));
}

-(BOOL)canApplyCardScale{
    if (![self isPanelFullyOpen] || contextView == nil || contextView.hidden ||
        keyboardZoomContainer.hidden || hostedCategoryTransitionPending ||
        runtimeHostedCategoryTransitionAnimating ||
        keyboardZoomSuspensionReasons != POKeyboardZoomSuspensionNone ||
        CGRectGetWidth(keyboardZoomBaseFrame) <= 0 || CGRectGetHeight(keyboardZoomBaseFrame) <= 0) {
        return NO;
    }
    return [self currentCardScaleContext] == POCardScaleContextLandscapeShellPortraitHosted;
}

-(BOOL)keyboardAutomaticScaleRequested{
    if ([self currentCardScaleContext] != POCardScaleContextLandscapeShellPortraitHosted ||
        keyboardZoomSuppressedForCurrentSession ||
        ![[POApplicationHelper settings][@"landscapeKeyboardZoom"] boolValue]) {
        return NO;
    }
    return hostedKeyboardLayerPresent &&
        keyboardNotificationState == POKeyboardNotificationStateVisible &&
        !keyboardHideAnimationInFlight;
}

-(CGFloat)keyboardZoomScaleForCardScaleContext:(POCardScaleContext)context{
    if (context != POCardScaleContextLandscapeShellPortraitHosted) {
        return 1.0;
    }
    CGFloat scaleValue = [self effectiveLandscapePortraitKeyboardZoomScale];
    return scaleValue >= PO_KEYBOARD_ZOOM_MINIMUM_USEFUL_SCALE ? scaleValue : 1.0;
}

-(CGFloat)resolvedCardScale{
    BOOL closingScaleFrozen = panelState == POPanelStateClosing ||
        (keyboardZoomSuspensionReasons & POKeyboardZoomSuspensionClosing) != 0;
    if (closingScaleFrozen && !keyboardZoomContainer.hidden) {
        CGFloat frozenScale = isfinite(closingFrozenCardScale) && closingFrozenCardScale > 0
            ? closingFrozenCardScale
            : appliedCardScale;
        return isfinite(frozenScale) && frozenScale > 0 ? frozenScale : 1.0;
    }
    if (![self canApplyCardScale]) {
        return 1.0;
    }
    // 【0.3.11】用户四边手势手动缩放的档位优先于键盘自动缩放（键盘弹出/面板关闭时会清除）
    if (mfUserCardScaleOverride > 0) {
        return mfUserCardScaleOverride;
    }
    POCardScaleContext context = [self currentCardScaleContext];
    if ([self keyboardAutomaticScaleRequested]) {
        return [self keyboardZoomScaleForCardScaleContext:context];
    }
    return 1.0;
}

-(BOOL)shouldApplyKeyboardZoom{
    return [self currentCardScaleContext] == POCardScaleContextLandscapeShellPortraitHosted &&
        [self resolvedCardScale] > 1.0 + PO_CARD_SCALE_EPSILON;
}

-(CGFloat)handleCompanionTranslationXForScale:(CGFloat)scaleValue{
    if (fabs(scaleValue - 1.0) <= PO_CARD_SCALE_EPSILON || CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return 0;
    }
    return CGRectGetWidth(keyboardZoomBaseFrame) * (1.0 - scaleValue);
}

/// 【0.3.20 血泪 log29】缩放锚点 = 缩放后**保持不动的那条边**（左/右手，上/下边），
/// 由 anchorAtLeft / anchorAtTop 两个开关给出，anchor 坐标在函数内从 baseFrame 直接取。
///
/// ★★ 0.3.19 的写法是无条件 `center = anchor − 缩放后尺寸/2`，这在数学上**只实现了"右下角不动"**
/// （上游键盘自动缩放的唯一用法：传 frame 的 maxX/maxY）。手动缩放/侧边停靠把左上角、右上角
/// 也按同一公式算，等价于"把那个角当成缩放后卡片的右下角" ⇒ 缩放后卡片整体**上移一个缩放后高度**，
/// 左停靠再**左移一个缩放后宽度**。log29 实证：
///   期望(5,103,252x545)  实际(−246,−443,252x545)  →  Δx = −251.25 = −w×0.75，Δy = −546 = −h×0.75
///   期望(257,103,252x545) 实际(257,−443,252x545) →  Δy 同上（右停靠右缘由锚决定，x 恰好对）
/// 也就是"停靠后浮窗大半在屏外"（用户 log28/log29 两次截图反馈）的直接来源。
-(CGPoint)keyboardZoomTargetCenterForBaseFrame:(CGRect)baseFrame
                                         scale:(CGFloat)zoom
                                  anchorAtLeft:(BOOL)anchorAtLeft
                                   anchorAtTop:(BOOL)anchorAtTop{
    CGFloat scaledWidth = CGRectGetWidth(baseFrame) * zoom;
    CGFloat scaledHeight = CGRectGetHeight(baseFrame) * zoom;
    CGFloat anchorX = anchorAtLeft ? CGRectGetMinX(baseFrame) : CGRectGetMaxX(baseFrame);
    CGFloat anchorY = anchorAtTop ? CGRectGetMinY(baseFrame) : CGRectGetMaxY(baseFrame);
    // 锚边不动 ⇒ 卡片中心 = 锚边向内偏半个缩放后尺寸
    CGPoint targetCenter = CGPointMake(anchorAtLeft ? anchorX + scaledWidth / 2.0
                                                   : anchorX - scaledWidth / 2.0,
                                       anchorAtTop  ? anchorY + scaledHeight / 2.0
                                                   : anchorY - scaledHeight / 2.0);
    CGFloat screenScale = UIScreen.mainScreen.scale;
    targetCenter.x = round(targetCenter.x * screenScale) / screenScale;
    targetCenter.y = round(targetCenter.y * screenScale) / screenScale;
    return targetCenter;
}

-(void)updateKeyboardAnimationFromNotification:(NSNotification *)notification{
    NSDictionary *userInfo = notification.userInfo;
    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    lastKeyboardAnimationDuration = duration > 0 ? duration : 0.25;
    if (curve < UIViewAnimationCurveEaseInOut || curve > UIViewAnimationCurveLinear) {
        curve = UIViewAnimationCurveEaseInOut;
    }
    lastKeyboardAnimationOptions = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction |
        ((UIViewAnimationOptions)curve << 16);
}

-(BOOL)keyboardFrameHasNonzeroSizeInNotification:(NSNotification *)notification{
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return YES;
    }
    CGRect keyboardFrame = frameValue.CGRectValue;
    return !CGRectIsEmpty(keyboardFrame) &&
        CGRectGetWidth(keyboardFrame) > 0 &&
        CGRectGetHeight(keyboardFrame) > 0;
}

-(BOOL)keyboardFrameIsVisibleInNotification:(NSNotification *)notification{
    return [self keyboardFrameHasNonzeroSizeInNotification:notification];
}

-(NSTimeInterval)cardScaleAnimationDurationForSource:(POCardScaleTransitionSource)source{
    return source == POCardScaleTransitionSourceKeyboard
        ? lastKeyboardAnimationDuration
        : PO_HANDLE_CARD_SCALE_ANIMATION_DURATION;
}

-(UIViewAnimationOptions)cardScaleAnimationOptionsForSource:(POCardScaleTransitionSource)source{
    if (source == POCardScaleTransitionSourceKeyboard) {
        return lastKeyboardAnimationOptions;
    }
    return UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction |
        UIViewAnimationOptionCurveEaseInOut;
}

-(void)reconcileCardChromeZOrder{
    [scrollView bringSubviewToFront:handleScrollView];
}

-(void)applyCardScaleTarget:(CGFloat)targetScale
                   animated:(BOOL)animated
                     source:(POCardScaleTransitionSource)source{
    if (!isfinite(targetScale) || targetScale <= 0) {
        targetScale = 1.0;
    }
    BOOL targetIsBase = fabs(targetScale - 1.0) <= PO_CARD_SCALE_EPSILON;
    if (targetIsBase) {
        targetScale = 1.0;
    }

    CGRect baseFrame = quickSwitchYieldActive && !CGRectIsEmpty(quickSwitchSavedContainerFrame)
        ? quickSwitchSavedContainerFrame
        : keyboardZoomBaseFrame;
    CGPoint targetCenter;
    CGFloat handleTranslationX;
    if (targetIsBase) {
        targetCenter = CGPointMake(CGRectGetMidX(baseFrame), CGRectGetMidY(baseFrame));
        handleTranslationX = 0;
        mfManualScaleAnchorRight = NO;   // 【0.3.19】回到基准尺寸 → 手动锚点复位为左上（用户默认）
    } else {
        // 【0.3.20】锚点改成"哪条边不动"两个开关（见 keyboardZoomTargetCenterForBaseFrame: 注释）：
        //   键盘自动缩放 = 上游右下角锚（保持原行为）；
        //   右侧停靠 = 右上锚（右缘+上边不动，向左缩）；
        //   手动缩放/左侧停靠 = 左上锚（用户指定：缩放时左上角固定不动）。
        CGRect anchorFrame = CGRectIsEmpty(keyboardZoomBaseFrame) ? baseFrame : keyboardZoomBaseFrame;
        BOOL anchorAtLeft;
        BOOL anchorAtTop;
        if (source == POCardScaleTransitionSourceKeyboard) {
            anchorAtLeft = NO;  anchorAtTop = NO;
        } else if (mfManualScaleAnchorRight) {
            anchorAtLeft = NO;  anchorAtTop = YES;
        } else {
            anchorAtLeft = YES; anchorAtTop = YES;
        }
        targetCenter = [self keyboardZoomTargetCenterForBaseFrame:anchorFrame
                                                            scale:targetScale
                                                     anchorAtLeft:anchorAtLeft
                                                      anchorAtTop:anchorAtTop];
        if (source == POCardScaleTransitionSourceKeyboard) {
            handleTranslationX = [self handleCompanionTranslationXForScale:targetScale];
        } else {
            // 手动：左上锚 → 右缘随缩小左移，手柄跟随（0.3.13 右下锚曾把手柄推出屏幕外，
            // log23 实证手柄跑到 x=445..479）；右上锚 → 右缘不动，手柄不动。
            handleTranslationX = mfManualScaleAnchorRight
                ? 0.0
                : CGRectGetWidth(anchorFrame) * (targetScale - 1.0);
        }
    }
    POInteractionMode interactionMode = [self currentInteractionMode];
    CGFloat panelBackdropTargetAlpha = interactionMode == POInteractionModeDrawerModal
        ? 0.5 * [self horizontalOpenProgress]
        : 0;

    CGAffineTransform modelTransform = keyboardZoomContainer.transform;
    BOOL cardTransformMatches = targetIsBase
        ? CGAffineTransformEqualToTransform(modelTransform, CGAffineTransformIdentity)
        : fabs(modelTransform.a - targetScale) <= PO_CARD_SCALE_EPSILON &&
          fabs(modelTransform.d - targetScale) <= PO_CARD_SCALE_EPSILON &&
          fabs(modelTransform.b) <= PO_CARD_SCALE_EPSILON && fabs(modelTransform.c) <= PO_CARD_SCALE_EPSILON;
    BOOL handleTransformMatches = fabs(handleScrollView.transform.tx - handleTranslationX) <= 0.25 &&
        fabs(handleScrollView.transform.ty) <= 0.25;
    BOOL backdropMatches = fabs(panelBackdropView.alpha - panelBackdropTargetAlpha) <= 0.001;
    // 【0.3.19】center 也参与判定：切换停靠侧（同 scale 换锚）或缩放态移动 baseFrame 时，
    // 仅 transform/tx 相同而 center 已变 —— 旧判定会误判"无变化"提前 return，导致不动。
    CGPoint modelCenter = keyboardZoomContainer.center;
    BOOL centerMatches = fabs(modelCenter.x - targetCenter.x) <= 0.5 &&
        fabs(modelCenter.y - targetCenter.y) <= 0.5;
    if (fabs(appliedCardScale - targetScale) <= PO_CARD_SCALE_EPSILON &&
        cardTransformMatches && handleTransformMatches && backdropMatches && centerMatches) {
        keyboardZoomApplied = !targetIsBase;
        [self reconcileCardChromeZOrder];
        return;
    }

    NSUInteger generation = ++keyboardZoomGeneration;
    keyboardZoomApplied = !targetIsBase;
    appliedCardScale = targetScale;
    [self reconcileCardChromeZOrder];

    void (^changes)(void) = ^{
        self->keyboardZoomContainer.transform = targetIsBase
            ? CGAffineTransformIdentity
            : CGAffineTransformMakeScale(targetScale, targetScale);
        if (!CGRectIsEmpty(baseFrame)) {
            self->keyboardZoomContainer.center = targetCenter;
        }
        self->handleScrollView.transform = CGAffineTransformMakeTranslation(handleTranslationX, 0);
        self->panelBackdropView.alpha = panelBackdropTargetAlpha;
    };

    void (^completion)(__unused BOOL finished) = ^(__unused BOOL finished) {
        if (generation != self->keyboardZoomGeneration) {
            return;
        }
        if (targetIsBase && !CGRectIsEmpty(baseFrame)) {
            [UIView performWithoutAnimation:^{
                self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
                self->keyboardZoomContainer.frame = baseFrame;
                self->handleScrollView.transform = CGAffineTransformIdentity;
            }];
        }
        [self reconcileCardChromeZOrder];
        [self mfUpdateEdgeBands];   // 【0.3.19】热区带跟随卡片（缩放/停靠/还原后位置变了）
    };

    if (animated) {
        [UIView animateWithDuration:[self cardScaleAnimationDurationForSource:source]
                              delay:0
                            options:[self cardScaleAnimationOptionsForSource:source]
                         animations:changes
                         completion:completion];
    } else {
        [UIView performWithoutAnimation:changes];
        completion(YES);
    }
}

-(void)applyResolvedCardScaleAnimated:(BOOL)animated source:(POCardScaleTransitionSource)source{
    [self applyCardScaleTarget:[self resolvedCardScale] animated:animated source:source];
}

-(void)applyKeyboardZoomAnimated:(BOOL)animated{
    [self applyResolvedCardScaleAnimated:animated source:POCardScaleTransitionSourceKeyboard];
}

-(void)restoreKeyboardZoomAnimated:(BOOL)animated{
    if (scaledProgrammaticCloseAnimating) {
        return;
    }
    [self applyCardScaleTarget:1.0 animated:animated source:POCardScaleTransitionSourceReconcile];
}

-(void)restoreKeyboardZoomImmediately{
    if (scaledProgrammaticCloseAnimating) {
        return;
    }
    [self applyCardScaleTarget:1.0 animated:NO source:POCardScaleTransitionSourceReconcile];
}

-(void)reevaluateCardScaleAnimated:(BOOL)animated source:(POCardScaleTransitionSource)source{
    UIGestureRecognizerState panState = scrollView.panGestureRecognizer.state;
    BOOL scrollPanActive = panState == UIGestureRecognizerStateBegan ||
        panState == UIGestureRecognizerStateChanged;
    if (!scrollView.dragging && !scrollView.decelerating &&
        !scrollSnapAnimationInProgress && !scrollPanActive && handlePanIntent == POHandlePanIntentNone) {
        keyboardZoomSuspensionReasons &= ~POKeyboardZoomSuspensionDragging;
    }
    [self applyResolvedCardScaleAnimated:animated source:source];
}

-(void)reevaluateKeyboardZoomAnimated:(BOOL)animated{
    [self reevaluateCardScaleAnimated:animated source:POCardScaleTransitionSourceReconcile];
}

-(BOOL)shouldHandleTapRestoreKeyboardZoom{
    if (panelState != POPanelStateOpen || [self isPanelTransitioning] ||
        scrollView.dragging || scrollView.decelerating || presentedQuickSwitchMenu ||
        self.handle.layoutMode != POHandleLayoutModeVerticalRail) {
        return NO;
    }
    return [self keyboardAutomaticScaleRequested] &&
        appliedCardScale > 1.0 + PO_CARD_SCALE_EPSILON;
}

-(void)restoreKeyboardZoomFromHandleTap{
    if (![self shouldHandleTapRestoreKeyboardZoom]) {
        return;
    }
    keyboardZoomSuppressedForCurrentSession = YES;
    [self applyResolvedCardScaleAnimated:YES source:POCardScaleTransitionSourceHandle];
}

-(void)addKeyboardZoomSuspension:(POKeyboardZoomSuspensionReason)reason{
    if (reason == POKeyboardZoomSuspensionClosing) {
        closingFrozenCardScale = isfinite(appliedCardScale) && appliedCardScale > 0
            ? appliedCardScale
            : 1.0;
        keyboardZoomSuspensionReasons |= reason;
        return;
    }
    keyboardZoomSuspensionReasons |= reason;
    [self applyResolvedCardScaleAnimated:NO source:POCardScaleTransitionSourceReconcile];
}

-(void)removeKeyboardZoomSuspension:(POKeyboardZoomSuspensionReason)reason{
    keyboardZoomSuspensionReasons &= ~reason;
    if (reason == POKeyboardZoomSuspensionClosing) {
        closingFrozenCardScale = 1.0;
    }
}

-(void)finishPanelDragZoomIfIdle{
    if (scrollView.dragging || scrollView.decelerating || scrollSnapAnimationInProgress ||
        handlePanIntent != POHandlePanIntentNone) {
        return;
    }
    [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
    if (pendingOpenState && [self isPanelFullyOpen]) {
        [self reevaluateKeyboardZoomAnimated:YES];
    }
}

-(void)scheduleFinishPanelDragZoomIfIdle{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishPanelDragZoomIfIdle];
    });
}

-(CGFloat)maximumContentOffsetX{
    return MAX(0, scrollView.contentSize.width - scrollView.bounds.size.width);
}

-(CGFloat)handleRailWidth{
    return CGRectGetWidth(self.handle.bounds) + HANDLE_EDGE_GAP * 2.0 + CONTENT_EDGE_GAP;
}

-(CGFloat)maximumHandleOffset{
    return MAX(0, handleScrollView.contentSize.height - handleScrollView.bounds.size.height);
}

-(CGFloat)clampedHandleOffset:(CGFloat)offset{
    return MIN(MAX(0, offset), [self maximumHandleOffset]);
}

-(void)storeHandlePosition{
    if ([self isHorizontalQuickSwitchLayoutMode]) {
        return;
    }
    handlePoint = handleScrollView.contentOffset;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:NSStringFromCGPoint(handlePoint) forKey:@"handlePoint"];
    CGFloat maximumOffset = [self maximumHandleOffset];
    if (maximumOffset > 0) {
        [defaults setDouble:(handlePoint.y / maximumOffset) forKey:@"handlePointRatio"];
    }
}

-(void)inheritVerticalHandleScreenY:(CGFloat)screenY{
    if (self.handle.layoutMode != POHandleLayoutModeVerticalRail || !isfinite(screenY)) {
        return;
    }

    CGFloat targetOffset = CGRectGetMinY(handleScrollView.frame) +
        CGRectGetMinY(self.handle.frame) - screenY;
    [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:targetOffset])
                                animated:NO];
}

-(CGFloat)horizontalOpenProgress{
    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0) {
        return 0;
    }
    return MIN(MAX(0, scrollView.contentOffset.x / maximumOffset), 1);
}

-(UIView *)beginHandleVisualHandoffSnapshot{
    [self clearHandleVisualHandoff];

    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    if (CGRectIsEmpty(handleInView) || !isfinite(CGRectGetMinX(handleInView)) ||
        !isfinite(CGRectGetMinY(handleInView))) {
        return nil;
    }

    UIView *snapshot = [self.handle snapshotViewAfterScreenUpdates:NO];
    if (!snapshot) {
        return nil;
    }
    snapshot.frame = handleInView;
    snapshot.userInteractionEnabled = NO;
    snapshot.alpha = MAX(self.handle.alpha, 0.02);
    [self.view addSubview:snapshot];
    [self.view bringSubviewToFront:snapshot];
    handleVisualHandoffSnapshotView = snapshot;

    self.handle.alpha = 0.02;
    return snapshot;
}

-(void)clearHandleVisualHandoff{
    handleVisualHandoffGeneration += 1;
    [handleVisualHandoffSnapshotView.layer removeAllAnimations];
    [handleVisualHandoffSnapshotView removeFromSuperview];
    handleVisualHandoffSnapshotView = nil;
    self.handle.alpha = 1;
}

-(void)completeHandleVisualHandoffFromSnapshot:(UIView *)snapshot{
    if (!snapshot || snapshot != handleVisualHandoffSnapshotView) {
        self.handle.alpha = 1;
        return;
    }

    NSUInteger generation = handleVisualHandoffGeneration;
    [UIView animateWithDuration:0.12
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        snapshot.alpha = 0;
        self.handle.alpha = 1;
    } completion:^(BOOL finished) {
        if (generation == self->handleVisualHandoffGeneration &&
            snapshot == self->handleVisualHandoffSnapshotView) {
            [snapshot removeFromSuperview];
            self->handleVisualHandoffSnapshotView = nil;
        }
    }];
}

-(void)cancelRuntimeHostedCategoryTransition{
    BOOL wasAnimating = runtimeHostedCategoryTransitionAnimating;
    BOOL hadRuntimeBridge = runtimeCategoryTransitionSnapshotActive || runtimeCategoryTransitionSnapshotFading;
    NSString *runtimeBridgeBundleId = hadRuntimeBridge ? [presentationSnapshotBundleId copy] : nil;
    if (!wasAnimating && !hostedCategoryTransitionPending && !handleVisualHandoffSnapshotView &&
        !hadRuntimeBridge) {
        return;
    }
    if (wasAnimating) {
        runtimeHostedCategoryTransitionGeneration += 1;
        runtimeHostedCategoryTransitionAnimating = NO;
        [keyboardZoomContainer.layer removeAllAnimations];
        [panelBackdropView.layer removeAllAnimations];
        [self.handle.layer removeAnimationForKey:@"po.runtimeRotationOpacity"];
        [UIView performWithoutAnimation:^{
            self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
            if (!CGRectIsEmpty(self->keyboardZoomBaseFrame)) {
                self->keyboardZoomContainer.frame = self->keyboardZoomBaseFrame;
            }
        }];
    }
    hostedCategoryTransitionPending = NO;
    [self clearHandleVisualHandoff];
    if (hadRuntimeBridge) {
        [self clearPresentationSnapshot];
        if (runtimeBridgeBundleId.length > 0) {
            [presentationSnapshotCache removeObjectForKey:runtimeBridgeBundleId];
            [presentationSnapshotCacheOrder removeObject:runtimeBridgeBundleId];
        }
    }
    if (wasAnimating) {
        [self updateInteractionBackdropsAnimated:NO];
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
        [self flushDeferredRuntimeScenePublicationIfNeeded];
    }
}

-(BOOL)canAnimateRuntimeHostedCategoryTransitionFromOrientation:(UIInterfaceOrientation)fromOrientation
                                                  toOrientation:(UIInterfaceOrientation)toOrientation{
    if (panelState != POPanelStateOpen || !contextView || contextView.hidden ||
        keyboardZoomContainer.hidden || presentationRetainedAfterRelease ||
        handlePanIntent != POHandlePanIntentNone || scrollSnapAnimationInProgress ||
        presentedQuickSwitchMenu || (quickSwitchInteractionOverlayView && !quickSwitchInteractionOverlayView.hidden)) {
        return NO;
    }
    if (!POIsConcretePresentationOrientation(fromOrientation) ||
        !POIsConcretePresentationOrientation(toOrientation) ||
        UIInterfaceOrientationIsLandscape(fromOrientation) == UIInterfaceOrientationIsLandscape(toOrientation)) {
        return NO;
    }
    if (![presentationBundleId isEqualToString:pinnedBundleId] ||
        ![hostSession.activeBundleId isEqualToString:pinnedBundleId] ||
        ![ContextHostManager sharedInstance].isForegroundLeaseActive) {
        return NO;
    }
    return YES;
}

-(BOOL)beginRuntimeHostedCategoryTransitionFromOrientation:(UIInterfaceOrientation)fromOrientation
                                             toOrientation:(UIInterfaceOrientation)toOrientation
                                     startingBackdropAlpha:(CGFloat)startingBackdropAlpha
                                  systemAnimationParameters:(id)animationParameters{
    Class animatorClass = NSClassFromString(@"UIStatusBarAnimationParameters");
    SEL animateSelector = NSSelectorFromString(@"animateWithParameters:fromCurrentState:animations:completion:");
    if (!animationParameters || !animatorClass || ![animatorClass respondsToSelector:animateSelector] ||
        ![self canAnimateRuntimeHostedCategoryTransitionFromOrientation:fromOrientation
                                                           toOrientation:toOrientation]) {
        return NO;
    }

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
        return NO;
    }

    NSUInteger hostGeneration = hostSession.currentGeneration;
    CGPoint oldScreenCenter = [scrollView convertPoint:keyboardZoomContainer.center toView:self.view];
    CGSize oldBoundsSize = keyboardZoomContainer.bounds.size;
    UIView *handleSnapshot = [self beginHandleVisualHandoffSnapshot];
    [self applyLayoutPreservingHandlePosition:YES];
    CGPoint finalCenter = keyboardZoomContainer.center;
    CGPoint initialCenter = [self.view convertPoint:oldScreenCenter toView:scrollView];
    CGSize finalBoundsSize = keyboardZoomContainer.bounds.size;
    POInteractionMode finalInteractionMode = [self baseInteractionModeForHostedOrientation:toOrientation];
    CGFloat finalBackdropAlpha = finalInteractionMode == POInteractionModeDrawerModal
        ? 0.5 * [self horizontalOpenProgress]
        : 0;
    BOOL fadeInBackdropAfterRotation = UIInterfaceOrientationIsLandscape(fromOrientation) &&
        !UIInterfaceOrientationIsLandscape(toOrientation) &&
        finalInteractionMode == POInteractionModeDrawerModal && finalBackdropAlpha > 0.001;
    CGFloat rotationBackdropAlpha = fadeInBackdropAfterRotation ? 0 : finalBackdropAlpha;

    CGFloat rotatedFinalWidth = finalBoundsSize.height;
    CGFloat rotatedFinalHeight = finalBoundsSize.width;
    if (oldBoundsSize.width <= 0 || oldBoundsSize.height <= 0 ||
        rotatedFinalWidth <= 0 || rotatedFinalHeight <= 0) {
        if (handleSnapshot == handleVisualHandoffSnapshotView) {
            [handleSnapshot removeFromSuperview];
            handleVisualHandoffSnapshotView = nil;
        }
        self.handle.alpha = 1;
        return NO;
    }

    CGFloat scaleX = oldBoundsSize.width / rotatedFinalWidth;
    CGFloat scaleY = oldBoundsSize.height / rotatedFinalHeight;
    CGFloat inverseScale = MIN(scaleX, scaleY);
    if (!isfinite(inverseScale) || inverseScale <= 0) {
        if (handleSnapshot == handleVisualHandoffSnapshotView) {
            [handleSnapshot removeFromSuperview];
            handleVisualHandoffSnapshotView = nil;
        }
        self.handle.alpha = 1;
        return NO;
    }

    CGFloat inverseAngle = POPresentationAngleForOrientation(fromOrientation) -
        POPresentationAngleForOrientation(toOrientation);
    CGAffineTransform initialTransform = CGAffineTransformMakeRotation(inverseAngle);
    initialTransform = CGAffineTransformScale(initialTransform, inverseScale, inverseScale);

    [keyboardZoomContainer.layer removeAllAnimations];
    [panelBackdropView.layer removeAllAnimations];
    [self.handle.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = initialTransform;
        self->keyboardZoomContainer.center = initialCenter;
        self->panelBackdropView.alpha = startingBackdropAlpha;
        self.handle.alpha = handleSnapshot ? 0.02 : 1;
    }];

    runtimeHostedCategoryTransitionAnimating = YES;
    NSUInteger generation = ++runtimeHostedCategoryTransitionGeneration;
    void (^animations)(void) = ^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->keyboardZoomContainer.center = finalCenter;
        self->panelBackdropView.alpha = rotationBackdropAlpha;
        if (handleSnapshot && handleSnapshot == self->handleVisualHandoffSnapshotView) {
            handleSnapshot.alpha = 0;
            self.handle.alpha = 1;
        }
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (generation != self->runtimeHostedCategoryTransitionGeneration) {
            return;
        }
        self->runtimeHostedCategoryTransitionAnimating = NO;
        [UIView performWithoutAnimation:^{
            self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
            self->keyboardZoomContainer.center = finalCenter;
            self->panelBackdropView.alpha = rotationBackdropAlpha;
            self.handle.alpha = 1;
        }];
        if (handleSnapshot == self->handleVisualHandoffSnapshotView) {
            [handleSnapshot removeFromSuperview];
            self->handleVisualHandoffSnapshotView = nil;
        }
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
        if (fadeInBackdropAfterRotation) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->runtimeHostedCategoryTransitionGeneration ||
                    self->runtimeHostedCategoryTransitionAnimating) {
                    return;
                }

                [self updateInteractionBackdropsAnimated:NO];
                [self->panelBackdropView.layer removeAnimationForKey:@"po.runtimeBackdropFadeIn"];
                CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
                fade.fromValue = @0;
                fade.toValue = @(self->panelBackdropView.alpha);
                fade.duration = 0.20;
                fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                [self->panelBackdropView.layer addAnimation:fade forKey:@"po.runtimeBackdropFadeIn"];
            });
        } else {
            [self updateInteractionBackdropsAnimated:NO];
        }

        [self flushDeferredRuntimeScenePublicationIfNeeded];

        if (hostGeneration == self->hostSession.currentGeneration) {
            ContextHostManager *manager = [ContextHostManager sharedInstance];
            UIInterfaceOrientation sourceOrientation =
                manager.currentHostedPresentationSourceOrientation;
            BOOL sourceNeedsCanonicalization =
                POIsConcretePresentationOrientation(sourceOrientation) &&
                POIsConcretePresentationOrientation(toOrientation) &&
                UIInterfaceOrientationIsLandscape(sourceOrientation) !=
                    UIInterfaceOrientationIsLandscape(toOrientation);
            if (sourceNeedsCanonicalization) {
                if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
                    self->runtimeScenePublicationStaging = YES;
                    [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:hostGeneration];
                    self->runtimeScenePublicationStaging = NO;
                } else {
                    BOOL snapshotReady =
                        [self prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:sourceOrientation];
                    if (snapshotReady) {
                        [self retargetRuntimeCategoryTransitionSnapshotForOrientation:toOrientation];
                    }
                    BOOL canonicalizationStarted = snapshotReady &&
                        [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:hostGeneration];
                    if (snapshotReady && !canonicalizationStarted) {
                        [self clearPresentationSnapshot];
                    }
                }
            }
        }
    };

    ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(
        animatorClass, animateSelector, animationParameters, YES, animations, completion);
    return YES;
}

-(void)updatePortraitHostedLandscapeHandleForCurrentOffset{
    if (self.handle.layoutMode != POHandleLayoutModeLandscapeFixedBottomLeft ||
        CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return;
    }

    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat progress = maximumOffset > 0
        ? MIN(MAX(scrollView.contentOffset.x / maximumOffset, 0), 1)
        : 0;

    CGFloat openCardX = CGRectGetMinX(keyboardZoomBaseFrame) - maximumOffset;
    CGFloat openHandleX = openCardX;
    CGFloat closedHandleX = CGRectGetWidth(self.view.bounds) - CONTENT_EDGE_GAP - CGRectGetWidth(self.handle.bounds);
    CGFloat desiredScreenX = closedHandleX + (openHandleX - closedHandleX) * progress;

    CGFloat desiredScreenY = CGRectGetMaxY(keyboardZoomBaseFrame) + HANDLE_EDGE_GAP;

    CGRect railFrame = handleScrollView.frame;
    railFrame.origin.x = desiredScreenX + scrollView.contentOffset.x;
    handleScrollView.frame = railFrame;

    self.handle.restingOriginX = 0;
    CGRect handleFrame = self.handle.frame;
    handleFrame.origin.x = 0;
    handleFrame.origin.y = desiredScreenY - CGRectGetMinY(handleScrollView.frame);
    self.handle.frame = handleFrame;
}

-(CGFloat)currentHandleScreenY{
    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    return !CGRectIsEmpty(handleInView) && isfinite(CGRectGetMinY(handleInView))
        ? CGRectGetMinY(handleInView)
        : NAN;
}

-(BOOL)isPanelFullyClosedAndIdle{
    return panelState == POPanelStateClosed &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(BOOL)canBeginQuickSwitchSession{
    if (presentedQuickSwitchMenu || scrollSnapAnimationInProgress ||
        scrollView.dragging || scrollView.decelerating ||
        handlePanIntent != POHandlePanIntentNone || hostedCategoryTransitionPending ||
        runtimeHostedCategoryTransitionAnimating || handleVisualHandoffSnapshotView) {
        return NO;
    }
    return [self isPanelFullyClosedAndIdle] || [self isPanelFullyOpen];
}

-(void)finishPanelSnapToOpenState:(BOOL)shouldOpen{
    MFLog(@"[panel] 吸附完成 -> %@（state=%lu，%@）", shouldOpen ? @"打开" : @"关闭",
          (unsigned long)(shouldOpen ? POPanelStateOpen : POPanelStateClosed),
          [self mfHandleScreenDescription]);
    scrollSnapAnimationInProgress = NO;
    interactiveHostIntentIssued = NO;
    interactiveHostResumeRequired = NO;

    if (shouldOpen) {
        panelState = POPanelStateOpen;
        keyboardZoomContainer.hidden = NO;
        // 【0.3.19】保险：打开完成即把 rail 摆到打开态位（跟随卡片右缘），不等下一次滚动回调
        [self mfUpdateVerticalHandleRailPosition];
        [self mfUpdateEdgeBands];   // 【0.3.19】打开完成 → 带子包住卡片
        if (presentationSnapshotView && !presentationSnapshotView.hidden &&
            hostSession.state == POHostSessionStateLive) {
            [self schedulePresentationSnapshotRetirementForBundleId:hostSession.requestedBundleId
                                                          generation:hostSession.currentGeneration];
        }
        if ([self isPanelFullyOpen]) {
            [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
            [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceReconcile];
        }
    } else {
        [scrollView setContentOffset:CGPointZero animated:NO];
        // 【0.3.20】关闭 → 撤销"用户挪过位置/已停靠"状态，下次打开回到标准打开位
        mfUserCardPositionPinned = NO;
        if (mfDockedSide != 0) {
            // 【0.3.22】停靠态关闭：基准 frame 还停在 16:9 小窗（240x135）上，
            // 必须先还原成标准打开位尺寸，否则下面的 restoreKeyboardZoomImmediately
            // 会把容器留成小窗尺寸（下次打开是"小窗"而不是新默认卡片）。
            mfDockedSide = 0;
            mfDockedCardFrame = CGRectZero;
            CGRect baseFrame = keyboardZoomBaseFrame;
            if (contentLayoutWidth > 0 && contentLayoutHeight > 0) {
                baseFrame.size = CGSizeMake(contentLayoutWidth, contentLayoutHeight);
            }
            baseFrame.origin.x = CGRectGetWidth(self.view.bounds);   // normalCardFrame 同款（内容坐标）
            keyboardZoomBaseFrame = baseFrame;
        }
        [self hidePresentationContainer];
        shadowView.layer.shadowOpacity = 0;
        BOOL deferSessionCleanup = deferScaledCloseSessionCleanup;
        deferScaledCloseSessionCleanup = NO;
        if (!deferSessionCleanup) {
            [self capturePresentationSnapshotIfPossible];
        }
        POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
        CGFloat inheritedHandleScreenY = NAN;
        if (previousLayoutMode == POQuickSwitchLayoutModeHorizontalBottom) {
            CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
            if (!CGRectIsEmpty(handleInView) && isfinite(CGRectGetMinY(handleInView))) {
                inheritedHandleScreenY = CGRectGetMinY(handleInView);
            }
        }
        UIView *handleHandoffSnapshot = nil;
        if (previousLayoutMode == POQuickSwitchLayoutModeHorizontalBottom) {
            handleHandoffSnapshot = [self beginHandleVisualHandoffSnapshot];
        }
        panelState = POPanelStateClosed;
        if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
            [self applyLayoutPreservingHandlePosition:YES];
            [self inheritVerticalHandleScreenY:inheritedHandleScreenY];
        }
        [self completeHandleVisualHandoffFromSnapshot:handleHandoffSnapshot];
        keyboardNotificationState = POKeyboardNotificationStateUnknown;
        hostedKeyboardLayerPresent = NO;
        keyboardHideAnimationInFlight = NO;
        keyboardStateHostGeneration = 0;
        keyboardZoomSuppressedForCurrentSession = NO;
        mfUserCardScaleOverride = 0;   // 【0.3.11】面板关闭 = 清除手动缩放档位
        [self restoreKeyboardZoomImmediately];
        // 【0.3.19 血泪 log25】缩放态关闭（performDirectScaledProgrammaticCloseAnimation）
        // 会把手柄 rail center 挪到 handleEndCenter，完成后果链上没人复位——
        // rail 停在内容坐标 ≈744（屏宽 430，完全屏外），用户关闭后手柄"消失"无法操作。
        // offset 已归零 → 此处按 progress=0 强制摆回贴右缘位。
        [self mfUpdateVerticalHandleRailPosition];
        [self mfUpdateEdgeBands];   // 【0.3.19】关闭完成 → 隐藏带子
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
        showingCantHost = NO;
        if (externalSceneStack) {
            [externalSceneStack removeFromSuperview];
            externalSceneStack = nil;
        }
        if (deferSessionCleanup) {
            NSUInteger cleanupGeneration = deferredOpenGeneration;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(PO_SCALED_CLOSE_POST_COMMIT_CLEANUP_DELAY * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (cleanupGeneration != self->deferredOpenGeneration ||
                    self->panelState != POPanelStateClosed) {
                    return;
                }
                [self capturePresentationSnapshotIfPossible];
                [self retainPresentationAfterReleaseIfPossible];
                [self->hostSession releaseActiveSessionPreservingPresentation];
                [[POSplitSessionController sharedInstance] end];
            });
        } else {
            [self retainPresentationAfterReleaseIfPossible];
            [hostSession releaseActiveSessionPreservingPresentation];
            [[POSplitSessionController sharedInstance] end];
        }
        [self storeHandlePosition];
        [self resetAutoNubTimer];
    }
    [self scheduleFinishPanelDragZoomIfIdle];
}

-(void)preparePanelForOpenPresentationIfNeeded{
    if (panelState != POPanelStateClosed) {
        return;
    }

    if ([self isHandleVisiblyNubbed]) {
        self.handle.isNubbed = NO;
    }

    POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
    UIView *handleHandoffSnapshot = nil;
    if ([self shouldUsePortraitHostedLandscapeOptimizationForOrientation:
            [self resolvedHostedLayoutOrientation]]) {
        handleHandoffSnapshot = [self beginHandleVisualHandoffSnapshot];
    }

    panelState = POPanelStateOpening;
    if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    if (handleHandoffSnapshot) {
        [self completeHandleVisualHandoffFromSnapshot:handleHandoffSnapshot];
    }
}

-(void)snapPanelToOpenState:(BOOL)shouldOpen{
    POPanelState previousState = panelState;
    pendingOpenState = shouldOpen;
    MFLog(@"[panel] 吸附请求 -> %@（from state=%lu）", shouldOpen ? @"打开" : @"关闭", (unsigned long)previousState);

    if (shouldOpen && previousState == POPanelStateClosed) {
        [self preparePanelForOpenPresentationIfNeeded];
    }
    if (!shouldOpen && previousState != POPanelStateClosed && previousState != POPanelStateClosing) {
        [self clearPresentationSnapshot];
        [hostSession beginClosingPreservingActiveLease];
    }
    POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
    panelState = shouldOpen ? POPanelStateOpening : POPanelStateClosing;
    if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat targetOffset = shouldOpen ? maximumOffset : 0;
    CGFloat rawOffsetX = scrollView.contentOffset.x;
    CGFloat rawOffsetY = scrollView.contentOffset.y;

    BOOL xAlreadyOnTarget = fabs(rawOffsetX - targetOffset) <= CLOSED_CONTENT_OFFSET_EPSILON;
    BOOL yAlreadyClean = fabs(rawOffsetY) <= CLOSED_CONTENT_OFFSET_EPSILON;
    if (xAlreadyOnTarget && yAlreadyClean) {
        [self finishPanelSnapToOpenState:shouldOpen];
        return;
    }

    if (xAlreadyOnTarget && !yAlreadyClean) {
        [scrollView setContentOffset:CGPointMake(targetOffset, 0) animated:NO];
        [self finishPanelSnapToOpenState:shouldOpen];
        return;
    }

    scrollSnapAnimationInProgress = YES;
    if (scrollView.decelerating) {
        [scrollView setContentOffset:scrollView.contentOffset animated:NO];
    }
    [scrollView setContentOffset:CGPointMake(targetOffset, 0) animated:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

// 【0.3.21】双指捏合已废弃（用户 log30：改成右下角滑动缩放），不再需要"捏合先判负"的动态失败依赖。

-(BOOL)canUseDirectScaledProgrammaticCloseAnimation{
    return panelState == POPanelStateOpen &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        self.handle.layoutMode == POHandleLayoutModeVerticalRail &&
        !keyboardZoomContainer.hidden &&
        fabs(appliedCardScale - 1.0) > PO_CARD_SCALE_EPSILON &&
        fabs(scrollView.contentOffset.x - [self maximumContentOffsetX]) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        !CGRectIsEmpty(keyboardZoomBaseFrame);
}

-(void)performDirectScaledProgrammaticCloseAnimation{
    if (![self canUseDirectScaledProgrammaticCloseAnimation]) {
        [self snapPanelToOpenState:NO];
        return;
    }

    pendingOpenState = NO;
    [self cancelPresentationHandoff];
    [hostSession beginClosingPreservingActiveLease];
    panelState = POPanelStateClosing;
    scrollSnapAnimationInProgress = YES;
    scaledProgrammaticCloseAnimating = YES;
    scaledProgrammaticCloseNeedsLayout = NO;
    CALayer *cardPresentationLayer = keyboardZoomContainer.layer.presentationLayer;
    CALayer *handlePresentationLayer = handleScrollView.layer.presentationLayer;
    CGPoint cardStartCenter = cardPresentationLayer ? cardPresentationLayer.position : keyboardZoomContainer.center;
    CGPoint handleStartCenter = handlePresentationLayer ? handlePresentationLayer.position : handleScrollView.center;
    CGAffineTransform cardVisualTransform = cardPresentationLayer
        ? cardPresentationLayer.affineTransform
        : keyboardZoomContainer.transform;
    CGAffineTransform handleVisualTransform = handlePresentationLayer
        ? handlePresentationLayer.affineTransform
        : handleScrollView.transform;

    keyboardZoomGeneration += 1;
    [keyboardZoomContainer.layer removeAllAnimations];
    [handleScrollView.layer removeAllAnimations];
    [panelBackdropView.layer removeAllAnimations];
    [quickSwitchBackdropView.layer removeAllAnimations];
    [shadowView.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.center = cardStartCenter;
        self->keyboardZoomContainer.transform = cardVisualTransform;
        self->handleScrollView.center = handleStartCenter;
        self->handleScrollView.transform = handleVisualTransform;
    }];

    CGFloat visualScale = fabs(cardVisualTransform.a);
    if (!isfinite(visualScale) || visualScale <= 0) {
        visualScale = isfinite(appliedCardScale) && appliedCardScale > 0 ? appliedCardScale : 1.0;
    }
    appliedCardScale = visualScale;
    closingFrozenCardScale = visualScale;

    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat handleCompanionX = handleVisualTransform.tx;
    CGFloat enlargementOverflow = MAX(0.0, CGRectGetWidth(keyboardZoomBaseFrame) * (visualScale - 1.0));
    CGFloat cardTravelX = maximumOffset + enlargementOverflow + CONTENT_SHADOW_FADE_DISTANCE;
    CGFloat handleTravelX = maximumOffset - handleCompanionX;

    CGPoint cardEndCenter = CGPointMake(cardStartCenter.x + cardTravelX, cardStartCenter.y);
    CGPoint handleEndCenter = CGPointMake(handleStartCenter.x + handleTravelX, handleStartCenter.y);

    [UIView animateWithDuration:PO_SCALED_PROGRAMMATIC_CLOSE_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseInOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        self->keyboardZoomContainer.center = cardEndCenter;
        self->handleScrollView.center = handleEndCenter;
        self->panelBackdropView.alpha = 0;
        self->quickSwitchBackdropView.alpha = 0;
        self->shadowView.layer.shadowOpacity = 0;
    } completion:^(__unused BOOL finished) {
        if (!self->scaledProgrammaticCloseAnimating) {
            return;
        }

        BOOL replayDeferredLayout = self->scaledProgrammaticCloseNeedsLayout;
        [UIView performWithoutAnimation:^{
            [self hidePresentationContainer];
            [self->scrollView setContentOffset:CGPointZero animated:NO];
            self->keyboardZoomContainer.center = cardStartCenter;
            self->handleScrollView.center = handleStartCenter;
            self->handleScrollView.transform = CGAffineTransformIdentity;
        }];
        self->scaledProgrammaticCloseAnimating = NO;
        self->scaledProgrammaticCloseNeedsLayout = NO;
        self->deferScaledCloseSessionCleanup = YES;
        [self finishPanelSnapToOpenState:NO];
        if (replayDeferredLayout) {
            [self applyCurrentSettings];
        }
    }];
}

-(CGFloat)portraitHostedLandscapeReservedBottomChromeHeight{
    return MAX(CGRectGetHeight(self.handle.bounds), [QuickSwitchHorizontalBarView preferredBarHeight]);
}

-(CGFloat)clampedPortraitHostedLandscapeCardBottomYForHandleAnchorY:(CGFloat)handleAnchorY
                                                          cardHeight:(CGFloat)cardHeight{
    CGRect bounds = self.view.bounds;
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    CGFloat topInset = MAX(viewInsets.top, windowInsets.top) + CONTENT_EDGE_GAP;
    CGFloat bottomInset = MAX(viewInsets.bottom, windowInsets.bottom) + CONTENT_EDGE_GAP;
    CGFloat minimumCardBottomY = topInset + cardHeight;
    CGFloat maximumCardBottomY = CGRectGetHeight(bounds) - bottomInset -
        [self portraitHostedLandscapeReservedBottomChromeHeight] - HANDLE_EDGE_GAP;
    if (maximumCardBottomY < minimumCardBottomY) {
        return minimumCardBottomY;
    }
    CGFloat desiredCardBottomY = handleAnchorY - HANDLE_EDGE_GAP;
    return MIN(MAX(desiredCardBottomY, minimumCardBottomY), maximumCardBottomY);
}

-(void)syncHorizontalQuickSwitchPresentationAnchor{
    if (!quickSwitchHorizontalBarView ||
        [self currentQuickSwitchLayoutMode] != POQuickSwitchLayoutModeHorizontalBottom ||
        CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return;
    }
    quickSwitchHorizontalBarView.presentationAnchorFrame =
        CGRectOffset(keyboardZoomBaseFrame, -[self maximumContentOffsetX], 0);
}

-(BOOL)canMovePortraitHostedLandscapeCardVertically{
    return panelState == POPanelStateOpen &&
        [self currentQuickSwitchLayoutMode] == POQuickSwitchLayoutModeHorizontalBottom &&
        !presentedQuickSwitchMenu &&
        (quickSwitchInteractionOverlayView == nil || quickSwitchInteractionOverlayView.hidden) &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        !CGRectIsEmpty(keyboardZoomBaseFrame);
}

-(void)applyPortraitHostedLandscapeVerticalHandleAnchorY:(CGFloat)handleAnchorY{
    if (![self canMovePortraitHostedLandscapeCardVertically] &&
        handlePanIntent != POHandlePanIntentVerticalCardMove) {
        return;
    }
    CGFloat cardHeight = CGRectGetHeight(keyboardZoomBaseFrame);
    if (cardHeight <= 0) {
        return;
    }
    CGFloat cardBottomY = [self clampedPortraitHostedLandscapeCardBottomYForHandleAnchorY:handleAnchorY
                                                                                     cardHeight:cardHeight];
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGRect baseFrame = keyboardZoomBaseFrame;
    baseFrame.origin.y = round((cardBottomY - cardHeight) * screenScale) / screenScale;
    portraitHostedLandscapeHandleAnchorY = cardBottomY + HANDLE_EDGE_GAP;
    keyboardZoomBaseFrame = baseFrame;

    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->keyboardZoomContainer.frame = baseFrame;
    }];
    [self updatePortraitHostedLandscapeHandleForCurrentOffset];
    [self syncHorizontalQuickSwitchPresentationAnchor];
}

#pragma mark - 【0.3.19】浮窗卡外热区带（移动/停靠/缩放/关闭全在卡外 20pt 环带）

/// 【0.3.19 重做（log28 用户指令）】所有手势操作都在悬浮窗外紧贴边缘的 20pt 环带上：
///   左带 = 点击停靠左；右带 = 点击停靠右；底带左段 = pan 自由移动；底带右端 = pan 滑动缩放；
///   顶带 = 点击关闭；停靠态 = 小窗上盖一层透明层（单击还原 / 拖动移动）。
/// 【0.3.19 血泪 log28】0.3.13~0.3.19 把热区塞在 keyboardZoomContainer 里（卡片内侧），
/// 被 App 内容视图整层压死：`移动热区按下` 全程只触发过 1 次、捏合 0 次，
/// 所有"生效"的功能（左右停靠/上方关闭）全是 backdrop 点击——卡内触摸根本到不了热区。
/// 现在带子挂在 self.view 顶层、frame 跟随卡片屏幕矩形外扩 20pt（mfUpdateEdgeBands），
/// 触摸路由见 interactiveViewForWindowPoint:（宿主已加入白名单）。
-(void)mfInstallCardEdgeBands{
    if (self.view == nil || mfEdgeBandHost != nil) {
        return;
    }
    CGFloat w = MF_CARD_EDGE_HOTZONE_WIDTH;
    mfEdgeBandHost = [[MFEdgeBandHostView alloc] initWithFrame:CGRectZero];
    mfEdgeBandHost.backgroundColor = [UIColor clearColor];
    mfEdgeBandHost.userInteractionEnabled = YES;
    mfEdgeBandLeft        = [[UIView alloc] initWithFrame:CGRectZero];
    mfEdgeBandRight       = [[UIView alloc] initWithFrame:CGRectZero];
    mfEdgeBandBottom      = [[UIView alloc] initWithFrame:CGRectZero];
    mfEdgeBandBottomRight = [[UIView alloc] initWithFrame:CGRectZero];   // 【0.3.21】滑动缩放区（在底带之上）
    mfEdgeBandTop         = [[UIView alloc] initWithFrame:CGRectZero];
    mfDockedTapView       = [[UIView alloc] initWithFrame:CGRectZero];   // 【0.3.21】停靠态小窗盖层
    NSDictionary<NSString *, UIView *> *bands =
        @{ @"left"  : mfEdgeBandLeft,  @"right" : mfEdgeBandRight,
           @"bottom": mfEdgeBandBottom, @"top"   : mfEdgeBandTop };
    [bands enumerateKeysAndObjectsUsingBlock:^(NSString *key, UIView *band, __unused BOOL *stop) {
        band.translatesAutoresizingMaskIntoConstraints = YES;
        band.userInteractionEnabled = YES;
        band.backgroundColor = [UIColor clearColor];
        if ([key isEqualToString:@"bottom"]) {
            band.tag = MF_CARD_EDGE_HOTZONE_TAG_BOTTOM;
            // 【0.3.21 血泪 log30】移动 pan 不再挂在底带这个**子视图**上：log30 实证底带的 pan
            // Began/Ended 落在同一毫秒、Changed 一次都没进（同期挂在宿主上的捏合 pan 却收得到
            // 连续 Changed，缩放正常）⇒ 改挂宿主（同一套已被实证可用的机制），位置在 Began 里用
            // 触点在"底带（去掉右端缩放区）+ 停靠小窗盖层"内自行判定。
        } else if ([key isEqualToString:@"top"]) {
            band.tag = MF_CARD_EDGE_HOTZONE_TAG_TOP;
            [band addGestureRecognizer:[[UITapGestureRecognizer alloc]
                initWithTarget:self action:@selector(mfBandTopTap:)]];
        } else {
            band.tag = [key isEqualToString:@"left"] ? MF_CARD_EDGE_HOTZONE_TAG_LEFT
                                                     : MF_CARD_EDGE_HOTZONE_TAG_RIGHT;
            [band addGestureRecognizer:[[UITapGestureRecognizer alloc]
                initWithTarget:self action:@selector(mfCardSideTap:)]];
        }
        [mfEdgeBandHost addSubview:band];
    }];
    // 【0.3.21】自由移动 pan：挂宿主，Began 时按触点位置判定归属（底带左段 / 停靠小窗）
    UIPanGestureRecognizer *movePan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(mfCardMovePan:)];
    [mfEdgeBandHost addGestureRecognizer:movePan];
    // 【0.3.21】底带右端 = 滑动缩放区（用户 log30：双指捏合太麻烦，改成右下角滑动缩放）。
    // 独立子视图 + 独立 pan（与底带移动 pan 不会互抢）；mfUpdateEdgeBands 里被 bringSubviewToFront 压在最上层。
    mfEdgeBandBottomRight.translatesAutoresizingMaskIntoConstraints = YES;
    mfEdgeBandBottomRight.userInteractionEnabled = YES;
    mfEdgeBandBottomRight.backgroundColor = [UIColor clearColor];
    [mfEdgeBandBottomRight addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(mfCardCornerScalePan:)]];
    [mfEdgeBandHost addSubview:mfEdgeBandBottomRight];
    // 【0.3.21】停靠态盖层：小窗本体收不到我们的触摸（内容层是 App 的场景层），
    // 只有在本窗口顶层再盖一层才接得住"点小窗还原"；显示期间（仅停靠态）才 hidden=NO。
    mfDockedTapView.translatesAutoresizingMaskIntoConstraints = YES;
    mfDockedTapView.userInteractionEnabled = YES;
    mfDockedTapView.backgroundColor = [UIColor clearColor];
    [mfDockedTapView addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(mfDockedCardTap:)]];
    // 拖动（移动小窗）由宿主的移动 pan 按位置接管，这里不再挂 pan（避免两个 pan 抢同一触点）
    [mfEdgeBandHost addSubview:mfDockedTapView];
    [self.view addSubview:mfEdgeBandHost];
    mfEdgeBandHost.hidden = YES;   // 卡片未打开前不参与 hitTest
    MFLog(@"[card] 0.3.22 卡外热区带已安装（20pt 环带：左右=停靠16:9小窗 底=移动 右下角=缩放 顶=关闭 停靠态=点小窗还原）");
}

/// 【0.3.19】热区带跟随：按卡片"屏幕矩形"外扩 20pt 摆四条带，空隙（卡片本体）透传。
/// 在卡片位置/缩放/开合变化的所有出口调用（applyCardScaleTarget / 移动 / 停靠 / 开合完成）。
-(void)mfUpdateEdgeBands{
    if (mfEdgeBandHost == nil || self.view == nil) {
        return;
    }
    BOOL show = panelState == POPanelStateOpen && !keyboardZoomContainer.hidden &&
        !CGRectIsEmpty(keyboardZoomBaseFrame) && !CGRectIsEmpty(keyboardZoomContainer.frame);
    if (!show) {
        mfEdgeBandHost.hidden = YES;
        return;
    }
    CGRect cardRect = [keyboardZoomContainer.superview convertRect:keyboardZoomContainer.frame
                                                            toView:self.view];
    if (CGRectIsEmpty(cardRect) || !isfinite(cardRect.origin.x) || !isfinite(cardRect.origin.y)) {
        mfEdgeBandHost.hidden = YES;
        return;
    }
    CGFloat w = MF_CARD_EDGE_HOTZONE_WIDTH;
    CGRect viewBounds = self.view.bounds;
    CGFloat w20 = w;
    CGRect leftBand   = CGRectMake(CGRectGetMinX(cardRect) - w20, CGRectGetMinY(cardRect),
                                   w20, CGRectGetHeight(cardRect));
    CGRect rightBand  = CGRectMake(CGRectGetMaxX(cardRect), CGRectGetMinY(cardRect),
                                   w20, CGRectGetHeight(cardRect));
    CGRect bottomBand = CGRectMake(CGRectGetMinX(cardRect), CGRectGetMaxY(cardRect),
                                   CGRectGetWidth(cardRect), w20);
    CGRect topBand    = CGRectMake(CGRectGetMinX(cardRect), CGRectGetMinY(cardRect) - w20,
                                   CGRectGetWidth(cardRect), w20);
    // 钳到屏幕内，出屏部分裁掉；整条出屏 → 隐藏该带
    CGRect (^clip)(CGRect) = ^CGRect(CGRect band){
        CGRect r = CGRectIntersection(band, viewBounds);
        return r.size.width > 1.0 && r.size.height > 1.0 ? r : CGRectNull;
    };
    leftBand = clip(leftBand); rightBand = clip(rightBand);
    bottomBand = clip(bottomBand); topBand = clip(topBand);
    // 【0.3.22 血泪 log31】右下角"滑动缩放"热区：0.3.21 只贴在卡片**外侧** 20pt（84x20 一条），
    // 用户实测"按不到"（全日志 `缩放带内=1` 一次都没出现）。现在热区压住卡片右下角：
    // 内侧 40pt + 外侧 20pt = 84x60 的方块（像 iPad/macOS 的角把手），手指落点容差大得多。
    // 停靠小窗（16:9，高仅 ~135）不出缩放区 —— 整条底带都归"移动"，还原靠点小窗。
    CGRect scaleZone = CGRectNull;
    CGFloat cardW = CGRectGetWidth(cardRect);
    if (mfDockedSide == 0) {
        CGFloat zoneW = MF_CARD_EDGE_CORNER_SCALE_WIDTH;
        CGFloat inside = MF_CARD_EDGE_CORNER_SCALE_INSIDE;
        if (cardW < zoneW * 1.6) {
            zoneW = MAX(52.0, cardW * 0.5);
        }
        scaleZone = clip(CGRectMake(CGRectGetMaxX(cardRect) - (zoneW - w20),
                                    CGRectGetMaxY(cardRect) - inside,
                                    zoneW, inside + w20));
    }
    // 【0.3.21】停靠态盖层：正好盖住小窗本体（点击=还原停靠前尺寸，拖动=移动小窗）
    CGRect dockedOverlay = CGRectIntersection(cardRect, viewBounds);
    BOOL dockedOverlayVisible = mfDockedSide != 0 && !CGRectIsNull(dockedOverlay) &&
        dockedOverlay.size.width > 1.0 && dockedOverlay.size.height > 1.0;
    CGRect hostRect = cardRect;
    for (NSValue *bandValue in @[ [NSValue valueWithCGRect:leftBand], [NSValue valueWithCGRect:rightBand],
                                  [NSValue valueWithCGRect:bottomBand], [NSValue valueWithCGRect:topBand],
                                  [NSValue valueWithCGRect:scaleZone] ]) {
        CGRect r = [bandValue CGRectValue];
        if (CGRectIsNull(r)) {
            continue;
        }
        hostRect = CGRectUnion(hostRect, r);
    }
    mfEdgeBandHost.frame = hostRect;
    mfEdgeBandLeft.frame   = CGRectIsNull(leftBand)   ? CGRectZero
        : [self.view convertRect:leftBand toView:mfEdgeBandHost];
    mfEdgeBandRight.frame  = CGRectIsNull(rightBand)  ? CGRectZero
        : [self.view convertRect:rightBand toView:mfEdgeBandHost];
    mfEdgeBandBottom.frame = CGRectIsNull(bottomBand) ? CGRectZero
        : [self.view convertRect:bottomBand toView:mfEdgeBandHost];
    mfEdgeBandTop.frame    = CGRectIsNull(topBand)    ? CGRectZero
        : [self.view convertRect:topBand toView:mfEdgeBandHost];
    mfEdgeBandBottomRight.frame = CGRectIsNull(scaleZone) ? CGRectZero
        : [self.view convertRect:scaleZone toView:mfEdgeBandHost];
    mfDockedTapView.frame = dockedOverlayVisible
        ? [self.view convertRect:dockedOverlay toView:mfEdgeBandHost] : CGRectZero;
    mfEdgeBandLeft.hidden   = CGRectIsNull(leftBand);
    mfEdgeBandRight.hidden  = CGRectIsNull(rightBand);
    mfEdgeBandBottom.hidden = CGRectIsNull(bottomBand);
    mfEdgeBandTop.hidden    = CGRectIsNull(topBand);
    mfEdgeBandBottomRight.hidden = CGRectIsNull(scaleZone);
    mfDockedTapView.hidden  = !dockedOverlayVisible;
    mfEdgeBandHost.hidden = NO;
    [self.view bringSubviewToFront:mfEdgeBandHost];
    // 缩放区压住底带、停靠盖层压住全部（盖层只在小窗内部，不与带子重叠）
    [mfEdgeBandHost bringSubviewToFront:mfEdgeBandBottomRight];
    [mfEdgeBandHost bringSubviewToFront:mfDockedTapView];
    // 【0.3.22 诊断】卡片矩形一变就打一行（round31 就是靠 `缩放带内=` 全程为 0 判定"热区没被按到"，
    // 但看不出热区到底在哪 —— 这行把每条带的屏幕矩形都写出来，下一轮定因一眼可查）
    static CGRect mfLastBandLoggedCard;
    static BOOL mfHasBandLoggedCard;
    if (!mfHasBandLoggedCard || !CGRectEqualToRect(mfLastBandLoggedCard, cardRect)) {
        mfHasBandLoggedCard = YES;
        mfLastBandLoggedCard = cardRect;
        MFLog(@"[card] 热区带几何：卡(%.0f,%.0f,%.0fx%.0f) 左%@ 右%@ 底%@ 顶%@ 缩放区%@ 停靠盖层%@",
              CGRectGetMinX(cardRect), CGRectGetMinY(cardRect),
              CGRectGetWidth(cardRect), CGRectGetHeight(cardRect),
              CGRectIsNull(leftBand) ? @"无" : @"有",
              CGRectIsNull(rightBand) ? @"无" : @"有",
              CGRectIsNull(bottomBand) ? @"无" : @"有",
              CGRectIsNull(topBand) ? @"无" : @"有",
              CGRectIsNull(scaleZone) ? @"无（已停靠）" : NSStringFromCGRect(scaleZone),
              dockedOverlayVisible ? @"有" : @"无");
    }
}

/// 【0.3.19】顶带点击 = 关闭浮窗（原生"点空白关闭"已被分区逻辑接管，这里是贴卡顶的专用关闭带）
-(void)mfBandTopTap:(UITapGestureRecognizer *)tap{
    if (![self mfCanDragCardEdgeNow]) {
        return;
    }
    MFLog(@"[card] 顶带点击 → 关闭浮窗");
    [self close];
}

/// 【0.3.12】四边热区手势的总开关——布局模式无关（竖屏 VerticalSide 也放行）。
/// 0.3.11 误用 canMovePortraitHostedLandscapeCardVertically（要求 HorizontalBottom 布局，
/// 竖屏 iPhone 恒 NO）当总开关 → 四条热区 Began 全部静默失效（log21 实证）。
-(BOOL)mfCanDragCardEdgeNow{
    return panelState == POPanelStateOpen &&
        !CGRectIsEmpty(keyboardZoomBaseFrame) &&
        ![self isPanelTransitioning] &&
        !presentedQuickSwitchMenu &&
        (quickSwitchInteractionOverlayView == nil || quickSwitchInteractionOverlayView.hidden) &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating;
}

#pragma mark - 【0.3.19】卡片内容坐标 <-> 屏幕坐标

/// 【0.3.19 血泪 log24】卡片容器是 scrollView 的内容子视图（addSubview:keyboardZoomContainer），
/// keyboardZoomBaseFrame 是"内容坐标"；屏幕可见位置 = 内容坐标 − scrollView.contentOffset.x。
/// 0.3.13/0.3.19 把内容坐标当屏幕坐标做钳制（算出 x∈[5,90]，而屏幕可见范围在内容坐标里
/// 是 [offset+5, offset+90]≈[388,473]）→ 移动/停靠后卡片被甩出屏幕左缘，用户无法操作。
/// 注意：y 轴没有滚动，两个坐标系一致，只有 x 需要换算。
-(CGFloat)mfCardScrollOffsetX{
    return scrollView ? scrollView.contentOffset.x : 0.0;
}

/// 卡片 origin.x 的屏幕钳制下限
-(CGFloat)mfCardScreenMinX{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    return MAX(viewInsets.left, windowInsets.left) + CONTENT_EDGE_GAP;
}

/// 卡片 origin.x 的屏幕钳制上限
-(CGFloat)mfCardScreenMaxXForCardWidth:(CGFloat)cardWidth{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    return CGRectGetWidth(self.view.bounds) - MAX(viewInsets.right, windowInsets.right) -
        CONTENT_EDGE_GAP - cardWidth;
}

/// 【0.3.20】自由移动的 Y 可用区间（唯一出处：mfApplyCardPositionBottomY: 与本诊断日志共用）。
/// 语义 = **卡片整体留在屏内**：上边留一个最小边距、下边不越过屏底。
/// ★★ 0.3.19 沿用上游"顶部安全区 + 卡片高 / 再扣底部保留区（手柄/横条高）+ 边距"的窄区间：
/// 竖屏竖向布局下卡片高 727、屏高 932，扣完只剩约 57pt 行程，而且一旦上限被底部保留区
/// 压到下限之下就直接锁死在最小值 ⇒ 底带怎么拖都回到原处（log29 实证：4 次拖动
/// `自由移动开始/结束` 底边恒为 830、屏 x 恒为 47，用户感知"底部手势无法触发"）。
-(void)mfCardBottomYRangeMin:(CGFloat *)minOut max:(CGFloat *)maxOut{
    CGFloat cardHeight = CGRectGetHeight(keyboardZoomBaseFrame);
    CGFloat screenHeight = CGRectGetHeight(self.view.bounds);
    CGFloat minBottom = cardHeight + CONTENT_EDGE_GAP;
    CGFloat maxBottom = screenHeight - HANDLE_EDGE_GAP;
    if (maxBottom < minBottom) {          // 卡片比屏还高（异常）→ 只能锁在屏内
        minBottom = maxBottom = screenHeight;
    }
    if (minOut) *minOut = minBottom;
    if (maxOut) *maxOut = maxBottom;
}

/// 【0.3.13】自由移动跟随：直接改 keyboardZoomBaseFrame（Y 钳制在屏内，X 屏幕坐标钳制后换算回内容坐标）。
/// 布局无关（绕开 PortraitHostedLandscape 专属链路），移动后同步手柄/横条锚。
-(void)mfApplyCardPositionBottomY:(CGFloat)cardBottomY originX:(CGFloat)originX{
    CGFloat cardWidth = CGRectGetWidth(keyboardZoomBaseFrame);
    CGFloat cardHeight = CGRectGetHeight(keyboardZoomBaseFrame);
    if (cardWidth <= 0 || cardHeight <= 0) {
        return;
    }
    // 【0.3.20】Y 钳制 = 卡片整体不出屏（宽区间，见 mfCardBottomYRangeMin:max: 注释）
    CGFloat minimumCardBottomY = 0;
    CGFloat maximumCardBottomY = 0;
    [self mfCardBottomYRangeMin:&minimumCardBottomY max:&maximumCardBottomY];
    cardBottomY = MIN(MAX(cardBottomY, minimumCardBottomY), maximumCardBottomY);
    // 【0.3.19】X 钳制必须在屏幕坐标空间做（originX 是内容坐标）：
    // 屏幕可见 x = 内容 x − contentOffset.x，钳完再加回 offset。
    CGFloat offsetX = [self mfCardScrollOffsetX];
    CGFloat screenMinX = [self mfCardScreenMinX];
    CGFloat screenMaxX = [self mfCardScreenMaxXForCardWidth:cardWidth];
    CGFloat screenX = originX - offsetX;
    if (screenMaxX < screenMinX) {
        screenX = screenMinX;
    } else {
        screenX = MIN(MAX(screenX, screenMinX), screenMaxX);
    }
    originX = screenX + offsetX;
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGRect baseFrame = keyboardZoomBaseFrame;
    baseFrame.origin.x = round(originX * screenScale) / screenScale;
    baseFrame.origin.y = round((cardBottomY - cardHeight) * screenScale) / screenScale;
    portraitHostedLandscapeHandleAnchorY = cardBottomY + HANDLE_EDGE_GAP;
    keyboardZoomBaseFrame = baseFrame;
    if (mfDockedSide != 0) {
        // 【0.3.22】停靠态拖动 = 挪动 16:9 小窗：基准 frame 就是小窗 frame，跟着更新，
        // 否则下一次布局 passe 会按"停在屏幕边缘"的旧位置把它拽回去。
        mfDockedCardFrame = baseFrame;
    }
    mfUserCardPositionPinned = YES;   // 【0.3.20】用户挪过 → 布局 passe 不得拉回标准打开位
    if (fabs(appliedCardScale - 1.0) > PO_CARD_SCALE_EPSILON) {
        // 【0.3.19】缩放态（停靠/手动缩放）移动：保持缩放与锚点，只按新 baseFrame 重摆中心。
        // 0.3.13 直接把 transform 打回 Identity 会把停靠态拖回满尺寸（视觉上"吸附丢失"）。
        [self applyCardScaleTarget:appliedCardScale animated:NO source:POCardScaleTransitionSourceReconcile];
    } else {
        [UIView performWithoutAnimation:^{
            self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
            self->keyboardZoomContainer.frame = baseFrame;
        }];
    }
    [self updatePortraitHostedLandscapeHandleForCurrentOffset];
    [self syncHorizontalQuickSwitchPresentationAnchor];
    [self mfUpdateVerticalHandleRailPosition];   // 【0.3.19】rail 跟随移动后的卡片右缘
    [self mfUpdateEdgeBands];                    // 【0.3.19】带子跟手（每帧移动都同步）
}

/// 【0.3.13】底部热区：pan 自由移动（X+Y 跟手，松手停在哪就是哪，不吸附）。
/// 【0.3.21 血泪 log30】0.3.20 把 pan 挂在**底带子视图**上：log30 实证 `按下/开始/结束` 三行落在
/// **同一毫秒**、全程没有 `跟手首帧` ⇒ Changed 一次都没进来（Began 后立刻 Ended、位移(0,0)），
/// 用户感知"底部手势失效"；而同版挂在**宿主**上的捏合 pan 收得到连续 Changed（缩放正常）。
/// 本版把移动 pan 改挂宿主，Began 时用触点位置判定归属：**底带（去掉右端缩放区）** 或 **停靠小窗盖层**。
-(void)mfCardMovePan:(UIPanGestureRecognizer *)pan{
    if (pan.state == UIGestureRecognizerStateBegan) {
        // 归属判定：只有落在"底带左段（去掉右端缩放区）"或"停靠小窗盖层"才认领
        CGPoint p = [pan locationInView:mfEdgeBandHost];
        BOOL inScaleZone = mfEdgeBandBottomRight != nil && !mfEdgeBandBottomRight.hidden &&
            CGRectContainsPoint(mfEdgeBandBottomRight.frame, p);
        BOOL inMoveZone = (mfEdgeBandBottom != nil && !mfEdgeBandBottom.hidden &&
                           CGRectContainsPoint(mfEdgeBandBottom.frame, p)) ||
                          (mfDockedTapView != nil && !mfDockedTapView.hidden &&
                           CGRectContainsPoint(mfDockedTapView.frame, p));
        MFLog(@"[card] 移动热区按下 canDrag=%d 触点数=%lu 触点(%.0f,%.0f) 移动带内=%d 缩放带内=%d mode=%ld",
              [self mfCanDragCardEdgeNow], (unsigned long)pan.numberOfTouches, p.x, p.y,
              inMoveZone, inScaleZone, (long)mfEdgeDragMode);
        if (!inMoveZone || inScaleZone) {
            return;   // 不认领（不占 mode，让缩放 pan 正常工作）
        }
        if (![self mfCanDragCardEdgeNow]) {
            pan.enabled = NO;
            pan.enabled = YES;
            return;
        }
        if (mfEdgeDragMode != 0) {   // 已有手势在跑（例如同时在缩放）→ 让位
            MFLog(@"[card] 移动热区按下 → 让位（mode=%ld 已占用）", (long)mfEdgeDragMode);
            return;
        }
        [self cancelAutoNubTimer];
        mfEdgeDragMode = 1;
        mfEdgeDragLoggedChanged = NO;
        // 【0.3.22】起手自"停靠小窗盖层"：小位移（<16pt）= 用户其实是在点小窗 → 松手时还原，
        // 不算移动。用户反馈"点小窗还原不灵敏"里有一部分是手抖把 tap 变成 pan（tap 识别失败）。
        mfEdgeDragFromDocked = (mfDockedTapView != nil && !mfDockedTapView.hidden &&
                                CGRectContainsPoint(mfDockedTapView.frame, p));
        mfEdgeDragStartBottomY = CGRectGetMaxY(keyboardZoomBaseFrame);
        mfEdgeDragStartX = CGRectGetMinX(keyboardZoomBaseFrame);
        CGFloat rangeMin = 0, rangeMax = 0;
        [self mfCardBottomYRangeMin:&rangeMin max:&rangeMax];
        // 【0.3.19】不再强制 restoreKeyboardZoomImmediately：停靠/缩放态拖动保持当前大小移动
        MFLog(@"[card] 自由移动开始（起点 屏x=%.0f 内容x=%.0f 底边 %.0f，scale %.2f，Y 可用区间 %.0f..%.0f）",
              mfEdgeDragStartX - [self mfCardScrollOffsetX], mfEdgeDragStartX,
              mfEdgeDragStartBottomY, appliedCardScale, rangeMin, rangeMax);
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged) {
        if (mfEdgeDragMode != 1) {
            return;
        }
        CGPoint t = [pan translationInView:self.view];
        // 【0.3.20 诊断】每次拖动的第一帧打一行，用来区分"Changed 到底有没有到"
        // 与"到了但被钳制压回原处"（log29 只有首尾两行、位移恒为 0，无法区分这两种真因）
        if (!mfEdgeDragLoggedChanged) {
            mfEdgeDragLoggedChanged = YES;
            MFLog(@"[card] 自由移动跟手首帧 位移(%.1f,%.1f) 触点数=%lu",
                  t.x, t.y, (unsigned long)pan.numberOfTouches);
        }
        [self mfApplyCardPositionBottomY:mfEdgeDragStartBottomY + t.y
                                 originX:mfEdgeDragStartX + t.x];
        return;
    }
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        // 【0.3.20】只清自己那一档（mode==1）。0.3.19 无条件清 0：底带 pan 被系统取消时
        // 会把捏合刚写好的 mode=2 抹掉 → 捏合后续 Changed 全被早退（"双指缩放触发不了"成因之一）
        if (mfEdgeDragMode != 1) {
            return;
        }
        CGPoint endTranslation = [pan translationInView:self.view];
        if (pan.state == UIGestureRecognizerStateEnded) {
            // 【0.3.22】停靠小窗上"手抖式拖动"（位移 < 16pt）= 用户想点小窗还原 → 还原，不移动
            if (mfEdgeDragFromDocked &&
                hypot(endTranslation.x, endTranslation.y) < MF_CARD_EDGE_TAP_SLOP) {
                MFLog(@"[card] 小窗上小位移(%.1f,%.1f) → 视作点了小窗，还原停靠前尺寸",
                      endTranslation.x, endTranslation.y);
                mfEdgeDragMode = 0;
                mfEdgeDragFromDocked = NO;
                [self resetAutoNubTimer];
                [self mfRestoreFromDock];
                return;
            }
            // 【0.3.21】从未进过 Changed 但总位移非零（log30 的"Began 后同毫秒 End"）→ 补一次移动，
            // 让"拖动只报首尾两帧"的手势也能生效。
            if (!mfEdgeDragLoggedChanged &&
                (fabs(endTranslation.x) > 0.5 || fabs(endTranslation.y) > 0.5)) {
                MFLog(@"[card] 自由移动：全程无 Changed，按总位移补一次(%.1f,%.1f)", 
                      endTranslation.x, endTranslation.y);
                [self mfApplyCardPositionBottomY:mfEdgeDragStartBottomY + endTranslation.y
                                         originX:mfEdgeDragStartX + endTranslation.x];
            }
            CGFloat endScreenX = CGRectGetMinX(keyboardZoomBaseFrame) - [self mfCardScrollOffsetX];
            CGFloat cardWidth = CGRectGetWidth(keyboardZoomBaseFrame);
            CGFloat cardRight = endScreenX + cardWidth;
            CGFloat screenWidth = CGRectGetWidth(self.view.bounds);
            CGPoint velocity = [pan velocityInView:self.view];
            // 【0.3.19】TrollOpen 式甩边关闭：快速向右甩 + 卡片右缘已贴近屏幕右缘 → 关闭浮窗
            if (velocity.x > MF_CARD_EDGE_FLICK_CLOSE_VELOCITY &&
                cardRight >= screenWidth - MF_CARD_EDGE_FLICK_CLOSE_MARGIN) {
                MFLog(@"[card] 自由移动结束 → 向右甩边关闭（右缘 %.0f 屏宽 %.0f 速度 %.0f）",
                      cardRight, screenWidth, velocity.x);
                mfEdgeDragMode = 0;
                [self resetAutoNubTimer];
                [self close];
                return;
            }
            MFLog(@"[card] 自由移动结束（位移(%.1f,%.1f) 屏x=%.0f 底边 %.0f，不吸附）",
                  endTranslation.x, endTranslation.y,
                  endScreenX, CGRectGetMaxY(keyboardZoomBaseFrame));
        }
        mfEdgeDragMode = 0;
        [self resetAutoNubTimer];
    }
}

/// 【0.3.21 重做（用户 log30 指令）】缩放 = **右下角滑动缩放**（双指捏合太麻烦，废弃）。
/// 区域 = 底带右端 84pt（mfEdgeBandBottomRight，独立子视图 + 独立 pan）。
/// 映射沿用 0.3.13 用户指定：向左/上（对角）滑 = 缩小，向右/下 = 放大；对角位移 220pt ≈ 一整个档位。
/// 缩放锚点：右侧停靠时保持右上锚（右缘贴着屏缘不动），其余保持左上锚（用户指定：左上角不动）。
/// 松手吸附 0.5 / 0.75 / 1.0 最近档。
-(void)mfCardCornerScalePan:(UIPanGestureRecognizer *)pan{
    if (pan.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[card] 右下角缩放按下 canDrag=%d 触点数=%lu mode=%ld",
              [self mfCanDragCardEdgeNow], (unsigned long)pan.numberOfTouches, (long)mfEdgeDragMode);
        if (![self mfCanDragCardEdgeNow]) {
            pan.enabled = NO;
            pan.enabled = YES;
            return;
        }
        if (mfEdgeDragMode != 0) {   // 已有手势在跑 → 让位
            MFLog(@"[card] 右下角缩放按下 → 让位（mode=%ld 已占用）", (long)mfEdgeDragMode);
            return;
        }
        [self cancelAutoNubTimer];
        mfEdgeDragMode = 2;
        mfEdgeDragLoggedChanged = NO;
        mfEdgeDragStartScale = (appliedCardScale > 0 && isfinite(appliedCardScale))
            ? appliedCardScale : 1.0;
        MFLog(@"[card] 右下角缩放开始（起点 %.2f，锚=%@）",
              mfEdgeDragStartScale, mfDockedSide == 1 ? @"右上" : @"左上");
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged) {
        if (mfEdgeDragMode != 2) {
            return;
        }
        CGPoint t = [pan translationInView:self.view];
        if (!mfEdgeDragLoggedChanged) {
            mfEdgeDragLoggedChanged = YES;
            MFLog(@"[card] 右下角缩放跟手首帧 位移(%.1f,%.1f)", t.x, t.y);
        }
        [self mfApplyCornerScaleDragTranslation:t];
        return;
    }
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        if (mfEdgeDragMode != 2) {
            return;
        }
        if (pan.state == UIGestureRecognizerStateEnded) {
            // 补最后一帧（log30 实证：短促手势可能只有 Began→Ended，没有 Changed）
            [self mfApplyCornerScaleDragTranslation:[pan translationInView:self.view]];
            [self mfSnapCardScaleAnimated:YES];
        }
        mfEdgeDragMode = 0;
        [self resetAutoNubTimer];
    }
}

/// 【0.3.21】右下角缩放跟手：对角位移 → 档位（向右下=放大 / 向左上=缩小），实时钳制 [0.5, 1.0]。
-(void)mfApplyCornerScaleDragTranslation:(CGPoint)translation{
    CGFloat delta = (translation.x + translation.y) / 2.0;   // 对角
    CGFloat target = mfEdgeDragStartScale + delta / MF_CARD_EDGE_SCALE_DRAG_SPAN;
    target = MIN(MAX(target, MF_CARD_EDGE_SCALE_MIN), MF_CARD_EDGE_SCALE_MAX);
    if (fabs(target - appliedCardScale) <= PO_CARD_SCALE_EPSILON) {
        return;
    }
    mfManualScaleAnchorRight = (mfDockedSide == 1);   // 右停靠 → 右缘不动；其余 → 左上角不动
    [self applyCardScaleTarget:target animated:NO source:POCardScaleTransitionSourceHandle];
}

/// 【0.3.22】停靠小窗的目标 frame（**内容坐标**）：固定 16:9，贴该侧屏幕边缘，
/// 纵向沿用当前卡片顶边（钳在屏内）—— 停靠只改"贴哪侧 + 变成 16:9 小窗"，不动纵向位置。
-(CGRect)mfDockedCardFrameForSide:(BOOL)toRight{
    CGRect bounds = self.view.bounds;
    CGFloat screenW = CGRectGetWidth(bounds);
    CGFloat screenH = CGRectGetHeight(bounds);
    if (screenW <= 0 || screenH <= 0) {
        return CGRectZero;
    }
    CGFloat offsetX = [self mfCardScrollOffsetX];
    CGFloat minX = [self mfCardScreenMinX];
    CGFloat h = MAX(MF_CARD_DOCK_MIN_HEIGHT, screenH * MF_CARD_DOCK_HEIGHT_RATIO);
    CGFloat w = h * MF_CARD_DOCK_ASPECT;
    CGFloat maxW = screenW * MF_CARD_DOCK_MAX_WIDTH_RATIO;
    if (w > maxW) {
        w = maxW;
        h = w / MF_CARD_DOCK_ASPECT;
    }
    w = round(w);
    h = round(h);
    CGFloat screenX = toRight ? [self mfCardScreenMaxXForCardWidth:w] : minX;
    if (screenX < minX) {
        screenX = minX;
    }
    CGFloat top = CGRectGetMinY(keyboardZoomBaseFrame);
    if (!isfinite(top) || top < minX) {
        top = screenH * 0.12;
    }
    CGFloat maxTop = MAX(minX, screenH - minX - h);
    top = round(MIN(MAX(top, minX), maxTop));
    return CGRectMake(screenX + offsetX, top, w, h);
}

/// 【0.3.22】把卡片**真正**变成 16:9 小窗（不是"缩放到 0.5"）：
/// 0.3.21 之前停靠靠 transform 缩放实现 ⇒ ① 比例改不了（缩放不影响宽高比）；
/// ② 会被 `applyLayoutPreservingHandlePosition:` 的 `transform=Identity` 打回满尺寸
/// （log31 实证：停靠后拖动时 `scale 1.00` 而内容 x 仍是停靠位 472）—— 于是"点小窗还原不灵敏、
/// 触摸落到 App 里"。现在停靠 = 改**基准 frame**（容器真身就是 240x135），
/// App 内容由 layoutContextView 按"填满裁切"重排，布局 passe 也只认这个 frame。
-(void)mfApplyDockedCardFrame:(CGRect)frame animated:(BOOL)animated{
    if (CGRectIsEmpty(frame)) {
        return;
    }
    mfDockedCardFrame = frame;
    keyboardZoomBaseFrame = frame;
    portraitHostedLandscapeHandleAnchorY = CGRectGetMaxY(frame) + HANDLE_EDGE_GAP;
    appliedCardScale = 1.0;                 // 停靠不是缩放档位（容器已是小窗真身）
    mfManualScaleAnchorRight = NO;
    keyboardZoomApplied = NO;
    void (^changes)(void) = ^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->keyboardZoomContainer.frame = frame;
        self->shadowView.frame = self->keyboardZoomContainer.bounds;
        self.contentView.frame = self->keyboardZoomContainer.bounds;
        self->shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self->shadowView.bounds
                                                                  cornerRadius:MFPanelCornerRadius()].CGPath;
    };
    [UIView performWithoutAnimation:changes];
    // 容器尺寸变了 → App 内容按"填满裁切"重排（mfDockedSide 已在调用方写好）
    [self layoutContextView];
    [self updatePortraitHostedLandscapeHandleForCurrentOffset];
    [self syncHorizontalQuickSwitchPresentationAnchor];
    [self mfUpdateVerticalHandleRailPosition];
    [self mfUpdateEdgeBands];
    MFLog(@"[card] 停靠小窗落位：%@（内容 %.0f,%.0f %.0fx%.0f，16:9，scale 复位 1.00，animated=%d）",
          NSStringFromCGRect(frame), frame.origin.x, frame.origin.y,
          CGRectGetWidth(frame), CGRectGetHeight(frame), (int)animated);
}

/// 【0.3.21】停靠态：点小窗 → 还原停靠前的尺寸与位置（用户 log30 指令）。
-(void)mfDockedCardTap:(UITapGestureRecognizer *)tap{
    if (mfDockedSide == 0) {
        return;
    }
    if (![self mfCanDragCardEdgeNow]) {
        MFLog(@"[card] 点小窗（盖层）→ 当前不可操作（canDrag=0）");
        return;
    }
    MFLog(@"[card] 点小窗（盖层）→ 还原停靠前尺寸（停靠边=%ld）", (long)mfDockedSide);
    [self mfRestoreFromDock];
}

/// 【0.3.21】从停靠态还原：把停靠前记录的 frame/档位写回去（缺记录时退回"满尺寸 + 标准打开位"）。
/// 【0.3.22】停靠期间容器是 16:9 小窗 ⇒ 必须**先把尺寸/transform 写回基准**，再叠缩放档位；
/// 0.3.21 直接 applyCardScaleTarget 只改 center/transform，尺寸会留在小窗上（还原不彻底）。
-(void)mfRestoreFromDock{
    if (mfDockedSide == 0) {
        return;   // 未停靠 → 不处理
    }
    NSInteger fromSide = mfDockedSide;
    CGFloat restoreScale = (mfPreDockScale > PO_CARD_SCALE_EPSILON) ? mfPreDockScale : 1.0;
    if (fabs(restoreScale - 1.0) <= PO_CARD_SCALE_EPSILON) {
        restoreScale = 1.0;
    }
    CGRect restoreFrame = mfPreDockFrame;
    CGFloat currentScreenX = CGRectGetMinX(keyboardZoomBaseFrame) - [self mfCardScrollOffsetX];
    CGFloat screenScale = UIScreen.mainScreen.scale;
    // 记录失效（旋转/换尺寸后）→ 退回"新默认尺寸 + 标准打开位（内容 x = 屏宽）"
    if (CGRectIsEmpty(restoreFrame) ||
        fabs(CGRectGetWidth(restoreFrame) - contentLayoutWidth) > 1.0 ||
        fabs(CGRectGetHeight(restoreFrame) - contentLayoutHeight) > 1.0) {
        restoreFrame = keyboardZoomBaseFrame;
        restoreFrame.size = CGSizeMake(contentLayoutWidth, contentLayoutHeight);
        restoreFrame.origin.x = CGRectGetWidth(self.view.bounds);
        CGFloat maxTop = MAX(CONTENT_EDGE_GAP,
                             CGRectGetHeight(self.view.bounds) - CONTENT_EDGE_GAP - contentLayoutHeight);
        restoreFrame.origin.y = round(MIN(MAX(CGRectGetMinY(restoreFrame), CONTENT_EDGE_GAP), maxTop) * screenScale) / screenScale;
    }
    mfDockedSide = 0;
    mfDockedCardFrame = CGRectZero;
    mfEdgeDragMode = 0;
    mfEdgeDragFromDocked = NO;
    mfUserCardScaleOverride = (restoreScale >= 1.0 - PO_CARD_SCALE_EPSILON) ? 0.0 : restoreScale;
    mfManualScaleAnchorRight = NO;
    keyboardZoomBaseFrame = restoreFrame;
    portraitHostedLandscapeHandleAnchorY = CGRectGetMaxY(restoreFrame) + HANDLE_EDGE_GAP;
    mfUserCardPositionPinned = YES;
    [self cancelAutoNubTimer];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->keyboardZoomContainer.frame = restoreFrame;   // 尺寸先回基准（16:9 小窗 → 满卡）
        self->shadowView.frame = self->keyboardZoomContainer.bounds;
        self.contentView.frame = self->keyboardZoomContainer.bounds;
        self->shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self->shadowView.bounds
                                                                  cornerRadius:MFPanelCornerRadius()].CGPath;
    }];
    [self layoutContextView];   // mfDockedSide 已清 → 回到"完整装入"
    if (fabs(restoreScale - 1.0) > PO_CARD_SCALE_EPSILON) {
        [self applyCardScaleTarget:restoreScale animated:NO source:POCardScaleTransitionSourceHandle];
    }
    [self updatePortraitHostedLandscapeHandleForCurrentOffset];
    [self syncHorizontalQuickSwitchPresentationAnchor];
    [self mfUpdateVerticalHandleRailPosition];
    [self mfUpdateEdgeBands];
    MFLog(@"[card] 停靠还原：%@侧 → 尺寸 %.2f（屏x %.0f -> %.0f，底边 %.0f）",
          fromSide == 1 ? @"右" : @"左", restoreScale, currentScreenX,
          CGRectGetMinX(restoreFrame) - [self mfCardScrollOffsetX], CGRectGetMaxY(restoreFrame));
}

/// 【0.3.19】左/右侧热区：点击停靠到该侧（已停靠该侧再点=还原满尺寸）。
/// 实际落位见 mfSnapCardToSide:（平移 + 贴边锚缩放，否则满宽卡片下平移不可见）。
-(void)mfCardSideTap:(UITapGestureRecognizer *)tap{
    BOOL toRight = tap.view.tag == MF_CARD_EDGE_HOTZONE_TAG_RIGHT;
    MFLog(@"[card] 侧边点击（%@侧） canDrag=%d", toRight ? @"右" : @"左", [self mfCanDragCardEdgeNow]);
    [self mfSnapCardToSide:toRight];
}

/// 【0.3.22 重做（log31 用户指令）】侧边停靠 = **固定 16:9 小窗**贴该侧屏幕边缘：
///   点某侧带 = 卡片变成 16:9 小窗（本机 240x135）贴到该侧，纵向位置不动；
///   点小窗（或同侧再点）= 还原**停靠前的尺寸与位置**（mfRestoreFromDock）。
///   【0.3.22 血泪 log31】0.3.21 用"缩放到 0.5"实现停靠：① 比例还是竖向 168x364（用户要 16:9）；
///   ② 会被布局 passe 的 `transform = Identity` 打回**满尺寸**（实证：停靠后拖动时 `scale 1.00`、
///   内容 x 仍是停靠位 472）⇒ 小窗盖层与实际卡片错位，用户"点小窗还原不灵敏、点到 App 里去了"。
///   现在停靠改的是**基准 frame 本身**（容器真身就是 16:9），布局 passe 也按停靠态重建它。
-(void)mfSnapCardToSide:(BOOL)toRight{
    if (![self mfCanDragCardEdgeNow]) {
        return;
    }
    mfUserCardPositionPinned = YES;   // 【0.3.20】停靠过 → 布局 passe 不得把卡片拉回标准打开位
    [self cancelAutoNubTimer];
    // "是否已停靠该侧"只认 mfDockedSide（0.3.19 借用 mfManualScaleAnchorRight，
    // 于是"手动缩到 0.5 但没停靠"的卡片点左带会被当成"取消停靠左"直接还原，语义串味）。
    NSInteger sideFlag = toRight ? 1 : -1;
    if (mfDockedSide == sideFlag) {
        // 同侧再点 = 还原**停靠前的尺寸与位置**（与"点小窗还原"同一语义）
        MFLog(@"[card] 取消停靠（%@侧再点）→ 还原停靠前尺寸", toRight ? @"右" : @"左");
        [self mfRestoreFromDock];
        return;
    }
    // 【0.3.21】记录停靠前的尺寸/位置（点小窗还原用）。已在停靠态换边时不覆盖。
    if (mfDockedSide == 0) {
        mfPreDockScale = (appliedCardScale > 0 && isfinite(appliedCardScale)) ? appliedCardScale : 1.0;
        mfPreDockFrame = keyboardZoomBaseFrame;
    }
    CGFloat currentScreenX = CGRectGetMinX(keyboardZoomBaseFrame) - [self mfCardScrollOffsetX];
    CGRect dockFrame = [self mfDockedCardFrameForSide:toRight];
    if (CGRectIsEmpty(dockFrame)) {
        return;
    }
    mfDockedSide = toRight ? 1 : -1;   // 【0.3.20】记录停靠边（"再点同侧=还原"的唯一依据）
    mfUserCardScaleOverride = 0;       // 停靠不是缩放档位（还原时用 mfPreDockScale）
    mfManualScaleAnchorRight = NO;
    mfEdgeDragMode = 0;
    mfEdgeDragFromDocked = NO;
    [self mfApplyDockedCardFrame:dockFrame animated:YES];
    MFLog(@"[card] 侧边停靠：屏x %.0f -> %.0f，%@侧（16:9 小窗 %.0fx%.0f，内容x=%.0f，offset=%.0f，"
          @"停靠前 尺寸 %.2f / frame %.0fx%.0f）",
          currentScreenX, CGRectGetMinX(dockFrame) - [self mfCardScrollOffsetX], toRight ? @"右" : @"左",
          CGRectGetWidth(dockFrame), CGRectGetHeight(dockFrame),
          CGRectGetMinX(dockFrame), [self mfCardScrollOffsetX],
          mfPreDockScale, CGRectGetWidth(mfPreDockFrame), CGRectGetHeight(mfPreDockFrame));
    // 【0.3.19 自愈】log28 实证：停靠指令执行后卡片实际位置与期望不符，且期间有别的代码动了容器。
    // 0.35s 后（动画已完成）核对"实际屏幕矩形 vs 期望矩形"，不符 → 打日志并强制重施一次停靠。
    CGFloat expectedLeft = CGRectGetMinX(dockFrame) - [self mfCardScrollOffsetX];
    CGFloat expectedTop = CGRectGetMinY(dockFrame);
    CGFloat expectedWidth = CGRectGetWidth(dockFrame);
    CGFloat expectedHeight = CGRectGetHeight(dockFrame);
    CGFloat expectedContentX = CGRectGetMinX(dockFrame);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->panelState != POPanelStateOpen || self->mfDockedSide == 0) {
            return;
        }
        CGRect actual = [self->keyboardZoomContainer.superview
            convertRect:self->keyboardZoomContainer.frame toView:self.view];
        BOOL match = fabs(CGRectGetMinX(actual) - expectedLeft) <= 8.0 &&
            fabs(CGRectGetMinY(actual) - expectedTop) <= 8.0 &&
            fabs(CGRectGetWidth(actual) - expectedWidth) <= 8.0 &&
            fabs(CGRectGetHeight(actual) - expectedHeight) <= 8.0;
        MFLog(@"[card] 停靠落位核对：期望(%.0f,%.0f,%0.fx%.0f) 实际(%.0f,%.0f,%.0fx%.0f) %@",
              expectedLeft, expectedTop, expectedWidth, expectedHeight,
              CGRectGetMinX(actual), CGRectGetMinY(actual),
              CGRectGetWidth(actual), CGRectGetHeight(actual),
              match ? @"一致" : @"不一致 → 自愈重施");
        if (!match) {
            CGRect fix = self->mfDockedCardFrame;
            fix.origin.x = expectedContentX;   // 停靠位是权威（几何助手按屏宽算出来的）
            [self mfApplyDockedCardFrame:fix animated:NO];
        }
    });
}

/// 松手吸附（缩放）：弹到 0.5 / 0.75 / 1.0 中最近的一档（弹簧动画）。
/// 非 1.0 档记入 mfUserCardScaleOverride，键盘弹出/面板关闭时自动清除。
/// 【0.3.21】吸附回满尺寸（1.0）时清掉停靠标记（已经不是"小窗"了，盖层要撤）。
-(void)mfSnapCardScaleAnimated:(BOOL)animated{
    CGFloat current = appliedCardScale > 0 && isfinite(appliedCardScale) ? appliedCardScale : 1.0;
    const CGFloat steps[3] = { MF_CARD_EDGE_SCALE_SNAP_A, MF_CARD_EDGE_SCALE_SNAP_B, 1.0 };
    CGFloat best = 1.0;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (int i = 0; i < 3; i++) {
        CGFloat distance = fabs(current - steps[i]);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = steps[i];
        }
    }
    mfUserCardScaleOverride = best >= 1.0 - PO_CARD_SCALE_EPSILON ? 0.0 : best;
    if (mfDockedSide != 0) {
        // 【0.3.22】停靠小窗不出缩放热区 ⇒ 正常到不了这里；真到了就只改档位、绝不动停靠标记
        // （0.3.21 这里会把 mfDockedSide 清 0 → 小窗盖层消失、点小窗再也不能还原）
        MFLog(@"[card] 缩放吸附（停靠态，保持停靠边=%ld）：%.2f -> %.2f",
              (long)mfDockedSide, current, best);
        [self applyCardScaleTarget:best animated:animated source:POCardScaleTransitionSourceHandle];
        return;
    }
    if (best >= 1.0 - PO_CARD_SCALE_EPSILON) {
        mfDockedSide = 0;   // 回到满尺寸 = 不再是小窗
    }
    [self applyCardScaleTarget:best animated:animated source:POCardScaleTransitionSourceHandle];
    MFLog(@"[card] 缩放吸附：%.2f -> %.2f（override=%g，停靠边=%ld）",
          current, best, mfUserCardScaleOverride, (long)mfDockedSide);
}

#pragma mark - 【MF 0.1.2】面板打开后把手柄移到浮窗右侧

/// 竖屏（vertical rail）时手柄 rail 应有的"屏幕坐标 x"：
///   · 关闭态 → 贴屏幕右缘（上游行为，不变）
///   · 打开态 → 平移到卡片右边缘外侧，使 nub **完整显示在浮窗右边**（右手可及）
///   中间按打开进度线性插值 —— 手柄随面板一起滑入，不会突兀跳位。
///   注：上游竖屏分支把 rail 固定在"内容坐标"，面板滑入时会被 scrollView 一起带走
///   （打开后手柄跑到屏幕左侧），这里就是把这个偏移补回来。
-(CGFloat)mfVerticalHandleRailScreenX{
    CGRect bounds = self.view.bounds;
    CGFloat screenWidth = CGRectGetWidth(bounds);
    CGFloat railWidth = [self handleRailWidth];
    CGFloat closedScreenX = screenWidth - railWidth;
    if (railWidth <= 0 || contentLayoutWidth <= 0 || contentLayoutWidth >= screenWidth - 1.0) {
        return closedScreenX;   // 卡片接近满宽 → 无需移动（保持上游行为）
    }

    // 打开态卡片右缘：【0.3.19】跟随实际位置（自由移动/侧边停靠后不再居中）；
    // 缩放造成的右缘变化由 handleScrollView 的伴移 transform 补偿，这里只给未缩放右缘。
    // 过渡态（Opening/Closing）或无基准 frame 时退回"居中假设"（上游行为不变）。
    CGFloat openCardRight;
    if (panelState == POPanelStateOpen && !CGRectIsEmpty(keyboardZoomBaseFrame)) {
        openCardRight = CGRectGetMaxX(keyboardZoomBaseFrame) - scrollView.contentOffset.x;
    } else {
        openCardRight = (screenWidth + contentLayoutWidth) / 2.0;
    }
    CGFloat handleWidth = CGRectGetWidth(self.handle.bounds);
    if (handleWidth <= 0) {
        return closedScreenX;
    }

    // nub 呈现时手柄在 rail 内右移 (railW - 可见宽)，故 nub 左边缘 = railX + railW - visibleWidth
    CGFloat hiddenPercent = 67.0;
    id configuredHidden = [POApplicationHelper settings][@"nubHiddenPercentage"];
    if ([configuredHidden respondsToSelector:@selector(doubleValue)]) {
        hiddenPercent = [configuredHidden doubleValue];
    }
    hiddenPercent = MIN(MAX(hiddenPercent, 0.0), 80.0);
    CGFloat visibleWidth = handleWidth * (1.0 - hiddenPercent / 100.0);

    CGFloat openScreenX = openCardRight + MFPanelHandleEdgeGap() - railWidth + visibleWidth;
    openScreenX = MIN(MAX(openScreenX, 0.0), closedScreenX);   // 不允许比贴右缘更靠右

    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat progress = maximumOffset > 0
        ? MIN(MAX(scrollView.contentOffset.x / maximumOffset, 0), 1)
        : 0;
    return closedScreenX + (openScreenX - closedScreenX) * progress;
}

/// 把手柄 rail 摆到上面的位置。rail 是 scrollView 的子视图（坐标属于 content），
/// 因此要加回 contentOffset.x 才能落到期望的屏幕位置 —— 与上游 landscape 分支同一思路。
-(void)mfUpdateVerticalHandleRailPosition{
    if (self.handle.layoutMode != POHandleLayoutModeVerticalRail) {
        return;
    }
    if (CGRectIsEmpty(handleScrollView.frame) || CGRectGetWidth(handleScrollView.frame) <= 0) {
        return;
    }
    CGRect railFrame = handleScrollView.frame;
    CGFloat contentX = [self mfVerticalHandleRailScreenX] + scrollView.contentOffset.x;
    if (fabs(railFrame.origin.x - contentX) <= 0.25) {
        return;   // 已在位，避免无意义的 frame 写入
    }
    railFrame.origin.x = contentX;
    handleScrollView.frame = railFrame;
}

/// 手柄当前在屏幕上的可见区间（仅用于日志）
-(NSString *)mfHandleScreenDescription{
    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    return [NSString stringWithFormat:@"手柄屏幕 x=%.0f..%.0f（屏宽 %.0f，%@）",
            CGRectGetMinX(handleInView), CGRectGetMaxX(handleInView),
            CGRectGetWidth(self.view.bounds),
            self.handle.isNubbed ? @"收起态" : @"展开态"];
}

-(void)applyLayoutPreservingHandlePosition:(BOOL)preserveHandlePosition{
    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= 0 || CGRectGetHeight(bounds) <= 0 || !self.handle) {
        return;
    }
    if (scaledProgrammaticCloseAnimating) {
        scaledProgrammaticCloseNeedsLayout = YES;
        return;
    }

    CGFloat previousMaximumOffset = [self maximumHandleOffset];
    CGFloat handleRatio = previousMaximumOffset > 0
        ? [self clampedHandleOffset:handleScrollView.contentOffset.y] / previousMaximumOffset
        : 0;
    CGFloat previousProgress = scrollView.contentSize.width > scrollView.bounds.size.width
        ? scrollView.contentOffset.x / (scrollView.contentSize.width - scrollView.bounds.size.width)
        : 0;
    BOOL preserveInteractiveOffset =
        scrollView.dragging || scrollView.decelerating || scrollSnapAnimationInProgress ||
        handlePanIntent != POHandlePanIntentNone;

    keyboardZoomGeneration += 1;
    [keyboardZoomContainer.layer removeAllAnimations];
    [handleScrollView.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->handleScrollView.transform = CGAffineTransformIdentity;
    }];
    keyboardZoomApplied = NO;
    appliedCardScale = 1.0;
    mfManualScaleAnchorRight = NO;   // 【0.3.19】布局重排回基准 → 手动锚点复位

    CGFloat portraitCanvasWidth = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat portraitCanvasHeight = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat handleRailWidth = [self handleRailWidth];
    chromeScale = (portraitCanvasWidth - handleRailWidth) / portraitCanvasWidth;
    BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    UIInterfaceOrientation resolvedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (!POIsConcretePresentationOrientation(resolvedOrientation)) {
        resolvedOrientation = [self resolvedHostedLayoutOrientation];
    }
    if (!POIsConcretePresentationOrientation(resolvedOrientation)) {
        resolvedOrientation = UIInterfaceOrientationPortrait;
    }
    hostedLayoutOrientation = resolvedOrientation;
    BOOL portraitHostedLandscapeOptimization =
        [self isPortraitHostedLandscapeOptimizationActiveForOrientation:hostedLayoutOrientation];
    if (portraitHostedLandscapeOptimization &&
        self.handle.layoutMode == POHandleLayoutModeVerticalRail) {
        CGFloat currentHandleScreenY = [self currentHandleScreenY];
        if (isfinite(currentHandleScreenY)) {
            portraitHostedLandscapeHandleAnchorY = currentHandleScreenY;
        }
    } else if (!portraitHostedLandscapeOptimization) {
        portraitHostedLandscapeHandleAnchorY = NAN;
    }
    CGSize logicalCanvas = [self contextManagerPreferredSceneStackSize:nil];
    CGFloat leadingInset = [self leadingSafeAreaInset] + CONTENT_EDGE_GAP;
    CGFloat trailingInset = [self trailingSafeAreaInset] + CONTENT_EDGE_GAP;
    CGFloat availableCardWidth = portraitHostedLandscapeOptimization
        ? CGRectGetWidth(bounds) - leadingInset - trailingInset
        : CGRectGetWidth(bounds) - CONTENT_EDGE_GAP - self.handle.frame.size.width - HANDLE_EDGE_GAP - trailingInset;
    CGFloat availableCardHeight = shellIsLandscape
        ? CGRectGetHeight(bounds) - (CONTENT_EDGE_GAP * 2)
        : portraitCanvasHeight * chromeScale;
    availableCardWidth = MAX(1, availableCardWidth);
    availableCardHeight = MAX(1, availableCardHeight);

    CGFloat widthScale = availableCardWidth / MAX(1, logicalCanvas.width);
    CGFloat heightScale = availableCardHeight / MAX(1, logicalCanvas.height);
    // 【MF】上限从 1.0 改为面板宽度比例：卡片整体缩小，配合下面的居中补偿 ->
    // 打开后停在屏幕正中（Stheno 风格），不再贴着屏幕边缘铺满。
    CGFloat mfPanelScaleCap = MFPanelWidthRatio();
    scale = MIN(mfPanelScaleCap, MIN(widthScale, heightScale));

    CGFloat screenScale = UIScreen.mainScreen.scale;
    contentLayoutWidth = round(logicalCanvas.width * scale * screenScale) / screenScale;
    contentLayoutHeight = round(logicalCanvas.height * scale * screenScale) / screenScale;
    CGFloat anchoredCardBottomY = CGRectGetMidY(bounds);
    if (portraitHostedLandscapeOptimization) {
        CGFloat handleAnchorY = isfinite(portraitHostedLandscapeHandleAnchorY)
            ? portraitHostedLandscapeHandleAnchorY
            : CGRectGetMidY(bounds);
        anchoredCardBottomY = [self clampedPortraitHostedLandscapeCardBottomYForHandleAnchorY:handleAnchorY
                                                                                          cardHeight:contentLayoutHeight];
        portraitHostedLandscapeHandleAnchorY = anchoredCardBottomY + HANDLE_EDGE_GAP;
    }

    quickSwitchInteractionOverlayView.frame = bounds;
    [quickSwitchDragCoordinator layoutForBounds:bounds safeAreaInsets:self.view.safeAreaInsets];

    scrollView.frame = bounds;
    // 【MF】居中补偿：卡片比屏幕窄时，把"滑到底"的目标再向右多推一段，
    // 这样打开态 contentOffset.x == maximumContentOffsetX 时，卡片正好落在屏幕正中：
    //   卡片屏幕 x = bounds.width - (contentLayoutWidth + trailingInset + mfCenteringInset)
    //             = (bounds.width - contentLayoutWidth) / 2   ← 左右留白相等
    CGFloat mfCenteringInset = MAX(0.0, (CGRectGetWidth(bounds) - contentLayoutWidth) / 2.0 - trailingInset);
    scrollView.contentSize = CGSizeMake(CGRectGetWidth(bounds) + contentLayoutWidth + trailingInset + mfCenteringInset,
                                        CGRectGetHeight(bounds));
    CGFloat maximumContentOffsetX = [self maximumContentOffsetX];
    CGFloat restoredOffset = 0;
    if (preserveInteractiveOffset) {
        restoredOffset = MIN(MAX(0, previousProgress), 1) * maximumContentOffsetX;
    } else {
        restoredOffset = previousProgress >= 0.5 ? maximumContentOffsetX : 0;
    }
    if (fabs(scrollView.contentOffset.x - restoredOffset) > CLOSED_CONTENT_OFFSET_EPSILON ||
        fabs(scrollView.contentOffset.y) > CLOSED_CONTENT_OFFSET_EPSILON) {
        [scrollView setContentOffset:CGPointMake(restoredOffset, 0) animated:NO];
    }

    CGRect normalCardFrame = CGRectMake(CGRectGetWidth(bounds), 0, contentLayoutWidth, contentLayoutHeight);
    normalCardFrame.origin.y = portraitHostedLandscapeOptimization
        ? anchoredCardBottomY - CGRectGetHeight(normalCardFrame)
        : CGRectGetMidY(bounds) - CGRectGetHeight(normalCardFrame) / 2.0;
    normalCardFrame.origin.y = round(normalCardFrame.origin.y * screenScale) / screenScale;

    // 【MF】几何诊断：尺寸/圆角变化时打一行，确认"居中 + 缩小 + 圆角"是否按预期生效
    static CGSize mfLastLoggedCardSize = {0, 0};
    if (fabs(mfLastLoggedCardSize.width - contentLayoutWidth) > 0.5 ||
        fabs(mfLastLoggedCardSize.height - contentLayoutHeight) > 0.5) {
        mfLastLoggedCardSize = CGSizeMake(contentLayoutWidth, contentLayoutHeight);
        MFLog(@"[ui] 面板几何: 卡片 %.0fx%.0f @y=%.0f | 屏幕 %.0fx%.0f | 比例 %.2f | 左右留白 %.0f | 圆角 %.0f",
              contentLayoutWidth, contentLayoutHeight, normalCardFrame.origin.y,
              CGRectGetWidth(bounds), CGRectGetHeight(bounds), scale,
              MAX(0.0, (CGRectGetWidth(bounds) - contentLayoutWidth) / 2.0), MFPanelCornerRadius());
    }

    BOOL horizontalMode = portraitHostedLandscapeOptimization;
    self.handle.layoutMode = horizontalMode
        ? POHandleLayoutModeLandscapeFixedBottomLeft
        : POHandleLayoutModeVerticalRail;
    handleScrollView.scrollEnabled = !horizontalMode;
    handleScrollView.bounces = !horizontalMode;
    handleScrollView.alwaysBounceVertical = !horizontalMode;

    CGFloat handleViewportHeight = horizontalMode
        ? CGRectGetHeight(bounds)
        : CGRectGetHeight(bounds) * chromeScale;
    handleScrollView.frame = CGRectMake(CGRectGetWidth(bounds) - handleRailWidth, 0, handleRailWidth, handleViewportHeight);
    if (!horizontalMode) {
        handleScrollView.center = CGPointMake(handleScrollView.center.x, CGRectGetMidY(bounds));
        handleScrollView.contentSize = CGSizeMake(handleRailWidth, (handleViewportHeight * 2) - self.handle.frame.size.height);

        CGFloat targetHandleOffset = 0;
        if (preserveHandlePosition) {
            if (previousMaximumOffset <= 0) {
                NSNumber *storedRatio = [[NSUserDefaults standardUserDefaults] objectForKey:@"handlePointRatio"];
                CGFloat ratio = storedRatio ? storedRatio.doubleValue : 0.5;
                targetHandleOffset = ratio * [self maximumHandleOffset];
            } else {
                targetHandleOffset = handleRatio * [self maximumHandleOffset];
            }
        } else {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSNumber *storedRatio = [defaults objectForKey:@"handlePointRatio"];
            NSString *storedPoint = [defaults valueForKey:@"handlePoint"];
            if (storedRatio) {
                targetHandleOffset = storedRatio.doubleValue * [self maximumHandleOffset];
            } else if (storedPoint) {
                targetHandleOffset = CGPointFromString(storedPoint).y;
            } else {
                targetHandleOffset = [self maximumHandleOffset] / 2.0;
            }
        }
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:targetHandleOffset]) animated:NO];

        self.handle.restingOriginX = handleRailWidth - HANDLE_EDGE_GAP - self.handle.frame.size.width;
        CGRect handleLayoutFrame = self.handle.frame;
        handleLayoutFrame.origin.y = handleViewportHeight - CGRectGetHeight(self.handle.bounds);
        if (!self.handle.isNubbed) {
            handleLayoutFrame.origin.x = self.handle.restingOriginX;
        }
        self.handle.frame = handleLayoutFrame;
        quickSwitchHorizontalBarView.presentationAnchorFrame = CGRectZero;
        // 【MF 0.1.2】把手柄摆到"关闭态=屏幕右缘 / 打开态=浮窗右侧"
        [self mfUpdateVerticalHandleRailPosition];
    } else {
        handleScrollView.contentSize = handleScrollView.bounds.size;
        [handleScrollView setContentOffset:CGPointZero animated:NO];

        // 【0.3.20 血泪 log29】布局 passe 不得无条件重写卡片位置：0.3.13~0.3.19 这里每次布局
        // 都把 keyboardZoomBaseFrame 打回"标准打开位"（内容 x = 屏宽、底边 = 手柄锚 − 间隙），
        // 于是用户拖完底带、只要触发过一次布局就"弹回原处"（log29 实证：4 次拖动起止
        // 都是 屏x=47 底边 830 = 标准打开位，用户感知"底部自由移动无法触发"）。
        // 用户挪过位置（拖带/停靠）→ 只要卡片尺寸没变（同布局、未旋转）就保留用户位置。
        // 【0.3.22 血泪 log31】停靠态优先级最高：布局 passe 必须把卡片重建为**16:9 小窗**，
        // 绝不能按 contentLayoutWidth/Height 重铺（0.3.21 的停靠靠 transform，被这里的
        // `transform = Identity` 一打就回满尺寸，而 mfDockedSide 还是"已停靠" ⇒ 盖层/热区全错位）。
        if (mfDockedSide != 0) {
            CGRect dockFrame = [self mfDockedCardFrameForSide:(mfDockedSide > 0)];
            if (CGRectIsEmpty(dockFrame)) {
                dockFrame = keyboardZoomBaseFrame;
            } else {
                mfDockedCardFrame = dockFrame;
            }
            normalCardFrame = dockFrame;
            keyboardZoomBaseFrame = normalCardFrame;
            portraitHostedLandscapeHandleAnchorY = CGRectGetMaxY(normalCardFrame) + HANDLE_EDGE_GAP;
        } else if (mfUserCardPositionPinned && !CGRectIsEmpty(keyboardZoomBaseFrame) &&
                   fabs(CGRectGetWidth(keyboardZoomBaseFrame) - contentLayoutWidth) <= 1.0 &&
                   fabs(CGRectGetHeight(keyboardZoomBaseFrame) - contentLayoutHeight) <= 1.0) {
            normalCardFrame = keyboardZoomBaseFrame;
            keyboardZoomBaseFrame = normalCardFrame;
        } else {
            keyboardZoomBaseFrame = normalCardFrame;
        }
        [self updatePortraitHostedLandscapeHandleForCurrentOffset];
        [scrollView bringSubviewToFront:handleScrollView];

        [self syncHorizontalQuickSwitchPresentationAnchor];
    }

    [self.handle refreshNubbedPositionAnimated:NO];
    [self storeHandlePosition];

    [UIView performWithoutAnimation:^{
        keyboardZoomContainer.transform = CGAffineTransformIdentity;
        handleScrollView.transform = CGAffineTransformIdentity;
        keyboardZoomContainer.frame = normalCardFrame;
        self->keyboardZoomBaseFrame = normalCardFrame;
        shadowView.frame = keyboardZoomContainer.bounds;
        self.contentView.frame = keyboardZoomContainer.bounds;
        shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds
                                                                  cornerRadius:MFPanelCornerRadius()].CGPath;
    }];
    // 【0.3.20】上面把 transform 打回 Identity 了：若当前是缩放/停靠态，按新 baseFrame 重算缩放锚，
    // 否则布局 passe 一来，停靠态卡片会"视觉上弹回满尺寸"。
    if (fabs(appliedCardScale - 1.0) > PO_CARD_SCALE_EPSILON) {
        [self applyCardScaleTarget:appliedCardScale animated:NO source:POCardScaleTransitionSourceReconcile];
    }
    CGFloat shadowProgress = MIN(MAX(scrollView.contentOffset.x / CONTENT_SHADOW_FADE_DISTANCE, 0), 1);
    shadowView.layer.shadowOpacity = CONTENT_SHADOW_OPACITY * shadowProgress;
    if (presentationSnapshotView) {
        [self layoutPresentationSnapshotView];
    }
    if (contextView) {
        [self layoutContextView];
    }
    if (showingCantHost) {
        [self layoutCantHostView];
    }
    lastLaidOutSize = bounds.size;
    [self updateInteractionBackdropsAnimated:NO];
    [self reevaluateKeyboardZoomAnimated:NO];
    if (panelState == POPanelStateOpen &&
        self.quickSwitchTableView &&
        presentedQuickSwitchMenu == (UIView<POQuickSwitchMenuPresenting> *)self.quickSwitchTableView &&
        !self.quickSwitchTableView.hidden) {
        quickSwitchYieldActive = NO;
        [self applyQuickSwitchContentYieldIfNeededAnimated:NO];
    }

    if (scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating) {
        [self snapPanelToOpenState:pendingOpenState];
    }
}

-(void)dismissTransientInteractionUI{
    if (hostedCategoryTransitionPending || runtimeHostedCategoryTransitionAnimating || handleVisualHandoffSnapshotView) {
        [self cancelRuntimeHostedCategoryTransition];
    }
    if (handlePanIntent == POHandlePanIntentVerticalCardMove) {
        handlePanIntent = POHandlePanIntentNone;
        panelVerticalMoveStartAnchorY = 0;
    }
    if (presentedQuickSwitchMenu) {
        [self dismissPresentedQuickSwitchMenuImmediately];
        return;
    }
    [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
    quickSwitchInteractionOverlayView.hidden = YES;
    [quickSwitchDragCoordinator cancelAnimated:NO];
    [mirrorZoneView.layer removeAllAnimations];
    mirrorZoneView.transform = CGAffineTransformIdentity;
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneView.alpha = 0;
    mirrorZoneHighlighted = NO;
    [self updateInteractionBackdropsAnimated:NO];
    [scrollView bringSubviewToFront:keyboardZoomContainer];
}

-(void)prepareForOrientationChange{
    if (!self.isViewLoaded) {
        return;
    }

    BOOL shouldBridgeIOS26Rotation =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        panelState != POPanelStateClosed && panelState != POPanelStateClosing &&
        contextView && !contextView.hidden && contextView.superview == self.contentView &&
        presentationBundleId.length > 0 &&
        [presentationBundleId isEqualToString:hostSession.activeBundleId];
    if (shouldBridgeIOS26Rotation && !presentationSnapshotView) {
        [self capturePresentationSnapshotIfPossible];
    }
    if (shouldBridgeIOS26Rotation && presentationSnapshotView &&
        runtimeCategoryTransitionSnapshotFallbackArmed &&
        presentationSnapshotView.hidden && !runtimeCategoryTransitionSnapshotActive) {
        [self clearPresentationSnapshot];
        [self capturePresentationSnapshotIfPossible];
    }
    if (shouldBridgeIOS26Rotation && presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder) {
        [self prewarmRuntimeCategoryTransitionSnapshot];
    }
    if (shouldBridgeIOS26Rotation && presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder &&
        [presentationSnapshotBundleId isEqualToString:presentationBundleId]) {
        runtimeCategoryTransitionSnapshotFallbackArmed = YES;
        if (runtimeCategoryTransitionSnapshotActive) {
            presentationSnapshotView.userInteractionEnabled = NO;
            presentationSnapshotView.hidden = NO;
            [self layoutPresentationSnapshotView];
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }

    keyboardZoomSuppressedForCurrentSession = NO;
    [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
    [self restoreKeyboardZoomImmediately];

    origOffset = nil;
    [self dismissTransientInteractionUI];
}

-(void)handleOrientationChange{
    if (!self.isViewLoaded) {
        return;
    }
    [self applyLayoutPreservingHandlePosition:YES];
    [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
    [self reevaluateKeyboardZoomAnimated:NO];
}

-(CGSize)contextManagerPreferredSceneStackSize:(id)manager{
    CGRect bounds = self.view.bounds;
    CGFloat shortSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat longSide = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    UIInterfaceOrientation orientation = [self contextManagerPreferredHostedInterfaceOrientation:manager];
    return UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(longSide, shortSide)
        : CGSizeMake(shortSide, longSide);
}

-(CGSize)hostSessionPreferredSystemSceneStackSize:(POHostSessionController *)__unused controller{
    UIWindowScene *scene = self.view.window.windowScene;
    CGRect bounds = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = UIScreen.mainScreen.bounds;
    }

    UIInterfaceOrientation orientation = [[ContextHostManager sharedInstance] currentSystemInterfaceOrientation];
    if (!POIsConcretePresentationOrientation(orientation) && scene) {
        orientation = scene.interfaceOrientation;
    }
    CGFloat shortSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat longSide = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    return UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(longSide, shortSide)
        : CGSizeMake(shortSide, longSide);
}

-(UIInterfaceOrientation)contextManagerPreferredHostedInterfaceOrientation:(id)manager{
    ContextHostManager *hostManager = [manager isKindOfClass:[ContextHostManager class]]
        ? (ContextHostManager *)manager
        : [ContextHostManager sharedInstance];

    NSString *requestedBundleId = hostSession.requestedBundleId;
    NSString *activeBundleId = hostSession.activeBundleId;
    BOOL committedQuickSwitchTargetPending = pinnedBundleId.length > 0 &&
        activeBundleId.length > 0 &&
        [requestedBundleId isEqualToString:activeBundleId] &&
        ![pinnedBundleId isEqualToString:activeBundleId];
    NSString *hostingBundleId = committedQuickSwitchTargetPending
        ? pinnedBundleId
        : (requestedBundleId.length > 0 ? requestedBundleId : pinnedBundleId);

    return [self resolvedHostedOrientationForBundleId:hostingBundleId manager:hostManager];
}

-(BOOL)shouldAutorotate
{
    return YES;
}

-(UIInterfaceOrientationMask)supportedInterfaceOrientations{
    return UIInterfaceOrientationMaskAll;
}

-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [self applyLayoutPreservingHandlePosition:YES];
    }];
}

-(void)keyboardWillShow:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    mfUserCardScaleOverride = 0;   // 【0.3.11】键盘弹出 = 恢复自动缩放（避让优先于手动档位）
    if (panelState == POPanelStateOpen && hostSession.state == POHostSessionStateLive &&
        hostSession.currentGeneration != 0) {
        [[ContextHostManager sharedInstance]
            canonicalizeHostedSourceForCurrentOrientationWithGeneration:hostSession.currentGeneration];
    }
    if (keyboardNotificationState != POKeyboardNotificationStateVisible) {
        keyboardZoomSuppressedForCurrentSession = NO;
    }
    keyboardNotificationState = POKeyboardNotificationStateVisible;
    keyboardHideAnimationInFlight = NO;
    [self avoidClosedHandleForKeyboardWillShow:notification];
    [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardWillChangeFrame:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    if (keyboardHideAnimationInFlight) {
        return;
    }
    BOOL frameVisible = [self keyboardFrameIsVisibleInNotification:notification];
    if (keyboardNotificationState == POKeyboardNotificationStateVisible &&
        [self keyboardFrameHasNonzeroSizeInNotification:notification]) {
        frameVisible = YES;
    }
    keyboardNotificationState = frameVisible
        ? POKeyboardNotificationStateVisible
        : POKeyboardNotificationStateHidden;
    keyboardHideAnimationInFlight = keyboardNotificationState != POKeyboardNotificationStateVisible;
    [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardWillHide:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    keyboardNotificationState = POKeyboardNotificationStateHidden;
    keyboardHideAnimationInFlight = YES;
    [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceKeyboard];
    if ([[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] && origOffset) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:YES];
        origOffset = nil;
    }
}

-(void)keyboardDidShow:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    keyboardNotificationState = POKeyboardNotificationStateVisible;
    keyboardHideAnimationInFlight = NO;
    [self reevaluateCardScaleAnimated:NO source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardDidChangeFrame:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    if (keyboardHideAnimationInFlight) {
        return;
    }
    BOOL frameVisible = [self keyboardFrameIsVisibleInNotification:notification];
    if (keyboardNotificationState == POKeyboardNotificationStateVisible &&
        [self keyboardFrameHasNonzeroSizeInNotification:notification]) {
        frameVisible = YES;
    }
    keyboardNotificationState = frameVisible
        ? POKeyboardNotificationStateVisible
        : POKeyboardNotificationStateHidden;
    [self reevaluateCardScaleAnimated:NO source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardDidHide:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    keyboardNotificationState = POKeyboardNotificationStateHidden;
    keyboardHideAnimationInFlight = NO;
    keyboardZoomSuppressedForCurrentSession = NO;
    [self reevaluateCardScaleAnimated:NO source:POCardScaleTransitionSourceKeyboard];
}

-(void)avoidClosedHandleForKeyboardWillShow:(NSNotification *)notification{
    if ([self isHorizontalQuickSwitchLayoutMode] ||
        ![[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] || [self isPanelActive]) {
        return;
    }
    CGRect keyboardFrame = [[notification userInfo][UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    if (!CGRectIntersectsRect(handleInView, keyboardFrameInView)) {
        origOffset = nil;
        return;
    }
    CGFloat overlap = CGRectGetMaxY(handleInView) + HANDLE_EDGE_GAP - CGRectGetMinY(keyboardFrameInView);
    if (overlap > 0) {
        origOffset = @(handleScrollView.contentOffset.y);
        CGFloat adjustedOffset = [self clampedHandleOffset:handleScrollView.contentOffset.y + overlap];
        [handleScrollView setContentOffset:CGPointMake(0, adjustedOffset) animated:YES];
    } else {
        origOffset = nil;
    }
}


-(void)commitPinnedBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    pinnedBundleId = bundleId;
    [[NSUserDefaults standardUserDefaults] setObject:bundleId forKey:@"lastPinnedBundleId"];
    [self refreshHandleIconIfNeeded];
}

-(void)restoreExternallyActivatedApplicationNatively:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    externallyActivatedGeneration += 1;
    externallyActivatedBundleId = nil;
    [self prepareForNativeApplicationTakeover:bundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleId suspended:NO];
}

-(void)completeExternallyActivatedApplicationIfNeeded:(NSString *)bundleId{
    if (bundleId.length == 0 || ![externallyActivatedBundleId isEqualToString:bundleId]) {
        return;
    }
    externallyActivatedGeneration += 1;
    externallyActivatedBundleId = nil;
}

-(BOOL)openExternallyActivatedApplicationInPullOver:(NSString *)bundleId{
    if (!NSThread.isMainThread || bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId] ||
        panelState != POPanelStateClosed || [self isPanelTransitioning] ||
        presentedQuickSwitchMenu || scaledProgrammaticCloseAnimating) {
        return NO;
    }

    externallyActivatedGeneration += 1;
    NSUInteger activationGeneration = externallyActivatedGeneration;
    externallyActivatedBundleId = [bundleId copy];
    [self pinAppWithBundleId:bundleId];
    if (![pinnedBundleId isEqualToString:bundleId]) {
        externallyActivatedGeneration += 1;
        externallyActivatedBundleId = nil;
        return NO;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (activationGeneration != self->externallyActivatedGeneration ||
            ![self->externallyActivatedBundleId isEqualToString:bundleId]) {
            return;
        }
        BOOL scenePublished = self->hostSession.state == POHostSessionStateLive &&
            [self->hostSession.activeBundleId isEqualToString:bundleId] &&
            [self->presentationBundleId isEqualToString:bundleId];
        if (scenePublished) {
            [self completeExternallyActivatedApplicationIfNeeded:bundleId];
            return;
        }
        [self restoreExternallyActivatedApplicationNatively:bundleId];
    });
    return YES;
}

-(void)pinAppWithBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }

    BOOL hasVisibleLivePresentation = contextView && !contextView.hidden &&
        contextView.superview == self.contentView && presentationBundleId.length > 0;
    BOOL switchingVisibleTarget = panelState == POPanelStateOpen && hasVisibleLivePresentation &&
        ![hostSession.activeBundleId isEqualToString:bundleId];
    UIInterfaceOrientation previousHostedOrientation =
        [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (switchingVisibleTarget) {
        [self capturePresentationSnapshotIfPossible];
    }

    [self commitPinnedBundleId:bundleId];

    UIInterfaceOrientation nextHostedOrientation =
        [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (UIInterfaceOrientationIsLandscape(previousHostedOrientation) !=
        UIInterfaceOrientationIsLandscape(nextHostedOrientation)) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    if (switchingVisibleTarget) {
        if (![self revealCachedPresentationSnapshotForBundleId:bundleId]) {
            [self showTargetTransitionPresentationForBundleId:bundleId];
        }
    }

    if (panelState == POPanelStateOpen) {
        [hostSession activateBundleId:bundleId];
        return;
    }

    [hostSession prepareBundleId:bundleId];
    NSUInteger openGeneration = ++deferredOpenGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (openGeneration == self->deferredOpenGeneration &&
            self->panelState == POPanelStateClosed &&
            [self->pinnedBundleId isEqualToString:bundleId]) {
            [self open];
        }
    });
}

-(BOOL)beginExternalHostedApplication:(NSString *)bundleId{
    if (!NSThread.isMainThread || bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId] ||
        [self isPanelTransitioning] || presentedQuickSwitchMenu ||
        scaledProgrammaticCloseAnimating ||
        [[POApplicationHelper frontMostBundleId] isEqualToString:bundleId]) {
        return NO;
    }
    [self pinAppWithBundleId:bundleId];
    return [pinnedBundleId isEqualToString:bundleId];
}

-(BOOL)isExternallyHostedApplicationVisible:(NSString *)bundleId{
    return bundleId.length > 0 && [self isPanelFullyOpen] &&
        hostSession.state == POHostSessionStateLive &&
        [hostSession.activeBundleId isEqualToString:bundleId] &&
        [presentationBundleId isEqualToString:bundleId] &&
        contextView && !contextView.hidden &&
        contextView.superview == self.contentView;
}

-(void)open{
    MFLog(@"[panel] open() 调用（pinned=%@，state=%lu，手柄 %@）",
          pinnedBundleId ?: @"(空)", (unsigned long)panelState, [self mfHandleScreenDescription]);
    if (pinnedBundleId.length == 0 || scaledProgrammaticCloseAnimating ||
        panelState == POPanelStateOpening || panelState == POPanelStateOpen) {
        return;
    }
    deferredOpenGeneration += 1;
    [self cancelAutoNubTimer];
    [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionClosing];
    [self beginSplitSessionIfNeeded];

    [self preparePanelForOpenPresentationIfNeeded];

    BOOL revealed = [self revealPresentationForBundleIdIfCompatible:pinnedBundleId];
    if (!revealed) {
        [self showTargetTransitionPresentationForBundleId:pinnedBundleId];
    }
    [hostSession activateBundleId:pinnedBundleId];
    [self snapPanelToOpenState:YES];
}

-(void)close{
    MFLog(@"[panel] close() 调用（state=%lu）", (unsigned long)panelState);
    if (panelState == POPanelStateClosed || panelState == POPanelStateClosing) {
        return;
    }
    deferredOpenGeneration += 1;
    [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionClosing];
    [self dismissPresentedQuickSwitchMenuImmediately];
    if ([self canUseDirectScaledProgrammaticCloseAnimation]) {
        [self performDirectScaledProgrammaticCloseAnimation];
    } else {
        [self snapPanelToOpenState:NO];
    }
}
     

#pragma mark - MHHandleDelegate

-(void)handle:(POHandle *)handle didReceiveTap:(UIGestureRecognizer *)recognizer{
    // 【0.3.19】手柄已移除（hidden+禁交互），正常不会收到回调；此短路为保险。
    // 旧逻辑：关闭态点手柄=open、展开态点手柄=停靠右侧——全部作废。
    MFLog(@"[handle] 单击手柄（手柄已移除，忽略）");
    return;
    MFLog(@"[handle] 单击手柄（state=%lu，%@）", (unsigned long)panelState, [self mfHandleScreenDescription]);
    [self cancelAutoNubTimer];
    if ([self isPanelTransitioning] || scrollView.dragging || scrollView.decelerating) {
        return;
    }
    if (panelState == POPanelStateClosed) {
        if ([self isHandleActivationGuardActive]) {
            self.handle.isNubbed = NO;
            [self resetAutoNubTimerWithMinimumDelay:PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION];
            return;
        }
        [self open];
        return;
    }
    if (panelState == POPanelStateOpen && [self shouldHandleTapRestoreKeyboardZoom]) {
        [self restoreKeyboardZoomFromHandleTap];
        [self resetAutoNubTimer];
        return;
    }
    if (panelState == POPanelStateOpen) {
        // 【0.3.19】展开态单击手柄 = 停靠右侧（幂等）：未停靠→停右；已停右→还原满尺寸；
        // 已停左→切停右。行为完全可预测（log25：旧版双翻转导致连点手柄左右乱跳）。
        // 关闭方式不变：拖动手柄甩到屏幕边缘 / 点击浮窗外空白 / Home 键。
        MFLog(@"[card] 手柄点击 → 停靠右侧（幂等：已停右则还原满尺寸）");
        [self mfSnapCardToSide:YES];
    }
}

-(void)handle:(POHandle *)handle didPanPanel:(UIPanGestureRecognizer *)recognizer{
    // 【0.3.19】手柄已移除：拖手柄开合/竖移卡片全部作废（底边热区 pan 接管移动）。
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[handle] 拖动手柄（手柄已移除，忽略）");
    }
    return;
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[handle] 拖动手柄开始（nubbed=%d，%@）", self.handle.isNubbed, [self mfHandleScreenDescription]);
        handlePanIntent = POHandlePanIntentNone;
        handlePanStartedNubbed = self.handle.isNubbed;
        if ([self isPanelTransitioning]) {
            return;
        }

        CGPoint velocity = [recognizer velocityInView:self.view];
        BOOL verticalIntent = fabs(velocity.y) > fabs(velocity.x);
        if (verticalIntent) {
            if (![self canMovePortraitHostedLandscapeCardVertically]) {
                return;
            }
            CGFloat currentHandleY = [self currentHandleScreenY];
            if (!isfinite(currentHandleY)) {
                return;
            }
            handlePanIntent = POHandlePanIntentVerticalCardMove;
            portraitHostedLandscapeHandleAnchorY = currentHandleY;
            panelVerticalMoveStartAnchorY = currentHandleY;
            [self cancelAutoNubTimer];
            [self restoreKeyboardZoomImmediately];
            return;
        }

        handlePanIntent = [self horizontalHandlePanIntentForVelocityX:velocity.x];
        switch (handlePanIntent) {
            case POHandlePanIntentRevealHandle:
                [self cancelAutoNubTimer];
                self.handle.isNubbed = NO;
                return;

            case POHandlePanIntentNubHandle:
                [self cancelAutoNubTimer];
                self.handle.isNubbed = YES;
                return;

            case POHandlePanIntentOpenPanel:
                if ([self isHandleVisiblyNubbed]) {
                    self.handle.isNubbed = NO;
                }
                pendingOpenState = NO;
                [self beginSplitSessionIfNeeded];
                break;

            case POHandlePanIntentClosePanel:
                pendingOpenState = YES;
                break;

            case POHandlePanIntentNone:
            case POHandlePanIntentVerticalCardMove:
                return;
        }

        panelPanStartOffsetX = scrollView.contentOffset.x;
        [self scrollViewWillBeginDragging:scrollView];
        return;
    }

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        if (handlePanIntent == POHandlePanIntentVerticalCardMove) {
            CGFloat translationY = [recognizer translationInView:self.view].y;
            [self applyPortraitHostedLandscapeVerticalHandleAnchorY:
                panelVerticalMoveStartAnchorY + translationY];
            return;
        }
        if (handlePanIntent != POHandlePanIntentOpenPanel &&
            handlePanIntent != POHandlePanIntentClosePanel) {
            return;
        }
        CGFloat translationX = [recognizer translationInView:self.view].x;
        CGFloat maximumOffset = [self maximumContentOffsetX];
        CGFloat nextOffset = MIN(MAX(0, panelPanStartOffsetX - translationX), maximumOffset);
        [scrollView setContentOffset:CGPointMake(nextOffset, 0) animated:NO];
        return;
    }

    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        if (handlePanIntent == POHandlePanIntentVerticalCardMove) {
            CGFloat translationY = [recognizer translationInView:self.view].y;
            [self applyPortraitHostedLandscapeVerticalHandleAnchorY:
                panelVerticalMoveStartAnchorY + translationY];
            handlePanIntent = POHandlePanIntentNone;
            [self resetAutoNubTimer];
            return;
        }
        if (handlePanIntent == POHandlePanIntentRevealHandle) {
            BOOL cancelled = recognizer.state == UIGestureRecognizerStateCancelled ||
                recognizer.state == UIGestureRecognizerStateFailed;
            handlePanIntent = POHandlePanIntentNone;
            if (cancelled) {
                self.handle.isNubbed = handlePanStartedNubbed;
            } else {
                [self resetAutoNubTimerWithMinimumDelay:PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION];
            }
            return;
        }
        if (handlePanIntent == POHandlePanIntentNubHandle) {
            if (recognizer.state == UIGestureRecognizerStateCancelled ||
                recognizer.state == UIGestureRecognizerStateFailed) {
                self.handle.isNubbed = handlePanStartedNubbed;
            }
            handlePanIntent = POHandlePanIntentNone;
            return;
        }
        if (handlePanIntent != POHandlePanIntentOpenPanel &&
            handlePanIntent != POHandlePanIntentClosePanel) {
            handlePanIntent = POHandlePanIntentNone;
            return;
        }

        if (recognizer.state == UIGestureRecognizerStateCancelled ||
            recognizer.state == UIGestureRecognizerStateFailed) {
            pendingOpenState = handlePanIntent == POHandlePanIntentClosePanel;
        } else {
            CGFloat maximumOffset = [self maximumContentOffsetX];
            CGFloat velocityX = [recognizer velocityInView:self.view].x;
            if (fabs(velocityX) > 120) {
                pendingOpenState = velocityX < 0;
            } else {
                pendingOpenState = scrollView.contentOffset.x >= maximumOffset / 2.0;
            }
        }
        handlePanIntent = POHandlePanIntentNone;
        [self scrollViewDidEndDragging:scrollView willDecelerate:NO];
    }
}

-(void)handle:(POHandle *)handle didLongPress:(UILongPressGestureRecognizer *)recognizer{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[handle] 长按手柄（快速切换菜单）");
        if (![self canBeginQuickSwitchSession]) {
            return;
        }

        POQuickSwitchLayoutMode candidateMode = [self currentQuickSwitchLayoutMode];
        POQuickSwitchLayoutMode selectedMode = (panelState == POPanelStateOpen)
            ? candidateMode
            : POQuickSwitchLayoutModeVerticalSide;
        [self cancelAutoNubTimer];

        if (selectedMode == POQuickSwitchLayoutModeVerticalSide && self.handle.isNubbed) {
            self.handle.isNubbed = NO;
        }

        UIView<POQuickSwitchMenuPresenting> *candidateMenu =
            [self quickSwitchMenuForLayoutMode:selectedMode];
        BOOL menuHandledGesture = [candidateMenu presentFromHandle:handle withRecognizer:recognizer];
        if (!menuHandledGesture && selectedMode == POQuickSwitchLayoutModeHorizontalBottom) {
            selectedMode = POQuickSwitchLayoutModeVerticalSide;
            if (self.handle.isNubbed) {
                self.handle.isNubbed = NO;
            }
            candidateMenu = [self quickSwitchMenuForLayoutMode:selectedMode];
            menuHandledGesture = [candidateMenu presentFromHandle:handle withRecognizer:recognizer];
        }
        if (!menuHandledGesture) {
            [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
            [scrollView bringSubviewToFront:keyboardZoomContainer];
            [quickSwitchDragCoordinator cancelAnimated:NO];
            [self resetAutoNubTimer];
        }
        return;
    }

    UIView<POQuickSwitchMenuPresenting> *presentingMenu = presentedQuickSwitchMenu;
    if (!presentingMenu) {
        return;
    }

    [presentingMenu presentFromHandle:handle withRecognizer:recognizer];
}


#pragma mark - QuickSwitch

-(void)cancelQuickSwitchPrewarm{
    quickSwitchPrewarmGeneration += 1;
    quickSwitchPrewarmBundleId = nil;
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didHoverBundleId:(NSString *)bundleId{
    [self cancelQuickSwitchPrewarm];
    if (panelState != POPanelStateOpen || bundleId.length == 0 ||
        [bundleId isEqualToString:hostSession.activeBundleId] ||
        [[POApplicationHelper frontMostBundleId] isEqualToString:bundleId]) {
        return;
    }

    quickSwitchPrewarmBundleId = [bundleId copy];
    UIView<POQuickSwitchMenuPresenting> *presentingMenu = quickSwitchTableView;
    NSUInteger generation = quickSwitchPrewarmGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self->quickSwitchPrewarmGeneration ||
            ![self->quickSwitchPrewarmBundleId isEqualToString:bundleId] ||
            self->panelState != POPanelStateOpen || presentingMenu.alpha < 0.01 || presentingMenu.hidden) {
            return;
        }
        [self->hostSession prewarmBundleId:bundleId];
    });
}

-(void)quickSwitchTableViewDidClearHover:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [self cancelQuickSwitchPrewarm];
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didSelectBundleId:(NSString *)bundleId{
    [self cancelQuickSwitchPrewarm];
    quickSwitchOpeningApp = YES;
    [self cancelAutoNubTimer];
    [self pinAppWithBundleId:bundleId];
}

-(void)syncHostedContentGeometryToContentView{
    if (contextView) {
        CGRect hostBounds = self.contentView.bounds;
        contextView.center = CGPointMake(CGRectGetMidX(hostBounds), CGRectGetMidY(hostBounds));
        for (UIView *v in contextView.subviews) {
            v.frame = contextView.bounds;
            v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
    }
    if (showingCantHost && cantHostCanvas) {
        cantHostCanvas.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                            CGRectGetMidY(self.contentView.bounds));
    }
}

-(void)applyQuickSwitchContentYieldIfNeeded{
    [self applyQuickSwitchContentYieldIfNeededAnimated:YES];
}

-(void)applyQuickSwitchContentYieldIfNeededAnimated:(BOOL)animated{
    if (panelState != POPanelStateOpen || !self.quickSwitchTableView ||
        presentedQuickSwitchMenu != (UIView<POQuickSwitchMenuPresenting> *)self.quickSwitchTableView) {
        return;
    }

    CGRect menuInScroll = [self.quickSwitchTableView convertRect:self.quickSwitchTableView.bounds
                                                          toView:scrollView];
    CGRect baseContainerFrame = quickSwitchYieldActive ? quickSwitchSavedContainerFrame : keyboardZoomContainer.frame;

    CGRect containerFrame = baseContainerFrame;
    CGFloat gap = CONTENT_EDGE_GAP; // 5pt
    CGFloat menuMidX = CGRectGetMidX(menuInScroll);
    CGFloat contentMidX = CGRectGetMidX(containerFrame);
    BOOL menuIsLeftOfContent = menuMidX <= contentMidX;
    CGFloat deltaX = 0;

    if (menuIsLeftOfContent) {
        CGFloat desiredMinX = CGRectGetMaxX(menuInScroll) + gap;
        deltaX = desiredMinX - CGRectGetMinX(containerFrame);
    } else {
        CGFloat desiredMaxX = CGRectGetMinX(menuInScroll) - gap;
        deltaX = desiredMaxX - CGRectGetMaxX(containerFrame);
    }

    if (fabs(deltaX) <= 0.5) {
        if (quickSwitchYieldActive) {
            [self restoreQuickSwitchContentYieldIfNeededAnimated:animated];
        }
        return;
    }

    if (!quickSwitchYieldActive) {
        quickSwitchSavedContainerFrame = baseContainerFrame;
        quickSwitchYieldActive = YES;
    }

    containerFrame.origin.x += deltaX;
    CGFloat screenScale = UIScreen.mainScreen.scale;
    containerFrame.origin.x = round(containerFrame.origin.x * screenScale) / screenScale;

    void (^applyFrames)(void) = ^{
        self->keyboardZoomContainer.frame = containerFrame;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyFrames
                         completion:nil];
    } else {
        applyFrames();
    }
}

-(void)restoreQuickSwitchContentYieldIfNeeded{
    [self restoreQuickSwitchContentYieldIfNeededAnimated:YES];
}

-(void)restoreQuickSwitchContentYieldIfNeededAnimated:(BOOL)animated{
    if (!quickSwitchYieldActive) {
        return;
    }
    quickSwitchYieldActive = NO;
    CGRect containerFrame = CGRectIsEmpty(keyboardZoomBaseFrame)
        ? quickSwitchSavedContainerFrame
        : keyboardZoomBaseFrame;

    void (^applyFrames)(void) = ^{
        self->keyboardZoomContainer.frame = containerFrame;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyFrames
                         completion:nil];
    } else {
        [keyboardZoomContainer.layer removeAllAnimations];
        [UIView performWithoutAnimation:applyFrames];
    }
}

-(void)beginQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu{
    if (!menu || presentedQuickSwitchMenu) {
        if (menu && presentedQuickSwitchMenu && menu != presentedQuickSwitchMenu) {
            [menu dismissImmediately];
        }
        return;
    }

    presentedQuickSwitchMenu = menu;
    [self cancelQuickSwitchPrewarm];
    [quickSwitchBackdropView.layer removeAllAnimations];
    quickSwitchBackdropView.alpha = 0;
    quickSwitchInteractionOverlayView.hidden = NO;
    [self.view bringSubviewToFront:quickSwitchInteractionOverlayView];
    [quickSwitchDragCoordinator cancelAnimated:NO];
    self.handle.alpha = 0;
    [self updateInteractionBackdropsAnimated:YES];

    if ([self isHorizontalQuickSwitchMenu:menu]) {
        [quickSwitchInteractionOverlayView bringSubviewToFront:quickSwitchHorizontalBarView];
        [self hideMirrorZone];
        return;
    }

    [scrollView bringSubviewToFront:handleScrollView];
    [handleScrollView insertSubview:self.handle belowSubview:self.quickSwitchTableView];
    [handleScrollView bringSubviewToFront:self.quickSwitchTableView];
    if (fabs([self resolvedCardScale] - 1.0) <= PO_CARD_SCALE_EPSILON) {
        [self applyQuickSwitchContentYieldIfNeededAnimated:YES];
    }
}

-(void)finishQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu{
    if (!menu || menu != presentedQuickSwitchMenu) {
        return;
    }

    presentedQuickSwitchMenu = nil;
    [self cancelQuickSwitchPrewarm];
    [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
    [self hideQuickSwitchBackdropImmediately];
    quickSwitchInteractionOverlayView.hidden = YES;
    self.handle.alpha = 1;
    [self updateInteractionBackdropsAnimated:NO];
    [self reconcileCardChromeZOrder];
    [self reevaluateKeyboardZoomAnimated:NO];
    [self hideMirrorZone];
    [quickSwitchDragCoordinator cancelAnimated:NO];
    if (quickSwitchOpeningApp) {
        if (panelState != POPanelStateClosed) {
            quickSwitchOpeningApp = NO;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->quickSwitchOpeningApp = NO;
            if (self->panelState == POPanelStateClosed) {
                [self resetAutoNubTimer];
            }
        });
        return;
    }
    [self resetAutoNubTimer];
}

-(void)dismissPresentedQuickSwitchMenuImmediately{
    if (!presentedQuickSwitchMenu) {
        return;
    }
    [presentedQuickSwitchMenu dismissImmediately];
}

-(void)hideQuickSwitchBackdropImmediately{
    if (!quickSwitchBackdropView) {
        return;
    }
    [quickSwitchBackdropView.layer removeAllAnimations];
    quickSwitchBackdropView.alpha = 0;
}

-(void)quickSwitchTableViewWillAppear:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [self beginQuickSwitchSessionForMenu:quickSwitchTableView];
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView draggingDidChangeForQuickSwitchItem:(SBApplication *)app withPoint:(CGPoint)point{
    [self cancelQuickSwitchPrewarm];
    BOOL startedDragging = !quickSwitchDragCoordinator.isDragging;
    [quickSwitchDragCoordinator beginDraggingBundleId:app.bundleIdentifier
                                           displayName:app.displayName
                                            sourceView:quickSwitchTableView
                                            sourcePoint:point];
    [quickSwitchDragCoordinator updateDraggingFromView:quickSwitchTableView atPoint:point];
    if ([self isHorizontalQuickSwitchMenu:quickSwitchTableView]) {
        mirrorZoneView.alpha = 0;
    } else {
        if (startedDragging) {
            [self showMirrorZoneForMenu:quickSwitchTableView];
        }
        [self setMirrorZoneHighlighted:[self mirrorZoneContainsPoint:point fromView:quickSwitchTableView]];
    }
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didDropApp:(SBApplication *)app atPoint:(CGPoint)point{
    [self cancelQuickSwitchPrewarm];
    BOOL shouldOpenApp = [quickSwitchDragCoordinator finishDraggingFromView:quickSwitchTableView atPoint:point];
    BOOL shouldSwitchSide = !shouldOpenApp &&
        ![self isHorizontalQuickSwitchMenu:quickSwitchTableView] &&
        [self mirrorZoneContainsPoint:point fromView:quickSwitchTableView];
    quickSwitchOpeningApp = shouldOpenApp;
    if (shouldOpenApp) {
        [self cancelAutoNubTimer];
    }

    if (shouldSwitchSide) {
        mirrorZoneView.alpha = 0;
        [self commitMirrorSideSwitch];
        return;
    }

    [self hideMirrorZone];
    if (shouldOpenApp) {
        NSString *bundleId = [app.bundleIdentifier copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openApplicationExternallyFromQuickSwitch:bundleId];
        });
    }
}

-(void)routeExternalApplicationInsidePullOver:(NSString *)bundleId{
    if (bundleId.length == 0 || [bundleId isEqualToString:pinnedBundleId] ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }

    BOOL sourcePresentationVisible = contextView && !contextView.hidden &&
        contextView.superview == self.contentView &&
        [presentationBundleId isEqualToString:pinnedBundleId] &&
        [hostSession.activeBundleId isEqualToString:pinnedBundleId];
    if (!sourcePresentationVisible) {
        [self showTargetTransitionPresentationForBundleId:bundleId];
    }

    [hostSession activateBundleId:bundleId];
}

-(void)showCantHostAfterNativeTakeover{
    if (panelState == POPanelStateClosed) {
        return;
    }

    deferredOpenGeneration += 1;
    [self cancelAutoNubTimer];
    [self dismissTransientInteractionUI];
    scrollSnapAnimationInProgress = NO;
    [scrollView setContentOffset:CGPointMake([self maximumContentOffsetX], 0) animated:NO];
    panelState = POPanelStateOpen;
    [self applyLayoutPreservingHandlePosition:YES];
    [self hidePresentationContainer];
    shadowView.layer.shadowOpacity = 0;
    [hostSession releaseActiveSessionForExternalTakeoverPreservingPresentation];
    [[POSplitSessionController sharedInstance] end];
    [self cleanUpSubviews];
    presentationBundleId = nil;
    presentationSceneIdentity = nil;
    presentationCanvasSize = CGSizeZero;
    presentationOrientation = UIInterfaceOrientationUnknown;
    presentationSourceCanvasSize = CGSizeZero;
    presentationSourceOrientation = UIInterfaceOrientationUnknown;
    presentationRetainedAfterRelease = NO;
    keyboardZoomContainer.hidden = NO;
    keyboardZoomSuspensionReasons = POKeyboardZoomSuspensionNone;
    [self restoreKeyboardZoomImmediately];
    [self showCantHostView];
    [self updateInteractionBackdropsAnimated:NO];
}

-(void)prepareForNativeApplicationTakeover:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }

    NSString *activeHostedBundleId = [ContextHostManager activeHostedBundleId];
    BOOL targetIsCurrentHostedApp = activeHostedBundleId.length > 0 &&
        [activeHostedBundleId isEqualToString:bundleId];

    deferredOpenGeneration += 1;
    [[POSplitSessionController sharedInstance] end];
    [self cancelQuickSwitchPrewarm];

    if (targetIsCurrentHostedApp && panelState != POPanelStateClosed) {
        [self showCantHostAfterNativeTakeover];
        return;
    }

    BOOL panelHasVisibleTransaction = panelState != POPanelStateClosed;
    if (panelHasVisibleTransaction) {
        [self cancelAutoNubTimer];
        [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionClosing];
        [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];

        mirrorZoneView.alpha = 0;
        [quickSwitchDragCoordinator cancelAnimated:NO];

        if (panelState != POPanelStateClosing) {
            [self snapPanelToOpenState:NO];
            [self capturePresentationSnapshotIfPossible];
        }
        [self hidePresentationContainer];
        shadowView.layer.shadowOpacity = 0;
        [self retainPresentationAfterReleaseIfPossible];
    }

    if (activeHostedBundleId.length == 0) {
        return;
    }

    if (targetIsCurrentHostedApp) {
        [hostSession releaseActiveSessionForExternalTakeoverPreservingPresentation];
    } else {
        [hostSession releaseActiveSessionPreservingPresentation];
    }
}

-(void)openApplicationExternallyFromQuickSwitch:(NSString *)bundleId{
    if (bundleId.length == 0) {
        quickSwitchOpeningApp = NO;
        return;
    }

    [self prepareForNativeApplicationTakeover:bundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleId suspended:NO];
}

-(void)draggingDidEnterBoundsOfQuickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [quickSwitchDragCoordinator cancelAnimated:YES];
    [self hideMirrorZone];
}

#pragma mark - 镜像投放区（拖拽切换停靠side）

-(CGRect)mirrorZoneFrameForMenu:(UIView *)menu{
    CGRect menuInOverlay = [quickSwitchInteractionOverlayView convertRect:menu.bounds fromView:menu];
    CGFloat overlayWidth = CGRectGetWidth(quickSwitchInteractionOverlayView.bounds);
    CGFloat mirroredX = overlayWidth - CGRectGetMaxX(menuInOverlay);
    return CGRectMake(mirroredX, CGRectGetMinY(menuInOverlay),
                     CGRectGetWidth(menuInOverlay), CGRectGetHeight(menuInOverlay));
}

-(void)showMirrorZoneForMenu:(UIView *)menu{
    if ([self isHorizontalQuickSwitchMenu:(UIView<POQuickSwitchMenuPresenting> *)menu]) {
        mirrorZoneView.alpha = 0;
        mirrorZoneHighlighted = NO;
        return;
    }
    [mirrorZoneView.layer removeAllAnimations];
    mirrorZoneView.transform = CGAffineTransformIdentity;
    mirrorZoneView.frame = [self mirrorZoneFrameForMenu:menu];
    CGFloat cornerRadius = POQuickSwitchMenuCornerRadius;
    mirrorZoneView.layer.cornerRadius = cornerRadius;
    mirrorZoneBorder.frame = mirrorZoneView.bounds;
    mirrorZoneBorder.path = [UIBezierPath bezierPathWithRoundedRect:mirrorZoneView.bounds
                                                       cornerRadius:cornerRadius].CGPath;
    mirrorZoneIconView.center = CGPointMake(CGRectGetWidth(mirrorZoneView.bounds) / 2.0,
                                            CGRectGetHeight(mirrorZoneView.bounds) / 2.0);
    mirrorZoneHighlighted = NO;
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneView.alpha = 0;
    [UIView animateWithDuration:0.18
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self->mirrorZoneView.alpha = 1;
    } completion:nil];
}

-(void)hideMirrorZone{
    [mirrorZoneView.layer removeAllAnimations];
    mirrorZoneView.alpha = 0;
    mirrorZoneView.transform = CGAffineTransformIdentity;
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneHighlighted = NO;
}

-(void)setMirrorZoneHighlighted:(BOOL)highlighted{
    if (mirrorZoneHighlighted == highlighted) return;
    mirrorZoneHighlighted = highlighted;
    [UIView animateWithDuration:0.16
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self->mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.22 : 0.08];
        self->mirrorZoneView.transform = highlighted ? CGAffineTransformMakeScale(1.12, 1.05)
                                               : CGAffineTransformIdentity;
    } completion:nil];
}

-(BOOL)mirrorZoneContainsPoint:(CGPoint)point fromView:(UIView *)view{
    if (view == quickSwitchHorizontalBarView || presentedQuickSwitchMenu == quickSwitchHorizontalBarView) {
        return NO;
    }
    CGPoint local = [mirrorZoneView convertPoint:point fromView:view];
    return CGRectContainsPoint(mirrorZoneView.bounds, local);
}

-(void)commitMirrorSideSwitch{
    if (presentedQuickSwitchMenu == quickSwitchHorizontalBarView) {
        return;
    }
    NSUserDefaults *defaults = [POApplicationHelper settingsDefaults];
    BOOL leftHanded = [defaults boolForKey:@"leftHanded"];
    [defaults setBool:!leftHanded forKey:@"leftHanded"];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.mlgm.pulloverx.settings-changed"),
                                         NULL, NULL, YES);
}

-(void)quickSwitchTableViewDidDisappear:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [self finishQuickSwitchSessionForMenu:quickSwitchTableView];
}



#pragma mark - UIScrollViewDelegate

-(void)scrollViewWillEndDragging:(UIScrollView *)sv
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset{
    if (sv != scrollView) {
        return;
    }

    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0) {
        targetContentOffset->x = 0;
        targetContentOffset->y = 0;
        return;
    }

    CGFloat projectedOffset = MIN(MAX(0, targetContentOffset->x), maximumOffset);
    BOOL shouldOpen = velocity.x > 0.15 ||
        (velocity.x >= -0.15 && projectedOffset >= maximumOffset / 2.0);
    pendingOpenState = shouldOpen;
    targetContentOffset->x = sv.contentOffset.x;
    targetContentOffset->y = 0;
}

-(void)scrollViewWillBeginDragging:(UIScrollView *)sv{
    if (sv == scrollView || sv == handleScrollView) {
        [self cancelAutoNubTimer];
    }
    if (sv == scrollView) {
        BOOL startedClosed = panelState == POPanelStateClosed &&
            fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON;
        BOOL interruptedClosing = panelState == POPanelStateClosing;
        interactiveHostIntentIssued = !startedClosed;
        interactiveHostResumeRequired = interruptedClosing;
        POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
        UIView *handleHandoffSnapshot = nil;
        if (startedClosed &&
            [self shouldUsePortraitHostedLandscapeOptimizationForOrientation:
                [self resolvedHostedLayoutOrientation]]) {
            handleHandoffSnapshot = [self beginHandleVisualHandoffSnapshot];
        }
        panelState = POPanelStateInteractive;
        if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
            [self applyLayoutPreservingHandlePosition:YES];
        }
        if (handleHandoffSnapshot) {
            [self completeHandleVisualHandoffFromSnapshot:handleHandoffSnapshot];
        }
        [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
        [self restoreKeyboardZoomImmediately];
        scrollSnapAnimationInProgress = NO;
    }
}

-(void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decelerate{
    if (sv == handleScrollView) {
        [self storeHandlePosition];
        [self resetAutoNubTimer];
        return;
    }
    if (sv != scrollView) {
        return;
    }
    (void)decelerate;
    if (pendingOpenState) {
        if (interactiveHostResumeRequired) {
            interactiveHostIntentIssued = NO;
        }
        [self issueInteractiveHostIntentIfNeeded];
    }
    interactiveHostResumeRequired = NO;
    [self snapPanelToOpenState:pendingOpenState];
    [self scheduleFinishPanelDragZoomIfIdle];
}

-(void)scrollViewDidEndDecelerating:(UIScrollView *)sv{
    if (sv != scrollView) {
        return;
    }
    if (!pendingOpenState && [self isPanelFullyClosedAndIdle]) {
        [self storeHandlePosition];
        [self resetAutoNubTimer];
    }
    [self scheduleFinishPanelDragZoomIfIdle];
}

-(void)scrollViewDidEndScrollingAnimation:(UIScrollView *)sv{
    if (sv != scrollView) {
        return;
    }
    if (!scrollSnapAnimationInProgress) {
        [self scheduleFinishPanelDragZoomIfIdle];
        return;
    }

    CGFloat targetOffset = pendingOpenState ? [self maximumContentOffsetX] : 0;
    if (fabs(scrollView.contentOffset.x - targetOffset) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(scrollView.contentOffset.y) <= CLOSED_CONTENT_OFFSET_EPSILON) {
        [self finishPanelSnapToOpenState:pendingOpenState];
        return;
    }

    [self snapPanelToOpenState:pendingOpenState];
}

-(void)scrollViewDidScroll:(UIScrollView *)sv{
    if (sv == scrollView) {
        [self updatePortraitHostedLandscapeHandleForCurrentOffset];
        [self mfUpdateVerticalHandleRailPosition];   // 【MF 0.1.2】面板滑入/滑出时手柄跟着走
        [self updateInteractionBackdropsAnimated:NO];

        CGFloat shadowProgress = MIN(MAX(sv.contentOffset.x / CONTENT_SHADOW_FADE_DISTANCE, 0), 1);
        shadowView.layer.shadowOpacity = CONTENT_SHADOW_OPACITY * shadowProgress;

        CGFloat rawOffsetX = sv.contentOffset.x;
        if (panelState == POPanelStateClosing && !scaledProgrammaticCloseAnimating &&
            !scrollView.dragging && !scrollView.decelerating &&
            fabs(rawOffsetX) <= CLOSED_CONTENT_OFFSET_EPSILON &&
            fabs(sv.contentOffset.y) <= CLOSED_CONTENT_OFFSET_EPSILON) {
            [self finishPanelSnapToOpenState:NO];
            return;
        }
        if (panelState == POPanelStateInteractive && !interactiveHostIntentIssued && rawOffsetX > 0.5) {
            [self issueInteractiveHostIntentIfNeeded];
        }
    }
}

-(void)cancelAutoNubTimer{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoNubAfterDelay) object:nil];
}

-(void)resetAutoNubTimer{
    [self resetAutoNubTimerWithMinimumDelay:0];
}

-(void)resetAutoNubTimerWithMinimumDelay:(NSTimeInterval)minimumDelay{
    [self cancelAutoNubTimer];
    if ([self isHorizontalQuickSwitchLayoutMode] ||
        ![[POApplicationHelper settings][@"autoNub"] boolValue] || [self isPanelActive] || self.handle.isNubbed) {
        return;
    }

    NSTimeInterval configuredDelay = MAX(0, [[POApplicationHelper settings][@"autoNub-time"] doubleValue]);
    NSTimeInterval delay = MAX(configuredDelay, minimumDelay);
    [self performSelector:@selector(autoNubAfterDelay) withObject:nil afterDelay:delay];
}

-(void)autoNubAfterDelay{
    if (![self isHorizontalQuickSwitchLayoutMode] &&
        [[POApplicationHelper settings][@"autoNub"] boolValue] && ![self isPanelActive] && !self.handle.isNubbed) {
        [self.handle setIsNubbed:YES];
    }
}


-(void)layoutExternalSceneStack{
    if (!externalSceneStack || externalSceneStack.superview != self.contentView) {
        return;
    }

    UIInterfaceOrientation targetOrientation = [self resolvedHostedLayoutOrientation];
    CGSize sourceCanvas = hostedKeyboardLayerPresent
        ? externalSceneStack.bounds.size
        : [self hostSessionPreferredSystemSceneStackSize:hostSession];
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        sourceCanvas = externalSceneStack.bounds.size;
    }
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        return;
    }

    UIInterfaceOrientation sourceOrientation = targetOrientation;
    if (!hostedKeyboardLayerPresent) {
        sourceOrientation = [[ContextHostManager sharedInstance] currentSystemInterfaceOrientation];
        if (!POIsConcretePresentationOrientation(sourceOrientation)) {
            sourceOrientation = self.view.window.windowScene.interfaceOrientation;
        }
        if (!POIsConcretePresentationOrientation(sourceOrientation)) {
            sourceOrientation = sourceCanvas.width > sourceCanvas.height
                ? UIInterfaceOrientationLandscapeLeft
                : UIInterfaceOrientationPortrait;
        }
    }
    if (!POIsConcretePresentationOrientation(targetOrientation)) {
        targetOrientation = sourceOrientation;
    }
    BOOL crossCategory = UIInterfaceOrientationIsLandscape(sourceOrientation) !=
        UIInterfaceOrientationIsLandscape(targetOrientation);
    CGSize displayedSourceSize = crossCategory
        ? CGSizeMake(sourceCanvas.height, sourceCanvas.width)
        : sourceCanvas;
    CGFloat targetScale = MIN(CGRectGetWidth(self.contentView.bounds) / MAX(1, displayedSourceSize.width),
                              CGRectGetHeight(self.contentView.bounds) / MAX(1, displayedSourceSize.height));
    CGFloat rotationAngle = POPresentationAngleForOrientation(targetOrientation) -
        POPresentationAngleForOrientation(sourceOrientation);
    CGAffineTransform transform = CGAffineTransformMakeRotation(rotationAngle);
    transform = CGAffineTransformScale(transform, targetScale, targetScale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]) {
        transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }

    [UIView performWithoutAnimation:^{
        externalSceneStack.transform = CGAffineTransformIdentity;
        externalSceneStack.bounds = (CGRect){CGPointZero, sourceCanvas};
        externalSceneStack.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                                CGRectGetMidY(self.contentView.bounds));
        externalSceneStack.transform = transform;
    }];
}

-(void)layoutContextView{
    if (!contextView) {
        return;
    }

    BOOL wasAlreadyAttached = contextView.superview == self.contentView;
    if (!wasAlreadyAttached) {
        [self.contentView addSubview:contextView];
    }

    CGSize logicalCanvas = [self contextManagerPreferredSceneStackSize:nil];
    UIInterfaceOrientation targetOrientation = [self resolvedHostedLayoutOrientation];

    CGSize sourceCanvas = presentationSourceCanvasSize;
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        sourceCanvas = contextView.bounds.size;
    }
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        sourceCanvas = logicalCanvas;
    }
    UIInterfaceOrientation sourceOrientation = POIsConcretePresentationOrientation(presentationSourceOrientation)
        ? presentationSourceOrientation
        : targetOrientation;

    BOOL sourceAndTargetCategoriesDiffer =
        POIsConcretePresentationOrientation(sourceOrientation) &&
        POIsConcretePresentationOrientation(targetOrientation) &&
        UIInterfaceOrientationIsLandscape(sourceOrientation) != UIInterfaceOrientationIsLandscape(targetOrientation);
    CGSize displayedSourceSize = sourceAndTargetCategoriesDiffer
        ? CGSizeMake(sourceCanvas.height, sourceCanvas.width)
        : sourceCanvas;
    // 【0.3.22】停靠小窗 = 16:9 视口：App 内容按"填满裁切"（MAX）缩放，超出部分被 contentView
    // 裁掉（用户 log31 选定）；其余状态沿用上游"完整装入"（MIN）。最大缩放钳 3.0 防异常放大。
    BOOL mfAspectFill = (mfDockedSide != 0);
    CGFloat hostScale = mfAspectFill
        ? MAX(CGRectGetWidth(self.contentView.bounds) / MAX(1, displayedSourceSize.width),
              CGRectGetHeight(self.contentView.bounds) / MAX(1, displayedSourceSize.height))
        : MIN(CGRectGetWidth(self.contentView.bounds) / MAX(1, displayedSourceSize.width),
              CGRectGetHeight(self.contentView.bounds) / MAX(1, displayedSourceSize.height));
    hostScale = MIN(hostScale, 3.0);
    static BOOL mfLastLoggedAspectFill;
    static BOOL mfHasLoggedAspectFill;
    if (!mfHasLoggedAspectFill || mfLastLoggedAspectFill != mfAspectFill) {
        mfHasLoggedAspectFill = YES;
        mfLastLoggedAspectFill = mfAspectFill;
        MFLog(@"[card] App 内容 %@（窗口 %.0fx%.0f / 画布 %.0fx%.0f → scale %.3f）",
              mfAspectFill ? @"填满裁切（停靠小窗）" : @"完整装入",
              CGRectGetWidth(self.contentView.bounds), CGRectGetHeight(self.contentView.bounds),
              displayedSourceSize.width, displayedSourceSize.height, hostScale);
    }

    CGFloat rotationAngle = 0;
    if (POIsConcretePresentationOrientation(sourceOrientation) &&
        POIsConcretePresentationOrientation(targetOrientation)) {
        rotationAngle = POPresentationAngleForOrientation(targetOrientation) -
            POPresentationAngleForOrientation(sourceOrientation);
    }
    CGAffineTransform transform = CGAffineTransformMakeRotation(rotationAngle);
    transform = CGAffineTransformScale(transform, hostScale, hostScale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]) {
        transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    [UIView performWithoutAnimation:^{
        contextView.transform = CGAffineTransformIdentity;
        contextView.bounds = (CGRect){CGPointZero, sourceCanvas};
        contextView.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                         CGRectGetMidY(self.contentView.bounds));
        contextView.transform = transform;
    }];

    for (UIView *v in contextView.subviews) {
        v.frame = contextView.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    [self layoutExternalSceneStack];

    if (wasAlreadyAttached) {
        self->contextView.alpha = 1;
    } else {
        [UIView animateWithDuration:0.3 animations:^{
            self->contextView.alpha = 1;
        }];
    }

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        presentationSnapshotView && !presentationSnapshotIsTargetPlaceholder) {
        [self layoutPresentationSnapshotView];
    }
}

-(void)cleanUpSubviews{
    keyboardNotificationState = POKeyboardNotificationStateUnknown;
    hostedKeyboardLayerPresent = NO;
    keyboardHideAnimationInFlight = NO;
    keyboardStateHostGeneration = 0;
    keyboardZoomSuppressedForCurrentSession = NO;
    [self restoreKeyboardZoomImmediately];
    UIView *oldContextView = contextView;
    if (oldContextView) {
        [[ContextHostManager sharedInstance] invalidateIOS26PresentationContainersInSceneStack:oldContextView];
    }
    for (UIView *v in self.contentView.subviews) {
        if (v == cantHostCanvas) {
            cantHostCanvas = nil;
            cantHostIconView = nil;
            cantHostLabel = nil;
        }
        [v removeFromSuperview];
    }
    if (oldContextView) {
        contextView = nil;
        presentationBundleId = nil;
        presentationSceneIdentity = nil;
        presentationCanvasSize = CGSizeZero;
        presentationOrientation = UIInterfaceOrientationUnknown;
        presentationSourceCanvasSize = CGSizeZero;
        presentationSourceOrientation = UIInterfaceOrientationUnknown;
        presentationRetainedAfterRelease = NO;
    }
    [self clearPresentationSnapshot];
    if (externalSceneStack) {
        [externalSceneStack removeFromSuperview];
        externalSceneStack = nil;
    }
}

-(void)forceCloseAndReleaseImmediately{
    deferredOpenGeneration += 1;
    [self cancelAutoNubTimer];
    scrollSnapAnimationInProgress = NO;
    scaledProgrammaticCloseAnimating = NO;
    scaledProgrammaticCloseNeedsLayout = NO;
    deferScaledCloseSessionCleanup = NO;
    [keyboardZoomContainer.layer removeAllAnimations];
    [handleScrollView.layer removeAllAnimations];
    handlePanIntent = POHandlePanIntentNone;
    pendingOpenState = NO;
    interactiveHostIntentIssued = NO;
    interactiveHostResumeRequired = NO;
    quickSwitchOpeningApp = NO;
    POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
    CGFloat inheritedHandleScreenY = NAN;
    if (previousLayoutMode == POQuickSwitchLayoutModeHorizontalBottom) {
        CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
        if (!CGRectIsEmpty(handleInView) && isfinite(CGRectGetMinY(handleInView))) {
            inheritedHandleScreenY = CGRectGetMinY(handleInView);
        }
    }
    panelState = POPanelStateClosed;
    [scrollView setContentOffset:CGPointZero animated:NO];
    if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
        [self applyLayoutPreservingHandlePosition:YES];
        [self inheritVerticalHandleScreenY:inheritedHandleScreenY];
        [self storeHandlePosition];
    }
    shadowView.layer.shadowOpacity = 0;
    [self dismissTransientInteractionUI];
    showingCantHost = NO;
    if (origOffset && handleScrollView) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:NO];
        if (self.handle) {
            [self storeHandlePosition];
        }
    }
    origOffset = nil;
    keyboardNotificationState = POKeyboardNotificationStateUnknown;
    hostedKeyboardLayerPresent = NO;
    keyboardHideAnimationInFlight = NO;
    keyboardStateHostGeneration = 0;
    keyboardZoomSuppressedForCurrentSession = NO;
    [self restoreKeyboardZoomImmediately];
    keyboardZoomSuspensionReasons = POKeyboardZoomSuspensionNone;
    [self hidePresentationContainer];
    [hostSession invalidate];
    [[POSplitSessionController sharedInstance] end];
    [self cleanUpSubviews];
    presentationBundleId = nil;
    presentationSceneIdentity = nil;
    presentationCanvasSize = CGSizeZero;
    presentationOrientation = UIInterfaceOrientationUnknown;
    presentationSourceCanvasSize = CGSizeZero;
    presentationSourceOrientation = UIInterfaceOrientationUnknown;
    presentationRetainedAfterRelease = NO;
    [self updateInteractionBackdropsAnimated:NO];
}

-(void)showCantHostView{
    showingCantHost = YES;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showCantHostView];
        });
        return;
    }

    if (!cantHostCanvas) {
        cantHostCanvas = [[UIView alloc] initWithFrame:CGRectZero];
        cantHostCanvas.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:cantHostCanvas];

        UIImageConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:96 weight:UIImageSymbolWeightRegular];
        UIImage *scannerImage = [UIImage systemImageNamed:@"scanner" withConfiguration:config]
            ?: [UIImage systemImageNamed:@"scanner.fill" withConfiguration:config];
        cantHostIconView = [[UIImageView alloc] initWithImage:scannerImage];
        cantHostIconView.contentMode = UIViewContentModeScaleAspectFit;
        cantHostIconView.tintColor = [UIColor labelColor];
        [cantHostIconView sizeToFit];
        [cantHostCanvas addSubview:cantHostIconView];

        cantHostLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        cantHostLabel.numberOfLines = 1;
        cantHostLabel.textAlignment = NSTextAlignmentCenter;
        cantHostLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cantHostLabel.textColor = [UIColor labelColor];
        cantHostLabel.text = POLocalizedString(@"The current app is already open and can't be shown.", @"Tweak");
        [cantHostCanvas addSubview:cantHostLabel];
    }
    cantHostCanvas.hidden = NO;
    [self.contentView bringSubviewToFront:cantHostCanvas];
    [self layoutCantHostView];
}

-(void)layoutCantHostView{
    if (!cantHostCanvas || !cantHostIconView || !cantHostLabel) {
        return;
    }

    cantHostCanvas.transform = CGAffineTransformScale(CGAffineTransformIdentity, scale, scale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]){
        cantHostCanvas.transform = CGAffineTransformConcat(cantHostCanvas.transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    CGRect canvasFrame = cantHostCanvas.frame;
    canvasFrame.origin = CGPointZero;
    canvasFrame.size = self.contentView.bounds.size;
    cantHostCanvas.frame = canvasFrame;

    CGFloat width = cantHostCanvas.bounds.size.width;
    CGFloat height = cantHostCanvas.bounds.size.height;
    cantHostIconView.center = CGPointMake(width/2.0, height/2.0 - 40);
    cantHostLabel.frame = CGRectMake(0, 0, MAX(0, width-32), 30);
    cantHostLabel.center = CGPointMake(width/2.0, CGRectGetMaxY(cantHostIconView.frame) + 32);
}

#pragma mark - POHostSessionControllerDelegate

-(void)hostSessionController:(POHostSessionController *)controller
hostedPresentationContentDidBecomeUnavailableForBundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        controller != hostSession || generation != controller.currentGeneration ||
        ![bundleId isEqualToString:controller.requestedBundleId] ||
        panelState == POPanelStateClosed || panelState == POPanelStateClosing ||
        !runtimeCategoryTransitionSnapshotFallbackArmed ||
        !presentationSnapshotView ||
        ![presentationSnapshotBundleId isEqualToString:bundleId]) {
        return;
    }
    [self showRuntimeCategoryTransitionSnapshotFallback];
}

-(CGSize)hostSessionPreferredSceneStackSize:(POHostSessionController *)controller{
    return [self contextManagerPreferredSceneStackSize:nil];
}

-(UIInterfaceOrientation)hostSessionPreferredHostedInterfaceOrientation:(POHostSessionController *)controller{
    return [self contextManagerPreferredHostedInterfaceOrientation:nil];
}

-(void)hostSessionController:(POHostSessionController *)controller
hostedInterfaceOrientationDidChange:(UIInterfaceOrientation)orientation
   systemAnimationParameters:(id)animationParameters
                      bundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation{
    if (![bundleId isEqualToString:controller.requestedBundleId] || generation != controller.currentGeneration ||
        panelState == POPanelStateClosed || panelState == POPanelStateClosing) {
        return;
    }
    BOOL layoutOrientationKnown = hostedLayoutOrientation == UIInterfaceOrientationPortrait ||
        hostedLayoutOrientation == UIInterfaceOrientationPortraitUpsideDown ||
        UIInterfaceOrientationIsLandscape(hostedLayoutOrientation);
    if (layoutOrientationKnown &&
        UIInterfaceOrientationIsLandscape(hostedLayoutOrientation) == UIInterfaceOrientationIsLandscape(orientation)) {
        return;
    }

    BOOL hasPreRotationSnapshot = presentationSnapshotView && !presentationSnapshotIsTargetPlaceholder &&
        [presentationSnapshotBundleId isEqualToString:bundleId] &&
        (presentationSnapshotOrientation == UIInterfaceOrientationPortrait ||
         presentationSnapshotOrientation == UIInterfaceOrientationPortraitUpsideDown ||
         UIInterfaceOrientationIsLandscape(presentationSnapshotOrientation)) &&
        UIInterfaceOrientationIsLandscape(presentationSnapshotOrientation) != UIInterfaceOrientationIsLandscape(orientation);
    if (hasPreRotationSnapshot) {
        runtimeCategoryTransitionSnapshotActive = YES;
    }

    UIInterfaceOrientation previousLayoutOrientation = hostedLayoutOrientation;
    CGFloat previousBackdropAlpha = panelBackdropView.alpha;
    [self dismissTransientInteractionUI];

    hostedLayoutOrientation = orientation;
    hostedCategoryTransitionPending = YES;
    [self updateInteractionBackdropsAnimated:NO];
    [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
    [self restoreKeyboardZoomImmediately];

    BOOL transitionAnimated =
        [self beginRuntimeHostedCategoryTransitionFromOrientation:previousLayoutOrientation
                                                    toOrientation:orientation
                                            startingBackdropAlpha:previousBackdropAlpha
                                         systemAnimationParameters:animationParameters];
    hostedCategoryTransitionPending = NO;
    if (!transitionAnimated) {
        [self applyLayoutPreservingHandlePosition:YES];
        ContextHostManager *manager = [ContextHostManager sharedInstance];
        UIInterfaceOrientation sourceOrientation =
            manager.currentHostedPresentationSourceOrientation;
        BOOL sourceNeedsCanonicalization =
            POIsConcretePresentationOrientation(sourceOrientation) &&
            POIsConcretePresentationOrientation(orientation) &&
            UIInterfaceOrientationIsLandscape(sourceOrientation) !=
                UIInterfaceOrientationIsLandscape(orientation);
        if (sourceNeedsCanonicalization) {
            if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
                runtimeScenePublicationStaging = YES;
                [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:generation];
                runtimeScenePublicationStaging = NO;
            } else {
                BOOL snapshotReady =
                    [self prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:sourceOrientation];
                if (snapshotReady) {
                    [self retargetRuntimeCategoryTransitionSnapshotForOrientation:orientation];
                }
                BOOL canonicalizationStarted =
                    [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:generation];
                if (snapshotReady && !canonicalizationStarted) {
                    [self clearPresentationSnapshot];
                }
            }
        }
    }
    if (hasPreRotationSnapshot && presentationSnapshotView &&
        [presentationSnapshotBundleId isEqualToString:bundleId]) {
        [self retargetRuntimeCategoryTransitionSnapshotForOrientation:orientation];
        runtimeCategoryTransitionSnapshotActive = YES;
    }
    if (contextView && !presentationRetainedAfterRelease &&
        [presentationBundleId isEqualToString:bundleId] &&
        [controller.activeBundleId isEqualToString:bundleId]) {
        presentationCanvasSize = [self contextManagerPreferredSceneStackSize:nil];
        presentationOrientation = orientation;
        contextView.hidden = NO;
        [self.contentView bringSubviewToFront:contextView];
        if (presentationSnapshotView && !presentationSnapshotView.hidden &&
            presentationSnapshotView.superview == self.contentView) {
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }
    if (!transitionAnimated) {
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
    }

}

-(void)hostSessionController:(POHostSessionController *)controller
             didPublishScene:(FBScene *)scene
                 sceneStack:(UIView *)sceneStack
                   bundleId:(NSString *)bundleId
                 generation:(NSUInteger)generation{
    MFLog(@"[host] 场景已发布 bid=%@ gen=%lu stack=%@", bundleId, (unsigned long)generation,
          sceneStack != nil ? @"非空" : @"空");
    if (!sceneStack || generation != controller.currentGeneration ||
        ![bundleId isEqualToString:controller.requestedBundleId]) {
        return;
    }

    BOOL usesIOS15LiveRuntimeScenePublication =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        (runtimeHostedCategoryTransitionAnimating || runtimeScenePublicationStaging);
    if (runtimeHostedCategoryTransitionAnimating && !runtimeScenePublicationStaging &&
        !usesIOS15LiveRuntimeScenePublication) {
        deferredRuntimePublishedScene = scene;
        deferredRuntimePublishedSceneStack = sceneStack;
        deferredRuntimePublishedBundleId = [bundleId copy];
        deferredRuntimePublishedGeneration = generation;
        if (runtimeCategoryTransitionSnapshotActive) {
            [self scheduleRuntimeScenePublicationStagingIfNeeded];
        }
        return;
    }

    if (![bundleId isEqualToString:pinnedBundleId]) {
        [self commitPinnedBundleId:bundleId];
    }

    if (keyboardStateHostGeneration != generation) {
        keyboardStateHostGeneration = generation;
        keyboardNotificationState = POKeyboardNotificationStateUnknown;
        hostedKeyboardLayerPresent = NO;
        keyboardHideAnimationInFlight = NO;
        keyboardZoomSuppressedForCurrentSession = NO;
    }

    UIView *previousContextView = contextView;
    UIView *previousCantHostCanvas = cantHostCanvas;
    BOOL replacingVisibleMainStack = previousContextView && previousContextView != sceneStack &&
        previousContextView.superview == self.contentView && !previousContextView.hidden &&
        !presentationSnapshotView && panelState != POPanelStateClosed;
    if (replacingVisibleMainStack && !usesIOS15LiveRuntimeScenePublication) {
        [self capturePresentationSnapshotIfPossible];
        if (presentationSnapshotView) {
            presentationSnapshotView.hidden = NO;
        }
    }
    UIInterfaceOrientation currentHostedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    UIInterfaceOrientation publishedSourceOrientation =
        [manager publishedSourceOrientationForScene:scene];
    CGSize publishedSourceCanvas = [manager publishedSourceCanvasSizeForScene:scene];
    if (POIsConcretePresentationOrientation(publishedSourceOrientation) &&
        publishedSourceCanvas.width > 0 && publishedSourceCanvas.height > 0) {
        presentationSourceOrientation = publishedSourceOrientation;
        presentationSourceCanvasSize = publishedSourceCanvas;
    } else if (presentationSourceCanvasSize.width <= 0 || presentationSourceCanvasSize.height <= 0 ||
               !POIsConcretePresentationOrientation(presentationSourceOrientation)) {
        UIInterfaceOrientation sourceOrientation =
            [manager preferredHostedInterfaceOrientationForBundleId:bundleId];
        if (!POIsConcretePresentationOrientation(sourceOrientation)) {
            sourceOrientation = currentHostedOrientation;
        }
        presentationSourceCanvasSize = sceneStack.bounds.size;
        presentationSourceOrientation = sourceOrientation;
    }

    presentationBundleId = [bundleId copy];
    presentationSceneIdentity = scene;
    presentationCanvasSize = [self contextManagerPreferredSceneStackSize:nil];
    presentationOrientation = currentHostedOrientation;

    contextView = sceneStack;
    sceneStack.hidden = NO;
    sceneStack.alpha = 1;

    BOOL layoutOrientationKnown = POIsConcretePresentationOrientation(hostedLayoutOrientation);
    BOOL publishedOrientationKnown = POIsConcretePresentationOrientation(currentHostedOrientation);
    BOOL layoutCategoryMismatch = publishedOrientationKnown &&
        (!layoutOrientationKnown ||
         UIInterfaceOrientationIsLandscape(hostedLayoutOrientation) !=
             UIInterfaceOrientationIsLandscape(currentHostedOrientation));
    BOOL pendingRuntimeOrientationHandoff =
        [manager hasPendingRuntimeOrientationHandoffForScene:scene generation:generation];
    if (layoutCategoryMismatch && panelState != POPanelStateClosed &&
        panelState != POPanelStateClosing && !pendingRuntimeOrientationHandoff) {
        [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self restoreKeyboardZoomImmediately];
        [self applyLayoutPreservingHandlePosition:YES];
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
    } else if (!pendingRuntimeOrientationHandoff) {
        [self layoutContextView];
    }
    [self reconcilePresentedContainerGeometry];

    if (previousContextView && previousContextView != sceneStack && previousContextView.superview) {
        [manager invalidateIOS26PresentationContainersInSceneStack:previousContextView];
        [previousContextView removeFromSuperview];
    }
    if (previousCantHostCanvas && previousCantHostCanvas.superview) {
        [previousCantHostCanvas removeFromSuperview];
    }
    if (cantHostCanvas == previousCantHostCanvas) {
        cantHostCanvas = nil;
        cantHostIconView = nil;
        cantHostLabel = nil;
    }

    presentationRetainedAfterRelease = NO;
    showingCantHost = NO;
    [self.contentView bringSubviewToFront:contextView];

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        runtimeCategoryTransitionSnapshotActive && presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder &&
        [presentationSnapshotBundleId isEqualToString:bundleId] &&
        presentationSnapshotSceneIdentity == scene) {
        UIInterfaceOrientation snapshotTargetOrientation = currentHostedOrientation;
        [self retargetRuntimeCategoryTransitionSnapshotForOrientation:snapshotTargetOrientation];
    }

    BOOL snapshotCanBridgeHandoff = presentationSnapshotView && !presentationSnapshotView.hidden &&
        [self hasCompatiblePresentationSnapshotForBundleId:bundleId];
    BOOL snapshotCanRemainForOrientationHandoff = presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder && runtimeCategoryTransitionSnapshotFallbackArmed &&
        [presentationSnapshotBundleId isEqualToString:bundleId] &&
        (!presentationSnapshotSceneIdentity || presentationSnapshotSceneIdentity == scene);
    if (snapshotCanBridgeHandoff || snapshotCanRemainForOrientationHandoff) {
        presentationSnapshotView.hidden = NO;
        presentationSnapshotView.alpha = 1.0;
        [self layoutPresentationSnapshotView];
        [self.contentView bringSubviewToFront:presentationSnapshotView];
        [self schedulePresentationSnapshotRetirementForBundleId:bundleId generation:generation];
    } else if (presentationSnapshotView) {
        [self clearPresentationSnapshot];
    }

    [self completeExternallyActivatedApplicationIfNeeded:bundleId];
}

-(void)hostSessionController:(POHostSessionController *)controller
             didPublishScene:(FBScene *)scene
          externalSceneStack:(UIView *)sceneStack
       containsKeyboardLayer:(BOOL)containsKeyboardLayer
                   bundleId:(NSString *)bundleId
                 generation:(NSUInteger)generation{
    if (generation != controller.currentGeneration ||
        ![bundleId isEqualToString:controller.requestedBundleId]) {
        return;
    }

    hostedKeyboardLayerPresent = containsKeyboardLayer;
    if (containsKeyboardLayer &&
        keyboardNotificationState == POKeyboardNotificationStateUnknown &&
        !keyboardHideAnimationInFlight) {
        keyboardNotificationState = POKeyboardNotificationStateVisible;
        keyboardHideAnimationInFlight = NO;
    } else if (!containsKeyboardLayer) {
        if (keyboardNotificationState == POKeyboardNotificationStateUnknown) {
            keyboardNotificationState = POKeyboardNotificationStateHidden;
        }
    }

    if (!contextView || !sceneStack) {
        [self reevaluateKeyboardZoomAnimated:NO];
        return;
    }

    if (externalSceneStack && externalSceneStack != sceneStack) {
        [externalSceneStack removeFromSuperview];
    }
    externalSceneStack = sceneStack;
    if (sceneStack.subviews.count > 0) {
        [self.contentView addSubview:sceneStack];
        [self layoutExternalSceneStack];
        [self.contentView bringSubviewToFront:sceneStack];
        if (presentationSnapshotView && !presentationSnapshotView.hidden &&
            presentationSnapshotView.superview == self.contentView) {
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }
    [self reevaluateKeyboardZoomAnimated:YES];
    [self completeExternallyActivatedApplicationIfNeeded:bundleId];
}

-(void)hostSessionController:(POHostSessionController *)controller
cannotHostFrontmostBundleId:(NSString *)bundleId
                  generation:(NSUInteger)generation{
    MFLog(@"[host] !! 无法承载 bid=%@ gen=%lu", bundleId, (unsigned long)generation);
    if ([externallyActivatedBundleId isEqualToString:bundleId]) {
        [self restoreExternallyActivatedApplicationNatively:bundleId];
        return;
    }
    BOOL pendingExternalRoute = pinnedBundleId.length > 0 &&
        ![bundleId isEqualToString:pinnedBundleId];
    if (pendingExternalRoute) {
        if (presentationSnapshotIsTargetPlaceholder &&
            [presentationSnapshotBundleId isEqualToString:bundleId]) {
            [self clearPresentationSnapshot];
        }
        [hostSession activateBundleId:pinnedBundleId];
        return;
    }
    if (![bundleId isEqualToString:pinnedBundleId]) {
        return;
    }
    [[POSplitSessionController sharedInstance] end];
    [self cleanUpSubviews];
    presentationBundleId = nil;
    presentationSceneIdentity = nil;
    presentationCanvasSize = CGSizeZero;
    presentationOrientation = UIInterfaceOrientationUnknown;
    presentationSourceCanvasSize = CGSizeZero;
    presentationSourceOrientation = UIInterfaceOrientationUnknown;
    presentationRetainedAfterRelease = NO;
    if (panelState != POPanelStateClosed) {
        keyboardZoomContainer.hidden = NO;
        [self showCantHostView];
    }
    [self reevaluateKeyboardZoomAnimated:NO];
}

@end
