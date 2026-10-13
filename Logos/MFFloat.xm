//
//  MFFloat.xm — 浮窗外壳 + 真实承载（Route B）
//
//  ============ 为什么是 Route B ============
//  MFProbe v0.5.0 段 9 的全镜像归属搜索给出定论：
//      uiPresentationManager —— 全机 99398 个类里【只有 NSObject 记录到】(@16@0:8)。
//      FBScene 的 120 个自有方法里没有它，UIScene/UIWindowScene 也都没有覆写。
//      _uiPresentationManager / _setResizesHostedContext: 更是 0 个类。
//  => 旧方案（scene.uiPresentationManager -> createPresenterWithIdentifier:）在 17.3.1 上拿不到东西。
//
//  而 SpringBoard 自己的"宿主视图"这条路实测全都在：
//      SBSceneHandle              -newSceneViewController                        @16@0:8
//      SBSceneHandle              -sceneIfExists                                @16@0:8
//      SBDeviceApplicationSceneViewController -setSceneResizesHostedContext:    v20@0:8B16
//      SBSceneManager             -existingSceneHandleForPersistenceIdentifier: @24@0:8@16
//      SBSceneManager             -existingSceneHandleForScene:                 @24@0:8@16
//      SBSceneManagerCoordinator  +mainDisplaySceneManager
//      SBApplicationController    -applicationWithBundleIdentifier:             @24@0:8@16
//
//  ============ 0.3.0 → 0.4.0 要解决的问题 ============
//  0.3.0 真机：外壳完全正常（可拖动/缩放），一点"运行中应用列表"里的行就崩，
//  连崩两次进安全模式。日志给出两件事：
//
//   (1) 崩点定位：最后一行是
//         [host] setSceneResizesHostedContext:YES 已设置
//       而它之后紧接着的两条语句是
//         ① [scene respondsToSelector:@selector(activateWithTransitionContext:)]
//         ② objc_msgSend(scene, @selector(activateWithTransitionContext:), nil)   ← nil 上下文
//       下一行 `activateWithTransitionContext:nil 已发送` 从未出现。
//       查 FBScene 方法表：activateWithTransitionContext: 确实存在（v24@0:8@16，吃一个对象）。
//       => 高度怀疑 ② ：给 FBScene 传 nil transition context。
//       而 scene 本身 active=1，压根不需要我们再激活一次。所以 0.4.0 直接【删掉这次调用】。
//
//   (2) 为什么会"连崩→安全模式"：两个独立缺陷
//       缺陷 A（最致命）：用户用 Filza 改 plist 时把 mode 写成 shell，iOS 键盘自动更正成 she'll。
//            我们的判定是 `if ([mode isEqualToString:@"shell"]) 走 shell else 走 host`，
//            字符串不匹配 => 掉进 host 分支 => **每次开屏自动承载** => 崩→重启→再崩→安全模式。
//            修法：所有行为开关改成布尔/整数（hostEnabled），mode 只做展示；且判定方向反过来
//            —— 不认识的配置一律走"最保守"分支，绝不允许"写错一个字就进危险路径"。
//       缺陷 B：attempt 标记在 (delay+30s) 无条件清除，而承载是"用户点行"才发生的。
//            用户点得晚，标记早没了 => 危险动作完全没保护。
//            修法：标记改为【只在承载前后】写/清，并且承载入口每次都重新检查标记。
//
//  ============ 0.4.0 的三道防线（0.5.0 沿用）============
//   防线 1  默认 hostEnabled=false：装上只显示外壳，一个 SpringBoard 对象都不碰。
//   防线 2  承载前写 /var/mobile/MF-float-attempt.txt，链路走完并存活 20 秒才清除。
//           任何一次崩溃都会让标记留下 => 之后所有承载直接拒绝 => 物理上不可能崩循环。
//   防线 3  承载链路每一步写 `>>> 步名` / `<<< 步名 ok` 到 /var/mobile/MF-host-step.txt。
//           崩了就靠"最后一个没配对的 >>>"定位；下一次启动自动写成 MF-crash-attribution.txt。
//           配合配置项 hostStep(1..6) 可以做不崩的逐步逼近。
//
//  ============ 0.5.0 修的是什么 ============
//  0.4.0 真机：用户装好后【一个浮窗都没有】。日志只有一个原因：
//      [gate] enabled=false -> 完全惰性
//  用户只把 hostEnabled 改成了 true，而 enabled（总显示开关）仍是 false。
//  两个开关名字太像 => 又一次"开关把用户坑了"。0.5.0 的处理：
//      (a) 默认 enabled=true —— 装上就显示外壳（0.3.0 已证明外壳安全）；
//      (b) 启动时自动修复 "enabled=false 且 hostEnabled=true" 的自相矛盾；
//      (c) enabled=false 时的日志直接点明"只改 hostEnabled 没用"。
//  承载链路（S1..S7）本身与 0.4.0 完全一致，没有改动。
//
//  另外：本版仍然【一个 hook 都不装】。
//
#import "MFInternal.h"

