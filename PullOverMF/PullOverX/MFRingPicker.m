//
//  MFRingPicker.m
//  PullOverMF —— Stheno 风格「圆盘」呼出选择器（本 fork 新增）
//
//  ============================ 0.1.9 核心改动 ============================
//  **不再自建 UIWindow。** 圆盘与触发条改挂到 PullOver 自己那扇窗口（POXWindow）。
//
//  证据链（三轮失败的共同点）：
//    · 0.1.5（可用）真机日志：`触发区按下` → 40ms 后 `圆盘已展开：5 个 App`，
//      反复十几次都正常，还在全屏「设置」之上呼出过。
//    · 0.1.6 / 0.1.7 / 0.1.8 三版日志：`贴边按下` 之后**再也没有任何圆盘日志**，
//      0.4~2.4 秒后出现新的 `===== 日志会话开始 =====` ⇒ SpringBoard 被硬重启
//      （没有 NSException、不进安全模式）。日志是无缓冲写入，最后一条一定在盘上。
//    · 把 0.1.5 → 0.1.6 逐行 diff：按下之后我们执行的代码只多了"读手指坐标 + 几个
//      属性赋值"这种纯读操作，**不可能**崩；0.1.7/0.1.8 更是把整个展开步骤都拆成
//      了 `>>> / <<<` 日志，而日志连第一行都没打出来 ⇒ 崩溃发生在进入展开逻辑之前。
//    ⇒ 结论：不是"哪一行写错"，而是**我们那扇自己造的窗口在抢屏幕边缘触摸**这件事
//      本身触发了 SpringBoard 侧的中止。PullOver 上游那套窗口模型（level 100、
//      全屏、hitTest 交给控制器）在真机上被反复验证可用——手柄就是靠它工作的。
//
//  Stheno 的实证正好同向：**它也不自己造窗口**，而是把 UI 挂到系统既有的
//  UIStatusBarWindow 上（字符串实证 UIStatusBarWindowHook / setWindowLevel: /
//  hitTest:withEvent: / ownsHomeGesture）。结论一致：宿主用既有的，别造新的。
//
//  新的触摸路径（完全复用 PullOver 已验证的一条）：
//    POXWindow.hitTest:
//      → MFRingHitTestViewForWindowPoint()
//          ├─ 圆盘展开态 → 返回容器里最深的那层（图标按钮可直接点）或容器本身
//          ├─ 收起态、点落在贴边触发条内、且不在 PullOver 手柄上 → 返回 stripView
//          └─ 其余 → nil（原样交回 PullOver 控制器，既有行为零改变）
//    触发条是一个**窗口子视图**，挂 UIPanGestureRecognizer（与 POHandle 同款做法）。
//
//  为什么不会和 PullOver 手柄打架：手柄是个方形小把件（`refreshHandleSizeAnimated:`
//  里 frame.size 被做成正方形，默认约 50x50pt 命中区），命中它时我们把这次触摸
//  **原样让给 PullOver**（与上游 `interactiveViewForWindowPoint:` 里的判定完全一致）。
//
//  ======================================================================
//
//  设计依据（逆向自 Stheno 0.1.23，com.nx.stheno）：
//    · 圆盘本体：RingView / RingShape / RingType；文案 'RTSIF'=圆盘 / 'RTSIH'=半圆盘
//      几何键：Radius / IconWidth / RotationAngle / LastIconAngle / DampingFraction
//    · 圆盘内容：Stheno 走**应用搜索器**（遍历已安装 App），**不是**翻多任务切换器模型
//    · 呼出方式：Stheno 走"系统手势 hook + 既有宿主窗口"，所以全屏 App 之上也能呼出
//
//  交互（沿用 0.1.6 用户指定的形态）：
//    ① 贴边手势呼出后圆盘**跟随手指**；
//    ② 手指停住 / 靠近停靠点 → 圆盘**固定到屏幕下半屏中心**；
//    ③ 手指滑动 → 高亮离手指最近的图标（悬停选择）；
//    ④ **手指离开屏幕** → 收起圆盘；已选中 App → 立即以浮窗打开。
//
//  铁律（继续保持）：
//    · 触摸路径零 SpringBoard 查询：圆盘内容只读配置 / 进程内缓存；
//    · 真图标延后贴（圆盘先出来，图标随后补），每个图标 `>>> 取图标` / `<<<`；
//    · 崩溃自解除闸门 `/var/mobile/PullOverMF.ringguard`：危险动作前立、走完且存活才撤；
//      下次启动若发现标记还在 ⇒ 自动**降级模式**（不枚举不抓图标），删文件可重试；
//    · 全程 `>>> 步骤` / `<<< 步骤 ok`，万一还出问题，日志最后一行直接点名。
//
//  配置项（suite com.mlgm.pulloverx，改完 respring 生效）：
//    mfRingEnabled      BOOL   是否启用圆盘（默认 YES）
//    mfTriggerEdge      string 触发边：right(默认) / left / top / bottom
//    mfTriggerLength    number 触发区长度（默认 300）
//    mfTriggerThickness number 触发区厚度（默认 56）
//    mfTriggerCenterRatio number 触发区中心位置 0~1（默认 0.78）
//    mfTriggerBottomInset number 触发区距屏幕底边最少留白（默认 44）
//    mfRingSummonThreshold number 手势呼出阈值，pt（默认 18）
//    mfRingRadius       number 圆盘半径（默认 150）
//    mfRingIconSize     number 图标尺寸（默认 44）
//    mfRingEdgeMargin   number 圆盘外沿距屏幕边的间距（默认 12）
//    mfRingRotation     number 图标整体旋转角，度（默认 0）
//    mfRingStartAngle   number 第一个图标的角度，度（默认 -90 = 正上方）
//    mfRingParkRatioY   number 停靠点纵向比例（默认 0.72 = 下半屏中心）
//    mfRingLatchTolerance number 手指靠近停靠点多少 pt 即固定（默认 72）
//    mfRingSettleDelay  number 手指停住多久自动固定，秒（默认 0.18）
//    mfRingMaxIcons     number 圆盘最多显示几个（默认 8，上限 12）
//    mfRingFetchIcons   BOOL   是否抓取真图标（默认 YES；关掉就只用首字母）
//    ringApps           array  bundleID 数组（**你自己指定圆盘内容，最优先**）
//    ringAppsAuto       array  自动枚举出的 App 列表（本 fork 自己维护，别手改）
//
//  版本备注：0.1.4 及以前圆心在屏幕边缘（半圆出屏）；0.1.5 整圆可见；0.1.6 交互重做；
//  0.1.7 全屏窗口 + hitTest 点透；0.1.8 触摸路径零 SB 查询 + 图标延后 + 崩溃降级；
//  **0.1.9 删掉自建窗口，改挂 PullOver 既有窗口（POXWindow）—— 本轮修复一滑就注销**。
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "POXWindow.h"
#import "PullOverViewController.h"
#import "POHandle.h"
#import "POApplicationHelper.h"

