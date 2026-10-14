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
//  本实现（第一阶段，零 hook，确保不卡开机）：
//    · 圆盘：贴边半圆盘（圆心在屏幕边缘中点），图标沿弧排布，点图标→浮窗打开该 App；
//    · 呼出：屏幕边缘一条透明触发区，**向内滑动 / 向下滑动 / 单击**都能呼出；
//    · 可自定义：配置键 ringApps（bundleID 数组），未配置时用最近使用的 App；
//      圆盘内长按图标即可移出（写回配置，立即生效）。
//    · 全程 MFLog 记录（含触摸来源窗口类名），用来验证「前台 App 上边缘区能否收到触摸」——
//      若日志证实收不到，下一步再照 Stheno 加**单个**系统手势 hook（用户已授权：前期不要多个 hook）。
//
//  配置项（suite com.mlgm.pulloverx，改完 respring 生效）：
//    mfRingEnabled     BOOL   是否启用圆盘（默认 YES）
//    mfTriggerEdge     string 触发边：right(默认) / left / top / bottom
//    mfTriggerLength   number 触发区长度（默认 380）
//    mfTriggerThickness number 触发区厚度（默认 56）
//    mfRingRadius      number 圆盘半径（默认 150）
//    mfRingIconSize    number 图标尺寸（默认 44；0.1.5 起从 56 缩小）
//    mfRingEdgeMargin  number 圆盘外沿距屏幕边的间距（默认 12；圆心会内缩 radius+margin 保证整圆可见）
//    mfRingRotation    number 图标整体旋转角，度（默认 0）
//    mfRingStartAngle  number 第一个图标的角度，度（默认 -90 = 正上方）
//    mfRingMaxIcons    number 未配置时最多显示几个（默认 8）
//    ringApps          array  bundleID 数组（自定义圆盘内容）
//
//  版本备注：0.1.4 及以前圆心放在**屏幕边缘** → 圆有一半在屏幕外（用户反馈"只有半圆显示"）；
//  0.1.5 起圆心内缩（screenWidth - radius - edgeMargin），**整圆完整显示在屏幕内**，图标绕整圈排布。
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
@property (nonatomic, strong) UIView *container;        // 展开态的根视图（含遮罩 + 圆盘）
@property (nonatomic, strong) CAShapeLayer *dialLayer;  // 半圆盘背景
@property (nonatomic, strong) NSMutableArray<UIButton *> *iconButtons;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) CGPoint dialCenter;
+ (instancetype)shared;
- (void)install;
- (void)show;
- (void)hide;
- (void)toggle;
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

        // ---- 收起态：屏幕边缘一条透明触发区 ----
        CGRect trigger = [self triggerFrameForScreen:screen];
        window.frame = trigger;

        UIView *triggerView = [[UIView alloc] initWithFrame:window.bounds];
        triggerView.backgroundColor = [UIColor clearColor];
        triggerView.userInteractionEnabled = YES;
        triggerView.tag = 991001;
        [window addSubview:triggerView];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onTriggerPan:)];
        pan.delegate = self;
        [triggerView addGestureRecognizer:pan];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onTriggerTap:)];
        tap.delegate = self;
        [triggerView addGestureRecognizer:tap];
        [tap requireGestureRecognizerToFail:pan];

        MFLog(@"[ring] 圆盘选择器已安装：触发边=%@，触发区=%@，窗口 scene=%@",
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

#pragma mark 触发

- (void)onTriggerTap:(UITapGestureRecognizer *)gesture {
    MFLog(@"[ring] 触发区单击 -> 呼出圆盘");
    [self show];
}

- (void)onTriggerPan:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (view == nil) {
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[ring] 触发区按下 来源=%@(tag=%ld)",
              NSStringFromClass([view.window class]), (long)view.tag);
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:view];
        MFLog(@"[ring] 触发区滑动 dx=%.0f dy=%.0f", translation.x, translation.y);
        // 任意方向滑出 18pt 即呼出（Stheno 是"边缘下拉"，这里放宽为"边缘滑动")
        if (fabs(translation.x) > 18.0 || fabs(translation.y) > 18.0) {
            [self show];
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        MFLog(@"[ring] 触发区松手（未达到阈值）");
    }
}

#pragma mark 展开 / 收起

- (void)toggle {
    if (self.expanded) {
        [self hide];
    } else {
        [self show];
    }
}