// ============ 承载链路步骤名（顺序即执行顺序）============
static NSString *const kMFStepApp     = @"S1-app";
static NSString *const kMFStepHandle  = @"S2-handle";
static NSString *const kMFStepScene   = @"S3-scene";
static NSString *const kMFStepVC      = @"S4-hostvc";
static NSString *const kMFStepResize  = @"S5-resize";
static NSString *const kMFStepAttach  = @"S6-attach";
static NSString *const kMFStepSettle  = @"S7-settle";

// 启动时由 HookBridge 灌入"上一轮崩在哪一步"（nil = 上一轮没崩）
static NSString *gMFBootCrashStep = nil;
void MFFloatSetBootCrashStep(NSString *step) {
    gMFBootCrashStep = [step copy];
}

#pragma mark ========== 小工具 ==========

/// SpringBoard 的主 windowScene（带 SB 前缀的 sceneManager 才算）
static UIWindowScene *MFMainWindowScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(connectedScenes)]) return nil;

    UIWindowScene *firstAny = nil;
    NSArray *scenes = MFIterate([app connectedScenes]);
    for (id s in scenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (firstAny == nil) firstAny = (UIWindowScene *)s;
        id mgr = MFMsg(s, NSSelectorFromString(@"sceneManager"));
        if (mgr == nil) continue;
        NSString *cn = NSStringFromClass([mgr class]);
        if ([cn hasPrefix:@"SB"]) {
            MFLog(@"[ui] 命中 SB windowScene=%@ sceneManager=%@", NSStringFromClass([s class]), cn);
            return (UIWindowScene *)s;
        }
    }
    MFLog(@"[ui] 未命中 SB sceneManager，回退第一个 windowScene=%@",
         firstAny ? NSStringFromClass([firstAny class]) : @"nil");
    return firstAny;
}

/// SBSceneManagerCoordinator 的主显示 scene manager
static id MFMainSceneManager(void) {
    Class coord = objc_getClass("SBSceneManagerCoordinator");
    if (coord != Nil) {
        SEL sel = NSSelectorFromString(@"mainDisplaySceneManager");
        if ([coord respondsToSelector:sel]) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)((id)coord, sel);
            if (mgr != nil) return mgr;
        }
    }
    id shared = MFClassSharedInstance(@"SBSceneManagerCoordinator");
    if (shared != nil) return MFMsg(shared, NSSelectorFromString(@"mainDisplaySceneManager"));
    return nil;
}

/// 路线 1：纯字符串查表（不接触任何 scene 对象，最安全）
static id MFFindHandleByPersistenceID(id app) {
    id sceneManager = MFMainSceneManager();
    MFLog(@"[host] SBSceneManager=%@", sceneManager ? NSStringFromClass([sceneManager class]) : @"nil");
    if (sceneManager == nil) return nil;

    NSString *sceneID = MFStr(app, NSSelectorFromString(@"_baseSceneIdentifier"));
    Class handleCls = objc_getClass("SBApplicationSceneHandle");
    SEL lookupSel = NSSelectorFromString(@"lookupOrCreatePersistenceIDFromApplication:sceneID:");
    NSString *persistenceID = nil;

    if (sceneID != nil && handleCls != Nil && [handleCls respondsToSelector:lookupSel]) {
        @try {
            persistenceID = ((id (*)(id, SEL, id, id))objc_msgSend)((id)handleCls, lookupSel, app, sceneID);
        } @catch (NSException *e) {
            MFLog(@"[host] lookupOrCreatePersistenceID 抛异常: %@", e.reason);
            persistenceID = nil;
        }
    }
    MFLog(@"[host] sceneID=%@ persistenceID=%@", sceneID ?: @"nil", persistenceID ?: @"nil");
    if (![persistenceID isKindOfClass:[NSString class]] || persistenceID.length == 0) return nil;

    id handle = MFMsg1(sceneManager,
                       NSSelectorFromString(@"existingSceneHandleForPersistenceIdentifier:"),
                       persistenceID);
    if (handle != nil) return handle;

    // 再试一次按 scene identity 查（部分是 nil 的 persistence id）
    if (sceneID != nil) {
        id token = MFMsg1(sceneManager, NSSelectorFromString(@"sceneIdentityForApplication:"), app);
        MFLog(@"[host] sceneIdentityForApplication:=%@",
             token ? NSStringFromClass([token class]) : @"nil");
        if (token != nil) {
            handle = MFMsg1(sceneManager,
                            NSSelectorFromString(@"existingSceneHandleForSceneIdentity:"), token);
            if (handle != nil) return handle;
        }
    }
    return nil;
}