#define MF_RING_GUARD_PATH   "/var/mobile/PullOverMF.ringguard"

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

/// 数值兜底：任何 NaN/Inf 都不允许进入几何计算（NaN frame = 渲染服务器直接带走进程）
static CGFloat MFRingSafe(CGFloat value, CGFloat fallback) {
    return isfinite(value) ? value : fallback;
}

#pragma mark - 崩溃自解除闸门（纯 C 文件 IO）

/// 危险动作（枚举 App / 抓图标）执行前立标记；动作**走完并存活**才撤。
/// 下次启动若发现标记还在 ⇒ 上回就是被这一步带走的 ⇒ 进入降级模式，绝不死循环。
static BOOL MFRingGuardArmed(void) {
    FILE *file = fopen(MF_RING_GUARD_PATH, "rb");
    if (file == NULL) {
        return NO;
    }
    fclose(file);
    return YES;
}

static void MFRingGuardArm(void) {
    FILE *file = fopen(MF_RING_GUARD_PATH, "wb");
    if (file != NULL) {
        fputs("1\n", file);
        fclose(file);
    }
}

static void MFRingGuardDisarm(void) {
    remove(MF_RING_GUARD_PATH);
}

#pragma mark - 进程内状态

static NSArray<NSString *> *gMFRingAutoBundleIds = nil;   // 自动枚举结果（进程内缓存）
static BOOL gMFRingListing = NO;                          // 枚举进行中
static NSUInteger gMFRingListGeneration = 0;              // 枚举代次
static BOOL gMFRingDegraded = NO;                         // 降级模式（上回被危险动作带走过）

#pragma mark - bundleID 校验

/// 是否是"可以喂给图标系统"的 bundleID。
/// ⚠️ SB 的最近使用列表里混有 SBDisplayItem 标识符（形如 "com.tencent.xin:default"）与
///    非 App 的字符串；把它们交给 SBIconModel / IconServices 会硬崩 SpringBoard。
static BOOL MFRingIsUsableBundleId(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *bundleId = (NSString *)value;
    if (bundleId.length == 0 || bundleId.length > 160) {
        return NO;
    }
    if ([bundleId rangeOfString:@":"].location != NSNotFound) {
        return NO;   // SBDisplayItem: "bundle:role"
    }
    if ([bundleId rangeOfString:@" "].location != NSNotFound) {
        return NO;
    }
    if ([bundleId rangeOfString:@"/"].location != NSNotFound) {
        return NO;
    }
    if ([bundleId rangeOfString:@"\n"].location != NSNotFound) {
        return NO;
    }
    return YES;
}

/// 过滤 + 去重（纯字符串处理，不查 SB）
static NSArray<NSString *> *MFRingFilterBundleIds(id raw, NSUInteger limit) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) {
        return ids;
    }
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *bundleId = (NSString *)item;
        if (!MFRingIsUsableBundleId(bundleId) || [ids containsObject:bundleId]) {
            continue;
        }
        if (limit > 0 && ids.count >= limit) {
            break;
        }
        [ids addObject:bundleId];
    }
    return ids;
}

#pragma mark - 已安装 App 的安全枚举

