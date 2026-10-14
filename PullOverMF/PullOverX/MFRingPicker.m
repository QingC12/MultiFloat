//
//  MFRingPicker.m
//  PullOverMF —— Stheno 风格「圆盘」呼出选择器（本 fork 新增）
//
//  设计依据（逆向自 Stheno 0.1.23，com.nx.stheno）：
//    · 圆盘本体：类型名 RingView / RingShape / RingType / RingTypeSwitchView / RingModifySlidersView
//      本地化文案：'RTSIF'=承载形状::圆盘 / 'RTSIH'=承载形状::半圆盘 / 'RTSIQ'=承载形状::直角盘 /
//                  'RTSIZ'=承载形状::任意, 拖拽旋转最后一个图标
//      几何参数键：IconWidth(图标宽度) / Radius(半径) / HeightFraction(高度系数) / RotationAngle(旋转角) /
//                  LastIconAngle(尾角) / DampingFraction(阻尼系数)
//      → 结论：圆盘 = 沿圆弧排布的一圈 App 图标，可自定义 App、可旋转、多种盘形。
//    · 呼出方式：Stheno 走「边缘手势」，hook 了 SpringBoard 的手势链：
//      SBReachabilityGestureRecognizerHook / SBReachabilityManagerHook / SBGrabberTongueHook /
//      SBFluidSwitcherGestureManagerHook / _SBFluidSwitcherPanGestureRecognizerHook，
//      并在 SBGrabberTongue 上处理 _handlePullGesture:（下拉）—— 所以它在**任何界面**（含全屏 App）都能触发。
//      配置项：EBCI(触发边, 可调节) / AppearEdge / EdgeBarControlView / EgdeGestureView / EdgeGestureShape。
//
//  本实现（零 hook，确保不卡开机）：
//    · 圆盘：完整圆形，图标沿整圈排布；可自定义 App（配置键 ringApps）。
//    · 呼出：**只保留手势**——屏幕边缘一条透明触发区，向内滑动 >阈值 即呼出。
//    · 交互（0.1.6 重做，用户指定）：
//        ① 手势呼出后圆盘**跟随手指**移动；
//        ② 手指停住 / 靠近停靠点 → 圆盘**固定到屏幕下半屏中心**（不再是屏幕正中心）；
//        ③ 手指自由滑动 → 高亮离手指最近的图标（悬停选择）；
//        ④ **手指离开屏幕** → 自动收起圆盘；若已选中 App → 立即以浮窗打开。
//    · 全程 MFLog 记录（含触摸来源窗口类名、悬停选中变化、固定时刻）。
//
//  配置项（suite com.mlgm.pulloverx，改完 respring 生效）：
//    mfRingEnabled      BOOL   是否启用圆盘（默认 YES）
//    mfTriggerEdge      string 触发边：right(默认) / left / top / bottom
//    mfTriggerLength    number 触发区长度（默认 380）
//    mfTriggerThickness number 触发区厚度（默认 56）
//    mfTriggerCenterRatio number 触发区中心位置 0~1（默认 0.78 = 屏幕偏下）
//    mfRingSummonThreshold number 手势呼出阈值，pt（默认 18）
//    mfRingRadius       number 圆盘半径（默认 150）
//    mfRingIconSize     number 图标尺寸（默认 44；0.1.5 起从 56 缩小）
//    mfRingEdgeMargin   number 圆盘外沿距屏幕边的间距（默认 12）
//    mfRingRotation     number 图标整体旋转角，度（默认 0）
//    mfRingStartAngle   number 第一个图标的角度，度（默认 -90 = 正上方）
//    mfRingParkRatioY   number 停靠点纵向比例（默认 0.72 = 下半屏中心）
//    mfRingLatchTolerance number 手指靠近停靠点多少 pt 即固定（默认 72）
//    mfRingSettleDelay  number 手指停住多久自动固定，秒（默认 0.18）
//    mfRingMaxIcons     number 未配置时最多显示几个（默认 8）
//    ringApps           array  bundleID 数组（自定义圆盘内容）
//
//  版本备注：0.1.4 及以前圆心放在屏幕边缘 → 圆一半在屏幕外；0.1.5 圆心内缩让整圆可见；
//  0.1.6 交互重做（本文件）：去掉「点击触发区呼出」，改为手势呼出 + 跟随手指 + 停靠下半屏中心 + 悬停选择 + 松手即开。
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "POXWindow.h"
#import "PullOverViewController.h"
#import "POApplicationHelper.h"