/// 路线 2：枚举活体 scene 反查（实测在主线程上安全：0.3.0 里它扫了 5 个 scene 没有崩）
static id MFFindHandleBySceneScan(NSString *bundleID) {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(connectedScenes)]) return nil;

    for (id windowScene in MFIterate([app connectedScenes])) {
        id sceneManager = MFMsg(windowScene, NSSelectorFromString(@"sceneManager"));
        if (sceneManager == nil) continue;
        NSArray *scenes = MFIterate(MFMsg(sceneManager, NSSelectorFromString(@"allScenes")));
        MFLog(@"[host] scan ws=%@ sm=%@ scenes=%lu",
             NSStringFromClass([windowScene class]),
             NSStringFromClass([sceneManager class]),
             (unsigned long)scenes.count);
        for (id scene in scenes) {
            NSString *sceneID = MFStr(scene, NSSelectorFromString(@"identifier"));
            id handle = MFMsg1(sceneManager, NSSelectorFromString(@"existingSceneHandleForScene:"), scene);
            NSString *handleBID = MFStr(MFMsg(handle, NSSelectorFromString(@"application")),
                                        NSSelectorFromString(@"bundleIdentifier"));
            MFLog(@"[host]   scene=%@ handle=%@ bid=%@",
                 sceneID ?: @"?", handle ? NSStringFromClass([handle class]) : @"nil", handleBID ?: @"?");
            if (handleBID != nil && [handleBID isEqualToString:bundleID]) return handle;
            if (handle != nil && handleBID == nil && sceneID != nil && [sceneID hasPrefix:bundleID]) return handle;
        }
    }
    return nil;
}

#pragma mark ========== 类声明 ==========

@class MFFloatPanel;

@interface MFFloatManager : NSObject
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) MFFloatPanel *panel;
@property (nonatomic, strong) UIWindow *window;
/// 每次承载 +1：用来让"存活确认"只在本次承载仍然是最新一次时才清标记
@property (nonatomic, assign) NSUInteger hostSeq;
+ (instancetype)shared;
- (void)startWithConfig:(NSDictionary *)config;
- (void)hostBundleID:(NSString *)bundleID;
- (void)refreshAppList;
@end

@interface MFFloatPanel : UIViewController
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *titleBar;
@property (nonatomic, strong) UIView *contentArea;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIViewController *contentVC;
- (void)setStatusText:(NSString *)text;
- (void)showMessage:(NSString *)message detail:(NSString *)detail;
- (void)showAppList:(NSArray<NSArray<NSString *> *> *)items;
- (void)attachContentViewController:(UIViewController *)vc;
@end

/// 应用列表行 → bundleID 的关联对象 key
static char kMFRowBundleIDKey;