/// 取对象上的一个字符串属性的第一个可用值（全部包 @try）
static NSString *MFRingStringProperty(id object, NSArray<NSString *> *selectorNames) {
    if (object == nil) {
        return nil;
    }
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return (NSString *)value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

/// 取对象上的一个数组属性的第一个可用值（全部包 @try）
static NSArray *MFRingArrayProperty(id object, NSArray<NSString *> *selectorNames) {
    if (object == nil) {
        return nil;
    }
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
                return (NSArray *)value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

/// 安全枚举已安装 App：**只做扁平遍历**，逐个读 bundleIdentifier。
/// 绝不对多任务切换器对象图做 KVC 递归遍历（那是 0.1.6 崩溃的嫌疑路径）。
static NSArray<NSString *> *MFRingEnumerateInstalledBundleIds(NSUInteger limit) {
    NSArray *candidates = nil;

    // 主路径：SBApplicationController（SpringBoard 自己的 App 注册表）
    @try {
        Class controllerClass = NSClassFromString(@"SBApplicationController");
        id controller = nil;
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        if (controllerClass && [controllerClass respondsToSelector:sharedSelector]) {
            controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
        }
        candidates = MFRingArrayProperty(controller, @[ @"allApplications", @"applications" ]);
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! SBApplicationController 枚举异常：%@", exception);
        candidates = nil;
    }

    // 备路径：LSApplicationWorkspace（LaunchServices）
    if (candidates.count == 0) {
        @try {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            id workspace = nil;
            SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
            if (workspaceClass && [workspaceClass respondsToSelector:defaultSelector]) {
                workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
            }
            candidates = MFRingArrayProperty(workspace, @[ @"allInstalledApplications", @"allApplications" ]);
        } @catch (NSException *exception) {
            MFLog(@"[ring] !! LSApplicationWorkspace 枚举异常：%@", exception);
            candidates = nil;
        }
    }

    MFLog(@"[ring] <<< 枚举原始对象 %lu 个", (unsigned long)candidates.count);

    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id application in candidates) {
        if (limit > 0 && ids.count >= limit) {
            break;
        }
        @try {
            NSString *bundleId = MFRingStringProperty(application,
                @[ @"bundleIdentifier", @"displayIdentifier", @"applicationIdentifier" ]);
            if (!MFRingIsUsableBundleId(bundleId) || [ids containsObject:bundleId]) {
                continue;
            }
            [ids addObject:bundleId];
        } @catch (__unused NSException *exception) {
        }
    }
    return ids;
}

#pragma mark - 圆盘内容（触摸路径上只读缓存，绝不查 SB）

/// 你手动指定的圆盘内容（配置 ringApps）—— 纯字符串过滤，不查 SB
static NSArray<NSString *> *MFRingConfiguredBundleIds(void) {
    return MFRingFilterBundleIds([MFRingDefaults() arrayForKey:@"ringApps"], 0);
}

/// 圆盘最终内容：**配置 > 自动枚举缓存 > 空**。只读内存 / NSUserDefaults。
static NSArray<NSString *> *MFRingBundleIds(void) {
    NSArray<NSString *> *configured = MFRingConfiguredBundleIds();
    NSUInteger limit = (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingMaxIcons", 8), 1.0), 12.0);
    if (configured.count > 0) {
        if (configured.count > limit) {
            return [configured subarrayWithRange:NSMakeRange(0, limit)];
        }
        return configured;
    }
    if (gMFRingAutoBundleIds.count > 0) {
        if (gMFRingAutoBundleIds.count > limit) {
            return [gMFRingAutoBundleIds subarrayWithRange:NSMakeRange(0, limit)];
        }
        return gMFRingAutoBundleIds;
    }
    return @[];
}

/// 把自动枚举结果固化：进程内缓存 + 落盘到 ringAppsAuto（下次启动免枚举）
static void MFRingStoreAutoBundleIds(NSArray<NSString *> *ids) {
    gMFRingAutoBundleIds = [ids copy];
    NSUserDefaults *defaults = MFRingDefaults();
    [defaults setObject:ids ?: @[] forKey:@"ringAppsAuto"];
    MFLog(@"[ring] ringAppsAuto 已保存 %lu 项", (unsigned long)ids.count);
}

static void MFRingWriteBundleIds(NSArray<NSString *> *ids) {
    NSUserDefaults *defaults = MFRingDefaults();
    [defaults setObject:ids ?: @[] forKey:@"ringApps"];
    MFLog(@"[ring] ringApps 已保存 %lu 项", (unsigned long)ids.count);
}

#pragma mark - 图标缓存

/// 图标缓存（进程内；respring 后重建）。减少对 SBIconModel / IconServices 的重复调用。
static NSMutableDictionary<NSString *, UIImage *> *MFRingIconCache(void) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

/// 取图标。调用方负责日志与闸门；这里只保证"不合法一律不查、异常一律降级为 nil"。
static UIImage *MFRingIconForBundleId(NSString *bundleId) {
    if (!MFRingIsUsableBundleId(bundleId)) {
        return nil;
    }
    UIImage *cached = MFRingIconCache()[bundleId];
    if (cached != nil) {
        return cached;
    }
    UIImage *icon = nil;
    @try {
        icon = [POApplicationHelper imageForBundleId:bundleId];
    } @catch (NSException *exception) {
        icon = nil;
    }
    if (icon != nil) {
        MFRingIconCache()[bundleId] = icon;
    }
    return icon;
}

#pragma mark - 圆盘选择器

@interface MFRingPicker : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *hostWindow;              // 宿主：PullOver 自己的窗口
@property (nonatomic, weak) PullOverViewController *hostController;
@property (nonatomic, strong) UIView *stripView;               // 贴边透明触发条（窗口子视图）
@property (nonatomic, strong) UIPanGestureRecognizer *stripPan;
@property (nonatomic, assign) CGRect hostBounds;               // 宿主窗口尺寸（变化时重建几何）
@property (nonatomic, assign) CGRect triggerFrame;             // 触发区（窗口坐标）
@property (nonatomic, strong) UIView *container;               // 展开态根视图（轻遮罩 + 圆盘）
@property (nonatomic, strong) UIView *ringRoot;                // 圆盘整体（移动它 = 移动圆盘）
@property (nonatomic, strong) CAShapeLayer *dialLayer;         // 圆形底盘
@property (nonatomic, strong) NSMutableArray<UIButton *> *iconButtons;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) NSUInteger buildGeneration;      // 构建代次（作废过期回调）
@property (nonatomic, assign) BOOL ringLatched;                // 圆盘是否已固定在停靠点
@property (nonatomic, assign) CGPoint parkCenter;              // 停靠点（屏幕下半屏中心）
@property (nonatomic, weak) UIButton *selectedButton;          // 悬停选中的图标
@property (nonatomic, assign) CGPoint lastFingerPoint;         // 最近一次手指屏幕坐标
@property (nonatomic, assign) CGPoint latchFingerPoint;        // 固定那一刻的手指坐标
@property (nonatomic, assign) BOOL hasLatchFinger;             // 是否已记录固定时的手指位置
@property (nonatomic, assign) NSUInteger settleGeneration;     // 手指停住计时器代次
+ (instancetype)shared;
- (void)install;
- (UIView *)hitTestViewForPoint:(CGPoint)point;
- (void)refreshHostGeometryIfNeeded;
- (CGRect)triggerFrameForBounds:(CGRect)bounds;
- (BOOL)pointBelongsToPullOverHandle:(CGPoint)point;
- (void)onStripPan:(UIPanGestureRecognizer *)gesture;
- (void)showAtPoint:(CGPoint)point;
- (void)moveRingToPoint:(CGPoint)point;
- (void)latchToParkAnimated:(BOOL)animated;
- (void)scheduleSettle;
- (void)buildRingInContainer:(UIView *)container;
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation;
- (void)refreshRingContentsIfVisible;
- (void)scheduleAutoBundleIdEnumeration;
- (void)updateSelectionForPoint:(CGPoint)point;
- (void)setSelectedButton:(UIButton *)button;
- (void)applySelectionVisual:(UIButton *)button selected:(BOOL)selected;
- (void)openFloatWithBundleId:(NSString *)bundleId;
- (CGPoint)clampRingCenter:(CGPoint)point;
- (void)hide;
@end

#pragma mark - 容器（展开态）：点空白收起

/// 展开态的整屏容器。它自己处理触摸：新触摸（不是在触发条上开始的那次）落下再抬起 = 点空白。
@interface MFRingContainerView : UIView
@end

@implementation MFRingContainerView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 必须实现：不实现的话这次触摸序列不会落到我们手里
    (void)touches;
    (void)event;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    MFLog(@"[ring] 点空白 -> 收起圆盘");
    [[MFRingPicker shared] hide];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
}

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
    if (self.stripView != nil) {
        return;   // 幂等
    }
    if (!MFRingBool(@"mfRingEnabled", YES)) {
        MFLog(@"[ring] 圆盘已按配置关闭（mfRingEnabled=false）");
        return;
    }
    @try {
        // 【0.1.9】宿主 = PullOver 自己的窗口（已被真机验证能收触摸，手柄就靠它）
        UIWindow *host = nil;
        id sharedWindow = [POXWindow sharedWindow];
        if ([sharedWindow isKindOfClass:[UIWindow class]]) {
            host = (UIWindow *)sharedWindow;
        }
        if (host == nil) {
            MFLog(@"[ring] !! PullOver 窗口不可用，1 秒后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self install]; });
            return;
        }
        CGRect bounds = host.bounds;
        if (CGRectIsEmpty(bounds)) {
            bounds = [UIScreen mainScreen].bounds;
        }
        if (CGRectIsEmpty(bounds)) {
            MFLog(@"[ring] !! 屏幕未就绪，1 秒后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self install]; });
            return;
        }
        if (host.hidden) {
            host.hidden = NO;
            MFLog(@"[ring] 宿主窗口原为隐藏 -> 已置为可见");
        }
        self.hostWindow = host;
        self.hostBounds = bounds;
        self.triggerFrame = [self triggerFrameForBounds:bounds];

        id controller = nil;
        @try {
            controller = [(POXWindow *)host controller];
        } @catch (__unused NSException *exception) {
            controller = nil;
        }
        if ([controller isKindOfClass:[PullOverViewController class]]) {
            self.hostController = (PullOverViewController *)controller;
        }

        // 崩溃降级判定：上次的标记还在 ⇒ 上回就是被"枚举 App / 抓图标"带走的
        gMFRingDegraded = MFRingGuardArmed();
        if (gMFRingDegraded) {
            MFLog(@"[ring] ⚠️ 检测到崩溃标记 %s —— 进入**降级模式**：不再枚举 App、不抓图标，"
                  @"只用配置/缓存 + 首字母图标。删除该文件可重新尝试。", MF_RING_GUARD_PATH);
        }
        gMFRingAutoBundleIds = MFRingFilterBundleIds([MFRingDefaults() arrayForKey:@"ringAppsAuto"], 12);
        if (gMFRingAutoBundleIds.count > 0) {
            MFLog(@"[ring] 载入上次的自动列表：%lu 项", (unsigned long)gMFRingAutoBundleIds.count);
        }

        // 贴边触发条：一个**窗口子视图**（不是自己的窗口）
        UIView *strip = [[UIView alloc] initWithFrame:bounds];
        strip.backgroundColor = [UIColor clearColor];
        strip.opaque = NO;
        strip.userInteractionEnabled = YES;
        strip.tag = 991001;
        [host addSubview:strip];
        self.stripView = strip;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onStripPan:)];
        pan.delegate = self;
        [strip addGestureRecognizer:pan];
        self.stripPan = pan;
        self.iconButtons = [NSMutableArray array];

        MFLog(@"[ring] 圆盘已挂到 PullOver 窗口（0.1.9 起不再自建窗口）：窗口 %@ level=%.0f hidden=%d "
              @"交互=%d 控制器=%@ | 触发边=%@ 触发条=%@ | 配置项=%lu 自动列表=%lu 降级=%@",
              NSStringFromCGRect(bounds), host.windowLevel, (int)host.hidden,
              (int)host.userInteractionEnabled,
              self.hostController != nil ? @"已就绪" : @"nil",
              MFRingEdge(), NSStringFromCGRect(self.triggerFrame),
              (unsigned long)MFRingConfiguredBundleIds().count,
              (unsigned long)gMFRingAutoBundleIds.count,
              gMFRingDegraded ? @"是" : @"否");

        // 触摸路径零 SB 查询 ⇒ 列表在安装后延后算一次
        [self scheduleAutoBundleIdEnumeration];
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 安装异常：%@", exception);
    }
}

