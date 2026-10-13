//
//  MFFloat.xm — 浮窗外壳 + 真实承载（Route B）
//
//  ============ 为什么是 Route B ============
//  v0.5.0 段 9 的全镜像归属搜索给出了定论：
//      uiPresentationManager —— 全机 99398 个类里【只有 NSObject 定义】(@16@0:8)。
//      FBScene 的 120 个自有方法里没有它，UIScene/UIWindowScene 也都没有覆写。
//  => 旧方案（scene.uiPresentationManager -> createPresenterWithIdentifier:）在 17.3.1 上拿不到东西。
//
//  而 SpringBoard 自己的"宿主视图"这条路实测全都在：
//      SBSceneHandle              -newSceneViewController                        @16@0:8
//      SBSceneHandle              -newSceneViewWithReferenceSize:...            @56@0:8...
//      SBDeviceApplicationSceneViewController -initWithSceneHandle:             @24@0:8@16
//      SBDeviceApplicationSceneViewController -setSceneResizesHostedContext:    v20@0:8B16  <-- 命门
//      SBSceneManager             -existingSceneHandleForPersistenceIdentifier: @24@0:8@16
//      SBSceneManager             -existingSceneHandleForScene:                 @24@0:8@16
//      SBSceneManagerCoordinator  +mainDisplaySceneManager
//      SBApplicationController    -applicationWithBundleIdentifier:             @24@0:8@16
//
//  所以本版用 SpringBoard 自己的 VC 去承载 scene，而不是自己拼 presenter。
//
//  ============ 三条铁律 ============
//   1. 全部在主线程执行（v0.4.0 的崩因高度怀疑就是后台线程上碰这些对象）。
//   2. 每一步先落盘日志再执行 —— 崩了就靠最后一行定位。
//   3. 任何一步失败都降级到"外壳 + 可读错误文本"，绝不给黑屏。
//
#import "MFInternal.h"

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
static id MFFindHandleByPersistenceID(id app, NSString *bundleID) {
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

    SEL existing = NSSelectorFromString(@"existingSceneHandleForPersistenceIdentifier:");
    id handle = MFMsg1(sceneManager, existing, persistenceID);
    if (handle != nil) return handle;

    // 再试一次按 scene identity 查（部分是 nil 的 persistence id）
    if (sceneID != nil) {
        SEL idSel = NSSelectorFromString(@"sceneIdentityForApplication:");
        id token = MFMsg1(sceneManager, idSel, app);
        MFLog(@"[host] sceneIdentityForApplication:=%@", token ? NSStringFromClass([token class]) : @"nil");
        if (token != nil) {
            handle = MFMsg1(sceneManager, NSSelectorFromString(@"existingSceneHandleForSceneIdentity:"), token);
            if (handle != nil) return handle;
        }
    }
    return nil;
}

/// 路线 2：枚举活体 scene 反查（v0.4.0 崩在这里，但那是后台线程 + 无类型守卫）
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
            NSString *handleBID = MFStr(MFMsg(handle, NSSelectorFromString(@"application")), NSSelectorFromString(@"bundleIdentifier"));
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

/// 管理器接口前置声明（实现体在后面），这样面板里可以直接调用它
@interface MFFloatManager : NSObject
@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) MFFloatPanel *panel;
@property (nonatomic, strong) UIWindow *window;
+ (instancetype)shared;
- (void)startWithConfig:(NSDictionary *)config;
- (void)hostBundleID:(NSString *)bundleID;
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

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 58, barH)];
    title.text = [NSString stringWithFormat:@"MultiFloat %@", MFVersionString()];
    title.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:13];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:title];
    self.titleLabel = title;

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

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, w - 40, statusH)];
    status.font = [UIFont systemFontOfSize:10];
    status.textColor = [UIColor colorWithWhite:0.80 alpha:1.0];
    status.text = @"初始化…";
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
        body.font = [UIFont systemFontOfSize:11];
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
        empty.text = @"没有正在运行的 App。\n先手动打开目标 App 再进 shell 模式。";
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
    [panel setStatusText:@"外壳就绪"];

    NSString *mode = self.config[@"mode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"host";

    if ([mode isEqualToString:@"shell"]) {
        [panel setStatusText:@"shell 模式：选一个在跑的 App 试试"];
        [self refreshAppList];
    } else {
        NSString *bid = self.config[@"targetBundleID"];
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) bid = @"com.apple.mobilesafari";
        [self hostBundleID:bid];
    }
}

#pragma mark 承载