@implementation MFFloatPanel

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.94];
    self.view.layer.cornerRadius = 14.0;
    self.view.layer.masksToBounds = YES;
    self.view.layer.borderWidth = 1.0;
    self.view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;

    const CGFloat barH = 36.0, statusH = 22.0;
    CGRect bounds = self.view.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;

    // ---- 标题栏（同时是拖动手柄）----
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, barH)];
    bar.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:bar];
    self.titleBar = bar;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 96, barH)];
    title.text = [NSString stringWithFormat:@"MultiFloat %@", MFVersionString()];
    title.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:13];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:title];
    self.titleLabel = title;

    // 刷新键：拉取"当前正在运行"的 App 列表。
    // 没有它就只能在 respring 后才能重试，而 respring 会杀掉目标 App 的 scene。
    UIButton *reload = [UIButton buttonWithType:UIButtonTypeCustom];
    reload.frame = CGRectMake(w - 76, 4, 34, 28);
    [reload setTitle:@"↻" forState:UIControlStateNormal];
    [reload setTitleColor:[UIColor colorWithWhite:0.90 alpha:1.0] forState:UIControlStateNormal];
    reload.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    reload.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [reload addTarget:self action:@selector(onReloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:reload];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(w - 42, 4, 34, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:0.90 alpha:1.0] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    // ---- 内容区 ----
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, barH, w, h - barH - statusH)];
    content.backgroundColor = [UIColor clearColor];
    content.clipsToBounds = YES;
    content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:content];
    self.contentArea = content;

    // ---- 底部状态条 ----
    UIView *statusBar = [[UIView alloc] initWithFrame:CGRectMake(0, h - statusH, w, statusH)];
    statusBar.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    statusBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:statusBar];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, w - 16, statusH)];
    status.font = [UIFont systemFontOfSize:10];
    status.textColor = [UIColor colorWithWhite:0.80 alpha:1.0];
    status.text = @"初始化…";
    status.lineBreakMode = NSLineBreakByTruncatingTail;
    status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [statusBar addSubview:status];
    self.statusLabel = status;

    // ---- 右下角缩放手柄 ----
    UILabel *grip = [[UILabel alloc] initWithFrame:CGRectMake(w - 26, h - statusH - 26, 24, 24)];
    grip.text = @"◢";
    grip.textColor = [UIColor colorWithWhite:0.78 alpha:0.9];
    grip.font = [UIFont systemFontOfSize:16];
    grip.textAlignment = NSTextAlignmentCenter;
    grip.userInteractionEnabled = YES;
    grip.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:grip];

    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)]];
    [grip addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onResize:)]];

    MFLog(@"[ui] 面板就绪 %.0fx%.0f", w, h);
}

- (void)setStatusText:(NSString *)text {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setStatusText:text]; });
        return;
    }
    self.statusLabel.text = text ?: @"";
}

#pragma mark 交互

- (void)onCloseTapped {
    MFLogS(@"[ui] 关闭按钮被点（respring 可再次显示）");
    self.hostWindow.hidden = YES;
}

- (void)onReloadTapped {
    MFLogS(@"[ui] 刷新按钮被点 -> 重拉运行中应用列表");
    [[MFFloatManager shared] refreshAppList];
}

- (void)onDrag:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.hostWindow;
    if (win == nil) return;
    CGPoint t = [g translationInView:win];
    CGRect f = win.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    win.frame = f;
    [g setTranslation:CGPointZero inView:win];
}

- (void)onResize:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.hostWindow;
    if (win == nil) return;
    CGPoint t = [g translationInView:win];
    CGRect f = win.frame;
    f.size.width = MAX(190.0, f.size.width + t.x);
    f.size.height = MAX(170.0, f.size.height + t.y);
    CGRect screen = [UIScreen mainScreen].bounds;
    if (f.origin.x + f.size.width > screen.size.width) f.size.width = screen.size.width - f.origin.x;
    if (f.origin.y + f.size.height > screen.size.height) f.size.height = screen.size.height - f.origin.y;
    win.frame = f;
    [g setTranslation:CGPointZero inView:win];
}

#pragma mark 内容

- (void)clearContentArea {
    for (UIView *v in [self.contentArea.subviews copy]) [v removeFromSuperview];
}

- (void)attachContentViewController:(UIViewController *)vc {
    if (self.contentVC != nil) {
        [self.contentVC willMoveToParentViewController:nil];
        [self.contentVC.view removeFromSuperview];
        [self.contentVC removeFromParentViewController];
        self.contentVC = nil;
    }
    [self clearContentArea];
    if (vc == nil) return;

    self.contentVC = vc;
    [self addChildViewController:vc];
    vc.view.frame = self.contentArea.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentArea addSubview:vc.view];
    [vc didMoveToParentViewController:self];
    MFLog(@"[ui] 已挂载承载视图 %@", NSStringFromClass([vc class]));
}

- (void)showMessage:(NSString *)message detail:(NSString *)detail {
    [self attachContentViewController:nil];
    UIView *box = [[UIView alloc] initWithFrame:self.contentArea.bounds];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(14, 18, box.bounds.size.width - 28, 0)];
    head.text = message ?: @"";
    head.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    head.font = [UIFont boldSystemFontOfSize:13];
    head.numberOfLines = 0;
    [head sizeToFit];
    [box addSubview:head];

    if (detail.length > 0) {
        UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(14, CGRectGetMaxY(head.frame) + 10,
                                                                 box.bounds.size.width - 28, 0)];
        body.text = detail;
        body.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
        body.font = [UIFont systemFontOfSize:10];
        body.numberOfLines = 0;
        [body sizeToFit];
        [box addSubview:body];
    }
    [self.contentArea addSubview:box];
}