/// 宿主窗口尺寸变化（旋转等）时同步几何。回调里只做一次 rect 比较，开销可忽略。
- (void)refreshHostGeometryIfNeeded {
    UIWindow *window = self.hostWindow;
    if (window == nil) {
        return;
    }
    CGRect bounds = window.bounds;
    if (CGRectIsEmpty(bounds) || CGRectEqualToRect(bounds, self.hostBounds)) {
        return;
    }
    self.hostBounds = bounds;
    self.triggerFrame = [self triggerFrameForBounds:bounds];
    if (self.stripView != nil) {
        self.stripView.frame = bounds;      // 命中区由 triggerFrame 决定，不是 frame
    }
    if (self.container != nil) {
        self.container.frame = bounds;
    }
    MFLog(@"[ring] 宿主尺寸更新 %@ -> 触发条 %@",
          NSStringFromCGRect(bounds), NSStringFromCGRect(self.triggerFrame));
}

/// 收起态的触发区（贴边一条）。默认长度 300，且离屏幕底边 ≥ mfTriggerBottomInset，
/// 避开底部"主屏手势（Home Indicator）"区。
- (CGRect)triggerFrameForBounds:(CGRect)bounds {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat thickness = MAX(16.0, MFRingNumber(@"mfTriggerThickness", 56.0));
    CGFloat length = MAX(80.0, MFRingNumber(@"mfTriggerLength", 300.0));
    CGFloat centerRatio = MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.95);
    CGFloat bottomInset = MAX(0.0, MFRingNumber(@"mfTriggerBottomInset", 44.0));
    NSString *edge = MFRingEdge();

    if ([edge isEqualToString:@"top"] || [edge isEqualToString:@"bottom"]) {
        CGFloat originX = MIN(MAX(width * centerRatio - length / 2.0, 0.0), MAX(width - length, 0.0));
        return ([edge isEqualToString:@"top"]) ? CGRectMake(originX, 0.0, length, thickness)
                                               : CGRectMake(originX, MAX(height - thickness - bottomInset, 0.0),
                                                            length, thickness);
    }
    CGFloat originY = MIN(MAX(height * centerRatio - length / 2.0, 0.0), MAX(height - length, 0.0));
    // 只对贴底的那一段做上移（左/右边缘条同样受这条约束）
    originY = MIN(originY, MAX(height - length - bottomInset, 0.0));
    if ([edge isEqualToString:@"left"]) {
        return CGRectMake(0.0, originY, thickness, length);
    }
    return CGRectMake(width - thickness, originY, thickness, length);   // right（默认）
}