#define MF_RING_WINDOW_LEVEL 130.0

static char kMFRingBundleIdKey;

#pragma mark - 配置读取

static NSUserDefaults *MFRingDefaults(void) {
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

static double MFRingNumber(NSString *key, double fallback) {
    id value = [MFRingDefaults() objectForKey:key];
    if (value == nil) {
        return fallback;
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double number = [value doubleValue];
        return isfinite(number) ? number : fallback;
    }
    return fallback;
}

static BOOL MFRingBool(NSString *key, BOOL fallback) {
    id value = [MFRingDefaults() objectForKey:key];
    if (value == nil) {
        return fallback;
    }
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return fallback;
}

static NSString *MFRingEdge(void) {
    NSString *edge = [MFRingDefaults() stringForKey:@"mfTriggerEdge"];
    if (![edge isKindOfClass:[NSString class]] || edge.length == 0) {
        return @"right";
    }
    return edge.lowercaseString;
}

/// 圆盘内容：配置键 ringApps（bundleID 数组）；未配置时退化为"最近使用的 App"
static NSArray<NSString *> *MFRingBundleIds(void) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    id configured = [MFRingDefaults() arrayForKey:@"ringApps"];
    if ([configured isKindOfClass:[NSArray class]]) {
        for (id item in configured) {
            if ([item isKindOfClass:[NSString class]] && [item length] > 0 && ![ids containsObject:item]) {
                [ids addObject:item];
            }
        }
        if (ids.count > 0) {
            return ids;
        }
    }
    int limit = (int)MAX(1.0, MFRingNumber(@"mfRingMaxIcons", 8));
    NSArray *recent = [POApplicationHelper recentAppsWithCount:limit];
    for (id item in recent) {
        if ([item isKindOfClass:[NSString class]] && [item length] > 0 && ![ids containsObject:item]) {
            [ids addObject:item];
        }
    }
    return ids;
}

static void MFRingWriteBundleIds(NSArray<NSString *> *ids) {
    NSUserDefaults *defaults = MFRingDefaults();
    [defaults setObject:ids ?: @[] forKey:@"ringApps"];
    [defaults synchronize];
    MFLog(@"[ring] ringApps 已保存 %lu 项", (unsigned long)ids.count);
}

#pragma mark - 窗口

@interface MFRingWindow : UIWindow
@end

@implementation MFRingWindow
@end

#pragma mark - 圆盘选择器

@interface MFRingPicker : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) MFRingWindow *window;
@property (nonatomic, strong) UIView *triggerView;          // 贴边透明触发区（收起态）
@property (nonatomic, strong) UIPanGestureRecognizer *triggerPan;
@property (nonatomic, strong) UIView *container;            // 展开态根视图（轻遮罩 + 圆盘）
@property (nonatomic, strong) UIView *ringRoot;             // 圆盘整体（移动它 = 移动圆盘）
@property (nonatomic, strong) CAShapeLayer *dialLayer;      // 圆形底盘
@property (nonatomic, strong) NSMutableArray<UIButton *> *iconButtons;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL ringLatched;             // 圆盘是否已固定在停靠点
@property (nonatomic, assign) CGPoint parkCenter;           // 停靠点（屏幕下半屏中心）
@property (nonatomic, weak) UIButton *selectedButton;       // 悬停选中的图标
@property (nonatomic, assign) CGPoint lastFingerPoint;      // 最近一次手指屏幕坐标
@property (nonatomic, assign) CGPoint latchFingerPoint;     // 固定那一刻的手指坐标
@property (nonatomic, assign) BOOL hasLatchFinger;          // 是否已记录固定时的手指位置
@property (nonatomic, assign) NSUInteger settleGeneration;  // 手指停住计时器代次
+ (instancetype)shared;
- (void)install;
- (void)showAtPoint:(CGPoint)point;
- (void)showRingWithAnchor:(CGPoint)point latch:(BOOL)latch;
- (void)moveRingToPoint:(CGPoint)point;
- (void)latchToParkAnimated:(BOOL)animated;
- (void)buildRingInContainer:(UIView *)container;
- (void)updateSelectionForPoint:(CGPoint)point;
- (void)openFloatWithBundleId:(NSString *)bundleId;
- (void)hide;
@end