- (void)showAppList:(NSArray<NSArray<NSString *> *> *)items {
    [self attachContentViewController:nil];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.contentArea.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;

    CGFloat y = 8.0;
    const CGFloat rowH = 40.0;
    if (items.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, scroll.bounds.size.width - 28, 60)];
        empty.text = @"没有正在运行的 App。\n先手动打开目标 App，再点右上角 ↻。";
        empty.textColor = [UIColor colorWithWhite:0.8 alpha:1];
        empty.font = [UIFont systemFontOfSize:12];
        empty.numberOfLines = 0;
        [scroll addSubview:empty];
    }
    for (NSArray<NSString *> *pair in items) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(8, y, scroll.bounds.size.width - 16, rowH - 4);
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        row.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
        row.layer.cornerRadius = 8.0;
        [row setTitle:pair.firstObject forState:UIControlStateNormal];
        [row setTitleColor:[UIColor colorWithWhite:0.96 alpha:1.0] forState:UIControlStateNormal];
        row.titleLabel.font = [UIFont systemFontOfSize:12];
        row.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        objc_setAssociatedObject(row, &kMFRowBundleIDKey, pair.lastObject, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [row addTarget:self action:@selector(onRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:row];
        y += rowH;
    }
    scroll.contentSize = CGSizeMake(scroll.bounds.size.width, MAX(y + 8.0, scroll.bounds.size.height));
    [self.contentArea addSubview:scroll];
    MFLog(@"[ui] 应用列表 %lu 项", (unsigned long)items.count);
}

- (void)onRowTapped:(UIButton *)sender {
    NSString *bid = objc_getAssociatedObject(sender, &kMFRowBundleIDKey);
    MFLog(@"[ui] 行被点 bid=%@", bid ?: @"nil");
    if (bid.length == 0) return;
    [[MFFloatManager shared] hostBundleID:bid];
}

@end

#pragma mark ========== 浮窗管理器实现 ==========

@implementation MFFloatManager

+ (instancetype)shared {
    static MFFloatManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[MFFloatManager alloc] init]; });
    return instance;
}

- (void)startWithConfig:(NSDictionary *)config {
    self.config = config;

    MFLogS(@"[mf] ---- start ----");
    UIWindowScene *scene = MFMainWindowScene();
    MFLog(@"[ui] windowScene=%@", scene ? NSStringFromClass([scene class]) : @"nil");

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat w = MAX(230.0, screen.size.width * 0.62);
    CGFloat h = MIN(screen.size.height * 0.65, w * 1.48);
    CGRect frame = CGRectMake(screen.size.width - w - 14.0, 118.0, w, h);

    UIWindow *win = nil;
    if (scene != nil) {
        win = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        win = [[UIWindow alloc] initWithFrame:frame];
    }
    if (win == nil) {
        MFLogS(@"[ui] !! UIWindow 创建失败");
        return;
    }
    win.frame = frame;

    double level = 1010.0;
    id cfgLevel = self.config[@"windowLevel"];
    if ([cfgLevel respondsToSelector:@selector(doubleValue)]) level = [cfgLevel doubleValue];
    win.windowLevel = level;

    MFFloatPanel *panel = [[MFFloatPanel alloc] init];
    panel.hostWindow = win;
    win.rootViewController = panel;
    win.hidden = NO;

    self.window = win;
    self.panel = panel;

    MFLog(@"[ui] 浮窗已显示 level=%.0f frame=%@ hidden=%d key=%d",
         level, NSStringFromCGRect(win.frame), (int)win.isHidden, (int)win.isKeyWindow);

    // ---- 0.4.0：绝不在启动时自动承载 ----
    // 0.3.0 的崩循环就是因为"启动即自动承载"。现在只出外壳 + 应用列表，
    // 承载必须由用户点某一行显式触发（点之前一定先过两道闸门）。
    BOOL hostEnabled = MFConfigBool(self.config, @"hostEnabled", NO);
    MFLog(@"[gate] hostEnabled=%d（字符串 mode 不再参与任何判断）", (int)hostEnabled);

    [self refreshAppList];

    if (gMFBootCrashStep.length > 0 && MFAttemptExists()) {
        [panel setStatusText:[NSString stringWithFormat:
                              @"上次承载崩在 %@ · 已停用承载（删 MF-float-attempt.txt 可重试）",
                              gMFBootCrashStep]];
    } else if (hostEnabled) {
        [panel setStatusText:@"hostEnabled=true · 点应用名开始承载"];
    } else {
        [panel setStatusText:@"只看外壳 · hostEnabled=false"];
    }
}

#pragma mark 承载