#pragma mark 命中判定（由 POXWindow.hitTest 调用）

/// PullOver 手柄优先：手柄是个方形小把件（默认约 50x50pt 命中区），
/// 命中它时把这次触摸**原样让给 PullOver**，保证浮窗手柄依旧能拖。
- (BOOL)pointBelongsToPullOverHandle:(CGPoint)point {
    PullOverViewController *controller = self.hostController;
    if (controller == nil || !controller.isViewLoaded) {
        return NO;
    }
    POHandle *handle = controller.handle;
    if (handle == nil || handle.hidden || handle.alpha <= 0.01) {
        return NO;
    }
    @try {
        CGPoint inHandle = [handle convertPoint:point fromView:self.hostWindow];
        return [handle pointInside:inHandle withEvent:nil];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

/// 返回本次触摸该落到的视图；返回 nil = 原样交回 PullOver（既有行为零改变）。
- (UIView *)hitTestViewForPoint:(CGPoint)point {
    UIView *window = self.hostWindow;
    if (window == nil) {
        return nil;
    }
    [self refreshHostGeometryIfNeeded];

    if (self.expanded) {
        UIView *container = self.container;
        if (container == nil) {
            return nil;
        }
        // 展开态：让图标按钮能正常被点到（返回最深的那层按钮），其余一律当"空白"处理
        @try {
            CGPoint inContainer = [container convertPoint:point fromView:window];
            UIView *deep = [container hitTest:inContainer withEvent:nil];
            for (UIView *view = deep; view != nil; view = view.superview) {
                if ([view isKindOfClass:[UIButton class]]) {
                    return view;
                }
                if (view == container) {
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        return container;
    }

    UIView *strip = self.stripView;
    if (strip == nil || strip.hidden || CGRectIsEmpty(self.triggerFrame)) {
        return nil;
    }
    if (!CGRectContainsPoint(self.triggerFrame, point)) {
        return nil;
    }
    if ([self pointBelongsToPullOverHandle:point]) {
        return nil;   // 手柄优先
    }
    return strip;
}

#pragma mark - 触发（仅手势）

- (void)onStripPan:(UIPanGestureRecognizer *)gesture {
    UIWindow *window = self.hostWindow;
    if (window == nil || self.stripView == nil) {
        return;
    }
    CGPoint finger = [gesture locationInView:window];
    self.lastFingerPoint = finger;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        MFLog(@"[ring] 贴边按下(POXWindow 子视图 tag=%ld) 屏幕(%.0f,%.0f)",
              (long)gesture.view.tag, finger.x, finger.y);
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

#pragma mark 坐标辅助

/// 把圆心夹到合法范围：整圆不出屏，且**只在下半屏**；NaN/Inf 一律兜底
- (CGPoint)clampRingCenter:(CGPoint)point {
    CGRect bounds = self.hostBounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }
    if (CGRectIsEmpty(bounds)) {
        return CGPointZero;
    }
    CGFloat radius = MAX(60.0, MFRingNumber(@"mfRingRadius", 150.0));
    CGFloat margin = MAX(0.0, MFRingNumber(@"mfRingEdgeMargin", 12.0));
    CGFloat extent = radius + margin;
    CGFloat minX = extent;
    CGFloat maxX = MAX(CGRectGetMaxX(bounds) - extent, minX);
    CGFloat minY = CGRectGetMidY(bounds);                       // 下半屏
    CGFloat maxY = MAX(CGRectGetMaxY(bounds) - extent, minY);
    CGFloat x = MIN(MAX(MFRingSafe(point.x, CGRectGetMidX(bounds)), minX), maxX);
    CGFloat y = MIN(MAX(MFRingSafe(point.y, CGRectGetMidY(bounds)), minY), maxY);
    return CGPointMake(x, y);
}

#pragma mark 展开 / 收起

/// 展开圆盘。anchor = 圆盘初始圆心（= 手指位置）。
/// 0.1.9 起**同步构建**：与 PullOver 手柄一样在手势回调里直接改视图（那是已验证可用的做法）。
- (void)showAtPoint:(CGPoint)point {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showAtPoint:point]; });
        return;
    }
    if (self.hostWindow == nil || self.stripView == nil) {
        MFLog(@"[ring] 尚未安装，忽略呼出");
        return;
    }
    if (self.expanded) {
        return;
    }
    CGRect bounds = self.hostBounds;
    if (CGRectIsEmpty(bounds)) {
        MFLog(@"[ring] !! 宿主尺寸为空，忽略呼出");
        return;
    }

    MFLog(@"[ring] >>> 呼出圆盘 起点(%.0f,%.0f)", point.x, point.y);
    @try {
        self.expanded = YES;
        self.buildGeneration += 1;
        self.ringLatched = NO;
        self.selectedButton = nil;
        self.hasLatchFinger = NO;
        self.settleGeneration += 1;

        CGFloat ratio = MIN(MAX(MFRingNumber(@"mfRingParkRatioY", 0.72), 0.5), 0.92);
        self.parkCenter = [self clampRingCenter:CGPointMake(CGRectGetMidX(bounds),
                                                            CGRectGetHeight(bounds) * ratio)];

        MFLog(@"[ring] >>> 建容器");
        MFRingContainerView *container = [[MFRingContainerView alloc] initWithFrame:bounds];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];   // 轻遮罩
        container.opaque = NO;
        container.userInteractionEnabled = YES;
        [self.hostWindow addSubview:container];
        self.container = container;
        MFLog(@"[ring] <<< 建容器 ok");

        MFLog(@"[ring] >>> 建圆盘");
        [self buildRingInContainer:container];
        MFLog(@"[ring] <<< 建圆盘 ok：%lu 个图标", (unsigned long)self.iconButtons.count);

        self.ringRoot.center = [self clampRingCenter:point];

        container.alpha = 0.0;
        [UIView animateWithDuration:0.15 animations:^{
            container.alpha = 1.0;
        }];

        MFLog(@"[ring] <<< 呼出完成：跟随手指(%.0f,%.0f) -> 停靠点(%.0f,%.0f)",
              point.x, point.y, self.parkCenter.x, self.parkCenter.y);

        if (self.iconButtons.count == 0) {
            [self scheduleAutoBundleIdEnumeration];
        } else {
            // 图标延后抓取：先把圆盘显示出来，再慢慢贴真图标（触摸路径零图标查询）
            [self scheduleIconFillWithGeneration:self.buildGeneration];
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 展开异常：%@", exception);
        [self hide];
    }
}

- (void)hide {
    self.buildGeneration += 1;   // 作废尚未执行的图标填充
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

    if (container == nil) {
        return;
    }
    [UIView animateWithDuration:0.15 animations:^{
        container.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [container removeFromSuperview];
    }];
    MFLog(@"[ring] 圆盘已收起（贴边手势恢复）");
}

#pragma mark 跟随 / 停靠

- (void)moveRingToPoint:(CGPoint)point {
    if (self.ringRoot == nil) {
        return;
    }
    self.ringRoot.center = [self clampRingCenter:point];
}

/// 手指停住一小会儿就把圆盘固定到停靠点（用户自然会在停靠点附近有个停顿）
- (void)scheduleSettle {
    self.settleGeneration += 1;
    NSUInteger generation = self.settleGeneration;
    NSTimeInterval delay = MAX(0.05, MFRingNumber(@"mfRingSettleDelay", 0.18));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf.settleGeneration) {
            return;
        }
        if (!strongSelf.expanded || strongSelf.ringLatched) {
            return;
        }
        [strongSelf latchToParkAnimated:YES];
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
    ringRoot.opaque = NO;
    ringRoot.userInteractionEnabled = YES;
    ringRoot.tag = 991002;
    [container addSubview:ringRoot];
    self.ringRoot = ringRoot;

    // 完整圆形底盘
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:
                          CGRectMake(extent - radius, extent - radius, radius * 2.0, radius * 2.0)];
    CAShapeLayer *dial = [CAShapeLayer layer];
    dial.path = path.CGPath;
    dial.fillColor = [UIColor colorWithWhite:0.12 alpha:0.55].CGColor;
    dial.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    dial.lineWidth = 1.0;
    [ringRoot.layer addSublayer:dial];
    self.dialLayer = dial;

    MFLog(@"[ring] >>> 取圆盘内容（只读配置/缓存，不查 SB）");
    NSArray<NSString *> *bundleIds = MFRingBundleIds();
    NSUInteger count = bundleIds.count;
    MFLog(@"[ring] <<< 取圆盘内容 ok：%lu 项", (unsigned long)count);

    if (count == 0) {
        NSString *text = gMFRingDegraded
            ? @"圆盘里还没有 App\n（当前为降级模式：自动枚举已停用）\n在 com.mlgm.pulloverx.plist 里设置 ringApps 即可"
            : @"圆盘里还没有 App\n正在后台枚举已安装应用，稍后从边缘再滑一次";
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, radius * 1.6, 80.0)];
        hint.numberOfLines = 0;
        hint.textAlignment = NSTextAlignmentCenter;
        hint.text = text;
        hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        hint.font = [UIFont systemFontOfSize:12.0];
        hint.center = CGPointMake(extent, extent);
        [ringRoot addSubview:hint];
        return;
    }

    // 图标放在圆周内侧一圈。**先铺"首字母"占位**，真图标延后贴（见 scheduleIconFillWithGeneration:）
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

        NSString *initial = (bundleId.length > 0)
            ? [[bundleId lastPathComponent] substringToIndex:1].uppercaseString : @"?";
        [button setTitle:initial forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:iconSize * 0.4];

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
    MFLog(@"[ring] <<< 图标铺好：半径 %.0f 图标 %.0f 起始角 %.0f",
          radius, iconSize, startAngle);
}