- (void)show {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self show]; });
        return;
    }
    if (self.window == nil) {
        MFLog(@"[ring] 尚未安装，忽略呼出");
        return;
    }
    if (self.expanded) {
        return;
    }
    @try {
        CGRect screen = [UIScreen mainScreen].bounds;
        self.expanded = YES;
        self.window.frame = screen;

        UIView *container = [[UIView alloc] initWithFrame:self.window.bounds];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];   // 轻遮罩
        container.userInteractionEnabled = YES;
        [container addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(onBackdropTap:)]];
        [self.window addSubview:container];
        self.container = container;

        [self layoutDialInContainer:container];

        container.alpha = 0.0;
        [UIView animateWithDuration:0.18 animations:^{
            container.alpha = 1.0;
        }];

        MFLog(@"[ring] 圆盘已展开：%@ 个 App（完整圆，半径 %.0f，图标 %.0f，边=%@）",
              @([self.iconButtons count]), MFRingNumber(@"mfRingRadius", 150.0),
              MFRingNumber(@"mfRingIconSize", 44.0), MFRingEdge());
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
    self.expanded = NO;
    [self.iconButtons removeAllObjects];

    void (^finish)(void) = ^{
        [container removeFromSuperview];
        if (self.window != nil) {
            CGRect screen = [UIScreen mainScreen].bounds;
            self.window.frame = [self triggerFrameForScreen:screen];
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
    MFLog(@"[ring] 圆盘已收起（触发区恢复）");
}

- (void)onBackdropTap:(UITapGestureRecognizer *)gesture {
    MFLog(@"[ring] 点空白 -> 收起圆盘");
    [self hide];
}

#pragma mark 圆盘绘制

- (void)layoutDialInContainer:(UIView *)container {
    CGRect bounds = container.bounds;
    CGFloat screenWidth = CGRectGetWidth(bounds);
    CGFloat screenHeight = CGRectGetHeight(bounds);
    CGFloat radius = MAX(60.0, MFRingNumber(@"mfRingRadius", 150.0));
    // 【0.1.5】图标默认缩小：56 -> 44（用户反馈图标偏大）
    CGFloat iconSize = MAX(24.0, MFRingNumber(@"mfRingIconSize", 44.0));
    CGFloat rotation = MFRingNumber(@"mfRingRotation", 0.0);
    CGFloat edgeMargin = MAX(0.0, MFRingNumber(@"mfRingEdgeMargin", 12.0));
    BOOL fromRight = ![MFRingEdge() isEqualToString:@"left"];

    // 【0.1.5 修复】圆心必须**移进屏幕内**，否则整圆有一半在屏幕外（0.1.4 就是这个问题）。
    //   圆心 x = 屏幕内缩 (半径 + 边距) -> 圆的外沿距屏幕边 edgeMargin，整圆完整可见。
    CGFloat centerX = fromRight ? (screenWidth - edgeMargin - radius) : (edgeMargin + radius);
    CGPoint center = CGPointMake(centerX, screenHeight / 2.0);
    self.dialCenter = center;

    // 完整圆形背景（不再是半圆）
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:
                          CGRectMake(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0)];

    CAShapeLayer *dial = [CAShapeLayer layer];
    dial.path = path.CGPath;
    dial.fillColor = [UIColor colorWithWhite:0.12 alpha:0.55].CGColor;
    dial.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    dial.lineWidth = 1.0;
    [container.layer addSublayer:dial];
    self.dialLayer = dial;

    // 图标沿弧排布（半圆内圈，留出半径余量）
    NSArray<NSString *> *bundleIds = MFRingBundleIds();
    NSUInteger count = bundleIds.count;
    if (count == 0) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, radius * 1.4, 60.0)];
        hint.numberOfLines = 0;
        hint.textAlignment = NSTextAlignmentCenter;
        hint.text = @"圆盘里还没有 App\n编辑 com.mlgm.pulloverx.plist 的 ringApps（bundleID 数组）即可添加";
        hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        hint.font = [UIFont systemFontOfSize:12.0];
        hint.center = center;
        [container addSubview:hint];
        return;
    }

    // 图标放在圆内侧一圈（外沿贴近圆周，不越出圆盘）
    CGFloat iconRadius = MAX(iconSize, radius - iconSize * 0.5 - 6.0);
    CGFloat startAngle = MFRingNumber(@"mfRingStartAngle", -90.0);   // 默认从正上方开始
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
            NSString *initial = (bundleId.length > 0) ? [[bundleId lastPathComponent] substringToIndex:1].uppercaseString : @"?";
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

        // 【0.1.5】沿**整圈**均匀铺开（圆已完整显示，图标绕整圈排布）。
        // 0.1.3/0.1.4 是半圆排布（那个版本圆心在屏幕边缘）。
        CGFloat angleDegrees = startAngle
            + 360.0 * (CGFloat)index / (CGFloat)MAX((NSUInteger)1, count)
            + rotation;
        CGFloat angle = angleDegrees * M_PI / 180.0;
        CGFloat x = center.x + iconRadius * cos(angle);
        CGFloat y = center.y + iconRadius * sin(angle);
        button.center = CGPointMake(x, y);

        [container addSubview:button];
        [self.iconButtons addObject:button];
    }
}

#pragma mark 图标交互

- (void)onIconTapped:(UIButton *)button {
    NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
    MFLog(@"[ring] 选中 %@ -> 打开浮窗", bundleId ?: @"(nil)");
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

    // 原地重建圆盘
    [self hide];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self show]; });
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