/// 到达 hostStep 上限时停下（用于不崩地逐步逼近崩点）
- (void)stopAtStep:(NSInteger)nextStep limit:(NSInteger)limit {
    MFLog(@"[host] 按 hostStep=%ld 在下一步(%ld)之前停止（本轮没有碰任何危险对象）",
                 (long)limit, (long)nextStep);
    MFFloatPanel *panel = self.panel;
    // 主动停下不是崩溃：标记必须清掉，否则下一次启动会被误判成"上一轮崩了"
    MFAttemptClear();
    [panel showMessage:[NSString stringWithFormat:@"已在 hostStep=%ld 处停止", (long)limit]
                detail:[NSString stringWithFormat:
                        @"配置里 hostStep=%ld，链路只走到第 %ld 步就主动停下。\n"
                        @"step=1 只解析应用；2 拿 sceneHandle；3 拿 FBScene；"
                        @"4 建宿主 VC；5 设 resizesHostedContext；6 挂载视图。\n"
                        @"把 hostStep 调大一位再 respring，就能不崩溃地逼近崩点。",
                        (long)limit, (long)limit]];
    [panel setStatusText:[NSString stringWithFormat:@"hostStep=%ld 上限停止", (long)limit]];
}

- (void)hostBundleID:(NSString *)bundleID {
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;

    MFLog(@"[host] ========== begin bid=%@ ==========", bundleID);

    // ---------- 闸门 1：行为开关一律用布尔，绝不用字符串 ----------
    if (!MFConfigBool(self.config, @"hostEnabled", NO)) {
        MFLogS(@"[host] 拒绝：hostEnabled=false");
        [panel showMessage:@"真承载未启用"
                    detail:@"当前 hostEnabled=false，只会显示外壳与应用列表。\n"
                           @"确认设备稳定后，用 Filza 把 /var/mobile/MultiFloat.plist 里的\n"
                           @"    <key>hostEnabled</key><false/>\n"
                           @"改成  <key>hostEnabled</key><true/>\n"
                           @"然后 respring。\n\n"
                           @"⚠️ 不要再去改 mode 那个字符串 —— 0.3.0 就是因为它被 iOS 自动更正"
                           @"（shell ➜ she'll）而误进危险分支的。hostEnabled 是布尔，敲不错。"];
        [panel setStatusText:@"承载未启用（hostEnabled=false）"];
        return;
    }

    // ---------- 闸门 2：崩溃自解除 ----------
    if (MFAttemptExists()) {
        MFLogS(@"[host] 拒绝：上一轮承载留下的崩溃标记仍在");
        [panel showMessage:@"上次承载崩过，已自动停用"
                    detail:@"这是保护机制在起作用，不是新故障 —— 设计上最多只会崩一次。\n\n"
                           @"重试方法：Filza 里删掉 /var/mobile/MF-float-attempt.txt，"
                           @"然后不用 respring，直接再点一次应用行。\n\n"
                           @"要先看崩点的话，日志在这两个文件里：\n"
                           @"  /var/mobile/MF-crash-attribution.txt\n"
                           @"  /var/mobile/MF-host-step-prev.txt"];
        [panel setStatusText:@"已停用 · 删掉 MF-float-attempt.txt 可重试"];
        return;
    }

    NSInteger limit = MFConfigInt(self.config, @"hostStep", 6);
    if (limit < 1) limit = 1;
    if (limit > 6) limit = 6;
    MFLog(@"[host] hostStep 上限 = %ld", (long)limit);

    // 从这里开始才有崩的可能：先落崩溃标记，再开一格新的步骤日志
    MFAttemptWrite("host-begin");
    MFStepReset();
    self.hostSeq += 1;
    NSUInteger mySeq = self.hostSeq;

    [panel setStatusText:[NSString stringWithFormat:@"正在承载 %@", bundleID]];

    // ---------- S1：解析应用 ----------
    MFStepMark(kMFStepApp);
    id controller = MFClassSharedInstance(@"SBApplicationController");
    MFLog(@"[host] SBApplicationController=%@",
         controller ? NSStringFromClass([controller class]) : @"nil");
    id app = (controller != nil)
           ? MFMsg1(controller, NSSelectorFromString(@"applicationWithBundleIdentifier:"), bundleID)
           : nil;
    MFLog(@"[host] SBApplication=%@", app ? NSStringFromClass([app class]) : @"nil");
    MFStepOk(kMFStepApp);

    if (controller == nil) {
        [self fail:@"SBApplicationController 不可用" detail:@"SpringBoard 里找不到这个类。"];
        return;
    }
    if (app == nil) {
        [self fail:[NSString stringWithFormat:@"找不到应用 %@", bundleID]
             detail:@"bundleID 拼错，或者这个 App 从来没在本机启动过。"];
        return;
    }
    if (limit < 2) { [self stopAtStep:2 limit:limit]; return; }

    // ---------- S2：拿 sceneHandle ----------
    MFStepMark(kMFStepHandle);
    id handle = MFFindHandleByPersistenceID(app);
    MFLog(@"[host] handle(路线1 查表)=%@", handle ? NSStringFromClass([handle class]) : @"nil");
    if (handle == nil) {
        handle = MFFindHandleBySceneScan(bundleID);
        MFLog(@"[host] handle(路线2 扫描)=%@", handle ? NSStringFromClass([handle class]) : @"nil");
    }
    MFStepOk(kMFStepHandle);

    if (handle == nil) {
        [self fail:@"找不到该 App 的运行中 scene"
             detail:@"这个 App 现在没有活着的 scene（被系统回收了，或者还没真正跑起来）。\n\n"
                    @"做法：手动打开目标 App 让它在前台跑一下，回到桌面后点右上角 ↻，"
                    @"点列表里对应那一行重试。\n"
                    @"不要用 respring 重试 —— respring 会把 App 的 scene 一起杀掉。"];
        return;
    }
    if (limit < 3) { [self stopAtStep:3 limit:limit]; return; }

    // ---------- S3：拿 FBScene ----------
    MFStepMark(kMFStepScene);
    id scene = MFMsg(handle, NSSelectorFromString(@"sceneIfExists"));
    MFLog(@"[host] sceneIfExists=%@ active=%d contentState=%ld",
         scene ? NSStringFromClass([scene class]) : @"nil",
         (int)MFBoolProp(scene, NSSelectorFromString(@"isActive")),
         (long)MFIntProp(scene, NSSelectorFromString(@"contentState")));
    MFStepOk(kMFStepScene);

    if (scene == nil) {
        [self fail:@"sceneIfExists 返回 nil"
             detail:@"handle 在，但它背后的 scene 已经失效了。\n"
                    @"先把目标 App 切到前台再点 ↻ 重试。"];
        return;
    }
    if (limit < 4) { [self stopAtStep:4 limit:limit]; return; }

    // ---------- S4：建宿主 VC ----------
    MFStepMark(kMFStepVC);
    id hostVC = MFMsg(handle, NSSelectorFromString(@"newSceneViewController"));
    MFLog(@"[host] newSceneViewController=%@", hostVC ? NSStringFromClass([hostVC class]) : @"nil");
    MFStepOk(kMFStepVC);

    if (hostVC == nil) {
        [self fail:@"newSceneViewController 返回 nil"
             detail:@"SpringBoard 拒绝了宿主视图创建。"];
        return;
    }
    if (limit < 5) { [self stopAtStep:5 limit:limit]; return; }

    // ---------- S5：setSceneResizesHostedContext:YES ----------
    // 这是让"浮窗里的 scene 按浮窗尺寸渲染"的关键；不设的话宿主会按整屏渲染，画面必然错位。
    MFStepMark(kMFStepResize);
    SEL resizeSel = NSSelectorFromString(@"setSceneResizesHostedContext:");
    BOOL resizeOK = NO;
    if ([hostVC respondsToSelector:resizeSel]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(hostVC, resizeSel, YES);
            resizeOK = YES;
        } @catch (NSException *e) {
            MFLog(@"[host] setSceneResizesHostedContext 抛异常: %@", e.reason);
        }
    }
    MFLog(@"[host] setSceneResizesHostedContext:YES -> %@",
         resizeOK ? @"已设置" : @"未设置（宿主可能按整屏渲染，画面会错位）");
    MFStepOk(kMFStepResize);

    if (limit < 6) { [self stopAtStep:6 limit:limit]; return; }

    // ---------- S6：把宿主视图挂进浮窗 ----------
    // 【0.4.0 关键删减】0.3.0 在这里之后调用了
    //     objc_msgSend(scene, @selector(activateWithTransitionContext:), nil)
    // 然后就崩了。FBScene 确实有这个方法（v24@0:8@16），但喂 nil 上下文极可能就是死因；
    // 而且日志里 scene 本来 active=1，根本不需要我们再激活。所以本版彻底不调它。
    MFStepMark(kMFStepAttach);
    [panel attachContentViewController:hostVC];
    MFStepOk(kMFStepAttach);

    [panel setStatusText:[NSString stringWithFormat:@"已承载 %@", bundleID]];

    // ---------- S7：存活确认 ----------
    // 链路走完还不够：宿主视图真正开始渲染是异步的，有些断言在之后几十毫秒~几秒才炸。
    // 所以标记要等 20 秒才清；只有"本次承载仍是最新一次"才允许清（防止误清下一轮的标记）。
    MFStepMark(kMFStepSettle);
    MFLog(@"[host] ========== done bid=%@ （20 秒后确认存活）==========", bundleID);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.hostSeq != mySeq) return;   // 期间又发起过承载 -> 不是本轮的事
        MFStepOk(kMFStepSettle);
        MFAttemptClear();
        MFLogS(@"[gate] 承载存活 20 秒 -> 崩溃标记已清除（下次还能再试）");
    });
}