@implementation MFRingPicker

+ (instancetype)shared {
    static MFRingPicker *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MFRingPicker alloc] init];
    });
    return instance;
}

#pragma mark 安装

- (void)install {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }
    if (self.window != nil) {
        return;   // 幂等
    }
    if (!MFRingBool(@"mfRingEnabled", YES)) {
        MFLog(@"[ring] 圆盘已按配置关闭（mfRingEnabled=false）");
        return;
    }
    @try {
        CGRect screen = [UIScreen mainScreen].bounds;
        if (CGRectIsEmpty(screen)) {
            MFLog(@"[ring] !! 屏幕未就绪，1 秒后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self install]; });
            return;
        }

        // 与浮窗窗口共用 windowScene（SpringBoard 里没有 windowScene 的窗口既不渲染也不收触摸）
        UIWindowScene *scene = nil;
        @try {
            id sharedWindow = [POXWindow sharedWindow];
            if ([sharedWindow isKindOfClass:[UIWindow class]]) {
                scene = [(UIWindow *)sharedWindow windowScene];
            }
        } @catch (NSException *exception) {
            scene = nil;
        }
        MFRingWindow *window = (scene != nil) ? [[MFRingWindow alloc] initWithWindowScene:scene]
                                              : [[MFRingWindow alloc] initWithFrame:screen];
        if (window == nil) {
            MFLog(@"[ring] !! 圆盘窗口创建失败");
            return;
        }
        window.windowLevel = MF_RING_WINDOW_LEVEL;
        window.backgroundColor = [UIColor clearColor];
        window.hidden = NO;
        self.window = window;
        self.iconButtons = [NSMutableArray array];

        // ---- 收起态：屏幕边缘一条透明触发区（**只挂 pan，不挂 tap** —— 0.1.6 起只保留手势呼出）----
        CGRect trigger = [self triggerFrameForScreen:screen];
        window.frame = trigger;

        UIView *triggerView = [[UIView alloc] initWithFrame:window.bounds];
        triggerView.backgroundColor = [UIColor clearColor];
        triggerView.userInteractionEnabled = YES;
        triggerView.tag = 991001;
        [window addSubview:triggerView];
        self.triggerView = triggerView;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(onTriggerPan:)];
        pan.delegate = self;
        [triggerView addGestureRecognizer:pan];
        self.triggerPan = pan;

        MFLog(@"[ring] 圆盘选择器已安装（仅手势呼出）：触发边=%@，触发区=%@，窗口 scene=%@",
              MFRingEdge(), NSStringFromCGRect(trigger),
              scene != nil ? NSStringFromClass([scene class]) : @"nil(回退 frame)");
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 安装异常：%@", exception);
    }
}

/// 收起态的触发区（贴边一条）
- (CGRect)triggerFrameForScreen:(CGRect)screen {
    CGFloat width = screen.size.width;
    CGFloat height = screen.size.height;
    CGFloat thickness = MAX(16.0, MFRingNumber(@"mfTriggerThickness", 56.0));
    CGFloat length = MAX(80.0, MFRingNumber(@"mfTriggerLength", 380.0));
    // 触发区中心位置（0~1，默认 0.78 = 屏幕偏下）—— 避开 PullOver 手柄常驻的垂直中部
    CGFloat centerRatio = MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.95);
    NSString *edge = MFRingEdge();
    if ([edge isEqualToString:@"top"] || [edge isEqualToString:@"bottom"]) {
        CGFloat originX = MIN(MAX(width * centerRatio - length / 2.0, 0.0), MAX(width - length, 0.0));
        return ([edge isEqualToString:@"top"]) ? CGRectMake(originX, 0.0, length, thickness)
                                               : CGRectMake(originX, height - thickness, length, thickness);
    }
    CGFloat originY = MIN(MAX(height * centerRatio - length / 2.0, 0.0), MAX(height - length, 0.0));
    if ([edge isEqualToString:@"left"]) {
        return CGRectMake(0.0, originY, thickness, length);
    }
    return CGRectMake(width - thickness, originY, thickness, length);   // right（默认）
}

#pragma mark 坐标辅助

