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
//  ============ 0.6.0 修的是什么 ============
//  0.5.0 真机结果（归档(4)）：浮窗出来了、S1..S7 全走完、20 秒存活、**没崩**，
//  但点 Safari 之后内容区**纯黑**。日志里唯一异常是
//      [host] sceneIfExists=FBScene active=1 contentState=0
//  原因：Route B 的 SBDeviceApplicationSceneViewController 是给 SpringBoard 自己的
//  布局系统用的，光把它的 view 挂进我们的窗口，**里面没有渲染用的 presenter** ⇒ 黑底。
//
//  而 Stheno / TrollOpen 用的都不是它，是
//      UIScenePresentationManager  →  _UIScenePresenter  →  presentationView
//  MFProbe v0.5.0 段 9 的真机方法表已确认这条路在 17.3.1 上全都在：
//      UIScenePresentationManager -_initWithScene:                        @24@0:8@16   ← 可自建
//      UIScenePresentationManager -createPresenterWithIdentifier:          @24@0:8@16
//      UIScenePresentationManager -createPresenterWithIdentifier:priority: @32@0:8@16q24
//      UIScenePresentationManager -defaultPresentationContext              @16@0:8
//      UIScenePresentationManager -modifyDefaultPresentationContext:       v24@0:8@?16
//      _UIScenePresenter          -presentationView / -activate / -deactivate / -invalidate
//  所以 0.6.0 新增 **Route A2** 并把它设为默认（hostRoute=2），Route B 保留为兜底（hostRoute=1）。
//  同时新增 forceActivate（默认关）：只有 A2 仍黑屏时才需要强制激活 scene，
//  且用的是 FBScene -_createTransitionContext 造出来的**非空**上下文（不走 0.3.0 的 nil 老路）。
//
//  另外：本版仍然【一个 hook 都不装】。
//
//  ============ 0.7.0 修的是什么 ============
//  0.6.0 真机结果（归档(5)）：浮窗外壳正常、S1..S7 全走完、20 秒存活、**不崩**，
//  presenter 链 P1..P5 也全通，拿到了真正的 _UIScenePresentationView，
//  但点 Safari 之后内容区**依然纯黑**。
//
//  对照一个公开、可用、且同样是 iOS 17 的实现后找到根因：
//      khanhduytran0/FrontBoardAppLauncher（LiveContainer 的多任务同款源码）
//  它拿 presenter 的写法只有一种：
//      FBScene *scene = [[FBSceneManager sharedInstance] createSceneWithDefinition:definition
//                                                              initialParameters:parameters];
//      self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
//      [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *ctx){
//          ctx.appearanceStyle = 2;
//      }];
//      [self.presenter activate];
//      self.view = self.presenter.presentationView;
//  注意两件事：
//   (1) **manager 来自 scene 自己**（`scene.uiPresentationManager`），
//       而我们 0.6.0 是 `[[UIScenePresentationManager alloc] _initWithScene:scene]` 自己造的。
//       自造的 manager 不在 scene 自己的 presenter owner 体系里，
//       presenter 永远进不了 "hosting" 状态 —— 而 _UIScenePresentationView 在
//       "not hosting" 时画的就是呈现上下文里的 backgroundColorWhileNotHosting（默认黑）。
//       => 那层黑底不是"没渲染出来"，是"presenter 明确在显示未承载态的背景色"。
//   (2) 它承载前会把 scene 的 settings 设成 **foreground=YES / level=1 / frame /
//       displayConfiguration**，也就是"这个 scene 是活的、在显示"。
//       已被 App 切到后台的 scene，设置里 foreground=NO，App 进程不会再往它里面渲染。
//
//  0.7.0 因此改成四条路线，默认走 3：
//      hostRoute=3（默认）接管**已存在**的 scene，用 **scene 自己的** manager 取 presenter，
//                        并在前面加 P0 步把 settings 拉成 foreground=YES/level=1/portrait。
//                        —— 改动最小、最像 Stheno 的做法。
//      hostRoute=4        完全照搬 FrontBoardAppLauncher：自己 createSceneWithDefinition: 造一个
//                        scene 给目标 App 渲染，再用它自己的 manager 取 presenter。
//                        —— 唯一有公开源码背书"能出画面"的路径。
//      hostRoute=2        0.6.0 的旧路（自建 _initWithScene: manager），保留做 A/B 对照。
//      hostRoute=1        0.5.0 的 Route B（SpringBoard 宿主 VC），已知黑屏，仅兜底。
//
//  同时【删掉 forceActivate】：真机实测那一次承载在写完 S7-settle 之后、
//  20 秒存活窗口之内进程就没了（MF-crash-attribution.txt: crashedStep=S7-settle）。
//  换句话说 forceActivate 引发的不是同步崩溃，而是 SpringBoard 在其后几秒里被弄挂。
//  现在改用"改 settings"这种非侵入手段达到同样目的。
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

// ============ Route A2（自建 presenter）的步骤名 ============
static NSString *const kMFStepPm      = @"P1-pm";
static NSString *const kMFStepCtx     = @"P2-ctx";
static NSString *const kMFStepPres    = @"P3-pres";
static NSString *const kMFStepAct     = @"P4-act";
static NSString *const kMFStepPView   = @"P5-view";

// ============ 0.7.0 新增的步骤名 ============
static NSString *const kMFStepP0      = @"P0-scene";   // 把 scene settings 拉成可渲染
static NSString *const kMFStepOwn     = @"P4-scene";   // Route 4：自己造一个 scene
static NSString *const kMFStepState   = @"P6-state";   // 挂载后 dump presenter / layer 状态

// 0.6.0：ARC 下必须把"我们真正持有的"对象放进静态 strong 变量。
// 否则局部变量一出作用域就被释放 —— 那个 presenter/宿主 VC 一死，浮窗里立刻变黑。
static id gMFPM        = nil;   // UIScenePresentationManager
static id gMFPresenter = nil;   // _UIScenePresenter
static id gMFHostVC    = nil;   // Route B 的宿主 VC
static id gMFOwnScene  = nil;   // Route 4 自己造出来的 FBScene（必须持有，否则立刻失效）

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

#pragma mark ========== Route A2：自建 presenter（0.6.0）==========