- (void)fail:(NSString *)message detail:(NSString *)detail {
    MFLog(@"[host] FAIL: %@", message);
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;
    // 注意：这不是崩溃，是"走到了但没成功"。标记清掉，否则会被误判成崩过。
    MFAttemptClear();
    [panel showMessage:message detail:detail];
    [panel setStatusText:@"承载失败 · 点右上角 ↻ 拉应用列表重试"];
}

#pragma mark 应用列表

- (void)refreshAppList {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshAppList]; });
        return;
    }
    id controller = MFClassSharedInstance(@"SBApplicationController");
    if (controller == nil) {
        [self.panel showMessage:@"SBApplicationController 不可用" detail:nil];
        return;
    }
    NSArray *running = MFIterate(MFMsg(controller, NSSelectorFromString(@"runningApplications")));
    MFLog(@"[ui] runningApplications=%lu", (unsigned long)running.count);

    NSMutableArray *items = [NSMutableArray array];
    for (id app in running) {
        NSString *bid = MFStr(app, NSSelectorFromString(@"bundleIdentifier"));
        if (bid == nil || [bid hasPrefix:@"com.apple.springboard"]) continue;
        NSString *name = MFStr(app, NSSelectorFromString(@"displayName"));
        [items addObject:@[ name.length > 0 ? name : bid, bid ]];
    }
    [self.panel showAppList:items];
}