/// 延后抓取真图标。危险动作 ⇒ 立闸门，走完并存活才撤。
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation {
    if (self.iconButtons.count == 0) {
        return;
    }
    if (!MFRingBool(@"mfRingFetchIcons", YES)) {
        MFLog(@"[ring] 按配置跳过图标抓取（mfRingFetchIcons=false，仅首字母）");
        return;
    }
    if (gMFRingDegraded) {
        MFLog(@"[ring] 降级模式：跳过图标抓取（仅首字母）。删除 %s 可重试", MF_RING_GUARD_PATH);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (generation != strongSelf.buildGeneration || !strongSelf.expanded) {
            MFLog(@"[ring] 图标填充已作废 gen=%lu", (unsigned long)generation);
            return;
        }
        NSArray<UIButton *> *buttons = [strongSelf.iconButtons copy];
        MFLog(@"[ring] >>> 抓取图标 %lu 个（逐个记录）", (unsigned long)buttons.count);
        MFRingGuardArm();
        BOOL anyIcon = NO;
        for (UIButton *button in buttons) {
            if (generation != strongSelf.buildGeneration || !strongSelf.expanded) {
                break;
            }
            if (button.superview == nil) {
                continue;
            }
            NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
            if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
                continue;
            }
            MFLog(@"[ring] >>> 取图标 %@", bundleId);
            UIImage *icon = MFRingIconForBundleId(bundleId);
            MFLog(@"[ring] <<< 取图标 %@ ok=%@", bundleId, icon != nil ? @"是" : @"否");
            if (icon != nil && generation == strongSelf.buildGeneration) {
                [button setImage:icon forState:UIControlStateNormal];
                button.imageView.contentMode = UIViewContentModeScaleAspectFill;
                [button setTitle:nil forState:UIControlStateNormal];
                anyIcon = YES;
            }
        }
        MFRingGuardDisarm();   // 整趟走完且存活 ⇒ 撤标记
        MFLog(@"[ring] <<< 图标抓取完成（%lu 个，取到图标=%@），崩溃标记已撤除",
              (unsigned long)buttons.count, anyIcon ? @"是" : @"否");
    });
}