/// 手指在**屏幕**坐标系里的位置。
/// 收起态窗口 frame = 触发区（原点非 0），展开态窗口 frame = 全屏（原点 0,0），
/// 所以统一用 "窗口 frame 原点 + 窗口内坐标" 换算，两种状态都正确。
- (CGPoint)screenPointForGesture:(UIGestureRecognizer *)gesture {
    if (self.window == nil) {
        return CGPointZero;
    }
    CGPoint inWindow = [gesture locationInView:self.window];
    CGRect frame = self.window.frame;
    return CGPointMake(frame.origin.x + inWindow.x, frame.origin.y + inWindow.y);
}

/// 把圆心夹到合法范围：整圆不出屏，且**只在下半屏**
- (CGPoint)clampRingCenter:(CGPoint)point {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat radius = MAX(60.0, MFRingNumber(@"mfRingRadius", 150.0));
    CGFloat margin = MAX(0.0, MFRingNumber(@"mfRingEdgeMargin", 12.0));
    CGFloat extent = radius + margin;
    CGFloat minX = extent;
    CGFloat maxX = MAX(CGRectGetMaxX(screen) - extent, minX);
    CGFloat minY = CGRectGetMidY(screen);                       // 下半屏
    CGFloat maxY = MAX(CGRectGetMaxY(screen) - extent, minY);
    CGFloat x = MIN(MAX(point.x, minX), maxX);
    CGFloat y = MIN(MAX(point.y, minY), maxY);
    return CGPointMake(x, y);
}

#pragma mark 触发（仅手势）

- (void)onTriggerPan:(UIPanGestureRecognizer *)gesture {
    if (gesture.view == nil) {
        return;
    }
    CGPoint finger = [self screenPointForGesture:gesture];
    self.lastFingerPoint = finger;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[ring] 贴边按下 来源=%@(tag=%ld) 屏幕(%.0f,%.0f)",
              NSStringFromClass([gesture.view.window class]), (long)gesture.view.tag, finger.x, finger.y);
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (!self.expanded) {
            CGPoint translation = [gesture translationInView:gesture.view];
            CGFloat threshold = MAX(6.0, MFRingNumber(@"mfRingSummonThreshold", 18.0));
            if (fabs(translation.x) > threshold || fabs(translation.y) > threshold) {
                [self showAtPoint:finger];
            }
            return;
        }

        if (!self.ringLatched) {
            [self moveRingToPoint:finger];
            CGFloat tolerance = MAX(12.0, MFRingNumber(@"mfRingLatchTolerance", 72.0));
            if (hypot(finger.x - self.parkCenter.x, finger.y - self.parkCenter.y) <= tolerance) {
                [self latchToParkAnimated:YES];
            } else {
                [self scheduleSettle];
            }
        }
        [self updateSelectionForPoint:finger];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        if (!self.expanded) {
            MFLog(@"[ring] 贴边松手（未达到呼出阈值，不呼出）");
            return;
        }
        [self updateSelectionForPoint:finger];
        UIButton *selected = self.selectedButton;
        NSString *bundleId = selected ? objc_getAssociatedObject(selected, &kMFRingBundleIdKey) : nil;
        if ([bundleId isKindOfClass:[NSString class]] && bundleId.length > 0) {
            MFLog(@"[ring] 手指离开屏幕 -> 打开 %@ 浮窗", bundleId);
            [self hide];
            [self openFloatWithBundleId:bundleId];
        } else {
            MFLog(@"[ring] 手指离开屏幕 -> 未选中，收起圆盘");
            [self hide];
        }
        return;
    }
}

#pragma mark 展开 / 收起

- (void)showAtPoint:(CGPoint)point {
    [self showRingWithAnchor:point latch:NO];
}