@end

#pragma mark ========== 入口 ==========

void MFFloatBootstrap(void) {
    MFLogRawC("--- MFFloatBootstrap 进入 ---\n");

    // 首次运行写出默认配置（enabled=false, hostEnabled=false），方便用户在 Filza 里直接改
    MFWriteDefaultConfigIfNeeded();

    NSDictionary *config = MFLoadConfig();
    if (config == nil) {
        MFLogRawC("[gate] 无配置 -> 完全惰性（不做任何事）\n");
        return;
    }
    // 老 plist 缺 0.4.0 的新键时原地补齐，省得用户手打键名
    MFUpgradeConfigIfNeeded(config);
    // 【0.5.0】修复 "enabled=false 但 hostEnabled=true" 的自相矛盾
    //（用户把 hostEnabled 改成了 true 却漏了总开关 —— 那正是"改了开关却不出浮窗"的原因）
    config = MFRepairConfigContradiction(config);
    if (!MFConfigBool(config, @"enabled", NO)) {
        MFLogRawC("[gate] enabled=false -> 完全惰性（浮窗不出现）\n"
                  "[gate]    注意：enabled 是【总开关】，优先于一切；hostEnabled 只是【真承载】的二级开关。\n"
                  "[gate]    只改 hostEnabled 不会让浮窗出现 —— 要用就把 enabled 也改成 <true/> 再 respring。\n");
        return;
    }

    // 【0.4.0 关键改动】这里【不再】写 attempt 标记，也【不再】无条件清除它。
    // 标记只在 hostBundleID: 里写、只在存活确认后清 —— 它现在严格属于"承载"这一件事。
    // 0.3.0 把标记清得太早（delay+30s），导致用户后来点行时其实是无保护状态。

    if (MFAttemptExists()) {
        MFLogRawC("[gate] 检测到承载崩溃标记：本轮的自动流程照常只显示外壳；"
                  "点应用行会被拒绝（详见 MultiFloat.log）\n");
    }

    double delay = 12.0;
    id cfgDelay = config[@"showDelay"];
    if ([cfgDelay respondsToSelector:@selector(doubleValue)]) delay = [cfgDelay doubleValue];
    MFLog(@"[gate] %.1f 秒后显示浮窗（0.5.0 不做任何自动承载）", delay);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[MFFloatManager shared] startWithConfig:config];
    });
}