/// 自建 UIScenePresentationManager：[UIScenePresentationManager alloc] → -_initWithScene:scene
/// 故意把 _initWithScene: 的返回值当 void：它按初始化器惯例返回 self，
/// 这样 alloc 的 +1 所有权刚好由 ARC 接管；随后对象存进静态 strong 变量长期存活。
static id MFCreatePresentationManager(id scene) {
    if (scene == nil) return nil;

    Class cls = objc_getClass("UIScenePresentationManager");
    if (cls == Nil) {
        MFLog(@"[pres] !! 本机没有 UIScenePresentationManager 类");
        return nil;
    }
    SEL initSel = NSSelectorFromString(@"_initWithScene:");
    if (![cls instancesRespondToSelector:initSel]) {
        MFLog(@"[pres] !! UIScenePresentationManager 没有 _initWithScene:，无法自建");
        return nil;
    }

    id pm = ((id (*)(id, SEL))objc_msgSend)((id)cls, NSSelectorFromString(@"alloc"));
    ((void (*)(id, SEL, id))objc_msgSend)(pm, initSel, scene);
    return pm;
}

/// Route A2 主流程。成功返回可直接挂进浮窗的 UIView；失败返回 nil（调用方退回 Route B）。
static UIView *MFTryPresenterRoute(id scene, NSDictionary *config) {
    if (scene == nil) return nil;

    // ---- P1：自建 presentation manager ----
    MFStepMark(kMFStepPm);
    id pm = MFCreatePresentationManager(scene);
    MFLog(@"[pres] UIScenePresentationManager=%@", pm ? NSStringFromClass([pm class]) : @"nil");
    MFStepOk(kMFStepPm);
    if (pm == nil) return nil;
    gMFPM = pm;

    // ---- P2：把 resizesHostedContext 写进默认呈现上下文（命门）----
    // 不设它，宿主 scene 仍按整屏尺寸渲染，浮窗里必然错位或黑屏。
    MFStepMark(kMFStepCtx);
    SEL modifySel = NSSelectorFromString(@"modifyDefaultPresentationContext:");
    if ([pm respondsToSelector:modifySel]) {
        @try {
            void (^blk)(id) = ^(id mc) {
                SEL s = NSSelectorFromString(@"setResizesHostedContext:");
                if ([mc respondsToSelector:s]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(mc, s, YES);
                    MFLog(@"[pres] 已在 %@ 上设 resizesHostedContext=YES", NSStringFromClass([mc class]));
                } else {
                    MFLog(@"[pres] %@ 没有 setResizesHostedContext:", NSStringFromClass([mc class]));
                }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(pm, modifySel, (id)blk);
        } @catch (NSException *e) {
            MFLog(@"[pres] modifyDefaultPresentationContext 抛异常: %@", e.reason);
        }
    } else {
        MFLog(@"[pres] manager 没有 modifyDefaultPresentationContext:（跳过）");
    }
    id defCtx = MFMsg(pm, NSSelectorFromString(@"defaultPresentationContext"));
    MFLog(@"[pres] defaultPresentationContext=%@ resizesHostedContext=%d",
         defCtx ? NSStringFromClass([defCtx class]) : @"nil",
         (int)MFBoolProp(defCtx, NSSelectorFromString(@"resizesHostedContext")));
    MFStepOk(kMFStepCtx);

    // ---- P3：建 presenter ----
    MFStepMark(kMFStepPres);
    id pres = nil;
    SEL mk2 = NSSelectorFromString(@"createPresenterWithIdentifier:priority:");
    SEL mk1 = NSSelectorFromString(@"createPresenterWithIdentifier:");
    @try {
        if ([pm respondsToSelector:mk2]) {
            pres = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(pm, mk2, @"MultiFloat", (NSInteger)0);
        } else if ([pm respondsToSelector:mk1]) {
            pres = ((id (*)(id, SEL, id))objc_msgSend)(pm, mk1, @"MultiFloat");
        } else {
            MFLog(@"[pres] manager 两个 createPresenter 都没有");
        }
    } @catch (NSException *e) {
        MFLog(@"[pres] createPresenter 抛异常: %@", e.reason);
    }
    MFLog(@"[pres] presenter=%@", pres ? NSStringFromClass([pres class]) : @"nil");
    MFStepOk(kMFStepPres);
    if (pres == nil) return nil;
    gMFPresenter = pres;

    // ---- P4：activate ----
    MFStepMark(kMFStepAct);
    SEL actSel = NSSelectorFromString(@"activate");
    if ([pres respondsToSelector:actSel]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(pres, actSel);
        } @catch (NSException *e) {
            MFLog(@"[pres] activate 抛异常: %@", e.reason);
        }
    } else {
        MFLog(@"[pres] presenter 没有 activate（不致命，继续取视图）");
    }
    MFStepOk(kMFStepAct);

    // ---- P4b 已删除（0.6.0 的 forceActivate）----
    // 真机实测：开着 forceActivate 的那一轮，S7-settle 写出后 20 秒内存活窗口都还没走完
    // 进程就没了（MF-crash-attribution.txt: crashedStep=S7-settle）。
    // 也就是说它不是同步崩溃，而是把 SpringBoard 弄进了一个几秒后才爆的状态。
    // 0.7.0 改用"改 settings"（P0）这种非侵入手段，不再碰 activateWithTransitionContext:。
    (void)config;
    MFLogS(@"[pres] （Route 2 旧路）已不包含 forceActivate —— 改用 P0 的 settings 方案");

    // ---- P5：取呈现视图 ----
    MFStepMark(kMFStepPView);
    id v = MFMsg(pres, NSSelectorFromString(@"presentationView"));
    MFLog(@"[pres] presentationView=%@ frame=%@",
         v ? NSStringFromClass([v class]) : @"nil",
         [v isKindOfClass:[UIView class]] ? NSStringFromCGRect(((UIView *)v).frame) : @"-");
    MFStepOk(kMFStepPView);

    return [v isKindOfClass:[UIView class]] ? (UIView *)v : nil;
}

#pragma mark ========== 0.7.0：带类型的消息发送（全部守卫）==========