/// 展开圆盘。anchor = 圆盘初始圆心（= 手指位置）；latch = 是否立即固定到停靠点
- (void)showRingWithAnchor:(CGPoint)point latch:(BOOL)latch {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showRingWithAnchor:point latch:latch]; });
        return;
    }
    if (self.window == nil) {
        MFLog(@"[ring] 尚未安装，忽略呼出");
        return;
    }
    if (self.expanded) {
        return;
    }
    CGRect screen = [UIScreen mainScreen].bounds;
    if (CGRectIsEmpty(screen)) {
        return;
    }
    @try {
        self.expanded = YES;
        self.ringLatched = NO;
        self.selectedButton = nil;
        self.hasLatchFinger = NO;
        self.settleGeneration += 1;
        self.window.frame = screen;

        UIView *container = [[UIView alloc] initWithFrame:self.window.bounds];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];   // 轻遮罩
        container.userInteractionEnabled = YES;
        [container addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(onBackdropTap:)]];
        [self.window addSubview:container];
        self.container = container;

        // 停靠点 = 屏幕下半屏中心（用户 0.1.6 指定，不再用屏幕正中心）
        CGFloat ratio = MIN(MAX(MFRingNumber(@"mfRingParkRatioY", 0.72), 0.5), 0.92);
        self.parkCenter = [self clampRingCenter:CGPointMake(CGRectGetMidX(screen),
                                                            CGRectGetHeight(screen) * ratio)];

        [self buildRingInContainer:container];

        CGPoint anchor = [self clampRingCenter:point];
        self.ringRoot.center = anchor;

        container.alpha = 0.0;
        [UIView animateWithDuration:0.15 animations:^{
            container.alpha = 1.0;
        }];

        MFLog(@"[ring] 手势呼出圆盘：跟随手指起点(%.0f,%.0f) -> 停靠点(%.0f,%.0f) | %lu 个 App 半径 %.0f 图标 %.0f",
              anchor.x, anchor.y, self.parkCenter.x, self.parkCenter.y,
              (unsigned long)self.iconButtons.count,
              MAX(60.0, MFRingNumber(@"mfRingRadius", 150.0)),
              MAX(24.0, MFRingNumber(@"mfRingIconSize", 44.0)));
        if (latch) {
            [self latchToParkAnimated:NO];
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 展开异常：%@", exception);
        [self hide];
    }
}

- (void)hide {
    if (!self.expanded) {
        return;
    }
    UIView *container = self.container;
    self.container = nil;
    self.dialLayer = nil;
    self.ringRoot = nil;
    self.selectedButton = nil;
    self.ringLatched = NO;
    self.hasLatchFinger = NO;
    self.settleGeneration += 1;
    self.expanded = NO;
    [self.iconButtons removeAllObjects];

    void (^finish)(void) = ^{
        [container removeFromSuperview];
        if (self.window != nil) {
            self.window.frame = [self triggerFrameForScreen:[UIScreen mainScreen].bounds];
        }
    };
    if (container == nil) {
        finish();
        return;
    }
    [UIView animateWithDuration:0.15 animations:^{
        container.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        finish();
    }];
    MFLog(@"[ring] 圆盘已收起（贴边手势恢复）");
}

- (void)onBackdropTap:(UITapGestureRecognizer *)gesture {
    MFLog(@"[ring] 点空白 -> 收起圆盘");
    [self hide];
}

#pragma mark 跟随 / 停靠

- (void)moveRingToPoint:(CGPoint)point {
    if (self.ringRoot == nil) {
        return;
    }
    CGPoint center = [self clampRingCenter:point];
    self.ringRoot.center = center;
}

/// 手指停住一小会儿就把圆盘固定到停靠点（用户自然会在停靠点附近有个停顿）
- (void)scheduleSettle {
    self.settleGeneration += 1;
    NSUInteger generation = self.settleGeneration;
    NSTimeInterval delay = MAX(0.05, MFRingNumber(@"mfRingSettleDelay", 0.18));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.settleGeneration) {
            return;
        }
        if (!self.expanded || self.ringLatched) {
            return;
        }
        [self latchToParkAnimated:YES];
    });
}

/// 固定到下半屏中心 —— 之后手指滑动只改变"选中"，圆盘不再跟着动
- (void)latchToParkAnimated:(BOOL)animated {
    if (self.ringRoot == nil || self.ringLatched) {
        return;
    }
    self.ringLatched = YES;
    self.settleGeneration += 1;
    // 记录"固定那一刻手指在哪"：手指还没动之前不产生选中，避免刚停靠就误开某个 App
    self.latchFingerPoint = self.lastFingerPoint;
    self.hasLatchFinger = YES;
    CGPoint park = self.parkCenter;
    if (animated) {
        [UIView animateWithDuration:0.16
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:^{
            self.ringRoot.center = park;
        } completion:nil];
    } else {
        self.ringRoot.center = park;
    }
    MFLog(@"[ring] 圆盘已固定到下半屏中心 (%.0f, %.0f) —— 滑动到图标上选择，松手即打开", park.x, park.y);
}

#pragma mark 圆盘构建