/// 列表迟到（枚举完成）时，若圆盘正开着就原地重建内容
- (void)refreshRingContentsIfVisible {
    if (!self.expanded || self.container == nil || self.ringRoot == nil) {
        return;
    }
    CGPoint center = self.ringRoot.center;
    [self.ringRoot removeFromSuperview];
    self.ringRoot = nil;
    self.dialLayer = nil;
    self.selectedButton = nil;
    [self.iconButtons removeAllObjects];
    [self buildRingInContainer:self.container];
    self.ringRoot.center = center;
    MFLog(@"[ring] 圆盘内容已刷新：%lu 个图标", (unsigned long)self.iconButtons.count);
    [self scheduleIconFillWithGeneration:self.buildGeneration];
}

#pragma mark 自动枚举（安装后延后执行，绝不在触摸路径）

- (void)scheduleAutoBundleIdEnumeration {
    if (gMFRingDegraded) {
        MFLog(@"[ring] 降级模式：跳过自动枚举");
        return;
    }
    if (gMFRingListing) {
        return;
    }
    if (MFRingConfiguredBundleIds().count > 0) {
        MFLog(@"[ring] 已有 ringApps 配置，跳过自动枚举");
        return;
    }
    if (gMFRingAutoBundleIds.count > 0) {
        return;   // 已有缓存
    }
    gMFRingListing = YES;
    gMFRingListGeneration += 1;
    NSUInteger generation = (NSUInteger)gMFRingListGeneration;
    __weak typeof(self) weakSelf = self;
    // 延后 0.6 秒：确保这次安装/呼出事件已经处理完，且 SpringBoard 已经稳定
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || generation != (NSUInteger)gMFRingListGeneration) {
            gMFRingListing = NO;
            return;
        }
        NSUInteger limit = (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingMaxIcons", 8), 1.0), 12.0);
        MFLog(@"[ring] >>> 枚举已安装 App（扁平遍历，最多 %lu 项）", (unsigned long)limit);
        MFRingGuardArm();
        NSArray<NSString *> *ids = MFRingEnumerateInstalledBundleIds(limit);
        MFRingGuardDisarm();   // 走完且存活 ⇒ 撤标记
        gMFRingListing = NO;
        if (generation != (NSUInteger)gMFRingListGeneration) {
            return;
        }
        if (ids.count == 0) {
            MFLog(@"[ring] !! 枚举结果为空（不写缓存）");
            return;
        }
        MFRingStoreAutoBundleIds(ids);
        MFLog(@"[ring] <<< 枚举完成：%lu 项 -> %@",
              (unsigned long)ids.count, [ids componentsJoinedByString:@", "]);
        [strongSelf refreshRingContentsIfVisible];
    });
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
        CGPoint center = [button.superview convertPoint:button.center toView:self.hostWindow];
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
    // 以"当前显示集"为基准物化，再移除 —— 保证自动枚举来的项也能真正移出
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
        [self showAtPoint:park];
        [self latchToParkAnimated:NO];
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

#pragma mark - 命中判定入口（供 POXWindow.hitTest 调用）

/// 窗口命中判定：圆盘展开态整窗接管、收起态只认贴边触发条；其余返回 nil，
/// 由 POXWindow 原样交回 PullOver 控制器 —— 对既有手柄/面板行为零改变。
UIView *MFRingHitTestViewForWindowPoint(UIWindow *window, CGPoint point) {
    if (window == nil) {
        return nil;
    }
    MFRingPicker *picker = [MFRingPicker shared];
    if (picker.hostWindow != window) {
        return nil;
    }
    @try {
        return [picker hitTestViewForPoint:point];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

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