// 这些 helper 只做一件事：在 respondsToSelector + @try 两层保护下按**正确 ABI**发消息。
// 0.3.0 的崩溃就是"参数类型/可空性想当然"造成的，这里不再犯。
static void MFMvBool(id o, NSString *selName, BOOL v) {
    if (o == nil || selName == nil) return;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(o, s, v); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); }
}

static void MFMvDouble(id o, NSString *selName, double v) {
    if (o == nil || selName == nil) return;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, double))objc_msgSend)(o, s, v); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); }
}

static void MFMvLong(id o, NSString *selName, long v) {
    if (o == nil || selName == nil) return;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, long))objc_msgSend)(o, s, v); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); }
}

static void MFMvRect(id o, NSString *selName, CGRect r) {
    if (o == nil || selName == nil) return;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, CGRect))objc_msgSend)(o, s, r); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); }
}

static id MFMvObj(id o, NSString *selName, id a) {
    if (o == nil || selName == nil) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(o, s, a); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); return nil; }
}

static id MFMvObj2(id o, NSString *selName, id a, id b) {
    if (o == nil || selName == nil) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, id, id))objc_msgSend)(o, s, a, b); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); return nil; }
}

/// 按名字取类对象（objc_getClass 不会 realize 任何类，安全）
static id MFCls(NSString *name) {
    if (name.length == 0) return nil;
    Class c = objc_getClass(name.UTF8String);
    return c ? (id)c : nil;
}