- (void)buildRingInContainer:(UIView *)container {
    CGFloat radius = MAX(60.0, MFRingNumber(@"mfRingRadius", 150.0));
    CGFloat iconSize = MAX(24.0, MFRingNumber(@"mfRingIconSize", 44.0));
    CGFloat rotation = MFRingNumber(@"mfRingRotation", 0.0);
    CGFloat extent = radius + iconSize * 0.5 + 10.0;   // 圆盘视图半边长（含图标外沿余量）

    // 圆盘整体放在一个固定尺寸的容器里 —— 移动圆盘 = 改 ringRoot.center
    UIView *ringRoot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, extent * 2.0, extent * 2.0)];
    ringRoot.backgroundColor = [UIColor clearColor];
    ringRoot.userInteractionEnabled = YES;
    ringRoot.tag = 991002;
    [container addSubview:ringRoot];
    self.ringRoot = ringRoot;

    // 完整圆形底盘（0.1.4 及以前是半圆；0.1.5 起整圆）
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:
                          CGRectMake(extent - radius, extent - radius, radius * 2.0, radius * 2.0)];
    CAShapeLayer *dial = [CAShapeLayer layer];
    dial.path = path.CGPath;
    dial.fillColor = [UIColor colorWithWhite:0.12 alpha:0.55].CGColor;
    dial.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    dial.lineWidth = 1.0;
    [ringRoot.layer addSublayer:dial];
    self.dialLayer = dial;

    NSArray<NSString *> *bundleIds = MFRingBundleIds();
    NSUInteger count = bundleIds.count;
    if (count == 0) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, radius * 1.4, 60.0)];
        hint.numberOfLines = 0;
        hint.textAlignment = NSTextAlignmentCenter;
        hint.text = @"圆盘里还没有 App\n编辑 com.mlgm.pulloverx.plist 的 ringApps（bundleID 数组）即可添加";
        hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        hint.font = [UIFont systemFontOfSize:12.0];
        hint.center = CGPointMake(extent, extent);
        [ringRoot addSubview:hint];
        return;
    }

    // 图标放在圆周内侧一圈
    CGFloat iconRadius = MAX(iconSize, radius - iconSize * 0.5 - 6.0);
    CGFloat startAngle = MFRingNumber(@"mfRingStartAngle", -90.0);   // 默认从正上方开始
    CGPoint localCenter = CGPointMake(extent, extent);
    for (NSUInteger index = 0; index < count; index++) {
        NSString *bundleId = bundleIds[index];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.bounds = CGRectMake(0.0, 0.0, iconSize, iconSize);
        button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        button.layer.cornerRadius = iconSize / 2.0;
        button.layer.masksToBounds = YES;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        UIImage *icon = [POApplicationHelper imageForBundleId:bundleId];
        if (icon == nil) {
            icon = [POApplicationHelper iconImageForIdentifier:bundleId];
        }
        if (icon != nil) {
            [button setImage:icon forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFill;
        } else {
            NSString *initial = (bundleId.length > 0)
                ? [[bundleId lastPathComponent] substringToIndex:1].uppercaseString : @"?";
            [button setTitle:initial forState:UIControlStateNormal];
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont boldSystemFontOfSize:iconSize * 0.4];
        }

        objc_setAssociatedObject(button, &kMFRingBundleIdKey, bundleId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addTarget:self action:@selector(onIconTapped:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(onIconLongPressed:)];
        longPress.minimumPressDuration = 0.5;
        [button addGestureRecognizer:longPress];

        // 沿整圈均匀铺开
        CGFloat angleDegrees = startAngle
            + 360.0 * (CGFloat)index / (CGFloat)MAX((NSUInteger)1, count)
            + rotation;
        CGFloat angle = angleDegrees * M_PI / 180.0;
        button.center = CGPointMake(localCenter.x + iconRadius * cos(angle),
                                   localCenter.y + iconRadius * sin(angle));

        [ringRoot addSubview:button];
        [self.iconButtons addObject:button];
    }
}

#pragma mark 悬停选择