- (void)hostBundleID:(NSString *)bundleID {
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;

    MFLog(@"[host] ========== begin bid=%@ ==========", bundleID);
    [panel setStatusText:[NSString stringWithFormat:@"正在承载 %@", bundleID]];

    id controller = MFClassSharedInstance(@"SBApplicationController");
    MFLog(@"[host] SBApplicationController=%@", controller ? NSStringFromClass([controller class]) : @"nil");
    if (controller == nil) {
        [self fail:@"SBApplicationController 不可用" detail:nil];
        return;
    }

    id app = MFMsg1(controller, NSSelectorFromString(@"applicationWithBundleIdentifier:"), bundleID);
    MFLog(@"[host] SBApplication=%@", app ? NSStringFromClass([app class]) : @"nil");
    if (app == nil) {
        [self fail:[NSString stringWithFormat:@"找不到应用 %@", bundleID]
             detail:@"检查配置里的 targetBundleID 是否拼写正确。"];
        return;
    }

    id handle = MFFindHandleByPersistenceID(app, bundleID);
    MFLog(@"[host] handle(路线1 查表)=%@", handle ? NSStringFromClass([handle class]) : @"nil");
    if (handle == nil) {
        handle = MFFindHandleBySceneScan(bundleID);
        MFLog(@"[host] handle(路线2 扫描)=%@", handle ? NSStringFromClass([handle class]) : @"nil");
    }
    if (handle == nil) {
        [self fail:@"找不到该 App 的运行中 scene"
             detail:@"这个 App 现在没有活着的 scene。先手动打开它、停在应用里，然后关闭浮窗重开（或 respring）再试。"];
        return;
    }

    id scene = MFMsg(handle, NSSelectorFromString(@"sceneIfExists"));
    MFLog(@"[host] sceneIfExists=%@ active=%d contentState=%ld",
         scene ? NSStringFromClass([scene class]) : @"nil",
         (int)MFBoolProp(scene, NSSelectorFromString(@"isActive")),
         (long)MFIntProp(scene, NSSelectorFromString(@"contentState")));

    id hostVC = MFMsg(handle, NSSelectorFromString(@"newSceneViewController"));
    MFLog(@"[host] newSceneViewController=%@", hostVC ? NSStringFromClass([hostVC class]) : @"nil");
    if (hostVC == nil) {
        [self fail:@"newSceneViewController 返回 nil"
             detail:@"SpringBoard 拒绝了宿主视图创建。把这条日志发回来。"];
        return;
    }

    SEL resizeSel = NSSelectorFromString(@"setSceneResizesHostedContext:");
    if ([hostVC respondsToSelector:resizeSel]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(hostVC, resizeSel, YES);
            MFLogS(@"[host] setSceneResizesHostedContext:YES 已设置");
        } @catch (NSException *e) {
            MFLog(@"[host] setSceneResizesHostedContext 抛异常: %@", e.reason);
        }
    } else {
        MFLogS(@"[host] !! 宿主 VC 不响应 setSceneResizesHostedContext:（可能出现画面错位）");
    }

    SEL activateSel = NSSelectorFromString(@"activateWithTransitionContext:");
    if (scene != nil && [scene respondsToSelector:activateSel]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(scene, activateSel, nil);
            MFLogS(@"[host] activateWithTransitionContext:nil 已发送");
        } @catch (NSException *e) {
            MFLog(@"[host] activate 抛异常: %@", e.reason);
        }
    }

    [panel attachContentViewController:hostVC];
    [panel setStatusText:[NSString stringWithFormat:@"已承载 %@", bundleID]];
    MFLog(@"[host] ========== done bid=%@ ==========", bundleID);
}

- (void)fail:(NSString *)message detail:(NSString *)detail {
    MFLog(@"[host] FAIL: %@", message);
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;
    [panel showMessage:message detail:detail];
    [panel setStatusText:@"承载失败（详见 /var/mobile/MultiFloat.log）"];
}

#pragma mark 应用列表

- (void)refreshAppList {
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

    // 首次运行写出默认配置（enabled=false），方便用户在 Filza 里直接改
    MFWriteDefaultConfigIfNeeded();

    // 崩溃自解除：上一轮写过标记又没活过存活窗口 => 上一轮崩了 => 本轮不动
    if (MFAttemptExists()) {
        MFLogRawC("[gate] 发现上次尝试标记 -> 本轮跳过浮窗。"
                  "确认设备稳定后，用 Filza 删除 /var/mobile/MF-float-attempt.txt 即可重新尝试。\n");
        return;
    }

    NSDictionary *config = MFLoadConfig();
    if (config == nil) {
        MFLogRawC("[gate] 无配置 -> 完全惰性（不做任何事）\n");
        return;
    }
    if (![config[@"enabled"] boolValue]) {
        MFLogRawC("[gate] enabled=false -> 完全惰性（把 /var/mobile/MultiFloat.plist 里 enabled 改成 <true/> 后 respring）\n");
        return;
    }

    NSString *mode = config[@"mode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"host";
    MFAttemptWrite(mode.UTF8String);
    MFLog(@"[gate] 已启用 mode=%@ target=%@", mode, config[@"targetBundleID"] ?: @"(默认 Safari)");

    double delay = 12.0;
    id cfgDelay = config[@"showDelay"];
    if ([cfgDelay respondsToSelector:@selector(doubleValue)]) delay = [cfgDelay doubleValue];
    MFLog(@"[gate] %.1f 秒后显示浮窗", delay);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[MFFloatManager shared] startWithConfig:config];
    });

    // 活过 (显示 + 30) 秒 => 判定为没崩 => 清除标记，下次 respring 还能再显示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 30.0) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MFAttemptClear();
        MFLogRawC("[gate] 存活确认 -> 自解除标记已清除（本轮没有崩）\n");
    });
}