static double MFDProp(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return 0.0;
    if (![obj respondsToSelector:sel]) return 0.0;
    @try { return ((double (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (NSException *e) { return 0.0; }
}

/// KVC 取一串"能打印的东西"，失败返回 <无>
static NSString *MFKV(id obj, NSString *key) {
    if (obj == nil || key == nil) return @"nil";
    @try {
        id v = [obj valueForKey:key];
        if (v == nil) return @"nil";
        return [NSString stringWithFormat:@"%@", v];
    } @catch (NSException *e) { return @"<无>"; }
}

/// KVC 取容器元素个数（hostedLayers / nonHostedLayers 这类）
static NSInteger MFKVCount(id obj, NSString *key) {
    if (obj == nil || key == nil) return -1;
    @try {
        id v = [obj valueForKey:key];
        if (v == nil) return -1;
        if ([v respondsToSelector:@selector(count)]) return (NSInteger)[v count];
        return -1;
    } @catch (NSException *e) { return -1; }
}

#pragma mark ========== 0.7.0：P0 —— 让 scene 变成"可渲染" ==========

/// 把目标 scene 的 settings 拉成"前台 + 在该屏 + 竖屏"。
///
/// 为什么必须做：App 被切到后台后，它的 scene settings 里 foreground=NO，
/// App 进程不会再往这个 scene 里渲染 —— 这种 scene 就算被 presenter 正确承载，
/// 拿到的也只是一块没有内容的表面。
/// 公开可用的实现（khanhduytran0/FrontBoardAppLauncher）在**创建** scene 时就直接给了
///     settings.foreground = YES;
///     settings.level = 1;
///     settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
///     settings.interfaceOrientation = UIInterfaceOrientationPortrait;
/// 我们这里对**已存在**的 scene 做同样的事（唯一区别是用 updateSettingsWithBlock: 原地改）。
static void MFForceSceneRenderable(id scene) {
    if (scene == nil) return;

    id before = MFMsg(scene, NSSelectorFromString(@"settings"));
    MFLog(@"[pres] P0 前 settings: foreground=%d level=%.1f frame=%@ contentState=%ld active=%d",
         (int)MFBoolProp(before, NSSelectorFromString(@"foreground")),
         MFDProp(before, NSSelectorFromString(@"level")),
         MFKV(before, @"frame") ?: @"-",
         (long)MFIntProp(scene, NSSelectorFromString(@"contentState")),
         (int)MFBoolProp(scene, NSSelectorFromString(@"isActive")));

    SEL upd = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (![scene respondsToSelector:upd]) {
        MFLogS(@"[pres] !! scene 没有 updateSettingsWithBlock:，P0 跳过");
        return;
    }

    id dc = MFMsg([UIScreen mainScreen], NSSelectorFromString(@"displayConfiguration"));

    void (^blk)(id) = ^(id st) {
        if (st == nil) return;
        MFMvBool(st,   @"setForeground:", YES);
        MFMvDouble(st, @"setLevel:", 1.0);
        MFMvLong(st,   @"setInterfaceOrientation:", (long)UIInterfaceOrientationPortrait);
        if (dc != nil) MFMvObj(st, @"setDisplayConfiguration:", dc);
    };

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, upd, (id)blk);
        MFLogS(@"[pres] P0 已发 updateSettingsWithBlock（foreground=YES / level=1 / portrait）");
    } @catch (NSException *e) {
        MFLog(@"[pres] P0 updateSettingsWithBlock 抛异常: %@", e.reason);
    }

    id after = MFMsg(scene, NSSelectorFromString(@"settings"));
    MFLog(@"[pres] P0 后 settings: foreground=%d level=%.1f frame=%@ contentState=%ld",
         (int)MFBoolProp(after, NSSelectorFromString(@"foreground")),
         MFDProp(after, NSSelectorFromString(@"level")),
         MFKV(after, @"frame") ?: @"-",
         (long)MFIntProp(scene, NSSelectorFromString(@"contentState")));
}

#pragma mark ========== 0.7.0：presenter 主链（Route 3 / Route 4 共用）==========

/// 把 scene 的渲染尺寸直接改成浮窗内容区大小。
/// 与 resizesHostedContext 是**两种不同的做法**，任选其一即可：
///   - resizesHostedContext=YES（P2，默认）：不动 scene 设置，由 presenter 把宿主内容缩放进浮窗
///   - 本函数：直接把 scene 的 frame 设成浮窗尺寸，让 App 自己按这个尺寸重新布局
/// 公开实现（FrontBoardAppLauncher）用的是后者；万一前者不出画面/尺寸不对，
/// 把配置 hostSceneFrame 设成 true 就能切到后者（原生分屏的手感）。
static void MFSetSceneFrame(id scene, CGRect frame) {
    if (scene == nil) return;
    SEL upd = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (![scene respondsToSelector:upd]) return;

    void (^blk)(id) = ^(id st) {
        if (st == nil) return;
        MFMvRect(st, @"setFrame:", frame);
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, upd, (id)blk);
        MFLog(@"[pres] 已把 scene.frame 设成 %@（hostSceneFrame=true）", NSStringFromCGRect(frame));
    } @catch (NSException *e) {
        MFLog(@"[pres] 设 scene.frame 抛异常: %@", e.reason);
    }
}

static id MFCreatePresenterForScene(id pm, NSString *ident) {
    if (pm == nil || ident.length == 0) return nil;
    SEL s2 = NSSelectorFromString(@"createPresenterWithIdentifier:priority:");
    SEL s1 = NSSelectorFromString(@"createPresenterWithIdentifier:");
    @try {
        if ([pm respondsToSelector:s2]) {
            return ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(pm, s2, ident, (NSInteger)0);
        }
        if ([pm respondsToSelector:s1]) {
            return ((id (*)(id, SEL, id))objc_msgSend)(pm, s1, ident);
        }
        MFLogS(@"[pres] manager 两个 createPresenter 都没有");
    } @catch (NSException *e) {
        MFLog(@"[pres] createPresenter 抛异常: %@", e.reason);
    }
    return nil;
}

/// presenter 完整链，返回可直接挂进浮窗的 presentationView。
///
/// **manager 一定优先取 scene 自己的**（`scene.uiPresentationManager`）——
/// 这是 0.6.0 黑屏的根因：自己 alloc 的 `_initWithScene:` manager 不在 scene 的
/// presenter owner 体系里，presenter 永远进不了 hosting 状态，
/// _UIScenePresentationView 就一直画 backgroundColorWhileNotHosting（黑）。
static UIView *MFPresentScene(id scene, NSString *sceneID, NSDictionary *config, NSString **outPMSource) {
    if (scene == nil || sceneID.length == 0) return nil;
    if (outPMSource) *outPMSource = @"?";

    // ---- P1：presentation manager（首选 scene 自己的）----
    MFStepMark(kMFStepPm);
    id pm = MFMsg(scene, NSSelectorFromString(@"uiPresentationManager"));
    NSString *src = @"scene.uiPresentationManager";
    if (pm == nil) {
        pm = MFCreatePresentationManager(scene);
        src = @"自建 _initWithScene:（0.6.0 旧法，已知进不了 hosting）";
    }
    MFLog(@"[pres] presentationManager=%@（来源=%@）", pm ? NSStringFromClass([pm class]) : @"nil", src);
    MFStepOk(kMFStepPm);
    if (pm == nil) return nil;
    gMFPM = pm;
    if (outPMSource) *outPMSource = src;

    // ---- P2：默认呈现上下文 ----
    MFStepMark(kMFStepCtx);
    if (MFConfigBool(config, @"resizesHosted", YES)) {
        SEL modifySel = NSSelectorFromString(@"modifyDefaultPresentationContext:");
        if ([pm respondsToSelector:modifySel]) {
            @try {
                void (^blk)(id) = ^(id mc) {
                    if (mc == nil) return;
                    MFMvBool(mc, @"setResizesHostedContext:", YES);
                    MFLog(@"[pres] 已在 %@ 上设 resizesHostedContext=YES",
                          NSStringFromClass([mc class]));
                };
                ((void (*)(id, SEL, id))objc_msgSend)(pm, modifySel, (id)blk);
            } @catch (NSException *e) {
                MFLog(@"[pres] modifyDefaultPresentationContext 抛异常: %@", e.reason);
            }
        } else {
            MFLogS(@"[pres] manager 没有 modifyDefaultPresentationContext:（跳过）");
        }
    } else {
        MFLogS(@"[pres] resizesHosted=false -> 不设 resizesHostedContext");
    }
    id defCtx = MFMsg(pm, NSSelectorFromString(@"defaultPresentationContext"));
    MFLog(@"[pres] defaultPresentationContext=%@ resizesHostedContext=%d",
         defCtx ? NSStringFromClass([defCtx class]) : @"nil",
         (int)MFBoolProp(defCtx, NSSelectorFromString(@"resizesHostedContext")));
    MFStepOk(kMFStepCtx);

    // ---- P3：建 presenter ----
    MFStepMark(kMFStepPres);
    id pres = MFCreatePresenterForScene(pm, sceneID);
    MFLog(@"[pres] presenter=%@", pres ? NSStringFromClass([pres class]) : @"nil");
    MFStepOk(kMFStepPres);
    if (pres == nil) return nil;
    gMFPresenter = pres;

    // ---- P3b：presenter 自己的呈现上下文（照抄 FrontBoardAppLauncher 的 appearanceStyle=2）----
    SEL presModify = NSSelectorFromString(@"modifyPresentationContext:");
    if ([pres respondsToSelector:presModify]) {
        @try {
            void (^blk)(id) = ^(id mc) {
                if (mc == nil) return;
                MFMvLong(mc, @"setAppearanceStyle:", 2);
            };
            ((void (*)(id, SEL, id))objc_msgSend)(pres, presModify, (id)blk);
            MFLogS(@"[pres] P3b 已设 appearanceStyle=2（FrontBoardAppLauncher 同款）");
        } @catch (NSException *e) {
            MFLog(@"[pres] modifyPresentationContext 抛异常: %@", e.reason);
        }
    } else {
        MFLogS(@"[pres] presenter 没有 modifyPresentationContext:（跳过）");
    }

    // ---- P4：activate ----
    MFStepMark(kMFStepAct);
    SEL actSel = NSSelectorFromString(@"activate");
    if ([pres respondsToSelector:actSel]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(pres, actSel);
        } @catch (NSException *e) {
            MFLog(@"[pres] activate 抛异常: %@", e.reason);
        }
    } else {
        MFLogS(@"[pres] presenter 没有 activate（不致命，继续取视图）");
    }
    MFStepOk(kMFStepAct);

    // ---- P5：取呈现视图 ----
    MFStepMark(kMFStepPView);
    id v = MFMsg(pres, NSSelectorFromString(@"presentationView"));
    MFLog(@"[pres] presentationView=%@ frame=%@",
         v ? NSStringFromClass([v class]) : @"nil",
         [v isKindOfClass:[UIView class]] ? NSStringFromCGRect(((UIView *)v).frame) : @"-");
    MFStepOk(kMFStepPView);

    return [v isKindOfClass:[UIView class]] ? (UIView *)v : nil;
}