- (void)updateSelectionForPoint:(CGPoint)point {
    UIView *container = self.container;
    if (container == nil || self.iconButtons.count == 0) {
        return;
    }
    // 刚固定时手指还停在原地 —— 必须真的滑动一下才算"选择"（防误开）
    if (self.hasLatchFinger &&
        hypot(point.x - self.latchFingerPoint.x, point.y - self.latchFingerPoint.y) < 22.0) {
        [self setSelectedButton:nil];
        return;
    }
    CGFloat iconSize = MAX(24.0, MFRingNumber(@"mfRingIconSize", 44.0));
    CGFloat hitRadius = MAX(30.0, iconSize * 0.85 + 10.0);

    UIButton *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (UIButton *button in self.iconButtons) {
        if (button.superview == nil) {
            continue;
        }
        CGPoint center = [button.superview convertPoint:button.center toView:container];
        CGFloat distance = hypot(center.x - point.x, center.y - point.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = button;
        }
    }
    if (bestDistance > hitRadius) {
        best = nil;
    }
    if (best == self.selectedButton) {
        return;
    }
    [self setSelectedButton:best];
}

- (void)setSelectedButton:(UIButton *)button {
    UIButton *previous = self.selectedButton;
    self.selectedButton = button;
    if (previous != nil && previous != button) {
        [self applySelectionVisual:previous selected:NO];
    }
    if (button != nil) {
        [self applySelectionVisual:button selected:YES];
        NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
        MFLog(@"[ring] 悬停选中 %@", bundleId ?: @"?");
    } else if (previous != nil) {
        MFLog(@"[ring] 悬停离开（当前无选中）");
    }
}

- (void)applySelectionVisual:(UIButton *)button selected:(BOOL)selected {
    if (button == nil) {
        return;
    }
    [UIView animateWithDuration:0.12 animations:^{
        button.transform = selected ? CGAffineTransformMakeScale(1.18, 1.18) : CGAffineTransformIdentity;
        button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:selected ? 0.42 : 0.14];
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:selected ? 0.95 : 0.35].CGColor;
    }];
}

#pragma mark 图标交互

- (void)onIconTapped:(UIButton *)button {
    NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
    MFLog(@"[ring] 直接点击 %@ -> 打开浮窗", bundleId ?: @"(nil)");
    if (bundleId.length == 0) {
        [self hide];
        return;
    }
    [self hide];
    [self openFloatWithBundleId:bundleId];
}

- (void)onIconLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    NSString *bundleId = objc_getAssociatedObject(gesture.view, &kMFRingBundleIdKey);
    if (bundleId.length == 0) {
        return;
    }
    // 以"当前显示集"为基准物化，再移除 —— 保证默认列表（最近使用）里的项也能真正移出
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSString *item in MFRingBundleIds()) {
        if (![item isEqualToString:bundleId] && ![ids containsObject:item]) {
            [ids addObject:item];
        }
    }
    MFRingWriteBundleIds(ids);
    MFLog(@"[ring] 长按移出 %@ -> 剩 %lu 项", bundleId, (unsigned long)ids.count);

    // 原地重建，并直接停靠在下半屏中心
    CGPoint park = self.parkCenter;
    [self hide];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self showRingWithAnchor:park latch:YES];
    });
}

#pragma mark 打开浮窗

- (void)openFloatWithBundleId:(NSString *)bundleId {
    @try {
        id sharedWindow = [POXWindow sharedWindow];
        if (![sharedWindow isKindOfClass:[UIWindow class]]) {
            MFLog(@"[ring] !! 浮窗窗口不存在，无法打开 %@", bundleId);
            return;
        }
        PullOverViewController *controller = [(POXWindow *)sharedWindow controller];
        if (controller == nil) {
            MFLog(@"[ring] !! 找不到 PullOver 控制器，无法打开浮窗");
            return;
        }
        SEL pinSelector = NSSelectorFromString(@"pinAppWithBundleId:");
        if ([controller respondsToSelector:pinSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, pinSelector, bundleId);
            MFLog(@"[ring] 已 pin App：%@", bundleId);
        } else {
            MFLog(@"[ring] !! 控制器不支持 pinAppWithBundleId:");
        }
        SEL openSelector = NSSelectorFromString(@"open");
        if ([controller respondsToSelector:openSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, openSelector);
            MFLog(@"[ring] 已请求打开浮窗");
        } else {
            MFLog(@"[ring] !! 控制器不支持 open");
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 打开浮窗异常：%@", exception);
    }
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

#pragma mark - 安装入口

/// 由 PullOverX.mm 的 constructor 延迟调用（避免在 SpringBoard 极早期碰 UIKit）
void MFRingPickerInstall(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MFRingPickerInstall(); });
        return;
    }
    @try {
        [[MFRingPicker shared] install];
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! MFRingPickerInstall 异常：%@", exception);
    }
}