/// 挂载后打印 presenter / 图层宿主的真实状态。
/// 这是 0.7.0 专门为"万一下一轮还得改"准备的第一手证据：
///   isHosting=0  => presenter 没进 hosting（manager 来源不对，或 scene 不可渲染）
///   isHosting=1 且 hostedLayers=0 => presenter 在承载，但 scene 没有可放的图层
///   isHosting=1 且 hostedLayers>0 但仍旧黑 => 是尺寸/变换/层级问题，不是内容问题
static void MFLogPresenterState(NSString *tag, id pres, id view) {
    MFLog(@"[pres] %@ presenter=%@ isActive=%d isHosting=%d isInvalidated=%d",
         tag,
         pres ? NSStringFromClass([pres class]) : @"nil",
         (int)MFBoolProp(pres, NSSelectorFromString(@"isActive")),
         (int)MFBoolProp(pres, NSSelectorFromString(@"isHosting")),
         (int)MFBoolProp(pres, NSSelectorFromString(@"isInvalidated")));

    if (![view isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)view;
    id host = MFMsg(v, NSSelectorFromString(@"hostContainerView"));
    MFLog(@"[pres] %@ view=%@ frame=%@ subviews=%lu hostContainer=%@",
         tag, NSStringFromClass([view class]), NSStringFromCGRect(v.frame),
         (unsigned long)v.subviews.count,
         host ? NSStringFromClass([host class]) : @"nil");
    if (host != nil) {
        MFLog(@"[pres] %@ hostContainer hostedLayers=%ld nonHostedLayers=%ld hostViews=%ld",
             tag,
             (long)MFKVCount(host, @"hostedLayers"),
             (long)MFKVCount(host, @"nonHostedLayers"),
             (long)MFKVCount(host, @"_hostViews"));
    }
    id hostScene = MFMsg(pres, NSSelectorFromString(@"scene"));
    if (hostScene != nil) {
        id st = MFMsg(hostScene, NSSelectorFromString(@"settings"));
        id lm = MFMsg(hostScene, NSSelectorFromString(@"layerManager"));
        // 这几项能直接回答"SpringBoard 有没有把我们设的 foreground=YES 又改回去"：
        // 若 P0 后是 1、这里变成 0，说明 SB 的 _scene:interceptUpdateWithNewSettings: 覆盖了我们。
        MFLog(@"[pres] %@ scene=%@ foreground=%@ level=%@ frame=%@ contentState=%@ layers=%ld",
             tag, NSStringFromClass([hostScene class]),
             MFKV(st, @"foreground"), MFKV(st, @"level"), MFKV(st, @"frame"),
             MFKV(hostScene, @"contentState"), (long)MFKVCount(lm, @"layers"));
    }
}

#pragma mark ========== 0.7.0：Route 4 —— 自建 scene ==========

/// 完全照搬 khanhduytran0/FrontBoardAppLauncher 的 scene 构造：
///   FBSMutableSceneDefinition（新 identity + 目标 App 的进程身份）
///   + UIMutableApplicationSceneSettings（foreground=YES / frame / level / displayConfiguration）
///   + UIMutableApplicationSceneClientSettings
///   → [[FBSceneManager sharedInstance] createSceneWithDefinition:initialParameters:]
/// 拿到的是一个**全新的**、生来就是"前台可渲染"的 scene。
static id MFCreateOwnSceneForApp(NSString *bundleID, NSString *sceneID, CGRect frame) {
    id mgrCls = MFCls(@"FBSceneManager");
    id defCls = MFCls(@"FBSMutableSceneDefinition");
    id idnCls = MFCls(@"FBSSceneIdentity");
    id cliCls = MFCls(@"FBSSceneClientIdentity");
    id spcCls = MFCls(@"UIApplicationSceneSpecification");
    id parCls = MFCls(@"FBSMutableSceneParameters");
    id setCls = MFCls(@"UIMutableApplicationSceneSettings");
    id cstCls = MFCls(@"UIMutableApplicationSceneClientSettings");
    id rbsCls = MFCls(@"RBSProcessIdentity");

    if (mgrCls == nil || defCls == nil || idnCls == nil || cliCls == nil ||
        spcCls == nil || parCls == nil || setCls == nil || cstCls == nil || rbsCls == nil) {
        MFLog(@"[pres] Route4 缺类：mgr=%d def=%d idn=%d cli=%d spec=%d par=%d set=%d cset=%d rbs=%d",
              mgrCls != nil, defCls != nil, idnCls != nil, cliCls != nil, spcCls != nil,
              parCls != nil, setCls != nil, cstCls != nil, rbsCls != nil);
        return nil;
    }

    // ---- 定义 ----
    MFStepMark(kMFStepOwn);
    id procIdentity = MFMvObj(rbsCls, @"identityForEmbeddedApplicationIdentifier:", bundleID);
    id def = MFMsg(defCls, NSSelectorFromString(@"definition"));
    if (def == nil) { MFStepOk(kMFStepOwn); MFLogS(@"[pres] Route4 定义创建失败"); return nil; }

    MFMvObj(def, @"setIdentity:", MFMvObj(idnCls, @"identityForIdentifier:", sceneID));
    if (procIdentity != nil) MFMvObj(def, @"setClientIdentity:", MFMvObj(cliCls, @"identityForProcessIdentity:", procIdentity));
    id spec = MFMsg(spcCls, NSSelectorFromString(@"specification"));
    MFMvObj(def, @"setSpecification:", spec);
    MFLog(@"[pres] Route4 定义 identity=%@ client=%d spec=%@",
          MFKV(def, @"identity"), procIdentity != nil, spec ? NSStringFromClass([spec class]) : @"nil");

    // ---- 参数 ----
    id params = MFMvObj(parCls, @"parametersForSpecification:", spec);
    if (params == nil) { MFStepOk(kMFStepOwn); MFLogS(@"[pres] Route4 parameters 创建失败"); return nil; }

    id st = MFMsg(setCls, NSSelectorFromString(@"new"));
    MFMvBool(st,   @"setForeground:", YES);
    MFMvDouble(st, @"setLevel:", 1.0);
    MFMvBool(st,   @"setCanShowAlerts:", YES);
    MFMvBool(st,   @"setStatusBarDisabled:", YES);
    MFMvLong(st,   @"setInterfaceOrientation:", (long)UIInterfaceOrientationPortrait);
    MFMvRect(st,   @"setFrame:", frame);
    MFMvObj(st,    @"setPersistenceIdentifier:", sceneID);
    id dc = MFMsg([UIScreen mainScreen], NSSelectorFromString(@"displayConfiguration"));
    if (dc != nil) MFMvObj(st, @"setDisplayConfiguration:", dc);
    MFMvObj(params, @"setSettings:", st);

    id cs = MFMsg(cstCls, NSSelectorFromString(@"new"));
    MFMvLong(cs, @"setInterfaceOrientation:", (long)UIInterfaceOrientationPortrait);
    MFMvLong(cs, @"setStatusBarStyle:", 0);
    MFMvObj(params, @"setClientSettings:", cs);

    // ---- 建 scene ----
    id mgr = MFMsg(mgrCls, NSSelectorFromString(@"sharedInstance"));
    id scene = MFMvObj2(mgr, @"createSceneWithDefinition:initialParameters:", def, params);
    MFStepOk(kMFStepOwn);
    MFLog(@"[pres] Route4 createSceneWithDefinition -> %@（mgr=%@）",
          scene ? NSStringFromClass([scene class]) : @"nil",
          mgr ? NSStringFromClass([mgr class]) : @"nil");
    return scene;
}

/// 能力报告：把关键类的"自有方法表"和目标对象的 responds 矩阵写到
/// /var/mobile/MF-presenter-report.txt。**纯读元数据**（class_copyMethodList / respondsToSelector），不发危险消息。
static void MFWritePresenterReport(NSString *bundleID, id scene, id handle, id hostVC) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"=== MultiFloat %@ presenter 能力报告 ===\n", MFVersionString()];
    [s appendFormat:@"bid=%@ t=%ld pid=%d\n\n", bundleID ?: @"?", (long)time(NULL), (int)getpid()];

    NSArray *classes = @[ @"UIScenePresentationManager", @"_UIScenePresenter", @"_UIScenePresenterOwner",
                          @"UIScenePresentationContext", @"UIMutableScenePresentationContext",
                          @"_UIScenePresentationView", @"_UISceneLayerHostView",
                          @"_UISceneLayerHostContainerView", @"UIApplicationSceneDeactivationManager",
                          @"SBDeviceApplicationSceneViewController",
                          // Route 4 需要的那一串（缺一个就造不出 scene）
                          @"FBSceneManager", @"FBSMutableSceneDefinition", @"FBSSceneIdentity",
                          @"FBSSceneClientIdentity", @"UIApplicationSceneSpecification",
                          @"FBSMutableSceneParameters", @"UIMutableApplicationSceneSettings",
                          @"UIMutableApplicationSceneClientSettings", @"RBSProcessIdentity",
                          @"RBSProcessHandle", @"FBProcessManager" ];
    for (NSString *cn in classes) {
        Class c = objc_getClass(cn.UTF8String);
        [s appendFormat:@"---- %@ : %@\n", cn, c ? @"存在" : @"不存在"];
        if (c == Nil) continue;
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        unsigned int lim = (n < 120) ? n : 120;
        for (unsigned int i = 0; i < lim; i++) {
            [s appendFormat:@"   - %s  %s\n", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i])];
        }
        if (ms != NULL) free(ms);
        [s appendFormat:@"   （自有方法 %u 个，列出 %u 个）\n", n, lim];
    }

    void (^dump)(NSString *, id) = ^(NSString *label, id obj) {
        if (obj == nil) {
            [s appendFormat:@"\n==== %@ : nil\n", label];
            return;
        }
        [s appendFormat:@"\n==== %@ : %@\n", label, NSStringFromClass([obj class])];
        const char *sels[] = {
            "contentState", "isActive", "isValid", "uiPresentationManager",
            "_createTransitionContext", "settings", "uiSettings", "display",
            "activate", "activateWithTransitionContext:", "deactivateWithTransitionContext:",
            "scene", "sceneHandle", "view", "presentationView", "resizesHostedContext",
            "setResizesHostedContext:", "setDisplayMode:", "displayMode", "setHostedContext:",
            "newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:",
            "application", "bundleIdentifier", "identifier", "setForeground:", "isForeground",
            "modifyPresentationContext:", "presentationContext", "deactivate", "invalidate",
            "setHidden:", "addSubview:"
        };
        for (unsigned k = 0; k < sizeof(sels) / sizeof(sels[0]); k++) {
            BOOL ok = [obj respondsToSelector:NSSelectorFromString([NSString stringWithUTF8String:sels[k]])];
            [s appendFormat:@"   %-30s %@\n", sels[k], ok ? @"YES" : @"-"];
        }
    };
    dump(@"scene", scene);
    dump(@"handle", handle);
    dump(@"hostVC(Route B)", hostVC);

    // ---- 0.7.0 新增：真正决定"黑不黑"的那几个取值 ----
    [s appendFormat:@"\n==== scene.settings 关键值 ====\n"];
    id st = MFMsg(scene, NSSelectorFromString(@"settings"));
    [s appendFormat:@"  foreground           = %@\n", MFKV(st, @"foreground")];
    [s appendFormat:@"  level                = %@\n", MFKV(st, @"level")];
    [s appendFormat:@"  frame                = %@\n", MFKV(st, @"frame")];
    [s appendFormat:@"  interfaceOrientation = %@\n", MFKV(st, @"interfaceOrientation")];
    [s appendFormat:@"  scene.contentState   = %@\n", MFKV(scene, @"contentState")];
    [s appendFormat:@"  scene.isActive       = %@\n", MFKV(scene, @"isActive")];
    id lm = MFMsg(scene, NSSelectorFromString(@"layerManager"));
    [s appendFormat:@"  scene.layerManager   = %@ layers=%ld\n",
     lm ? NSStringFromClass([lm class]) : @"nil", (long)MFKVCount(lm, @"layers")];

    [s appendFormat:@"\n==== presenter 状态（isHosting 就是黑屏的分水岭）====\n"];
    [s appendFormat:@"  isActive            = %@\n", MFKV(gMFPresenter, @"isActive")];
    [s appendFormat:@"  isHosting           = %@\n", MFKV(gMFPresenter, @"isHosting")];
    [s appendFormat:@"  identifier          = %@\n", MFKV(gMFPresenter, @"identifier")];
    [s appendFormat:@"  isInvalidated       = %@\n", MFKV(gMFPresenter, @"isInvalidated")];
    [s appendFormat:@"  presentationContext = %@\n", MFKV(gMFPresenter, @"presentationContext")];
    id pv = MFMsg(gMFPresenter, NSSelectorFromString(@"presentationView"));
    [s appendFormat:@"  presentationView    = %@\n", pv ? NSStringFromClass([pv class]) : @"nil"];
    if ([pv isKindOfClass:[UIView class]]) {
        id host = MFMsg(pv, NSSelectorFromString(@"hostContainerView"));
        [s appendFormat:@"  view.hostContainerView                    = %@\n", host ? NSStringFromClass([host class]) : @"nil"];
        [s appendFormat:@"  view.hostContainerView.hostedLayers       = %ld\n", (long)MFKVCount(host, @"hostedLayers")];
        [s appendFormat:@"  view.hostContainerView.nonHostedLayers    = %ld\n", (long)MFKVCount(host, @"nonHostedLayers")];
        [s appendFormat:@"  view.hostContainerView._hostViews         = %ld\n", (long)MFKVCount(host, @"_hostViews")];
    }

    [s appendFormat:@"\n==== 我们持有的对象（静态 strong）====\npm=%@\npresenter=%@\nhostVC=%@\nownScene=%@\n",
     gMFPM ? NSStringFromClass([gMFPM class]) : @"nil",
     gMFPresenter ? NSStringFromClass([gMFPresenter class]) : @"nil",
     gMFHostVC ? NSStringFromClass([gMFHostVC class]) : @"nil",
     gMFOwnScene ? NSStringFromClass([gMFOwnScene class]) : @"nil"];

    NSString *p = @"/var/mobile/MF-presenter-report.txt";
    BOOL ok = [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    MFLog(@"[pres] 能力报告已写 %@ ok=%d（%lu 字节）", p, (int)ok, (unsigned long)s.length);
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
/// 0.6.0：直接把一个 UIView 挂进内容区（Route A2 的 presentationView 走这里）
- (void)attachContentView:(UIView *)view;
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

- (void)attachContentView:(UIView *)view {
    [self attachContentViewController:nil];   // 清掉旧的承载内容
    if (view == nil) return;

    view.frame = self.contentArea.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentArea addSubview:view];
    MFLog(@"[ui] 已挂载承载视图(view) %@ frame=%@",
         NSStringFromClass([view class]), NSStringFromCGRect(view.frame));
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
                        @"4 拿承载视图（presenter / 宿主 VC）；5 设渲染尺寸；6 挂载视图。\n"
                        @"把 hostStep 调大一位再点一次应用名（不用 respring）就能继续。",
                        (long)limit, (long)limit]];
    [panel setStatusText:[NSString stringWithFormat:@"hostStep=%ld 上限停止", (long)limit]];
}

- (void)hostBundleID:(NSString *)bundleID {
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;

    MFLog(@"[host] ========== begin bid=%@ ==========", bundleID);

    // 【0.7.0】每次承载都重新读盘。
    // 原因：respring 会把目标 App 的 scene 一起杀掉，而调参（hostRoute / forceForeground /
    // resizesHosted）本来就得反复试。改成"点了才读"之后，用户在 Filza 改完 plist
    // 直接再点一次应用名就生效，**不用 respring**，也就不会丢掉想承载的那个 scene。
    NSDictionary *freshCfg = MFLoadConfig();
    if (freshCfg != nil) self.config = freshCfg;
    MFLog(@"[cfg] 本次生效配置：hostRoute=%ld forceForeground=%d resizesHosted=%d hostSceneFrame=%d hostStep=%ld",
          (long)MFConfigInt(self.config, @"hostRoute", 3),
          (int)MFConfigBool(self.config, @"forceForeground", YES),
          (int)MFConfigBool(self.config, @"resizesHosted", YES),
          (int)MFConfigBool(self.config, @"hostSceneFrame", NO),
          (long)MFConfigInt(self.config, @"hostStep", 6));

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

    // ---------- S4：取"呈现载体"（0.7.0 起四条路，默认 3）----------
    //   hostRoute=3  接管已存在的 scene，用 **scene 自己的** uiPresentationManager 取 presenter
    //                （前面加 P0：把 scene settings 拉成 foreground=YES/level=1/portrait）
    //   hostRoute=4  自己 createSceneWithDefinition: 造一个新 scene 再呈现（FrontBoardAppLauncher 原版）
    //   hostRoute=2  0.6.0 的旧路（自建 _initWithScene: manager）—— 实测黑屏，仅留做 A/B 对照
    //   hostRoute=1  0.5.0 的 Route B（SpringBoard 宿主 VC）—— 实测黑屏，仅兜底
    MFStepMark(kMFStepVC);

    NSInteger route = MFConfigInt(self.config, @"hostRoute", 3);
    if (route != 1 && route != 2 && route != 3 && route != 4) route = 3;
    NSString *routeName = (route == 3) ? @"3=接管已存在 scene（默认）"
                        : (route == 4) ? @"4=自建 scene 再呈现"
                        : (route == 2) ? @"2=旧版自建 _initWithScene: manager（已知黑屏）"
                        : @"1=SpringBoard 宿主 VC（已知黑屏）";
    MFLog(@"[host] hostRoute=%ld（%@）", (long)route, routeName);

    UIView *contentView = nil;
    id hostVC = nil;
    id targetScene = scene;

    // ---------- P0：让 scene 变成"可渲染"（route 3/4 才需要）----------
    // route=4 自己造的 scene 生来就是 foreground=YES，不用再拉。
    if (route == 3) {
        if (MFConfigBool(self.config, @"forceForeground", YES)) {
            MFStepMark(kMFStepP0);
            MFForceSceneRenderable(scene);
            MFStepOk(kMFStepP0);
        } else {
            MFLogS(@"[pres] forceForeground=false -> 跳过 P0（不改 scene settings）");
        }
    }

    // 可选：直接把 scene 的 frame 设成浮窗内容区尺寸（与 resizesHostedContext 二选一）
    if ((route == 3 || route == 4) && MFConfigBool(self.config, @"hostSceneFrame", NO)) {
        MFStepMark(kMFStepP0);
        MFSetSceneFrame(targetScene, panel.contentArea.bounds);
        MFStepOk(kMFStepP0);
    }

    // ---------- Route 4：先造一个属于我们的 scene ----------
    if (route == 4) {
        NSString *ownID = [NSString stringWithFormat:@"sceneID:%@-multifloat", bundleID];
        id ownScene = MFCreateOwnSceneForApp(bundleID, ownID, panel.contentArea.bounds);
        if (ownScene != nil) {
            gMFOwnScene = ownScene;
            targetScene = ownScene;
            MFLogS(@"[host] Route 4 已造出属于我们的 scene，改用它作为承载目标");
        } else {
            MFLogS(@"[host] Route 4 造 scene 失败 -> 退回 route 3（接管已存在的 scene）");
        }
    }

    if (route == 3 || route == 4) {
        NSString *pmSource = @"?";
        contentView = MFPresentScene(targetScene,
                                     [NSString stringWithFormat:@"MultiFloat-%@", bundleID],
                                     self.config, &pmSource);
        MFLog(@"[host] Route %ld 结果 -> %@（manager 来源：%@）",
              (long)route, contentView ? @"拿到呈现视图" : @"失败", pmSource);
    } else if (route == 2) {
        contentView = MFTryPresenterRoute(scene, self.config);
        MFLog(@"[host] Route 2(旧 A2) -> %@", contentView ? @"拿到呈现视图" : @"失败");
    }

    if (contentView == nil) {
        hostVC = MFMsg(handle, NSSelectorFromString(@"newSceneViewController"));
        MFLog(@"[host] 兜底 Route B newSceneViewController=%@", hostVC ? NSStringFromClass([hostVC class]) : @"nil");
        gMFHostVC = hostVC;   // 静态 strong 持有，否则出作用域就释放 -> 黑屏
    }
    MFWritePresenterReport(bundleID, scene, handle, hostVC);
    MFStepOk(kMFStepVC);

    if (contentView == nil && hostVC == nil) {
        [self fail:@"所有承载路线都失败"
             detail:@"route 3/4（presenter）与 route 1（SpringBoard 宿主 VC）都没拿到可挂载的东西。\n"
                    @"请看 /var/mobile/MF-presenter-report.txt —— 里面记录了每个类的方法表、"
                    @"scene.settings 的真实取值，以及 presenter 的 isHosting。"];
        return;
    }
    if (limit < 5) { [self stopAtStep:5 limit:limit]; return; }

    // ---------- S5：让宿主按浮窗尺寸渲染 ----------
    MFStepMark(kMFStepResize);
    if (hostVC != nil) {
        // Route B：在宿主 VC 上设；不设的话 scene 按整屏渲染，画面必然错位。
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
        MFLog(@"[host] Route B setSceneResizesHostedContext:YES -> %@",
             resizeOK ? @"已设置" : @"未设置（宿主可能按整屏渲染）");
    } else {
        // Route 3/4：resizesHostedContext 已在 P2 写进呈现上下文，这里只做确认。
        MFLog(@"[host] Route %ld 的 resizesHostedContext 已在 P2 写入呈现上下文", (long)route);
    }
    MFStepOk(kMFStepResize);

    if (limit < 6) { [self stopAtStep:6 limit:limit]; return; }

    // ---------- S6：把承载视图挂进浮窗 ----------
    // 【0.4.0 起】这里之后**不再**调 FBScene -activateWithTransitionContext:nil（0.3.0 的崩点），
    // 也不再有任何 forceActivate 实验（0.6.0 实测它会让 SpringBoard 在存活窗口内挂掉）。
    MFStepMark(kMFStepAttach);
    if (contentView != nil) {
        [panel attachContentView:contentView];
    } else {
        [panel attachContentViewController:hostVC];
    }
    MFStepOk(kMFStepAttach);

    // ---------- P6：把 presenter / 图层宿主的真实状态写下来 ----------
    // 这是判断"还黑不黑"的第一手证据，也是下一版唯一的依据：
    //   isHosting=0                    -> presenter 没进 hosting（manager 来源不对 / scene 不可渲染）
    //   isHosting=1 且 hostedLayers=0  -> presenter 在承载，但 scene 一个图层都没有（App 没在渲染）
    //   isHosting=1 且 hostedLayers>0  -> 内容其实进来了，黑屏就只是尺寸/变换/层级问题
    MFStepMark(kMFStepState);
    id stateView = contentView;
    if (stateView == nil) stateView = MFMsg(hostVC, NSSelectorFromString(@"view"));
    MFLogPresenterState(@"P6", gMFPresenter, stateView);
    MFStepOk(kMFStepState);

    [panel setStatusText:[NSString stringWithFormat:@"已承载 %@", bundleID]];

    // ---------- S7：存活确认 ----------
    // 链路走完还不够：宿主视图真正开始渲染是异步的，有些断言在之后几十毫秒~几秒才炸。
    // 所以标记要等 20 秒才清；只有"本次承载仍是最新一次"才允许清（防止误清下一轮的标记）。
    MFStepMark(kMFStepSettle);
    MFLog(@"[host] ========== done bid=%@ （20 秒后确认存活）==========", bundleID);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.hostSeq != mySeq) return;
        // 3 秒时再采一次状态：presenter 的 hosting 是**异步**建立的，
        // 很多情况下挂载那一刻还不是 hosting，要等一轮 runloop / 一次 scene update。
        MFLogPresenterState(@"P6+3s", gMFPresenter, stateView);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.hostSeq != mySeq) return;   // 期间又发起过承载 -> 不是本轮的事
        MFLogPresenterState(@"P6+20s", gMFPresenter, stateView);
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
