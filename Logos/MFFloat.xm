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
//  ============ 0.8.0 修的是什么（真机结果：归档(7)）============
//  0.7.0 真机：**第一次真的出画面了**。这次是三个具体缺陷，不是方向错。
//
//  (1) route 3 画面比例不对 —— 根因：presentationView 的自然尺寸 = scene.settings.frame。
//      我们用的真实 scene 是 430x932（整屏，宽高比 0.46），而浮窗内容区是 267x336.6
//      （宽高比 0.79）；presenter 把 0.46 的画面塞进 0.79 的视图 => 拉伸/错位。
//      对照证据：route 4 之所以比例正常，正是因为它建 scene 时就把 frame 设成了
//      contentArea.bounds（日志 P6: scene frame 与 view frame 完全相等）。
//      => 0.8.0 把 hostSceneFrame 默认改成 YES：**承载前先把 scene.frame 设成内容区尺寸**，
//         让宽高比天然一致（这才是原生分屏的做法）；挂载后再同步一次（异步布局会拖后腿），
//         用户拖 ◢ 缩放后也会重新同步。
//
//  (2) route 4 触发安全模式 —— 根因：**同一个 scene identity 被 createSceneWithDefinition:
//      建了第二次**。崩溃归因 crashedStep=P4-scene，MF-host-step-prev.txt 恰好停在
//      `>>> P4-scene`；而同一个 SpringBoard pid(19006) 在 t=291 已经用
//      identity=sceneID:com.apple.mobilesafari-multifloat 建过一次并成功了。
//      FBSceneManager 对重复 identity 直接断言 => SpringBoard 挂 => 安全模式。
//      => 0.8.0：自有 scene **缓存复用**（同一个 App 这辈子只建一次，之后只是重新呈现）；
//         换 App 时先用 destroyScene:withTransitionContext:（配 FBScene -_createTransitionContext
//         造的非空上下文）销毁旧的；建之前先查 sceneWithIdentifier:，已存在就**接管**而不是新建。
//         每个进程每个 App 硬上限 1 次新建。
//
//  (3) presenter "already in use" 被静默降级成黑屏 —— 日志里每次重试都出现
//          createPresenter 抛异常: Cannot create a presenter with this identifier as it's already in use.
//      旧代码一失败就退回 Route B（SBDeviceApplicationSceneViewController），
//      而 Route B 是已知纯黑 —— 于是"重试 = 画面变黑"。用户看到的就是这个。
//      => 0.8.0：presenter 同 scene + 同 identifier 且未 invalidated 时**复用**（必要时 activate），
//         换目标时才 deactivate + invalidate 再重建；presenter 失败**不再静默退 Route B**，
//         而是明确报错（除非配置 allowRouteB=true 显式开启）。
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

// ============ 0.8.0 新增的步骤名 ============
static NSString *const kMFStepReuse   = @"P3a-reuse";  // presenter 复用（不再重复 createPresenter）
static NSString *const kMFStepVoid    = @"P3c-void";   // 销毁上一个 presenter（deactivate+invalidate）
static NSString *const kMFStepDel     = @"P4a-del";    // Route 4：销毁上一个自有 scene
static NSString *const kMFStepGeom    = @"P7-geom";    // 把 scene.frame 同步成浮窗内容区尺寸

// 0.6.0：ARC 下必须把"我们真正持有的"对象放进静态 strong 变量。
// 否则局部变量一出作用域就被释放 —— 那个 presenter/宿主 VC 一死，浮窗里立刻变黑。
static id gMFPM        = nil;   // UIScenePresentationManager
static id gMFPresenter = nil;   // _UIScenePresenter
static id gMFHostVC    = nil;   // Route B 的宿主 VC
static id gMFOwnScene  = nil;   // Route 4 自己造出来的 FBScene（必须持有，否则立刻失效）

// 0.8.0：把"我持有的这些东西属于谁"记下来。
// 没有这三个变量，就会出现"同一个 identity 被建两次"（route 4 崩 SpringBoard）
// 和"同一个 identifier 的 presenter 被建两次"（抛异常后静默变黑屏）两个真机事故。
static NSString *gMFOwnSceneBundleID   = nil;   // gMFOwnScene 是给哪个 App 建的
static NSString *gMFOwnSceneIdentity   = nil;   // gMFOwnScene 的 FBSSceneIdentity
static NSString *gMFPresenterIdentifier = nil;  // gMFPresenter 的 identifier
static id        gMFPresenterScene      = nil;  // gMFPresenter 挂在哪个 scene 上
static id        gMFCurrentScene        = nil;  // 本轮承载的目标 scene（供缩放时重新同步几何）
static id        gMFCurrentContentView  = nil;  // 本轮挂上去的承载视图

// 【0.10.0 新增】scene.frame 的**唯一真源**：浮窗内容区的尺寸。
// 0.9.x 拿 presentationView.bounds 当尺寸源，而它在 presenter 掉 hosting 时会被系统改成整屏
// 430x932；我们把 430x932 写回 scene.frame => 比例崩 + 又一次重排 => 下一拍又"发现漂了"再写。
// 正反馈闭环，归档(10) 复现。从此只信 panel.contentArea.bounds（我们自己的视图，尺寸可控）。
static CGSize gMFDesiredContentSize = {0, 0};
// 【0.23.0】用户手势让路闸门：缩放手势进行中（及结束后 1.5s）守护不许掰几何 ——
// 归档(24) 实证"右下角缩放手势失效"的主因：承载/恢复后的几何按住窗口里，
// 守护逐拍把用户刚拖出的 win/scene 几何写回旧值 = 用户怎么拖都"弹回去"。
static NSTimeInterval gMFUserGestureUntil = 0.0;
static inline BOOL MFUserGestureActive(void) {
    return [NSDate timeIntervalSinceReferenceDate] < gMFUserGestureUntil;
}
static BOOL   gMFDesiredContentValid = NO;

// 【0.11.0 新增】承载视图"应该待在哪个内容区里"，以及 frame 写入备忘。
//
// 归档(11) 的 Filza 轮：P6+20s 时 scene 自己是好的（layers=2 contentState=2），
// 但 presenter.isHosting=0、hostContainer=nil、presentationView 被系统改成整屏 430x932
// —— 黑的不是 scene，是**承载**。这种情况写 scene settings 一点用都没有，只会白送一次重排。
// 所以要能把视图放回内容区，就得记住内容区是谁。
static UIView *gMFCurrentContentArea = nil;

// 【0.11.0 新增】"刚刚写过这个 frame"的备忘，用来把**挂载时的两次 settings 写合并成一次**。
// 归档(11) 的挂载序列是：P0 写一次（那时还没登记目标尺寸 ⇒ 不含 frame）→ 紧接着
// MFSyncSceneGeometry 再写一次（补 frame）。两次写 = 两次 SpringBoard 重算。
// 现在 P0 之前就登记目标尺寸，P0 的 block 里已经带了 setFrame:；这一层备忘拦住随后的重复写。
static id             gMFFrameMemoScene = nil;
static CGRect         gMFFrameMemoRect  = {{0, 0}, {0, 0}};
static NSTimeInterval gMFFrameMemoTime  = 0;

// 【0.13.0 新增】两件"别再自欺欺人"的事：
//
// ① 可变 settings 上的 setter 到底存不存在 —— 只探一次就写进日志。
//    归档(13) 那个存在性矩阵探的是 `scene.settings`（**不可变**对象），所以
//    `setIdleModeEnabled:` / `setDeactivationReasons:` 报 `-`，而它们在
//    `UIMutableApplicationSceneSettings` 上明明是有的（类 dump 里能看到）。
//    探错对象 = 结论全错。以后只在 `updateSettingsWithBlock:` 的 block 参数上探 —— 那
//    才是我们真正写入的那个对象。
static BOOL gMFProbedMutableSetters = NO;

// ② `setForeground:` 到底**管不管用** —— 写完读回 `FBScene.foreground` 验证。
//    如果连着几次写完读回仍然是 0，说明本机这个 setter 是空的，就**停止再试**，
//    否则每拍写一次 = 每拍闪一次（就是 0.9.1 的老毛病）。每次重新承载时重置。
static BOOL      gMFFgUsable = YES;
static NSInteger gMFFgFailStreak = 0;

// 【0.14.0 新增】③ `setDeactivationReasons:` 到底**管不管用** —— 同样写完读回验证。
//
// 归档(14) 把"不黑但闪"的账算清楚了：
//   预防档的**差量判据**是 `h.deact != 0`，而本机的常态就是 `deact = 32`（画面好好的），
//   于是**每一拍都有"差量"** ⇒ 每拍都调一次 `updateSettingsWithBlock:` ⇒
//   每拍一次 SpringBoard 全量重算 + scene 重新提交 ⇒ 屏幕上就是持续地"闪"。
//   更糟的是这个写**根本写不进去**：日志里 `已写 settings（预防差量(deact=1)）-> deact=32`，
//   写完读回还是 32 —— 属于"纯亏"：付了一次重排的代价，换回 0 收益。
// ⇒ 0.14.0 给这一项装上**和 setForeground 一样的熔断**：写完读回若仍是原值，
//   连败 N 次就**停止再写它**。判据是"实测有效才继续用"，而不是"理论上该有用就一直写"。
//   （阈值可配：keepAliveDeactFuse，0 = 不熔断，用于 A/B 复现 0.13.0 的持续闪。）
static BOOL      gMFDeactUsable = YES;
static NSInteger gMFDeactFailStreak = 0;

// 【0.14.0 新增】④ 真黑恢复的**分级档位**（tier）。
//
// 归档(14) 的日志里，"真黑 → 恢复"是一次事件里最刺眼的那一下：
//   真黑第 1 拍 ⇒ 我们立刻发"全量写"，而全量写里含 `setDisplayConfiguration:`
//   —— 它**会把 frame 打回整屏 430x932**，紧接着的 `setFrame:` 再改回浮窗尺寸。
//   一次写换来**两次几何重排**，画面从整屏"跳"回浮窗 ⇒ 用户看到的就是那一下闪。
// ⇒ 0.14.0 把恢复动作拆成三级，**从最温和的一级试起**，哪一级救回来就停在哪一级：
//     L1 = 只写状态量（fg / idle / deact / level），**一个几何字节都不碰** ⇒ 零几何变化 = 零可见闪
//     L2 = L1 + `setFrame:`（仅当尺寸真的漂了）⇒ 一次重排
//     L3 = L2 + `setDisplayConfiguration:`（0.13.0 的老全量写）⇒ 两次重排，最猛
//   绝大多数"一过性真黑"应该在第 1 拍就被 L1 拉回来 —— 那就永远走不到 L2/L3，也就不闪。
//   （开关：keepAliveTieredRestore，默认 YES；关掉则恒为 L3 = 回到 0.13.0 行为。）
static NSInteger gMFLastRestoreTier  = 0;   // 最近一次真黑恢复用的档位（1/2/3），供日志与统计
static NSInteger gMFRestoreTier1Hits = 0;   // L1 就救回来的次数（越接近"全部"越说明几何写是可以省的）
static NSInteger gMFRestoreTier2Hits = 0;   // 升到 L2 才救回来的次数
static NSInteger gMFRestoreTier3Hits = 0;   // 升到 L3 才救回来的次数

// 【0.17.0】tier 升级的"生效确认窗"：写完 L_n 后至少隔 2 拍才允许升 L_{n+1}。
// 为什么必须有：L1 写完的恢复是**异步**的（updateSettingsWithBlock ⇒ cs 2→0→1→2
// 要 400~800ms），写完下一拍采样 layers 仍是 0 ≠ L1 无效。
// 归档(17)：逐拍升级把"异步恢复中"误判成"无效" ⇒ L2×16 + L3×11 = 27 次几何写
//（上轮仅 1 次）⇒ 每次"内容变白再显示"。升档门槛同时从 2/3 提到 3/5。
static NSInteger gMFTierWriteDownTick = -1;  // 上一次写 tier 时的 downTicks（-1 = 新回合）
static NSInteger gMFTierLastWritten   = 0;   // 上一次实际写出的 tier（0 = 本回合还没写过）

// 【0.9.0】scene 守护（keep-alive）用到的状态。
// 声明放在这里而不是"函数旁边"，因为在它下面出现的 MFLogPresenterState 也要读它们。
static NSTimer *gMFKeepAliveTimer = nil;        // 守护定时器
static id       gMFKeepAliveScene = nil;        // 正在守护的 scene
static id       gMFKeepAliveApp   = nil;        // 目标 SBApplication（只用来打印 processState）

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

#pragma mark ========== 0.8.0：对象生命周期（复用 / 销毁）==========

// 这一节存在的唯一原因，是归档(7) 里的两个真机事故：
//   A) route 4 对同一个 identity 建了第二次 scene -> FBSceneManager 断言 -> SpringBoard 挂 -> 安全模式
//   B) 同一个 identifier 的 presenter 建了第二次 -> 抛 "already in use" -> 旧代码静默退 Route B（黑屏）
// 共同点都是"我们忘了自己手里已经有一个"。所以先把销毁/复用做干净，再谈功能。

/// 把当前持有的 presenter 收干净：先 deactivate 再 invalidate。
/// 只在"换承载目标"时调用；同一个 scene + 同一个 identifier 一律走复用（见 MFPresentScene）。
static void MFTeardownPresenter(void) {
    id pres = gMFPresenter;
    gMFPresenter = nil;
    gMFPresenterIdentifier = nil;
    gMFPresenterScene = nil;
    if (pres == nil) return;

    MFStepMark(kMFStepVoid);
    @try {
        MFMsg(pres, NSSelectorFromString(@"deactivate"));
        MFMsg(pres, NSSelectorFromString(@"invalidate"));
        MFLogS(@"[pres] 旧 presenter 已 deactivate + invalidate");
    } @catch (NSException *e) {
        MFLog(@"[pres] 销毁旧 presenter 抛异常: %@", e.reason);
    }
    MFStepOk(kMFStepVoid);
}

/// 销毁 route 4 自己造的那个 scene。
/// 一定带**非空** transition context —— 0.3.0 就是把 nil 喂给
/// activateWithTransitionContext: 崩的，同一个坑绝不踩第二次。
/// 拿不到上下文就干脆不销毁：宁可后面新建失败，也不能崩 SpringBoard。
static void MFTeardownOwnScene(void) {
    id s = gMFOwnScene;
    gMFOwnScene = nil;
    gMFOwnSceneBundleID = nil;
    gMFOwnSceneIdentity = nil;
    if (s == nil) return;

    MFStepMark(kMFStepDel);
    @try {
        id ctx = MFMsg(s, NSSelectorFromString(@"_createTransitionContext"));
        if (ctx == nil) {
            MFLogS(@"[pres] 拿不到 transition context -> 不做销毁（绝不能喂 nil）");
        } else {
            id mgr = MFMsg(MFCls(@"FBSceneManager"), NSSelectorFromString(@"sharedInstance"));
            SEL del = NSSelectorFromString(@"destroyScene:withTransitionContext:");
            if (mgr != nil && [mgr respondsToSelector:del]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, del, s, ctx);
                MFLog(@"[pres] 已 destroyScene 旧自有 scene（ctx=%@）", NSStringFromClass([ctx class]));
            } else {
                MFLogS(@"[pres] FBSceneManager 没有 destroyScene:withTransitionContext:（跳过销毁）");
            }
        }
    } @catch (NSException *e) {
        MFLog(@"[pres] destroyScene 抛异常: %@", e.reason);
    }
    MFStepOk(kMFStepDel);
}

/// 当前持有的自有 scene 还活着吗（FBScene.isValid）。
static BOOL MFOwnSceneIsAlive(void) {
    if (gMFOwnScene == nil) return NO;
    return MFBoolProp(gMFOwnScene, NSSelectorFromString(@"isValid"));
}

#pragma mark ========== 0.7.0：P0 —— 让 scene 变成"可渲染"（0.9.1 重写）==========

static void MFMvULL(id o, NSString *selName, unsigned long long v) {
    if (o == nil || selName == nil) return;
    SEL s = NSSelectorFromString(selName);
    if (![o respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, unsigned long long))objc_msgSend)(o, s, v); }
    @catch (NSException *e) { MFLog(@"[abi] %@ 抛异常: %@", selName, e.reason); }
}

/// 【0.9.1 新增 · 本轮最重要的一条】
/// 带 `has` 标记的属性读取：把"值就是 0"和"这个 getter 根本不存在"彻底分开。
///
/// 归档(9) 真机日志暴露了一个骗了两轮的陷阱：`fg=0` **从头到尾一次都没变过**。
/// 但 `[settings respondsToSelector:@selector(foreground)]` 完全可能是 NO ——
/// 因为所有 helper（MFBoolProp / MFMvBool ...）都带 responds 守卫，
/// 于是**整套 foreground 逻辑从头到尾都是空转**：设不上、读不准、判定恒为"掉出"，
/// 0.9.0 的守护因此每 1 秒就无谓地拉一次（日志里"第 10/20/30/40/50 次"就是这么来的）。
/// ⇒ 从此凡是被用作**判定依据**的属性，一律连存在性一起读出来，并写进日志。
static BOOL MFBoolPropEx(id obj, NSString *selName, BOOL *has) {
    SEL s = NSSelectorFromString(selName);
    if (obj == nil || ![obj respondsToSelector:s]) { if (has) *has = NO; return NO; }
    if (has) *has = YES;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return NO; }
}

static NSInteger MFIntPropEx(id obj, NSString *selName, BOOL *has) {
    SEL s = NSSelectorFromString(selName);
    if (obj == nil || ![obj respondsToSelector:s]) { if (has) *has = NO; return 0; }
    if (has) *has = YES;
    @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return 0; }
}

static unsigned long long MFULLPropEx(id obj, NSString *selName, BOOL *has) {
    SEL s = NSSelectorFromString(selName);
    if (obj == nil || ![obj respondsToSelector:s]) { if (has) *has = NO; return 0; }
    if (has) *has = YES;
    @try { return ((unsigned long long (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return 0; }
}

// ========== 【0.13.0】属性读取封装（必须定义在 MFReadHealth 之前）==========

/// 【0.13.0 新增】读 double 返回的属性（`settings.level` 就是 double）。
static double MFDPropEx(id obj, NSString *selName, BOOL *has) {
    SEL s = NSSelectorFromString(selName);
    if (obj == nil || ![obj respondsToSelector:s]) { if (has) *has = NO; return 0.0; }
    if (has) *has = YES;
    @try { return ((double (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return 0.0; }
}

/// 【0.13.0 核心】读 **FBScene.foreground** —— 这才是"这个 scene 还算不算前台"的唯一真值。
///
/// 为什么必须走 KVC，而且必须问 FBScene 而不是 settings：
///   · 归档(13) 的存在性矩阵实测：`foreground`(getter) 在 settings 上**不存在**（`-`），
///     而 `setForeground:`(setter) **存在**（`settings=YES`）—— 它是个"只写"开关；
///   · 但 `FBScene` 上有对应的 ivar，KVC `valueForKey:@"foreground"` 能读到真值：
///     挂载瞬间是 1，App 被切到后台之后变成 0（P6+20s 那行日志）。
///   · 0.9.x 的注释"本机没有 foreground/setForeground:"就是这么来的 ——
///     当年只问了 FBScene 的 **respondsToSelector**（=NO），于是把整条 foreground 逻辑
///     当成空转给删了。归档(13) 证明**删错了**：setter 在 settings 上是存在的。
///
/// 返回值：能读到就置 has=YES。
static BOOL MFForegroundOf(id scene, BOOL *has) {
    if (has) *has = NO;
    if (scene == nil) return NO;
    @try {
        id v = [scene valueForKey:@"foreground"];
        if (v != nil && [v respondsToSelector:@selector(boolValue)]) {
            if (has) *has = YES;
            return [v boolValue];
        }
    } @catch (NSException *e) {
        // 没有这个 key（NSUndefinedKeyException）—— 当"读不到"处理，绝不猜。
        return NO;
    }
    return NO;
}
/// 一次采样读到的全部"决定黑不黑"的量。`has*` = 该属性在本机是否真的存在。
typedef struct {
    BOOL hasFg, hasIdle, hasDeact, hasCs, hasLevel, hasFrame;
    BOOL fg, idle;
    unsigned long long deact;
    NSInteger cs;
    NSInteger layers;
    // ---- 【0.13.0 新增】把"能读到的当前值"和"setter 在不在"分开记，才能做**差量写** ----
    BOOL hasLvlVal;      // settings.level 的 getter 在不在
    double lvlVal;       // 当前的 settings.level
    BOOL hasSceneFg;     // FBScene.foreground 读没读到（KVC）
    BOOL sceneFg;        // 当前值：1=还算前台，0=已经不是了
} MFHealth;

/// 采一次样。**只读不写**；读不到就把对应 has 置 NO（绝不把"不存在"当成 0 用）。
static MFHealth MFReadHealth(id scene) {
    MFHealth h;
    memset(&h, 0, sizeof(h));
    if (scene == nil) return h;

    id st = MFMsg(scene, NSSelectorFromString(@"settings"));
    if (st != nil) {
        h.fg    = MFBoolPropEx(st, @"foreground",         &h.hasFg);
        h.idle  = MFBoolPropEx(st, @"idleModeEnabled",    &h.hasIdle);
        h.deact = MFULLPropEx(st, @"deactivationReasons", &h.hasDeact);
        h.hasLevel = [st respondsToSelector:NSSelectorFromString(@"setLevel:")];
        h.hasFrame = [st respondsToSelector:NSSelectorFromString(@"setFrame:")];
        // 【0.13.0】getter 与 setter 要分开问：deact/idle/level 都有 getter，
        // 但真正的"前台开关"只有 setter（getter 在 settings 上不存在）。
        h.lvlVal    = MFDPropEx(st, @"level", &h.hasLvlVal);
    }
    h.cs      = MFIntPropEx(scene, @"contentState", &h.hasCs);
    h.layers  = MFKVCount(MFMsg(scene, NSSelectorFromString(@"layerManager")), @"layers");
    h.sceneFg = MFForegroundOf(scene, &h.hasSceneFg);   // 【0.13.0】这是判据的一部分，不是日志字段
    return h;
}

/// 【0.10.0 新增】读 **32 位 int** 返回的属性。
/// **必须**把返回类型声明成 int（而不是 NSInteger）：arm64 上被调用者只写 w0，
/// 高 32 位是谁也不知道的垃圾。0.9.1 日志里 `ps=10751930112` 就是这么读出来的
/// —— `processState` 本身只有 0/1/2 三个值，我们却读出一个百亿的数，白白废掉一个字段。
static int MFIntProp32(id obj, NSString *selName, BOOL *has) {
    SEL s = NSSelectorFromString(selName);
    if (obj == nil || ![obj respondsToSelector:s]) { if (has) *has = NO; return -1; }
    if (has) *has = YES;
    @try { return ((int (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return -1; }
}

/// 【0.10.0 新增】读 CGRect 返回的属性（`settings.frame` 就是 CGRect）。
static CGRect MFRectProp(id obj, NSString *selName, BOOL *has) {
    SEL s = NSSelectorFromString(selName);
    if (obj == nil || ![obj respondsToSelector:s]) { if (has) *has = NO; return CGRectZero; }
    if (has) *has = YES;
    @try { return ((CGRect (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return CGRectZero; }
}

/// 【0.10.0 核心 · 这一版为什么能修掉闪屏】
/// 问题：这个 scene 现在到底黑不黑？三种结论，**只有一种允许动手**。
///
/// 归档(10) 把 0.9.1 的每一条判据都验了尸（同一 pid 20257、同一轮承载、deact 波动 20+ 次）：
///   ① deact=32/33/8/1 出现 20+ 次，其中**绝大多数与 layers=2 hosted=2 同时成立** —— 画面好好的；
///   ② cs=0 出现 11 次，其中 **8 次 layers/hosted 完好** —— cs 只是 settings 提交途中的瞬时值；
///   ③ layers=0（真黑）只出现 4 次，而这 **4 次全部发生在我们写完 settings 之后 0~2 秒内**
///      （反向成立：没有任何一次 layers=0 是在"我们没写过"的情况下出现的）。
/// ⇒ 结论一：`deact!=0` / `cs!=2` 根本不是黑屏，只是假警报。
/// ⇒ 结论二：真正制造那一帧黑的是**我们自己的写操作** —— `updateSettingsWithBlock:`
///    （尤其里面的 setDisplayConfiguration:）会让 SpringBoard 重算整份 settings、
///    让 App 的 scene 重新提交，contentState 走 2→0→1→2、图层重建一遍，
///    屏幕上就是"闪一下"。写一次 = 闪一次。
/// ⇒ 这就解释了用户的原话："把 keepAliveMs 改成 100 或 50，闪烁会加快"：
///    闪的频率 = 我们写 settings 的频率 = 1 / keepAliveMs。
///
/// 【0.10.0 的结论】判据收紧成"只有 layers<=0 或 hosted<=0 才算黑"。
///
/// 【0.12.0 的修正 —— 归档(12)】这条收紧**过头**了，而且方向错了：
///   用户原话："v0.10.0 和 v0.11.0 存在问题，v0.9.1 版本好像是正常的，
///             虽然屏幕会闪一下，但是切换应用时悬浮窗不会黑屏。"
///   归档(12) 的因果链非常干净（Filza 轮与 Safari 轮都复现）：
///     ① 挂载后 / 按 Home 之后，先出现 `deact=32`（或 33）——
///        此刻 `cs=2 layers=2 hosted=2`，**画面还是好的**；
///     ② 约 **1 秒后**才 `cs=0 layers=0`（Filza 轮更极端：挂载时就带着 deact=33，
///        1 秒后图层掉光）；
///     ③ 掉完之后**写什么都救不回来** —— Safari 轮里连着写了 81 次"全量写"
///        （含 level + displayConfiguration + frame），`layers` 始终是 0。
///   ⇒ 结论一：**图层一旦掉光就是不可逆的。**唯一有效的时机是
///     "deact!=0 而图层还在"的那一秒。
///     0.9.1 正是把 `deact!=0 / cs!=2` 也算作"要动手"，所以它不掉图层；
///     0.10.0/0.11.0 把这一档降级成"只记日志"，于是只能等图层掉完再救 —— 必然黑。
///   ⇒ 结论二：加回这一档时**必须把代价压到最低** —— 只写"纯状态量"，不碰几何
///     （归档(10) 测到的重排元凶正是 `setDisplayConfiguration:` 把 frame 打回整屏
///     + 随后的 `setFrame:`）。
///
/// 【0.13.0 的决定性修正 —— 归档(13)】0.12.0 的"低代价预防"方向对，但**写漏了最关键的一项**。
///   用户原话："切换应用时悬浮窗依旧黑屏。"日志给出的完整因果链（两次会话都复现）：
///     ① Safari 轮：`deact 0->32`（`cs=2 layers=2 hosted=2`，画面还好）
///        → 我们的"预防写（idle+deact+level）"确实发出去了
///        → **紧接着同一个 pid 里 `cs 2->0`，再下一拍 `layers 2->0`** ⇒ 真黑，再也回不来；
///     ② 报告实测挂在最后的状态是
///        `scene.settings.foreground = 1` 但 **`目标 App processState = taskState: Suspended;
///         visibility: Background`** —— **App 进程被挂起了**。一个被挂起的进程不可能出图，
///        写多少 settings 都没用（这解释了"81 次全量写、layers 恒为 0"）。
///   为什么 0.9.1 不掉图层？把两版的写操作对齐就只剩**一项差别**：
///     · 0.9.1：`hardDown` ⇒ `forceAll=YES` ⇒ `doFg = forceAll || … = **YES**`
///       ⇒ 每一拍都发 `setForeground:YES`；
///     · 0.10.0 起：`doFg = p0 || MFConfigBool(cfg, @"keepAliveForeground", NO)`，
///       而 0.9.x 留下的一句注释（"`foreground` / `setForeground:` 在本机不存在，
///       responds 守卫静默跳过"）让它默认 NO ⇒ **除了承载前的 P0，再没发过这一项**。
///   ⇒ 那句注释是**错的**，错在"问错了对象"：它只问了 `FBScene` 的 respondsToSelector（=NO），
///     而归档(13) 的存在性矩阵是问 settings 对象的，结果是
///     `foreground (getter) = -`、**`setForeground: (setter) = YES`**。
///     也就是说它是个"只写"的前台开关 —— 这正是 0.9.1 用来让 App 不被挂起的那一项。
///   ⇒ 0.13.0 的结论：
///     ① 预防档必须**包含** `setForeground:YES`（同时保留 level/idle/deact）；
///     ② 判据里加入 `FBScene.foreground == 0`（能读到才算）—— 那才是"App 要进后台"的直接信号；
///     ③ 但**绝不能每拍都写**（0.9.1 的闪就是这么来的）⇒ 改成**差量写**：
///        先读全量当前值，只把"真的不一样"的那几项发出去；没有差量就**一个字节都不写**。
typedef NS_ENUM(NSInteger, MFDropKind) {
    MFDropNone     = 0,   // 健康
    MFDropAdvisory = 1,   // 软警告：只记日志，**永不动手**（keepAliveSoft 打开才用，纯观察）
    MFDropPrevent  = 2,   // 【0.12.0】图层还在，但 scene 正在被去激活 / 进 idle / 掉出 ready
                          //   或 App 正在失去前台身份 ⇒ **必须预防性动手**（趁图层没掉先按住）
    MFDropReal     = 3,   // 真黑：图层没了（不可逆，只能全量写搏一下）
};

static MFDropKind MFJudgeDrop(MFHealth h, NSInteger hosted, NSDictionary *cfg) {
    // 直接表征症状：那块表面上一个图层都没有。
    if (h.layers <= 0 || hosted == 0) return MFDropReal;

    // 【0.12.0 核心】图层还在，但 scene 已经被"去激活 / 进 idle / 掉出 ready"。
    // 这就是"掉图层的最后一秒"：归档(12) 实测 deact 变 32 之后约 1 秒，layers 就 2 -> 0。
    // 【0.13.0 补充】再加上"失去了前台身份"（FBScene.foreground=0）。
    // 它是"App 要被挂起"的直接前兆 —— 归档(13) 里 App 最终就是 Suspended，
    // 而 Suspended 的进程按定义不出图，所以这一项必须进判据，抢在挂起**之前**动手。
    BOOL soft = (h.hasDeact && h.deact != 0) || (h.hasIdle && h.idle) ||
                (h.hasCs && h.cs != 2)      || (h.hasSceneFg && !h.sceneFg);
    if (!soft) return MFDropNone;

    if (MFConfigBool(cfg, @"keepAlivePrevent", YES)) return MFDropPrevent;
    if (MFConfigBool(cfg, @"keepAliveSoft",    NO))  return MFDropAdvisory;  // 只观察，用于 A/B
    return MFDropNone;
}

/// 把 health 渲染成一行可 diff 的签名。`y/n` 表示"该属性本机有没有"，一眼就能看出
/// 我们到底是在读真值，还是在读一个不存在的 getter 返回的 0。
/// 【0.13.0】签名里新增 `fgS=`：**FBScene.foreground**（0.9.x 一直想读却读错对象的那个值）。
/// `y/n` 表示读到了没有 —— KVC 读得到的机型上它就是"App 还算不算前台"的唯一真值。
static NSString *MFHealthSignature(id scene, MFHealth h) {
    return [NSString stringWithFormat:
            @"valid=%d cs=%@(%d) layers=%ld fg=%@(%d) fgS=%@(%d) idle=%@(%d) deact=%@(%llu) lvl=%.1f",
            (int)MFBoolProp(scene, NSSelectorFromString(@"isValid")),
            h.hasCs ? @"y" : @"n", (int)h.cs,
            (long)h.layers,
            h.hasFg ? @"y" : @"n", (int)h.fg,
            h.hasSceneFg ? @"y" : @"n", (int)h.sceneFg,
            h.hasIdle ? @"y" : @"n", (int)h.idle,
            h.hasDeact ? @"y" : @"n", h.deact,
            h.hasLvlVal ? h.lvlVal : -1.0];
}

/// presenter 的宿主容器里到底挂着几个图层 —— **这才是黑不黑的直接证据**：
/// 0 = 那块表面上什么都没有（黑），>0 = 有内容。`-1` = 拿不到（presenter/presentationView 已没了）。
static NSInteger MFHostedLayerCount(id pres) {
    if (pres == nil) return -1;
    id pv = MFMsg(pres, NSSelectorFromString(@"presentationView"));
    if (pv == nil) return -1;
    return MFKVCount(MFMsg(pv, NSSelectorFromString(@"hostContainerView")), @"hostedLayers");
}

/// 【0.11.0 新增】写 frame 之后记一笔，避免紧接着又为同一尺寸重复写。
/// 每一次 `updateSettingsWithBlock:` 都是一次 SpringBoard 全量重算 —— 少写一次就少一次重排。
static void MFFrameMemoPut(id scene, CGRect r) {
    gMFFrameMemoScene = scene;
    gMFFrameMemoRect  = r;
    gMFFrameMemoTime  = [NSDate timeIntervalSinceReferenceDate];
}

/// 刚刚（1.5 秒内）已经为**同一个** scene 写过**完全相同**的 frame？
/// 窗口取 1.5 秒是因为 `updateSettingsWithBlock:` 是异步的：写完之后立刻读 `settings.frame`
/// 读回来的可能还是旧值（归档(11) 挂载序列里 P0 写完读回 430x932 就是这一条）。
static BOOL MFFrameMemoHit(id scene, CGRect r) {
    if (scene == nil || gMFFrameMemoScene != scene) return NO;
    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - gMFFrameMemoTime;
    if (age < 0 || age * 1000.0 > 1500.0) return NO;
    return fabs(gMFFrameMemoRect.origin.x - r.origin.x) < 0.5 &&
           fabs(gMFFrameMemoRect.origin.y - r.origin.y) < 0.5 &&
           fabs(gMFFrameMemoRect.size.width  - r.size.width)  < 0.5 &&
           fabs(gMFFrameMemoRect.size.height - r.size.height) < 0.5;
}

/// 写一次 scene settings，返回**实际发出去**的动作摘要（要写进日志，否则下一轮又只能猜）。
///
/// 【0.10.0 重写】按"代价"分两档，默认只走第一档：
///   第一档（最小写 · 默认）：`setIdleModeEnabled:NO` + `setDeactivationReasons:0`
///                            （+ `setFrame:` 若尺寸已漂）
///   第二档（升级写 · 默认关）：再叠加 `setLevel:1` + `setDisplayConfiguration:`
/// 为什么把 level / displayConfiguration 降级为"升级手段"：
///   归档(10) 实测它们会让 SpringBoard 重算**整份** settings；而且 `setDisplayConfiguration:`
///   **会把 frame 打回整屏 430x932**（日志里"写完 settings 之后 frame 就是 430x932"反复出现，
///   包括 P0 那一次），于是比例崩、还要再补一次 setFrame: —— 一次写换两次重排，纯亏。
/// ⇒ 现在它们只在"真黑连续 N 拍都没救回来"时才作为升级手段出现，且 frame 一律放在**最后**设。
/// 【0.14.0 关键改动】`escalate` 布尔量换成**三档 tier** —— 恢复动作从最温和的一级试起。
///   tier 1 = 只写状态量（fg / idle / deact / level），**不碰几何**（不写 DC、不写 frame）
///   tier 2 = tier 1 + `setFrame:`（仅当尺寸真的漂了）
///   tier 3 = tier 2 + `setDisplayConfiguration:`（0.13.0 的老全量写，"最猛但最闪"）
/// 为什么值得这么拆：`setDisplayConfiguration:` 会把 frame 打回整屏 430x932、随后 `setFrame:`
/// 再改回来 —— 一次写换来两次几何重排，画面上是明显的"跳一下"。而大多数真黑是**一过性**的
/// （归档(14)：真黑持续 1 拍就恢复），根本不需要动几何。（开关 keepAliveTieredRestore）
static NSString *MFWriteSceneSettings(id scene, NSDictionary *cfg, NSInteger tier, BOOL verbose) {
    if (scene == nil) return @"scene=nil";

    SEL upd = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (![scene respondsToSelector:upd]) {
        MFLogS(@"[pres] !! scene 没有 updateSettingsWithBlock:，跳过");
        return @"no-updateSettingsWithBlock";
    }

    // cfg == nil 表示 P0（承载前的一次性设置）：全开，不受 A/B 开关限制。
    BOOL p0 = (cfg == nil);
    BOOL doIdle  = p0 || MFConfigBool(cfg, @"keepAliveIdle",  YES);
    BOOL doDeact = p0 || MFConfigBool(cfg, @"keepAliveDeact", YES);
    // 【0.13.0 关键改动：默认 NO -> YES】
    // 0.9.1 的 `forceAll` 让这一项恒为 YES，而 0.10.0 起它默认 NO（依据是一句**问错对象**的注释，
    // 见 MFJudgeDrop 上方那段说明）⇒ 承载之后我们再没把 scene 拉回前台，
    // App 遂被挂起（归档(13) 报告：`taskState: Suspended; visibility: Background`），图层永久消失。
    // `setForeground:` 在 settings 上**确实存在**（存在性矩阵 settings=YES）。
    BOOL doFg    = (p0 || MFConfigBool(cfg, @"keepAliveForeground", YES)) && gMFFgUsable;
    // 【0.14.0】几何按档位放行：tier>=3 才动 DC，tier>=2 才动 frame。
    // P0（承载前的一次性设置，cfg=nil）永远按 tier 3 走 —— 那时候画面还没出来，闪不闪无所谓，
    // 但比例必须一次到位。
    BOOL doEsc   = p0 || (tier >= 3);

    CGSize want = gMFDesiredContentSize;
    BOOL  wantFrame = gMFDesiredContentValid && want.width > 1.0 && want.height > 1.0 &&
                      (p0 || tier >= 2);

    // 【0.12.0】把 dc 的来源提到 block 外面：一是别在 settings block 里调 UIScreen，
    // 二是要能把"它到底有没有值"写进日志 —— 0.11.0 那行 `dc=__NSCFConstantString`
    // 是个假信息（它打的是 MFKV 返回的**格式化字符串**的类名，跟 displayConfiguration 毫无关系）。
    id dcSrc = nil;
    if (doEsc) dcSrc = MFMsg([UIScreen mainScreen], NSSelectorFromString(@"displayConfiguration"));

    void (^blk)(id) = ^(id st) {
        if (st == nil) return;

        // 【0.13.0】只探一次：在**可变** settings 上问每个 setter 在不在（这才是我们写的对象）。
        if (!gMFProbedMutableSetters) {
            gMFProbedMutableSetters = YES;
            const char *names[] = { "setForeground:", "setLevel:", "setDisplayConfiguration:",
                                    "setIdleModeEnabled:", "setDeactivationReasons:", "setFrame:" };
            BOOL bits[6];
            for (unsigned k = 0; k < 6; k++) {
                bits[k] = [st respondsToSelector:NSSelectorFromString([NSString stringWithUTF8String:names[k]])];
            }
            MFLog(@"[pres] ★ 可变 settings（%@）上的 setter 实况："
                  @"setForeground:=%d setLevel:=%d setDisplayConfiguration:=%d "
                  @"setIdleModeEnabled:=%d setDeactivationReasons:=%d setFrame:=%d",
                  NSStringFromClass([st class]),
                  (int)bits[0], (int)bits[1], (int)bits[2], (int)bits[3], (int)bits[4], (int)bits[5]);
        }

        if (doFg)    MFMvBool(st, @"setForeground:", YES);
        if (doIdle)  MFMvBool(st, @"setIdleModeEnabled:", NO);
        if (doDeact) MFMvULL(st,  @"setDeactivationReasons:", 0ULL);
        if (doEsc) {
            MFMvDouble(st, @"setLevel:", 1.0);
            if (dcSrc != nil) MFMvObj(st, @"setDisplayConfiguration:", dcSrc);
        }
        // frame **必须最后设**：setDisplayConfiguration: 会把它打回整屏
        if (wantFrame) MFMvRect(st, @"setFrame:", CGRectMake(0, 0, want.width, want.height));
    };

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, upd, (id)blk);
        if (wantFrame) MFFrameMemoPut(scene, CGRectMake(0, 0, want.width, want.height));
    } @catch (NSException *e) {
        MFLog(@"[pres] updateSettingsWithBlock 抛异常: %@", e.reason);
        return @"exception";
    }

    NSString *summary = [NSString stringWithFormat:@"L%ld fg=%d idle=%d deact=%d DC=%d frame=%d(%.0fx%.0f)",
                         (long)(p0 ? 3 : tier),
                         (int)doFg, (int)doIdle, (int)doDeact, (int)doEsc, (int)wantFrame,
                         want.width, want.height];

    if (verbose) {
        id after = MFMsg(scene, NSSelectorFromString(@"settings"));
        BOOL hasFrame = NO;
        CGRect f = MFRectProp(after, @"frame", &hasFrame);
        // 【0.12.0】这里改成打印 **dc 的来源**（见上）。0.11.0 打的 `dc=__NSCFConstantString`
        // 掩盖了真正关键的事实："setDisplayConfiguration: 到底有没有被调用过"。
        // 【0.13.0】再加一个 fgS 回读 —— 写完 `setForeground:YES` 之后
        // `FBScene.foreground` 到底有没有变回 1，这一项决定"是不是真能救"。
        BOOL hasFgS = NO;
        BOOL fgS = MFForegroundOf(scene, &hasFgS);
        MFLog(@"[pres] 已写 settings（%@）-> level=%.1f fgS=%@(%d) dc源=%@ cs=%ld layers=%ld frame=%@",
              summary,
              MFDProp(after, NSSelectorFromString(@"level")),
              hasFgS ? @"y" : @"n", (int)fgS,
              dcSrc ? NSStringFromClass([dcSrc class]) : @"nil（setDisplayConfiguration: 未被调用）",
              (long)MFIntProp(scene, NSSelectorFromString(@"contentState")),
              (long)MFKVCount(MFMsg(scene, NSSelectorFromString(@"layerManager")), @"layers"),
              hasFrame ? NSStringFromCGRect(f) : @"-");
    }
    return summary;
}

/// 【0.12.0 新增 / 0.13.0 重写成"差量写"】**预防性写** ——
/// 在"图层还在、但 scene 正在被去激活 / 正在失去前台身份"的那一秒把它按住。
///
/// 为什么单独做成一个函数、而不是复用 MFWriteSceneSettings：
///   · 真黑时（layers 已经 0）只能"全量写"：foreground + level + displayConfiguration
///     + idle + deact + frame，其中 `setDisplayConfiguration:` 会把 frame 打回整屏 430x932，
///     随后的 `setFrame:` 再改一次 ⇒ 一次写换来两次重排，必有一帧黑。但那时已经黑了，无所谓。
///   · 预防时（图层还在）**绝不能碰几何**（displayConfiguration / frame 一律不写）。
///     但 0.12.0 的脚步到此为止 —— 它只写 idle/deact 两个状态量，**漏了 `setForeground:`**，
///     于是 App 照样被挂起、图层照样掉光（归档(13) 两次会话都复现）。
///
/// 【0.13.0 的两个原则】
///   原则一：**必须包含 `setForeground:YES`** —— 它是 0.9.1 与 0.10.0+ 之间唯一有效的差别。
///   原则二：**只写差量**。先把"能读到的当前值"全读出来（`idleModeEnabled` /
///     `deactivationReasons` / `level` / `FBScene.foreground`），只把**真的不一样**的那几项发出去；
///     如果一项差量都没有，**连 `updateSettingsWithBlock:` 都不调**（零写入 = 零重排 = 零闪）。
///     这就是"既不掉图层、又不闪"的唯一出路：
///       0.9.1        = 预防 + 每拍全量写（不掉图层，但每次都闪）
///       0.10.0/0.11  = 不预防 + 全量写（不闪，但图层掉光 = 永久黑）
///       0.12.0       = 预防 + 只写 idle/deact（不闪，但按不住，照样黑）
///       0.13.0       = **预防 + 差量写（含 setForeground:）** ⇒ 一次事件只写一次
///
/// `keepAlivePreventHard=true` 时再叠加 `setDisplayConfiguration:` + `setFrame:`
/// （即"0.9.1 的完整版"，会闪但最猛），用于万一差量写仍按不住时的 A/B 逃生门。
static NSString *MFWritePreventiveSettings(id scene, NSDictionary *cfg, MFHealth h, BOOL verbose) {
    if (scene == nil) return @"scene=nil";

    SEL upd = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (![scene respondsToSelector:upd]) {
        MFLogS(@"[pres] !! scene 没有 updateSettingsWithBlock:，跳过预防写");
        return @"no-updateSettingsWithBlock";
    }

    // ---------- 1) 先算差量（纯读，不写）----------
    // 【0.17.0 关键改动】预防档 fg 保活**默认关**（keepAlivePreventForeground 默认 NO）。
    // 三轮实证（归档(15)(16)(17)）：本机 fg 读不到 ⇒ 保活 = 每个预防回合必写一帧
    //（每次 updateSettingsWithBlock = 一次重提交 = 一帧"内容闪"），而真黑次数
    // 一轮没降（92→93）⇒ 零收益纯成本。救命的 fg 在真黑档 L1（keepAliveForeground），
    // 与本键无关。读得到 fg 的机器想要预防保活可手动改回 YES。
    BOOL doFg = NO;
    if (MFConfigBool(cfg, @"keepAlivePreventForeground", NO) && gMFFgUsable) {
        doFg = h.hasSceneFg ? !h.sceneFg : YES;
    }

    BOOL doIdle  = MFConfigBool(cfg, @"keepAlivePreventIdle",  YES) && h.hasIdle  && h.idle;
    // 【0.14.0】这一项加了熔断。归档(14) 实测：本机 `deact` 常态就是 32（画面好好的），
    // 于是每拍都有"差量" ⇒ 每拍写一次；而写完读回**还是 32** ⇒ 写了个寂寞，只换来一次重排。
    BOOL doDeact = MFConfigBool(cfg, @"keepAlivePreventDeact", YES) &&
                   gMFDeactUsable && h.hasDeact && h.deact != 0;

    // level：0.9.1 每拍都发；这里只在"真的不是 1.0"时发一次。
    BOOL wantLevel = MFConfigBool(cfg, @"keepAlivePreventLevel", YES);
    BOOL doLevel = wantLevel && h.hasLvlVal && fabs(h.lvlVal - 1.0) > 0.001;

    BOOL hard = MFConfigBool(cfg, @"keepAlivePreventHard", NO);

    // 【0.14.0 修正】`hard` **不再参与"要不要写"的判断**。
    // 0.13.0 把它并进了短路条件 ⇒ 逃生门一开就"每拍必写"（归档(14)：26 秒写了 14 次，
    // 且每次都叠 `setDisplayConfiguration:` + `setFrame:` = 每次两次几何重排）
    // ⇒ 那 26 秒里就是"每 1~2 秒闪一下"。逃生门的本意是"差量写按不住时加猛药"，
    // 不是"每拍灌一次"。现在改成：hard 只在**本来就有差量**时额外带上几何（作为强化），
    // 没差量就仍然一个字都不写。
    if (!doFg && !doIdle && !doDeact && !doLevel) {
        // 关键：一个差量都没有 ⇒ **一个字都不写**。这是"不闪"的来源。
        return @"无差量（未调用 updateSettingsWithBlock:）";
    }

    id dcSrc = nil;
    CGSize want = gMFDesiredContentSize;
    BOOL wantFrame = hard && gMFDesiredContentValid && want.width > 1.0 && want.height > 1.0;
    if (hard) dcSrc = MFMsg([UIScreen mainScreen], NSSelectorFromString(@"displayConfiguration"));

    // ---------- 2) 只把差量写进去 ----------
    void (^blk)(id) = ^(id st) {
        if (st == nil) return;
        if (doFg)    MFMvBool(st, @"setForeground:", YES);
        if (doIdle)  MFMvBool(st, @"setIdleModeEnabled:", NO);
        if (doDeact) MFMvULL(st,  @"setDeactivationReasons:", 0ULL);
        if (doLevel) MFMvDouble(st, @"setLevel:", 1.0);
        if (hard) {
            if (dcSrc != nil) MFMvObj(st, @"setDisplayConfiguration:", dcSrc);
            // frame 一律最后设（setDisplayConfiguration: 会把它打回整屏）
            if (wantFrame) MFMvRect(st, @"setFrame:", CGRectMake(0, 0, want.width, want.height));
        }
    };

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, upd, (id)blk);
    } @catch (NSException *e) {
        MFLog(@"[pres] 预防写抛异常: %@", e.reason);
        return @"exception";
    }

    NSString *summary = [NSString stringWithFormat:@"预防差量(fg=%d idle=%d deact=%d level=%d%@)",
                         (int)doFg, (int)doIdle, (int)doDeact, (int)doLevel,
                         hard ? @" +几何(逃生门)" : @""];

    // ---------- 3) 写完**立刻验证** setForeground: 到底管不管用 ----------
    // 【0.15.0 修正】三态判定，不再是二态：
    //   · 读回 fg=1        ⇒ 成功，清零计败；
    //   · 读回 fg=0        ⇒ 失败，计败；连败 3 次 ⇒ 熔断（这个 setter 是空转）；
    //   · **读不到（KVC 抛异常）⇒ 未知，既不计败也不清零**。
    // 0.14.0 及之前是二态：hasAfter=NO 会掉进 else 计败 ⇒ 在"fg 读不到"的机器上
    // （归档(15)：全场 fg=n(0)），只要预防档真的开始发 fg，3 拍后就会被**误熔断**——
    // 而 gMFFgUsable 一旦为 NO，真黑档 L1 的 doFg 也跟着关闭（974 行共用它）
    // ⇒ 直接回到 0.12.0"layers 掉了写不回 = 永久黑"的险境。这是本轮最重要的一个修正。
    // 保活写是否真的在按住，用**宏观指标**验收：真黑次数应趋零（见交付说明第 5 节）。
    if (doFg) {
        BOOL hasAfter = NO;
        BOOL fgAfter = MFForegroundOf(scene, &hasAfter);
        if (hasAfter && fgAfter) {
            gMFFgFailStreak = 0;
            if (verbose) MFLogS(@"[keepalive] ✔ setForeground:YES 生效（FGScene.foreground 0 -> 1）");
        } else if (!hasAfter) {
            // 本机读不到 fg（KVC NSUndefinedKeyException）—— 写没写进去**无从得知**。
            // 不计败（那会把"读不到"误判成"空转"），也不清零（没有正面证据）。
            // 验收靠宏观指标：切换时真黑（layers 掉）次数是否趋零。
            if (verbose) MFLogS(@"[keepalive] · setForeground:YES 已发（本机 fg 读不到，无法逐笔回读验证；看真黑次数是否趋零）");
        } else {
            gMFFgFailStreak += 1;
            MFLog(@"[keepalive] ✘ setForeground:YES 写完读回仍然是 0（第 %ld 次）—— 这个 setter 可能是空转",
                  (long)gMFFgFailStreak);
            if (gMFFgFailStreak >= 3) {
                gMFFgUsable = NO;
                MFLogS(@"[keepalive] ★ setForeground: 连续 3 次无效 -> 停止再写它（避免每拍写一次 = 每拍闪一次）");
            }
        }
    }

    // ---------- 4) 写完同样验证 `setDeactivationReasons:` ----------
    // 【0.14.0 新增】这是本版最重要的一次"自证"：
    //   如果写完读回 deact 仍然是原值（归档(14) 里就是 32、1 之类），
    //   那这一项就是纯亏（付一次重排、换零收益）—— 连败 keepAliveDeactFuse 次就熔断、永不回写。
    //   反过来，如果它真的能清零，熔断就永远不会触发，功能原样保留。
    //   ⇒ 这条日志一出来，下一轮就不用再猜"闪是不是它造成的"了。
    if (doDeact) {
        MFHealth a2 = MFReadHealth(scene);
        NSInteger fuse = MFConfigInt(cfg, @"keepAliveDeactFuse", 5);
        if (a2.hasDeact && a2.deact == 0) {
            gMFDeactFailStreak = 0;
            if (verbose) MFLogS(@"[keepalive] ✔ setDeactivationReasons:0 生效（写完读回 deact=0）");
        } else {
            gMFDeactFailStreak += 1;
            MFLog(@"[keepalive] ✘ setDeactivationReasons:0 写完读回仍是 %@ —— 系统又把它设回来了（第 %ld 次）",
                  a2.hasDeact ? [NSString stringWithFormat:@"%llu", a2.deact] : @"?",
                  (long)gMFDeactFailStreak);
            if (fuse > 0 && gMFDeactFailStreak >= fuse) {
                gMFDeactUsable = NO;
                MFLog(@"[keepalive] ★ 熔断：setDeactivationReasons: 连写 %ld 次都无效 -> 停止再写它"
                      @"（每拍写一次 = 每拍闪一次，而实测零收益；keepAliveDeactFuse=0 可关掉熔断做 A/B）",
                      (long)fuse);
            }
        }
    }

    if (verbose) {
        MFHealth a = MFReadHealth(scene);
        MFLog(@"[pres] 已写 settings（%@）-> cs=%ld layers=%ld deact=%llu idle=%d fgS=%@(%d)",
              summary, (long)a.cs, (long)a.layers, a.deact, (int)a.idle,
              a.hasSceneFg ? @"y" : @"n", (int)a.sceneFg);
    }
    return summary;
}

/// P0：承载前把目标 scene 拉成可渲染。**一次性、全开**（恒按 tier 3）
/// （本机不存在的 setter 会被 responds 守卫自动跳过）。
static void MFForceSceneRenderable(id scene) {
    MFWriteSceneSettings(scene, nil, 3, YES);
}

#pragma mark ========== 0.7.0：presenter 主链（Route 3 / Route 4 共用）==========

/// 【0.10.0 新增】记录"内容区目标尺寸" —— 这是 scene.frame 的**唯一真源**。
///
/// 归档(10) 的教训（一个正反馈闭环）：
///   0.9.x 在守护里拿 `gMFCurrentContentView.bounds` 当尺寸源，而它就是
///   `_UIScenePresentationView` 的 bounds —— 这个视图在 presenter 掉 hosting 时
///   会被系统改成整屏 430x932（日志 P6+20s: view frame={{0,0},{430,932}} 而面板只有 274x478）。
///   我们把 430x932 写回 scene.frame ⇒ 画面比例崩 + 又一次重排 ⇒ 下一拍又"发现尺寸漂了"再写一次。
/// ⇒ 从现在起只信 panel.contentArea.bounds（我们自己的视图，尺寸稳定可控）。

static void MFSetDesiredContentSize(CGSize size) {
    if (size.width < 1.0 || size.height < 1.0) return;
    BOOL changed = !gMFDesiredContentValid ||
                   fabs(gMFDesiredContentSize.width  - size.width)  > 0.5 ||
                   fabs(gMFDesiredContentSize.height - size.height) > 0.5;
    if (changed) {
        MFLog(@"[pres] 内容区目标尺寸 -> %.0fx%.0f（scene.frame 的唯一真源）",
              size.width, size.height);
    }
    gMFDesiredContentSize = size;
    gMFDesiredContentValid = YES;
}


/// 把 scene 的渲染尺寸直接改成浮窗内容区大小。
///
/// 【0.8.0：这一条从"可选"变成了"必需"】
/// 0.7.0 真机（归档(7)）里 route 3 出了画面但**比例不对**，根因就在这里：
///   presentationView 的自然尺寸 = scene.settings.frame。
///   真实 App 的 scene 是整屏 430x932（宽高比 0.461），而浮窗内容区是 267x336.6（宽高比 0.793）。
///   presenter 把 0.461 的内容往 0.793 的视图里塞 => 拉伸变形。
/// 对照证据：同一次真机测试里 route 4 的比例是**对的**，因为它建 scene 时就把 frame
/// 设成了 contentArea.bounds（日志里 P6 的 scene.frame 与 view.frame 逐位相等）。
/// => 所以 route 3 也必须这么做：先把 scene.frame 改成内容区尺寸，宽高比天然一致。
static void MFSetSceneFrame(id scene, CGRect frame) {
    if (scene == nil) return;
    SEL upd = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (![scene respondsToSelector:upd]) return;

    // 【0.11.0】能不写就不写 —— 每一次写都是"一帧黑"的潜在来源。
    //   ① 刚写过同一个值（异步窗口内，读回来还是旧的）-> 跳过；
    //   ② settings.frame 本来就是我们要的尺寸 -> 跳过。
    if (MFFrameMemoHit(scene, frame)) {
        MFLog(@"[pres] scene.frame 刚设成 %@（异步窗口内）-> 不重复写", NSStringFromCGRect(frame));
        return;
    }
    BOOL hasCur = NO;
    CGRect cur = MFRectProp(MFMsg(scene, NSSelectorFromString(@"settings")), @"frame", &hasCur);
    if (hasCur &&
        fabs(cur.origin.x - frame.origin.x) < 0.5 && fabs(cur.origin.y - frame.origin.y) < 0.5 &&
        fabs(cur.size.width  - frame.size.width)  < 0.5 && fabs(cur.size.height - frame.size.height) < 0.5) {
        MFFrameMemoPut(scene, frame);
        MFLog(@"[pres] scene.frame 已经是 %@ -> 不写（少一次重排）", NSStringFromCGRect(frame));
        return;
    }

    void (^blk)(id) = ^(id st) {
        if (st == nil) return;
        MFMvRect(st, @"setFrame:", frame);
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, upd, (id)blk);
        MFFrameMemoPut(scene, frame);
        MFLog(@"[pres] 已把 scene.frame 设成 %@", NSStringFromCGRect(frame));
    } @catch (NSException *e) {
        MFLog(@"[pres] 设 scene.frame 抛异常: %@", e.reason);
    }
}

/// 【0.8.0 新增】把"scene 的渲染尺寸"和"呈现视图的尺寸"一起对齐到浮窗内容区。
///
/// 为什么要成一个步骤 + 反复调用：
///   updateSettingsWithBlock: 是**异步**的（日志里 P0 后 foreground 仍是 0，要到 P6 才变 1），
///   presenter 建 presentationView 时可能还没吃到新的 frame，于是视图尺寸会"晚一步"。
///   所以：承载前一次（让 presenter 建视图时就是对的）＋ 挂载后 3 秒再一次（纠正异步布局），
///   用户拖 ◢ 缩放之后再调一次（保持比例）。
static BOOL gMFSyncGeomBusy = NO;

static void MFSyncSceneGeometry(id scene, id view, CGRect bounds) {
    if (scene == nil && view == nil) return;

    // 【0.12.0】重入保护。归档(12) 的 MF-crash-attribution 指向 `crashedStep=P7-geom`，
    // 而 MF-host-step.txt 里 P7-geom 在 `S7-settle` 之后连着出现 3 次。
    // `v.frame = bounds` 会触发布局，布局回调里若再进本函数就是递归 ——
    // 在 SpringBoard 里递归 = 直接崩（这也解释了日志里"上一轮承载留下的崩溃标记仍在"，
    // 以及随后 8 秒无法重挂）。
    if (gMFSyncGeomBusy) {
        MFLogS(@"[pres] P7-geom 重入 -> 跳过本次（防递归崩）");
        return;
    }
    gMFSyncGeomBusy = YES;

    MFStepMark(kMFStepGeom);
    // 【0.10.0】先登记目标尺寸，再让 scene.frame 与承载视图都对齐到它。
    MFSetDesiredContentSize(bounds.size);
    if (scene != nil) MFSetSceneFrame(scene, bounds);
    if ([view isKindOfClass:[UIView class]]) {
        // 不覆盖 autoresizing（presenter 自己会调），但把当前帧对齐，并在日志里留下证据。
        UIView *v = (UIView *)view;
        v.frame = bounds;
        MFLog(@"[pres] 承载视图已对齐内容区 frame=%@（scene.frame 同步为同一尺寸）",
              NSStringFromCGRect(v.frame));
    }
    MFStepOk(kMFStepGeom);
    gMFSyncGeomBusy = NO;
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

    // ---- P3：建 presenter（0.8.0：同 scene + 同 identifier 一律复用）----
    MFStepMark(kMFStepPres);
    id pres = nil;

    // 复用判定：手里的 presenter 没被 invalidate、挂在同一个 scene 上、identifier 也一致。
    // 为什么必须复用 —— 归档(7) 日志里的原话：
    //   createPresenter 抛异常: Cannot create a presenter with this identifier as it's already in use.
    // 旧代码一失败就静默退回 Route B（SBDeviceApplicationSceneViewController，已知纯黑），
    // 于是"再点一次应用名"= 画面变黑。用户看到的正是这个现象，不是渲染坏了。
    if (gMFPresenter != nil &&
        gMFPresenterScene == scene &&
        [gMFPresenterIdentifier isEqualToString:sceneID] &&
        !MFBoolProp(gMFPresenter, NSSelectorFromString(@"isInvalidated"))) {
        MFStepMark(kMFStepReuse);
        pres = gMFPresenter;
        MFLogS(@"[pres] 复用已有 presenter（同 scene + 同 identifier，不重复 create）");
        MFStepOk(kMFStepReuse);
    } else {
        MFTeardownPresenter();   // 换目标：先收干净，否则新的那次一定抛 already in use
        pres = MFCreatePresenterForScene(pm, sceneID);
    }

    MFLog(@"[pres] presenter=%@", pres ? NSStringFromClass([pres class]) : @"nil");
    MFStepOk(kMFStepPres);
    if (pres == nil) return nil;
    gMFPresenter = pres;
    gMFPresenterIdentifier = [sceneID copy];
    gMFPresenterScene = scene;

    // ---- P3b：presenter 自己的呈现上下文（照抄 FrontBoardAppLauncher 的 appearanceStyle=2）----
    SEL presModify = NSSelectorFromString(@"modifyPresentationContext:");
    if ([pres respondsToSelector:presModify]) {
        @try {
            void (^blk)(id) = ^(id mc) {
                if (mc == nil) return;
                MFMvLong(mc, @"setAppearanceStyle:", 2);

                // 【0.15.0 消闪核心①】把"未承载背景色"从黑改成透明。
                // 归档(15) 的 context dump 给出了铁证：
                //   `BGColorWhileHosting = UIExtendedGrayColorSpace 0 1`（纯黑）
                // 而 `_UIScenePresentationView._updateBackgroundColor` 在**未承载**
                // （hostedLayers=0，即每次切换 App 掉图层的 200~400ms 黑窗）时
                // 画的就是这个色 —— "闪一下"不是没渲染，是 presenter 在明确画黑。
                // 设成 clearColor 之后，黑窗变成"透窗"：露出我们垫底的
                // 最后一帧快照（见 MFSnapshotPadUpdate）＝画面定格而不是闪黑。
                SEL setBg = NSSelectorFromString(@"setBackgroundColorWhileNotHosting:");
                if ([mc respondsToSelector:setBg]) {
                    SEL getBg = NSSelectorFromString(@"backgroundColorWhileNotHosting");
                    id before = [mc respondsToSelector:getBg] ? MFMsg(mc, getBg) : nil;
                    MFMvObj(mc, @"setBackgroundColorWhileNotHosting:", [UIColor clearColor]);
                    id after = [mc respondsToSelector:getBg] ? MFMsg(mc, getBg) : nil;
                    MFLog(@"[pres] P3b 未承载背景色：%@ -> %@（已设透明；切换掉图层时应透出垫底快照而不是黑）",
                          before, after);
                } else {
                    MFLogS(@"[pres] P3b 没有 setBackgroundColorWhileNotHosting:（黑窗维持原样）");
                }
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
        //
        // 【0.9.0 补充】idle / deact 也一并打出来 —— 归档(8) 里真正把内容弄黑的很可能不是
        // foreground 本身，而是 SpringBoard 顺手打开的 idleModeEnabled（App 进入空闲渲染模式，
        // layerManager.layers 直接掉到 0）。没有这两个数，下一轮还是只能猜。
        MFLog(@"[pres] %@ scene=%@ foreground=%@ idle=%@ deact=%@ level=%@ frame=%@ contentState=%@ layers=%ld",
             tag, NSStringFromClass([hostScene class]),
             MFKV(st, @"foreground"), MFKV(st, @"idleModeEnabled"),
             MFKV(st, @"deactivationReasons"),
             MFKV(st, @"level"), MFKV(st, @"frame"),
             MFKV(hostScene, @"contentState"), (long)MFKVCount(lm, @"layers"));
    }
    if (gMFKeepAliveApp != nil) {
        MFLog(@"[pres] %@ 目标 App processState=%@（0=运行 1=挂起 2=后台任务 3=没有进程）",
             tag, MFKV(gMFKeepAliveApp, @"processState"));
    }
}

#pragma mark ========== 0.9.0：scene 守护（0.11.0：真黑全量写 + 退避，不再"放弃"）==========

// 【0.11.0 修正了 0.10.0 的两个错误 —— 这一节以归档(11) 为准】
//
//  错误一：把"救命的写"给省掉了。
//    0.10.0 认为 setLevel / setDisplayConfiguration 是"越救越糟"的重排元凶，于是把它们从
//    常规拉回动作里降级成"升级手段"，而且默认关闭、永不触发。结果真黑时用的是**最小写**
//    （只有 idle + deact + frame）——归档(11) 里这一次都没救回来：
//      layers=0 连续 220+ 拍、其间写了十几次，全灭；画面上就是"悬浮窗大概率黑屏"。
//    对照 0.9.1 能一把拉回来，差别恰恰就是这两项。
//    ⇒ 真黑一律**全量写**（keepAliveHardWrite，默认 YES）。
//      想复现 0.10.0 的黑屏做对照，把它设成 false。
//
//  错误二："连续 30 拍救不回来就放弃"。
//    真黑是"必须救"的状态，放弃 = 永久黑屏。0.10.0 的 30 拍 ~ 6 秒之后我们就再也不写了，
//    归档(11) 里正是这样：日志一路刷到"第 220 拍"，画面始终没回来。
//    ⇒ 改成**退避**：连续失败越多、写入间隔越大（上限 keepAliveBackoffMaxMs），但永不停止。
//
//  顺带修掉一个"打偏了"的问题：黑有两种，0.10.0 只认一种。
//    归档(11) 的 Filza 轮：scene 自己完全健康（contentState=2 layers=2），
//    但 presenter.isHosting=0、hostContainer=nil、presentationView 被改成整屏 430x932。
//    这是**承载侧**掉了，写 scene settings 完全打不中 —— 只会白送一次全量重排。
//    ⇒ 现在先看 scene：layers>0 而 hosted<=0 ⇒ 只修承载（re-activate + 把视图放回内容区）。
//
// 【这一节要解决的问题：归档(8) 的"切到别的 App 就黑屏"、归档(9) 的"不黑了但闪一下"、
//   归档(10) 的"闪的频率跟着 keepAliveMs 走"、归档(11) 的"0.10.0 大概率黑屏"】
//
// 四轮日志串起来是一条完整证据链：
//
//   归档(8)  桌面主屏时正常，一切到"设置"就黑。
//            P6 contentState=2 layers=2 → P6+20s contentState=0 layers=0 hostedLayers=0。
//            ⇒ P0（一次性设置）守不住 SpringBoard 之后的重算，所以要"持续"。
//   归档(9)  0.9.0 用 1 秒守护：不再黑，但切 App 会闪一下。时序：
//            +8488 deact=33 → +8489 cs=0 layers=0 → +8490 cs=2 layers=2。
//   归档(10) 周期调到 100 / 50 ms 后，**闪烁反而更快**。这一条是决定性的：
//            如果黑是 SpringBoard 造成的，调小周期只会让黑窗更短，不会让它更频繁。
//            频率跟着我们的周期走 ⇒ **是我们自己在制造那一帧黑**。逐条比对日志：
//              · deact=32/33/8/1 出现 20+ 次，绝大多数与 layers=2 hosted=2 同时成立（画面好好的）
//              · cs=0 出现 11 次，其中 8 次 layers/hosted 完好（cs 只是 settings 提交途中的瞬时值）
//              · layers=0（真黑）只出现 4 次，**4 次全部在我们写完 settings 后 0~2 秒内**
//            机制：`updateSettingsWithBlock:`（尤其 setDisplayConfiguration:）让 SpringBoard
//            重算整份 settings、App 的 scene 重新提交，contentState 2→0→1→2、图层重建一遍，
//            屏幕上就是"闪一下"。0.9.1 的判据 `deact!=0` 在真机上几乎**一直成立**，
//            于是每拍写一次 ⇒ 闪的频率 = 1 / keepAliveMs。用户看到的现象，一字不差。
//
// 【0.10.0 改法】
//   1) 判据收紧成唯一一条：`layers<=0 || presenter 宿主 hosted<=0` —— 只有"一个图层都没有"才算黑。
//      deact / cs / idle 全部降级为日志字段（deact+idle 只算"软警告"，默认不动作）。
//   2) 写操作分两档，默认只走最小写：idle + deact（+ frame 若已漂）。
//      setLevel: / setDisplayConfiguration: 降级为"升级手段"（keepAliveLevel，默认关）——
//      它们是重排元凶，而且 setDisplayConfiguration: 会把 frame 打回整屏 430x932，越救越糟。
//   3) frame 的真源改成 panel.contentArea.bounds（gMFDesiredContentSize）。
//      presentationView 只做**视图层**纠正，绝不把它的 bounds 写回 scene settings（正反馈闭环）。
//   4) 三重刹车：挂载宽限期 + 两次写入最小间隔 + 连续 N 拍救不回来就停止写入。
//      有了它们，任何情况下都不会出现"持续重排"（也就是持续闪屏）。
//   5) 日志修两处：所有 %s 中文占位符换成 %@（0.9.1 日志里的 `Êúâdeact` 就是 %s 打中文的乱码）；
//      `ps=` 改用 int 返回类型读 processState.taskState/visibility（0.9.1 读到的是百亿假值）。
//
// 日志策略（要人肉回传）：状态签名变化记一行；软警告每 20 拍记一行；真掉出第一次与每 10 拍记一行；
// 其余每约 10 秒一行心跳。守护**绝不写** MFStepMark（几秒一行会冲垮 MF-host-step.txt）。

static NSString *gMFKeepAliveBundleID = nil;
static NSDictionary *gMFKeepAliveConfig = nil;
static NSInteger gMFKeepAliveTicks = 0;
static NSString *gMFKeepAliveLastSig = nil;
static NSInteger gMFKeepAliveNextHeartbeat = 0;
static NSInteger gMFKeepAliveNextFrameCheck = 0;
static NSInteger gMFKeepAliveDownTicks = 0;       // 连续"真黑"了几拍（0 = 当前不黑）
static NSInteger gMFKeepAliveWritesInDrop = 0;    // 本次掉出已经写了几次 settings
static NSInteger gMFKeepAliveAdvisoryTicks = 0;   // 连续"软警告"了几拍（只观察那一档）
static NSTimeInterval gMFKeepAliveStartTime = 0;
static NSTimeInterval gMFKeepAliveLastWriteTime = 0;
static NSInteger gMFKeepAlivePreventTicks = 0;      // 【0.12.0】连续进"预防档"了几拍
static NSInteger gMFKeepAlivePreventWrites = 0;     // 【0.12.0】本次预防档累计写了几次 settings
static NSTimeInterval gMFKeepAliveLastPreventTime = 0;  // 【0.12.0】上次预防写的时间（限流）
static NSTimeInterval gMFKeepAliveLastViewFix = 0;      // 【0.12.0】上次掰承载视图的时间（限流）
// 【0.16.0】预防写冷却：每次"去激活回合"第 1 发要快（250ms 内），但之后的写必须隔
// keepAlivePreventCooldownMs（默认 2s）。归档(16)：一个回合写 2~4 次，每次
// updateSettingsWithBlock 都是一次 scene 重提交（cs 2->0->1->2）= 一帧可见的内容闪，
// 而这些追加写并不能阻止掉层（掉了由真黑档 L1 兜底、垫底快照遮住）。
// （冷却值在预防分支里用 MFConfigInt 现读，不落静态变量 —— -Werror 不允许未引用的 static。）
// 【0.16.0】真黑恢复后的"几何按住"窗口：presenter 在重新 hosting 时会按它自己的
// 想法重设承载视图尺寸（归档(16) 实测 384x562 vs 目标 362x366，偏差 54%），
// 等 500ms 节流才掰回来，用户就看到画面被拉大又弹回 = "内容闪一下"。
// 恢复后 2s 内解除节流、逐拍掰，把错误尺寸的可见窗口压到一拍（200ms）以内。
static NSTimeInterval gMFViewHoldUntil = 0;

static NSInteger MFKeepAliveMsPerTick(void) {
    NSInteger ms = [gMFKeepAliveConfig[@"keepAliveMs"] integerValue];
    if (ms <= 0) ms = 200;
    return ms;
}

/// 目标 App 的进程状态，做成短签名。
/// 【0.10.0】必须走 MFIntProp32：`taskState` / `visibility` 是 32 位 int，
/// 用 64 位 NSInteger 去接会读到未初始化的高位（0.9.1 的 `ps=10751930112` 就是这么来的）。
static NSString *MFAppStateShort(id app) {
    if (app == nil) return @"-";
    id ps = MFMsg(app, NSSelectorFromString(@"processState"));
    if (ps == nil) return @"nil";
    BOOL a = NO, b = NO;
    return [NSString stringWithFormat:@"%d/%d",
            MFIntProp32(ps, @"taskState", &a),
            MFIntProp32(ps, @"visibility", &b)];
}

/// 采集一次"决定黑不黑"的全部关键值，做成可直接字符串比较的签名。
/// 放在一行里是为了让日志能直接做 diff（`旧 -> 新`）。
static NSString *MFKeepAliveSignature(id scene, id pres) {
    if (scene == nil) return @"scene=nil";
    MFHealth h = MFReadHealth(scene);
    return [NSString stringWithFormat:@"%@ host=%@ hosted=%ld ps=%@",
            MFHealthSignature(scene, h),
            MFBoolProp(pres, NSSelectorFromString(@"isHosting")) ? @"1" : @"0",
            (long)MFHostedLayerCount(pres),
            MFAppStateShort(gMFKeepAliveApp)];
}

/// 停掉守护（换目标 / 关闭浮窗 / scene 失效时一定要调，否则会一直摸一个已经不属于我们的 scene）
static void MFStopSceneKeepAlive(NSString *why) {
    if (gMFKeepAliveTimer != nil) {
        [gMFKeepAliveTimer invalidate];
        gMFKeepAliveTimer = nil;
        MFLog(@"[keepalive] 已停止守护（%@）", why ?: @"?");
    }
    gMFKeepAliveScene = nil;
    gMFKeepAliveApp = nil;
    gMFKeepAliveBundleID = nil;
    gMFKeepAliveConfig = nil;
    gMFKeepAliveLastSig = nil;
    gMFKeepAliveTicks = 0;
    gMFKeepAliveDownTicks = 0;
    gMFKeepAliveWritesInDrop = 0;
    gMFKeepAliveAdvisoryTicks = 0;
    gMFKeepAliveNextHeartbeat = 0;
    gMFKeepAliveNextFrameCheck = 0;
    gMFKeepAliveStartTime = 0;
    gMFKeepAliveLastWriteTime = 0;
    gMFKeepAlivePreventTicks = 0;
    gMFKeepAlivePreventWrites = 0;
    gMFKeepAliveLastPreventTime = 0;
    gMFKeepAliveLastViewFix = 0;
    gMFViewHoldUntil = 0;
}

/// 只在"尺寸真的漂了"时，把 scene.frame 纠回内容区尺寸（要写 settings，所以有节流）。
static void MFKeepAliveFixFrameIfNeeded(id scene, BOOL verbose) {
    if (scene == nil || !gMFDesiredContentValid) return;
    id st = MFMsg(scene, NSSelectorFromString(@"settings"));
    BOOL has = NO;
    CGRect cur = MFRectProp(st, @"frame", &has);
    if (!has) {
        if (verbose) MFLogS(@"[keepalive] 读不到 scene.settings.frame -> 关掉尺寸纠正（不猜）");
        gMFDesiredContentValid = NO;
        return;
    }
    CGSize want = gMFDesiredContentSize;
    if (fabs(cur.size.width - want.width) < 0.5 && fabs(cur.size.height - want.height) < 0.5) return;
    // 【0.23.0】用户缩放手势期间/刚结束：守护不纠 scene.frame（让用户改的尺寸活着）
    if (MFUserGestureActive()) return;
    MFLog(@"[keepalive] 尺寸漂了（scene %@ -> 目标 %.0fx%.0f）-> 纠一次",
          NSStringFromCGRect(cur), want.width, want.height);
    MFSetSceneFrame(scene, CGRectMake(0, 0, want.width, want.height));
}

/// 视图层纠正：**不写 settings**，只把承载视图按回内容区尺寸。
/// 归档(10) 里 `_UIScenePresentationView` 在 presenter 掉 hosting 时被系统改成整屏 430x932
/// （P6+20s: view frame={{0,0},{430,932}}，而面板内容区只有 274x478），这才是比例崩的源头；
/// 修它**不需要**碰 scene settings，也就不会引发重排。
/// 【0.12.0 加了容差 + 节流 —— 归档(12) 的教训】
/// 0.11.0 是"差 0.5 点就掰回来"。在 keepAliveMs=50 时这就是每秒 20 次，
/// 而承载视图当时正在**动画里**（日志里 271x346 / 291x371 / 284x356 … 一串中间值），
/// 等于我们跟 presenter 自己的布局在对拉：日志被刷掉 7 万字节，
/// 而且很可能就是把 hosting 搞掉的原因之一。现在：
///   · 偏差小于 keepAliveViewFrameTol（默认 8%）不管 —— 那是正常的布局抖动；
///   · 两次掰之间至少隔 keepAliveViewFrameMs（默认 500 ms）；
///   · 只有"偏差很大"（>25%，例如被改成整屏 430x932）才不受节流限制，立刻掰回来。
static void MFKeepAliveFixViewFrameIfNeeded(void) {
    if (!gMFDesiredContentValid) return;
    // 【0.23.0】用户缩放手势期间/刚结束：守护不掰承载视图（否则用户拖了白拖）
    if (MFUserGestureActive()) return;
    if (![gMFCurrentContentView isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)gMFCurrentContentView;
    CGSize want = gMFDesiredContentSize;
    if (want.width < 1.0 || want.height < 1.0) return;

    double dw = fabs(v.bounds.size.width  - want.width)  / want.width;
    double dh = fabs(v.bounds.size.height - want.height) / want.height;
    if (dw < 0.01 && dh < 0.01) return;

    double tol = 0.08;
    id tv = gMFKeepAliveConfig[@"keepAliveViewFrameTol"];
    if ([tv respondsToSelector:@selector(doubleValue)]) tol = [tv doubleValue];
    if (tol < 0.01) tol = 0.01;

    BOOL severe = (dw > 0.25 || dh > 0.25);
    if (!severe && !(dw > tol || dh > tol)) return;   // 正常的布局抖动，不管

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // 【0.16.0】真黑恢复后的 2s 窗口内解除节流：presenter 刚重新 hosting、正在按它
    // 自己的想法重设尺寸，这时候慢一拍用户就看见画面被拉大再弹回（"内容闪一下"）。
    BOOL holding = (now < gMFViewHoldUntil);
    if (!severe && !holding) {
        NSInteger minMs = MFConfigInt(gMFKeepAliveConfig, @"keepAliveViewFrameMs", 500);
        if (gMFKeepAliveLastViewFix > 0 &&
            (now - gMFKeepAliveLastViewFix) * 1000.0 < (double)minMs) {
            return;   // 限流（严重偏差除外）
        }
    }
    gMFKeepAliveLastViewFix = now;

    MFLog(@"[keepalive] 承载视图尺寸被系统改过（%.0fx%.0f -> %.0fx%.0f，偏差 %.0f%%%@）-> 按回内容区（只动视图，不写 settings）",
          v.bounds.size.width, v.bounds.size.height, want.width, want.height,
          MAX(dw, dh) * 100.0, severe ? @"，严重" : (holding ? @"，恢复后按住" : @""));
    v.frame = CGRectMake(0, 0, want.width, want.height);
}

/// 【0.11.0 新增】把"承载"这一侧修好 —— **不碰 scene settings**，所以不会引发重排。
///   ① presenter 掉了 hosting  -> 重新 activate（幂等；0.7.0 已实测不会崩）；
///   ② 承载视图不在内容区里了  -> 放回内容区并对齐尺寸。
///
/// 归档(11) 的 Filza 轮就是第 ① 种：P6+20s 时 scene 自己**完全健康**
/// （contentState=2 layers=2）、但 presenter.isHosting=0、hostContainer=nil、
/// presentationView 被系统改成整屏 430x932 —— 黑的根本不是 scene，是承载。
/// 这种情况下 0.10.0 会去写 scene settings（白送一次重排），完全打不中要害。
static BOOL MFRepairPresenterHosting(BOOL verbose) {
    BOOL did = NO;

    if (gMFPresenter != nil && !MFBoolProp(gMFPresenter, NSSelectorFromString(@"isHosting"))) {
        MFMsg(gMFPresenter, NSSelectorFromString(@"activate"));
        did = YES;
        if (verbose) MFLogS(@"[keepalive] presenter.isHosting=0 -> 重新 activate（只修承载，不写 settings）");
    }

    if (gMFCurrentContentArea != nil && [gMFCurrentContentView isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)gMFCurrentContentView;
        if (v.superview != gMFCurrentContentArea) {
            v.frame = gMFCurrentContentArea.bounds;
            [gMFCurrentContentArea addSubview:v];
            did = YES;
            if (verbose) {
                MFLog(@"[keepalive] 承载视图已不在内容区里（superview=%@）-> 重新挂回 frame=%@",
                      v.superview ? NSStringFromClass([v.superview class]) : @"nil",
                      NSStringFromCGRect(v.frame));
            }
        }
    }
    return did;
}

// ---------------- 【0.15.0 消闪三件套（视觉侧）】 ----------------
//
// 归档(15) 钉死的事实：切换 App 时系统会直接把浮窗 scene 的图层掉光
// （48 次真黑里 45 次前一拍 deact 还是 0 —— **没有前兆**，预防档根本来不及），
// 黑窗 200~400ms 后由我们的 L1 写拉回。轮询永远追不上"直接掉"，
// 所以真正能消闪的是**视觉侧**：掉图层的那一瞬间，别让用户看到黑。
//
//   ① context 的"未承载背景色"设透明（P3b，见上）—— 黑窗变透窗；
//   ② 剥掉 presentationView 自带的黑底（背景 view / layer 背景色）；
//   ③ 内容区最底层垫一张"最后一帧"快照 —— 透窗露出的不是面板底色，
//     而是定格的画面，体感 = 画面停了一拍，几乎无感。

static UIImageView *gMFPadView    = nil;   // 垫底快照视图（默认内容区 index 0）
static double       gMFPadLastTime = 0;     // 快照节流

// 【0.18.0】快照置顶遮盖：掉层瞬间把快照提到内容区最上层，盖住 presentationView
// 的任何可见异常（黑/白/半渲染），恢复后延迟 2 拍归位。
// 归档(19) 钉死：每次切出/切回系统**必掉层**（47 次真黑 = 用户每次操作都撞上），
// L1 拉回是异步的（400~800ms），垫底快照盖不住上层 presentationView 自己的闪烁
// ⇒ 必须临时置顶。恢复判定（layers>0，由 render server 报告）成立时图层已重建，
// 再留 2 拍缓冲防"恢复判定与可见性之间的小空窗"。
static BOOL        gMFPadRaised     = NO;  // 快照当前是否在最上层
static NSInteger   gMFHealthyTicks  = 0;   // 【0.19.0】连续健康拍数（≥2 才归位；真黑拍清零）

/// 把快照提到内容区最上层。**每个真黑拍都调用、每次都重新置前** ——
/// 归档(20) 钉死：系统恢复 hosting 时会把 presentationView 重新插回快照之上，
/// 只置顶一次守不住；置顶后掉层、恢复、再掉层，快照每拍都要重新爬回最上层。
/// 日志只在"从未置顶 -> 置顶"这一刻打（避免每拍刷屏）。
static void MFSnapshotPadRaise(NSDictionary *cfg) {
    if (cfg != nil && !MFConfigBool(cfg, @"keepAliveSnapshotMask", YES)) return;
    if (gMFPadView == nil || gMFPadView.superview == nil) return;
    @try {
        UIView *area = gMFPadView.superview;
        gMFPadView.frame = area.bounds;      // 对齐内容区（autoresizing 已兜底，双保险）
        gMFPadView.hidden = NO;
        [area bringSubviewToFront:gMFPadView];
        if (!gMFPadRaised) {
            gMFPadRaised = YES;
            MFLogS(@"[pres] 消闪：快照已置顶遮盖（掉层期间显示最后一帧定格画面）");
        }
    } @catch (NSException *e) { }
}

/// 把快照送回内容区最底层（幂等）。恢复后调用。
static void MFSnapshotPadLower(void) {
    if (gMFPadView == nil || gMFPadView.superview == nil || !gMFPadRaised) return;
    @try {
        [gMFPadView.superview sendSubviewToBack:gMFPadView];
        gMFPadRaised = NO;
        MFLogS(@"[pres] 消闪：快照已归位垫底（真实内容重新可见）");
    } @catch (NSException *e) { }
}

/// 剥掉承载视图的自带黑底。承载成功后调用一次。
/// 归档(15) 报告：`_UIScenePresentationView` 有 `backgroundView` 属性 +
/// `_updateBackgroundColor` 方法 —— 黑八成画在这个内部背景 view 上。
static void MFStripPresentationBlack(void) {
    if (![gMFCurrentContentView isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)gMFCurrentContentView;
    v.backgroundColor = [UIColor clearColor];
    v.layer.backgroundColor = [UIColor clearColor].CGColor;
    v.opaque = NO;
    id bg = MFMsg(v, NSSelectorFromString(@"backgroundView"));
    if ([bg isKindOfClass:[UIView class]]) {
        UIView *bgv = (UIView *)bg;
        bgv.backgroundColor = [UIColor clearColor];
        bgv.hidden = YES;   // 直接藏掉最稳（hosted layers 在 hostContainerView，不受影响）
        MFLog(@"[pres] 消闪：presentationView 背景已剥黑并隐藏（backgroundView=%@）",
              NSStringFromClass([bgv class]));
    } else {
        MFLogS(@"[pres] 消闪：presentationView 背景已剥黑（无 backgroundView 或读不到）");
    }
}

/// 更新垫底快照。只在**健康拍**调用（layers>0 且 hosted>0），黑窗期间绝不更新
/// —— 否则会把黑抓进去。限流 2 s 一次。
static void MFSnapshotPadUpdate(NSDictionary *cfg) {
    if (cfg != nil && !MFConfigBool(cfg, @"keepAliveSnapshot", YES)) return;
    UIView *area = gMFCurrentContentArea;
    if (![area isKindOfClass:[UIView class]] || area.bounds.size.width < 1.0) return;
    if (![gMFCurrentContentView isKindOfClass:[UIView class]]) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gMFPadLastTime > 0 && (now - gMFPadLastTime) < 2.0) return;
    gMFPadLastTime = now;
    @try {
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:area.bounds];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
            [area drawViewHierarchyInRect:area.bounds afterScreenUpdates:NO];
        }];
        if (img == nil) return;
        // 【0.19.0 修复】重建条件不能只看 gMFPadView == nil：
        // attachContentView 换 App 时 clearContentArea 会把快照一起 removeFromSuperview，
        // 对象活着但 superview 变 nil —— 归档(20) 里酷安会话 15 次真黑零遮盖的根因。
        // superview 不对（被摘/挂在旧区）都必须重挂。
        if (gMFPadView == nil || gMFPadView.superview != area) {
            if (gMFPadView != nil) [gMFPadView removeFromSuperview];
            gMFPadView = [[UIImageView alloc] initWithFrame:area.bounds];
            gMFPadView.userInteractionEnabled = NO;
            gMFPadView.autoresizingMask =
                UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [area addSubview:gMFPadView];
            [area sendSubviewToBack:gMFPadView];   // 垫在最底，承载视图盖在它上面
            MFLogS(@"[pres] 垫底快照视图已建立/重挂（内容区 index 0）");
        }
        gMFPadView.image = img;
    } @catch (NSException *e) {
        // 快照失败不影响主链路（部分 remote layer 结构抓不出来，垫底就当没有）
    }
}

/// 守护定时器的一次心跳。
/// 【注意】这里**故意不写** MFStepMark —— 步骤日志是给人肉回传用的，几秒一行会把它冲垮。
static void MFKeepAliveTick(void) {
    id scene = gMFKeepAliveScene;
    if (scene == nil) { MFStopSceneKeepAlive(@"scene 引用为空"); return; }

    gMFKeepAliveTicks += 1;

    if (!MFBoolProp(scene, NSSelectorFromString(@"isValid"))) {
        MFLogS(@"[keepalive] scene 已失效 -> 停止守护；点 ↻ 重新拉应用列表再点一次应用名即可重挂");
        MFStopSceneKeepAlive(@"scene 失效");
        return;
    }

    // 状态一变就记一行：这是"到底是谁把它改回去的"的唯一证据。
    NSString *sig = MFKeepAliveSignature(scene, gMFPresenter);
    if (gMFKeepAliveLastSig == nil || ![sig isEqualToString:gMFKeepAliveLastSig]) {
        MFLog(@"[keepalive] 状态变化 %@ -> %@",
             gMFKeepAliveLastSig ?: @"<初值>", sig);
        gMFKeepAliveLastSig = [sig copy];
    }

    MFHealth h = MFReadHealth(scene);
    NSInteger hosted = MFHostedLayerCount(gMFPresenter);
    NSDictionary *cfg = gMFKeepAliveConfig;
    MFDropKind kind = MFJudgeDrop(h, hosted, cfg);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSInteger ms = MFKeepAliveMsPerTick();

    // ---------------- 健康 ----------------
    if (kind == MFDropNone) {
        // 【0.15.0】健康时刷新垫底快照（内部自带 2 s 节流；黑窗期间不会进到这里，
        // 所以垫底永远是"最后一帧好画面"，不会把黑抓进去）。
        MFSnapshotPadUpdate(cfg);
        if (gMFKeepAliveDownTicks > 0) {
            MFLog(@"[keepalive] 已恢复：本次真黑持续 %ld 拍（约 %ld ms），写了 %ld 次 settings"
                  @"（末次档位 L%ld）｜ 本轮累计 L1救回=%ld L2救回=%ld L3救回=%ld",
                  (long)gMFKeepAliveDownTicks, (long)(gMFKeepAliveDownTicks * ms),
                  (long)gMFKeepAliveWritesInDrop, (long)gMFLastRestoreTier,
                  (long)gMFRestoreTier1Hits, (long)gMFRestoreTier2Hits, (long)gMFRestoreTier3Hits);
        }
        // 【0.16.0】刚从真黑恢复 -> 开 2s"几何按住"窗口：presenter 重新 hosting 时
        // 会按自己的想法重设承载视图尺寸（归档(16) 实测偏差 54%），恢复后逐拍掰回，
        // 把错误尺寸的可见窗口从"最长 500ms 节流 + 一拍"压到一拍以内。
        if (gMFKeepAliveDownTicks > 0) {
            gMFViewHoldUntil = now + 2.0;
        }
        // 【0.19.0】快照归位：**连续 2 个健康拍**（render server 确认新内容可见）才送回底层。
        // 归档(20) 修复：旧版"恢复拍设 ticks+2"会被下一个健康拍反复重置 ——
        // 切出切回密集时无限顺延（实测置顶 8 秒不归位），期间掉层又不能重新置顶，
        // 快照被系统重新插层埋掉 = 白闪回归。现在真黑拍清零计数，连稳 2 拍必归位。
        if (gMFPadRaised) {
            gMFHealthyTicks += 1;
            if (gMFHealthyTicks >= 2 && hosted > 0 && (!h.hasCs || h.cs == 2)) {
                MFSnapshotPadLower();
                gMFHealthyTicks = 0;
            }
        } else {
            gMFHealthyTicks = 0;
        }
        // 【0.12.0】预防档结束 —— 本轮最该看的一行：
        // "被去激活了 N 拍、写了 M 次状态量、图层始终没掉" = 预防成功（用户什么都感觉不到）。
        if (gMFKeepAlivePreventTicks > 0) {
            MFLog(@"[keepalive] 预防结束：连续 %ld 拍被去激活/idle，写了 %ld 次状态量，图层始终没掉 ✔",
                  (long)gMFKeepAlivePreventTicks, (long)gMFKeepAlivePreventWrites);
        }
        gMFKeepAliveDownTicks = 0;
        gMFKeepAliveWritesInDrop = 0;
        gMFKeepAliveAdvisoryTicks = 0;
        gMFKeepAlivePreventTicks = 0;
        gMFKeepAlivePreventWrites = 0;
        gMFTierWriteDownTick = -1;    // 【0.17.0】新回合：生效确认窗归零
        gMFTierLastWritten = 0;

        // 视图层纠正：便宜、不写 settings，顺手把比例守住
        MFKeepAliveFixViewFrameIfNeeded();

        // scene 尺寸纠正：只在真的漂了时写一次；每秒最多检查一次（写它会重排）
        if (MFConfigBool(cfg, @"keepAliveFrameSync", YES) &&
            gMFKeepAliveTicks >= gMFKeepAliveNextFrameCheck) {
            gMFKeepAliveNextFrameCheck = gMFKeepAliveTicks + (NSInteger)(1000.0 / (double)ms);
            MFKeepAliveFixFrameIfNeeded(scene, NO);
        }

        if (gMFKeepAliveTicks >= gMFKeepAliveNextHeartbeat) {
            MFLog(@"[keepalive] 心跳 %@", sig);
            gMFKeepAliveNextHeartbeat = gMFKeepAliveTicks + (NSInteger)(10000.0 / (double)ms);
        }
        return;
    }

    // ---------------- 预防：图层还在，但正在被去激活 / 正在失去前台身份 ----------------
    // 【0.12.0 引入 / 0.13.0 修好】这是唯一能"既不掉图层、又不闪"的时机：
    //   归档(13) 实测 `deact 0->32`（画面还好）之后约 1 秒才 `layers 2->0`；
    //   而 App 被挂起（`taskState: Suspended`）之后，写什么都没用。
    if (kind == MFDropPrevent) {
        gMFKeepAliveAdvisoryTicks = 0;
        gMFKeepAlivePreventTicks += 1;

        // 宽限期同样适用：presenter 刚建 hosting 那一两百毫秒里 deact 波动是正常的。
        NSInteger graceMs = MFConfigInt(cfg, @"keepAliveGraceMs", 600);
        if (gMFKeepAliveStartTime > 0 &&
            (now - gMFKeepAliveStartTime) * 1000.0 < (double)graceMs) {
            return;
        }

        // 限流：预防写的目的是"在图层掉光之前把它按住"，不需要每拍都写
        // （排掉 0.9.1 那种"每拍一次 = 每秒闪 5 次"的代价）。
        // 【0.13.0】再加一层**退避**：如果连续很多拍都在预防档（说明按不住，或者
        // 系统就是要它后台），就把间隔翻倍到上限为止 —— 只是变慢，**永不停止**
        // （0.10.0 在这里做成"放弃"是错的，那等于主动选择永久黑屏）。
        NSInteger preventMs = MFConfigInt(cfg, @"keepAlivePreventMs", 250);
        NSInteger pbAfter   = MFConfigInt(cfg, @"keepAlivePreventBackoffAfter", 40);
        if (pbAfter > 0 && gMFKeepAlivePreventTicks > pbAfter) {
            NSInteger steps = (gMFKeepAlivePreventTicks - pbAfter) / 20;
            if (steps > 5) steps = 5;
            preventMs = preventMs * (NSInteger)(1 << steps);
            NSInteger capMs = MFConfigInt(cfg, @"keepAlivePreventBackoffMaxMs", 2000);
            if (capMs > 0 && preventMs > capMs) preventMs = capMs;
        }
        if (gMFKeepAliveLastPreventTime > 0 &&
            (now - gMFKeepAliveLastPreventTime) * 1000.0 < (double)preventMs) {
            return;
        }

        // 【0.16.0】冷却：本回合已经写过 1 次的话，下一次写必须隔
        // keepAlivePreventCooldownMs（默认 2s）。归档(16) 钉死：
        // 每次 updateSettingsWithBlock 都是一次 scene 重提交（cs 2->0->1->2）
        // = 一帧可见的"内容闪"；而第 2~4 发并不能阻止掉层（掉了由真黑档 L1
        // 兜底、垫底快照遮住）。所以：第 1 发要快（上面的 preventMs=250），
        // 追加发要慢（这里 2s）—— 把每回合的可见闪帧从 2~4 帧压到 1 帧。
        if (gMFKeepAlivePreventWrites >= 1) {
            NSInteger cdMs = MFConfigInt(cfg, @"keepAlivePreventCooldownMs", 2000);
            if (cdMs > 0 && gMFKeepAliveLastPreventTime > 0 &&
                (now - gMFKeepAliveLastPreventTime) * 1000.0 < (double)cdMs) {
                return;   // 冷却中：只观察不动手（图层真掉会走真黑档，不受此限）
            }
        }

        BOOL verbose = (gMFKeepAlivePreventTicks == 1) || (gMFKeepAlivePreventTicks % 20 == 0);
        if (verbose) {
            MFLog(@"[keepalive] 预防性拉回（第 %ld 拍：deact=%llu idle=%d cs=%ld layers=%ld "
                  @"hosted=%ld fgS=%@(%d)）—— 图层还在，趁它没掉先按住",
                  (long)gMFKeepAlivePreventTicks, h.deact, (int)h.idle,
                  (long)h.cs, (long)h.layers, (long)hosted,
                  h.hasSceneFg ? @"y" : @"n", (int)h.sceneFg);
        }
        NSString *pdid = MFWritePreventiveSettings(scene, cfg, h, verbose);
        gMFKeepAliveLastPreventTime = now;
        if (![pdid hasPrefix:@"无差量"]) gMFKeepAlivePreventWrites += 1;
        if (verbose) {
            MFLog(@"[keepalive] 预防写[%@]（本次累计真写 %ld 次）", pdid, (long)gMFKeepAlivePreventWrites);
        }
        gMFKeepAliveLastSig = [MFKeepAliveSignature(scene, gMFPresenter) copy];
        return;
    }

    // ---------------- 软警告（只观察，永不动手）----------------
    // 【0.10.0 引入 / 0.12.0 降级为纯观察档】只有把 keepAlivePrevent 关掉、
    // 同时打开 keepAliveSoft 时才会走到这里 —— 用于 A/B 对照"什么都不做会怎样"
    // （0.10.0/0.11.0 的默认行为就是走到这里，结果就是永久黑屏）。
    if (kind == MFDropAdvisory) {
        gMFKeepAliveAdvisoryTicks += 1;
        if (gMFKeepAliveAdvisoryTicks == 1 || (gMFKeepAliveAdvisoryTicks % 20 == 0)) {
            MFLog(@"[keepalive] 软警告（不动手）：deact=%llu idle=%d，但 layers=%ld hosted=%ld 画面仍在",
                  h.deact, (int)h.idle, (long)h.layers, (long)hosted);
        }
        return;
    }

    // ---------------- 真黑：图层已经没了的**补救**（预防没赶上，多半没救了）----------------
    // 【0.12.0】为什么明知不可逆还要写：① 有些机型/时机下它能被 level+displayConfiguration 拉回来；
    // ② 日志里"写了 M 次都拉不回来"本身就是证据。真正解决问题的在上面那一档（预防）。
    gMFKeepAliveAdvisoryTicks = 0;
    gMFKeepAliveDownTicks += 1;
    BOOL verbose = (gMFKeepAliveDownTicks == 1) || (gMFKeepAliveDownTicks % 10 == 0);

    if (verbose) {
        MFLog(@"[keepalive] 真黑（第 %ld 拍：layers=%ld hosted=%ld cs=%ld deact=%llu idle=%d fg=%d）",
              (long)gMFKeepAliveDownTicks, (long)h.layers, (long)hosted,
              (long)h.cs, h.deact, (int)h.idle, (int)h.fg);
    }

    // ---- 刹车 1：挂载宽限期 ----
    // presenter 建 hosting 是异步的，刚挂上那一两百毫秒里"没图层"很正常；
    // 这段时间只观察不动手。0.11.0 把它从 1500 ms 收到 600 ms：真黑时我们本来就该尽快救，
    // 宽限期只需要盖住"P0 的写 + presenter 挂载"这一个异步窗口。
    NSInteger graceMs = MFConfigInt(cfg, @"keepAliveGraceMs", 600);
    if (gMFKeepAliveStartTime > 0 &&
        (now - gMFKeepAliveStartTime) * 1000.0 < (double)graceMs) {
        if (verbose) {
            MFLog(@"[keepalive] 仍在挂载宽限期（%ld ms）内 -> 只观察不写 settings", (long)graceMs);
        }
        return;
    }

    // ---- 【0.18.0】快照置顶遮盖：掉层窗口显示最后一帧定格画面 ----
    // 归档(19)：每次切出/切回系统必掉层（47 次真黑 = 用户每次操作都撞上），
    // L1 拉回异步 400~800ms；垫底快照盖不住上层 presentationView 的可见异常
    //（黑/白/半渲染）⇒ 置顶遮盖，恢复后归位。宽限期内不置顶（那时画面还没出来，
    // 置顶反而显示上一个 App 的定格画面）。
    // 【0.19.0】每个真黑拍都重新置前（系统恢复 hosting 会把 presentationView
    // 重新插回快照之上，置顶一次守不住）+ 健康计数清零。
    gMFHealthyTicks = 0;
    MFSnapshotPadRaise(cfg);

    // ---- 【0.11.0 关键】先分清"是谁黑了"，再决定动不动 scene settings ----
    // scene 自己还有图层（layers>0）而 presenter 宿主是 0 ⇒ scene 在正常出图，
    // 黑的只是**承载**这一侧（isHosting=0 / 视图被摘掉 / 被改成整屏）。
    // 这种情况写 scene settings 一点用都没有，只会白送一次全量重排。
    if (h.layers > 0 && hosted <= 0) {
        if (verbose) {
            MFLog(@"[keepalive] 承载侧掉了（scene 好的：layers=%ld；hosted=%ld isHosting=%d）-> 只修承载，不写 settings",
                  (long)h.layers, (long)hosted,
                  (int)MFBoolProp(gMFPresenter, NSSelectorFromString(@"isHosting")));
        }
        BOOL repaired = MFRepairPresenterHosting(verbose);
        MFKeepAliveFixViewFrameIfNeeded();
        if (repaired && !verbose) MFLogS(@"[keepalive] 承载侧已修（重新 activate / 视图挂回内容区）");
        gMFKeepAliveLastSig = [MFKeepAliveSignature(scene, gMFPresenter) copy];
        return;
    }

    // ---- 刹车 2：失败**退避**（0.10.0 在这里是"放弃"，那是错的）----
    // 0.10.0 的 keepAliveGiveUpAfter=30 让它连续 30 拍救不回来就**永久停止写入**；
    // 而真黑是"必须救"的状态 —— 放弃就是永久黑屏（归档(11) 里 layers=0 持续了 220+ 拍，
    // 用户看到的就是"大概率黑屏"）。现在改成退避：连续失败越多、写入间隔越大（有上限），
    // 但**永远不停止**。keepAliveGiveUpAfter 仍然保留（>0 时才生效），只为 A/B 复现旧行为。
    NSInteger baseWriteMs = MFConfigInt(cfg, @"keepAliveMinWriteMs", 300);
    NSInteger effWriteMs  = baseWriteMs;
    NSInteger giveUpAfter = MFConfigInt(cfg, @"keepAliveGiveUpAfter", 0);
    if (giveUpAfter > 0 && gMFKeepAliveDownTicks >= giveUpAfter) {
        if (verbose) {
            MFLog(@"[keepalive] 连续 %ld 拍都没救回来 -> 已停止写入（keepAliveGiveUpAfter=%ld，仅用于对照）",
                  (long)gMFKeepAliveDownTicks, (long)giveUpAfter);
        }
        return;
    }
    NSInteger backoffAfter = MFConfigInt(cfg, @"keepAliveBackoffAfter", 50);
    if (backoffAfter > 0 && gMFKeepAliveDownTicks > backoffAfter) {
        NSInteger steps = (gMFKeepAliveDownTicks - backoffAfter) / 20;
        if (steps > 6) steps = 6;
        effWriteMs = baseWriteMs * (NSInteger)(1 << steps);
        NSInteger capMs = MFConfigInt(cfg, @"keepAliveBackoffMaxMs", 2000);
        if (capMs > 0 && effWriteMs > capMs) effWriteMs = capMs;
    }

    // 【0.14.0】真黑第 1 拍**立刻写** —— 黑的时间越短，用户越看不到。
    // （真黑是采样到的那一刻才发现的，再叠一层限流只会把黑拖长。）
    if (gMFKeepAliveDownTicks <= 1) effWriteMs = 0;

    // ---- 刹车 3：两次写入的最小间隔（退避后取放大值）----
    if (gMFKeepAliveLastWriteTime > 0 &&
        (now - gMFKeepAliveLastWriteTime) * 1000.0 < (double)effWriteMs) {
        if (verbose) {
            MFLog(@"[keepalive] 距上次写入不足 %ld ms -> 本拍跳过（%@）",
                  (long)effWriteMs,
                  (effWriteMs > baseWriteMs) ? @"已进入退避，仍会继续试" : @"限流");
        }
        return;
    }

    // ---- 【0.11.0 关键】真黑一律**全量写** ----
    // 0.10.0 在这里用"最小写"（只有 idle + deact + frame），结果**一次都拉不回来**：
    // 归档(11) 里 layers=0 持续 220+ 拍、其间写了十几次，全灭，画面上就是永久黑屏。
    // 对照 0.9.1 能拉回来，是因为它的拉回动作里有 `setLevel:1` + `setDisplayConfiguration:`
    // —— 这两项才是让 render server 重新给这个 scene 建图层的开关。
    // 所以：真黑 ⇒ 全量写（含 level + displayConfiguration + idle + deact + frame）。
    // 要复现 0.10.0 的黑屏（仅用于对照实验）可以把 keepAliveHardWrite 设成 false。
    //
    // 【0.14.0 修正】"全量写"里那两项几何（尤其 `setDisplayConfiguration:` 会把 frame 打回
    // 整屏再被 `setFrame:` 改回来 = 两次重排）正是归档(14) 里"切换那一下"的来源。
    // 而归档(14) 同时证明：**真黑几乎都是一过性的**（"本次真黑持续 1 拍"，写 1 次就回来）。
    // ⇒ 从最温和的 L1 试起，哪级救回来就停在哪级。多数情况下 L1 就够，几何根本不用动，也就不闪。
    BOOL hardWrite = MFConfigBool(cfg, @"keepAliveHardWrite", YES);
    BOOL tiered    = MFConfigBool(cfg, @"keepAliveTieredRestore", YES);
    NSInteger tier;
    if (!hardWrite) {
        tier = 1;                                  // 对照实验：永远只写状态量（≈ 0.10.0 的"最小写"）
    } else if (!tiered) {
        tier = 3;                                  // 关掉分级 = 回到 0.13.0 恒全量写
    } else if (gMFTierLastWritten > 0 && gMFTierWriteDownTick > 0 &&
               gMFKeepAliveDownTicks > gMFTierWriteDownTick &&
               gMFKeepAliveDownTicks - gMFTierWriteDownTick < 2) {
        // 【0.17.0】生效确认窗内：沿用上次档位，**不升级**。
        // 上一次写完才过了 1 拍 —— 恢复是异步的，现在升档只会白送一次几何重排。
        tier = gMFTierLastWritten;
    } else {
        tier = (gMFKeepAliveDownTicks >= 5) ? 3
             : (gMFKeepAliveDownTicks >= 3) ? 2 : 1;
    }
    gMFTierWriteDownTick = gMFKeepAliveDownTicks;
    gMFTierLastWritten   = tier;
    NSString *did = MFWriteSceneSettings(scene, cfg, tier, YES);
    gMFLastRestoreTier = tier;
    if (tier <= 1)      gMFRestoreTier1Hits += 1;
    else if (tier == 2) gMFRestoreTier2Hits += 1;
    else                gMFRestoreTier3Hits += 1;
    gMFKeepAliveLastWriteTime = now;
    gMFKeepAliveWritesInDrop += 1;

    MFRepairPresenterHosting(verbose);
    MFKeepAliveFixViewFrameIfNeeded();

    // 拉回后立刻复采一次并写进"上一次签名"，这样下一拍只有**真的没拉回来**才会再报。
    NSString *after = MFKeepAliveSignature(scene, gMFPresenter);
    gMFKeepAliveLastSig = [after copy];
    MFLog(@"[keepalive] 已写[%@] -> %@", did, after);
}

/// 开启守护。承载成功后调用；已在守护别的 scene 时会先停掉旧的。
static void MFStartSceneKeepAlive(id scene, id app, NSString *bundleID, NSDictionary *cfg) {
    MFStopSceneKeepAlive(@"换守护目标");

    if (scene == nil) return;
    if (!MFConfigBool(cfg, @"keepAlive", YES)) {
        MFLogS(@"[keepalive] keepAlive=false -> 不启动守护（归档(8)「切到别的 App 就黑屏」的直接原因，仅用于 A/B 对照）");
        return;
    }

    double ms = 200.0;
    id v = cfg[@"keepAliveMs"];
    if ([v respondsToSelector:@selector(doubleValue)]) ms = [v doubleValue];
    if (ms < 50.0)   ms = 50.0;
    if (ms > 5000.0) ms = 5000.0;

    gMFKeepAliveScene = scene;
    gMFKeepAliveApp = app;
    gMFKeepAliveBundleID = [bundleID copy];
    gMFKeepAliveConfig = cfg;
    gMFKeepAliveTicks = 0;
    gMFKeepAliveLastSig = nil;
    gMFKeepAliveDownTicks = 0;
    gMFKeepAliveWritesInDrop = 0;
    gMFKeepAliveAdvisoryTicks = 0;
    gMFKeepAlivePreventTicks = 0;
    gMFKeepAlivePreventWrites = 0;
    gMFKeepAliveLastPreventTime = 0;
    gMFKeepAliveLastViewFix = 0;
    gMFViewHoldUntil = 0;
    gMFTierWriteDownTick = -1;    // 【0.17.0】
    gMFTierLastWritten = 0;
    // 【0.19.0】快照彻底作废：旧会话的快照可能已脱离视图树（或内容还是上个 App），
    // 置 nil 强制下一个健康拍在当前内容区重建；只清 image 不够（归档(20) 教训）。
    if (gMFPadView != nil) {
        [gMFPadView removeFromSuperview];
        gMFPadView = nil;
    }
    gMFPadRaised = NO;
    gMFHealthyTicks = 0;
    MFSnapshotPadLower();         // 兜底（若上个会话把快照留在了顶层）
    gMFKeepAliveNextHeartbeat = (NSInteger)(10000.0 / ms);
    gMFKeepAliveNextFrameCheck = (NSInteger)(1000.0 / ms);
    gMFKeepAliveStartTime = [NSDate timeIntervalSinceReferenceDate];
    gMFKeepAliveLastWriteTime = 0;

    // 【0.13.0】每次重新承载都重新给 setForeground: 一次机会（上一次可能只是没给够时间）。
    gMFFgUsable = YES;
    gMFFgFailStreak = 0;

    // 【0.14.0】deact 熔断同理：每次重新承载都重新试，并清空恢复档位统计。
    gMFDeactUsable = YES;
    gMFDeactFailStreak = 0;
    gMFLastRestoreTier  = 0;
    gMFRestoreTier1Hits = 0;
    gMFRestoreTier2Hits = 0;
    gMFRestoreTier3Hits = 0;

    NSTimer *t = [NSTimer timerWithTimeInterval:(ms / 1000.0)
                                        repeats:YES
                                          block:^(NSTimer *timer) { MFKeepAliveTick(); }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    gMFKeepAliveTimer = t;

    MFLog(@"[keepalive] 已启动守护 %.0f ms/次（bundle=%@ / 预防档=%d @ %ld ms"
          @"（差量写 + fg 保活：本机 fg 读不到时每拍发 setForeground:YES，不碰几何；"
          @"deact 写带熔断 keepAliveDeactFuse=%ld；追加写冷却=%ld ms —— 每回合第 1 发快、"
          @"后续发慢，因为每发 updateSettings 都是闪帧） / "
          @"预防退避=%ld 拍后至 %ld ms / 真黑恢复=分级(L1纯状态量/L2+frame/L3+DC) tiered=%d / "
          @"宽限=%ld ms / 真黑写入间隔=%ld ms / 退避上限=%ld ms / "
          @"消闪=背景透明+剥黑底+垫底快照=%d+恢复后几何按住2s）",
          ms, bundleID ?: @"?",
          (int)MFConfigBool(cfg, @"keepAlivePrevent", YES),
          (long)MFConfigInt(cfg, @"keepAlivePreventMs", 250),
          (long)MFConfigInt(cfg, @"keepAliveDeactFuse", 5),
          (long)MFConfigInt(cfg, @"keepAlivePreventCooldownMs", 2000),
          (long)MFConfigInt(cfg, @"keepAlivePreventBackoffAfter", 40),
          (long)MFConfigInt(cfg, @"keepAlivePreventBackoffMaxMs", 2000),
          (int)MFConfigBool(cfg, @"keepAliveTieredRestore", YES),
          (long)MFConfigInt(cfg, @"keepAliveGraceMs", 600),
          (long)MFConfigInt(cfg, @"keepAliveMinWriteMs", 300),
          (long)MFConfigInt(cfg, @"keepAliveBackoffMaxMs", 2000),
          (int)MFConfigBool(cfg, @"keepAliveSnapshot", YES));

    // 启动时把"本机到底有哪些属性"一次性写进日志 —— 归档(9)/(10) 的教训是：
    // 不确认存在性就下结论，会让人连着几轮对着一个不存在的 getter 调试。
    MFHealth h0 = MFReadHealth(scene);
    MFLog(@"[keepalive] 初始状态 %@", MFKeepAliveSignature(scene, gMFPresenter));
    // 【0.13.0】这一行过去**误导了两轮**：它问的是 `scene.settings`（不可变对象）的
    // getter，所以 `foreground=NO` 让人以为"本机没有前台开关"。真相是 getter 没有、
    // **setter 有**（`setForeground:` 在 settings 上 settings=YES），而且光看它有没有还不够 ——
    // 还要看写完到底管不管用（见 MFWritePreventiveSettings 的读回验证）。
    MFLog(@"[keepalive] 可读性: settings.foreground=%@ settings.idleModeEnabled=%@ "
          @"settings.deactivationReasons=%@ settings.level=%@ FBScene.foreground=%@ "
          @"scene.contentState=%@ | 可写性: setForeground=%@ setLevel=%@ setFrame=%@",
          h0.hasFg ? @"YES" : @"NO",
          h0.hasIdle ? @"YES" : @"NO",
          h0.hasDeact ? @"YES" : @"NO",
          h0.hasLvlVal ? @"YES" : @"NO",
          h0.hasSceneFg ? @"YES" : @"NO",
          h0.hasCs ? @"YES" : @"NO",
          [MFMsg(scene, NSSelectorFromString(@"settings")) respondsToSelector:NSSelectorFromString(@"setForeground:")] ? @"YES" : @"NO",
          h0.hasLevel ? @"YES" : @"NO",
          h0.hasFrame ? @"YES" : @"NO");
    MFLog(@"[keepalive] 尺寸真源: %@（来自 panel.contentArea.bounds，不再读 presentationView.bounds）",
          gMFDesiredContentValid
            ? [NSString stringWithFormat:@"%.0fx%.0f",
               gMFDesiredContentSize.width, gMFDesiredContentSize.height]
            : @"未知");
}
#pragma mark ========== 0.7.0：Route 4 —— 自建 scene ==========

/// 【0.8.0 重写】Route 4 的自有 scene 获取。
///
/// 0.7.0 这里是"每次调用都 createSceneWithDefinition: 建一个新的"，
/// 而 identity 是固定的 `...-multifloat`。真机（归档(7)）后果：
/// 同一个 SpringBoard pid(19006) 在 t=291 建过一次并成功，t=316 又建第二次
/// ⇒ FBSceneManager 对重复 identity 断言 ⇒ SpringBoard 挂 ⇒ 安全模式
/// （崩溃归因 crashedStep=P4-scene，MF-host-step-prev.txt 恰好停在 `>>> P4-scene`）。
///
/// 所以本函数的三条铁律：
///   1. 同一个 App **只建一次** —— 之后一律复用（scene 还活着就重新呈现）。
///   2. 建之前先 sceneWithIdentifier: 查一遍，已有同 identity 的 scene 就**接管**，绝不新建第二个。
///   3. 每个进程每个 App 硬上限 1 次新建（计数器），触顶只报错、绝不硬来。
static id MFAcquireOwnSceneForApp(NSString *bundleID, NSString *sceneID, CGRect frame) {
    static NSMutableDictionary<NSString *, NSNumber *> *gCreateCount = nil;
    if (gCreateCount == nil) gCreateCount = [NSMutableDictionary dictionary];

    // ---- 第 0 步：复用 ----
    if (MFOwnSceneIsAlive()) {
        if ([gMFOwnSceneBundleID isEqualToString:bundleID]) {
            MFStepMark(kMFStepOwn);
            MFLogS(@"[pres] Route4 复用自有 scene（同一个 App，绝不重复 createSceneWithDefinition）");
            MFStepOk(kMFStepOwn);
            return gMFOwnScene;
        }
        MFLog(@"[pres] Route4 换 App（%@ -> %@），先销毁旧自有 scene", gMFOwnSceneBundleID, bundleID);
        MFTeardownOwnScene();
    } else if (gMFOwnScene != nil) {
        MFLogS(@"[pres] Route4 旧自有 scene 已失效，丢弃引用");
        gMFOwnScene = nil;
        gMFOwnSceneBundleID = nil;
        gMFOwnSceneIdentity = nil;
    }

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

    MFStepMark(kMFStepOwn);
    id mgr = MFMsg(mgrCls, NSSelectorFromString(@"sharedInstance"));

    // ---- 第 1 步：已存在的同 identity scene 直接接管（关键保命步骤）----
    SEL lookup = NSSelectorFromString(@"sceneWithIdentifier:");
    if (mgr != nil && [mgr respondsToSelector:lookup]) {
        @try {
            id exist = ((id (*)(id, SEL, id))objc_msgSend)(mgr, lookup, sceneID);
            if (exist != nil) {
                MFLogS(@"[pres] Route4 发现同 identity 的已存在 scene -> 直接接管，不新建");
                gMFOwnScene = exist;
                gMFOwnSceneBundleID = [bundleID copy];
                gMFOwnSceneIdentity = [sceneID copy];
                MFStepOk(kMFStepOwn);
                return exist;
            }
        } @catch (NSException *e) {
            MFLog(@"[pres] sceneWithIdentifier: 抛异常: %@", e.reason);
        }
    }

    // ---- 第 2 步：硬上限 —— 每个进程每个 App 最多新建 1 次 ----
    NSNumber *used = gCreateCount[bundleID];
    if (used != nil && used.integerValue >= 1) {
        MFLog(@"[pres] !! %@ 本进程已建过一次自有 scene（硬上限 1）-> 拒绝再建（防 SpringBoard 崩）",
              bundleID);
        MFStepOk(kMFStepOwn);
        return nil;
    }

    // ---- 第 3 步：定义 ----
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
    MFMvRect(st,   @"setFrame:", frame);   // ← 画面比例正确的关键：建的时候就用内容区尺寸
    MFMvObj(st,    @"setPersistenceIdentifier:", sceneID);
    id dc = MFMsg([UIScreen mainScreen], NSSelectorFromString(@"displayConfiguration"));
    if (dc != nil) MFMvObj(st, @"setDisplayConfiguration:", dc);
    MFMvObj(params, @"setSettings:", st);

    id cs = MFMsg(cstCls, NSSelectorFromString(@"new"));
    MFMvLong(cs, @"setInterfaceOrientation:", (long)UIInterfaceOrientationPortrait);
    MFMvLong(cs, @"setStatusBarStyle:", 0);
    MFMvObj(params, @"setClientSettings:", cs);

    // ---- 建 scene ----
    gCreateCount[bundleID] = @((used != nil ? used.integerValue : 0) + 1);
    id scene = MFMvObj2(mgr, @"createSceneWithDefinition:initialParameters:", def, params);
    MFStepOk(kMFStepOwn);
    MFLog(@"[pres] Route4 createSceneWithDefinition -> %@（mgr=%@，本进程第 %@ 次）",
          scene ? NSStringFromClass([scene class]) : @"nil",
          mgr ? NSStringFromClass([mgr class]) : @"nil", gCreateCount[bundleID]);
    if (scene != nil) {
        gMFOwnScene = scene;
        gMFOwnSceneBundleID = [bundleID copy];
        gMFOwnSceneIdentity = [sceneID copy];
    }
    return scene;
}

/// 能力报告：把关键类的"自有方法表"和目标对象的 responds 矩阵写到
/// /var/mobile/MF-presenter-report.txt。**纯读元数据**（class_copyMethodList / respondsToSelector），不发危险消息。
/// 【0.10.0 新增】在某个对象的所有 ivar 里找"去激活管理器 / 断言"的持有者。
///
/// 为什么还要找它：0.10.0 已经把"闪屏"从"事后拉回"变成"根本不写 settings"，
/// 但要做到**零闪烁**（连那一次真掉出都不出现），唯一干净的路子是让 SpringBoard
/// 一开始就别把我们的 scene 去激活 —— 也就是 `UIApplicationSceneDeactivationManager`
/// 的 `newAssertionWithReason:`。那个类在真机存在（报告里有它的方法表：
/// newAssertionWithReason: / addAssertion:withTransitionContext: / _deactivationReasonsForScene:withSettings:），
/// 缺的只是**它的实例**。归档(10) 报告已排除 `UIApplication` 的 KVC 与 ivar，
/// 所以这一版把候选持有者（UIApplication / windowScene / FBScene / sceneHandle / presentationManager）
/// 逐个扫一遍 ivar，命中就写进报告 —— 下一轮就能直接写出 acquire 代码。
static void MFReportScanDeactManager(NSMutableString *out, NSString *tag, id obj) {
    if (out == nil) return;
    if (obj == nil) { [out appendFormat:@"  %@ = nil\n", tag]; return; }

    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([obj class], &n);
    NSInteger hits = 0;
    for (unsigned int i = 0; i < n; i++) {
        const char *tn = ivar_getTypeEncoding(ivars[i]);
        if (tn == NULL || tn[0] != '@') continue;      // 只看对象类型的 ivar
        id v = nil;
        @try { v = object_getIvar(obj, ivars[i]); } @catch (NSException *e) { v = nil; }
        if (v == nil) continue;
        NSString *cn = NSStringFromClass([v class]);
        if ([cn rangeOfString:@"Deact"].location != NSNotFound ||
            [cn rangeOfString:@"Assert"].location != NSNotFound) {
            [out appendFormat:@"  ★ %@.%s -> %@\n", tag, ivar_getName(ivars[i]), cn];
            hits++;
        }
    }
    if (ivars != NULL) free(ivars);
    if (hits == 0) [out appendFormat:@"  %@ 的 ivar 里没有 *Deact* / *Assert*（%u 个 ivar）\n", tag, n];
}

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
                          @"RBSProcessHandle", @"FBProcessManager",
                          // 【0.9.1 新增】去激活链路的另外两环 + 目标 scene 本体
                          @"UIApplication", @"UIApplicationSceneDeactivationAssertion",
                          @"UIApplicationSceneDeactivationAssertionGroup", @"FBScene" ];
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
    [s appendFormat:@"  settings 类           = %@（注意：这是**不可变**对象，缺 setter 不代表写不进去）\n",
     st ? NSStringFromClass([st class]) : @"nil"];
    {
        [s appendFormat:@"  foreground           = %@（getter 本身在不在：%d）\n",
         MFKV(st, @"foreground"),
         (int)[st respondsToSelector:NSSelectorFromString(@"foreground")]];
        // 【0.13.0】这是 0.9.x 读错的那个值 —— 它要去 FBScene 上读（KVC）。
        BOOL hFs = NO;
        BOOL fs = MFForegroundOf(scene, &hFs);
        [s appendFormat:@"  ★ FBScene.foreground = %@(%d)  ← 【0.13.0】这才是「App 还算不算前台」的真值\n",
         hFs ? @"y" : @"n", (int)fs];
    }
    [s appendFormat:@"  level                = %@\n", MFKV(st, @"level")];
    [s appendFormat:@"  frame                = %@\n", MFKV(st, @"frame")];
    [s appendFormat:@"  interfaceOrientation = %@\n", MFKV(st, @"interfaceOrientation")];
    [s appendFormat:@"  scene.contentState   = %@\n", MFKV(scene, @"contentState")];
    [s appendFormat:@"  scene.isActive       = %@\n", MFKV(scene, @"isActive")];
    id lm = MFMsg(scene, NSSelectorFromString(@"layerManager"));
    [s appendFormat:@"  scene.layerManager   = %@ layers=%ld\n",
     lm ? NSStringFromClass([lm class]) : @"nil", (long)MFKVCount(lm, @"layers")];

    // ---- 0.10.0 新增：尺寸真源 + "去激活管理器"持有者定位 ----
    [s appendFormat:@"\n==== 0.10.0 尺寸真源 / 去激活管理器定位 ====\n"];
    [s appendFormat:@"  gMFDesiredContentSize = %.0fx%.0f (valid=%d)  ← scene.frame 的唯一真源（panel.contentArea）\n",
     gMFDesiredContentSize.width, gMFDesiredContentSize.height, (int)gMFDesiredContentValid];
    {
        BOOL hf = NO;
        CGRect f = MFRectProp(st, @"frame", &hf);
        [s appendFormat:@"  scene.settings.frame  = %@（读到 frame 属性=%d）\n",
         hf ? NSStringFromCGRect(f) : @"-", (int)hf];
    }
    [s appendFormat:@"  目标 App processState  = %@\n", MFMsg(gMFKeepAliveApp, NSSelectorFromString(@"processState"))];
    MFReportScanDeactManager(s, @"UIApplication.shared", [UIApplication sharedApplication]);
    MFReportScanDeactManager(s, @"windowScene", MFMainWindowScene());
    MFReportScanDeactManager(s, @"scene", scene);
    MFReportScanDeactManager(s, @"sceneHandle", handle);
    MFReportScanDeactManager(s, @"scene.uiPresentationManager", MFMsg(scene, NSSelectorFromString(@"uiPresentationManager")));

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

    [s appendFormat:@"\n==== 我们持有的对象（静态 strong）====\npm=%@\npresenter=%@\nhostVC=%@\nownScene=%@\n"
                       @"presenter.identifier=%@\npresenter 挂在的 scene=%@\nownScene 属于=%@\nownScene identity=%@\n",
     gMFPM ? NSStringFromClass([gMFPM class]) : @"nil",
     gMFPresenter ? NSStringFromClass([gMFPresenter class]) : @"nil",
     gMFHostVC ? NSStringFromClass([gMFHostVC class]) : @"nil",
     gMFOwnScene ? NSStringFromClass([gMFOwnScene class]) : @"nil",
     gMFPresenterIdentifier ?: @"nil",
     gMFPresenterScene ? NSStringFromClass([gMFPresenterScene class]) : @"nil",
     gMFOwnSceneBundleID ?: @"nil",
     gMFOwnSceneIdentity ?: @"nil"];

    // ---- 0.9.1 新增：这些属性/设置器到底"存不存在" ----
    // 归档(9) 的教训：`fg` 恒 0 被我们当成"被 SpringBoard 改回来了"，足足追了两轮。
    //
    // 【0.13.0 严重提醒】这张表探的是 `scene.settings` —— 一个**不可变**对象。
    // 所以 `setIdleModeEnabled:` / `setDeactivationReasons:` 在这里报 `-`，
    // 而它们在 `UIMutableApplicationSceneSettings`（也就是 `updateSettingsWithBlock:`
    // 的 block 参数，**我们真正写入的那个对象**）上明明存在（见类 dump）。
    // 归档(13) 就是被这张表的 `foreground=-` 误导过：`foreground` 这个 **getter**
    // 确实不在 settings 上，但 `setForeground:` 这个 **setter** 在（下面这行就是证据）。
    // ⇒ 结论：**这张表只用于"读得到什么"，判断"写不写得进去"必须问 block 参数**
    //   （运行时一次性打的 `★ 可变 settings … setter 实况` 那一行才是答案）。
    [s appendFormat:@"\n==== 属性/设置器存在性矩阵（YES=本机有；settings=在【不可变】settings 对象上，scene=在 FBScene 上）====\n"];
    id stx = MFMsg(scene, NSSelectorFromString(@"settings"));
    const char *ssels[] = {
        "foreground", "setForeground:", "level", "setLevel:", "frame", "setFrame:",
        "idleModeEnabled", "setIdleModeEnabled:", "deactivationReasons", "setDeactivationReasons:",
        "interfaceOrientation", "setInterfaceOrientation:",
        "interfaceOrientationMode", "setInterfaceOrientationMode:",
        "displayConfiguration", "setDisplayConfiguration:",
        "canShowAlerts", "setCanShowAlerts:", "statusBarDisabled", "setStatusBarDisabled:",
        "updateSettingsWithBlock:"
    };
    for (unsigned k = 0; k < sizeof(ssels) / sizeof(ssels[0]); k++) {
        SEL sl = NSSelectorFromString([NSString stringWithUTF8String:ssels[k]]);
        [s appendFormat:@"   %-32s settings=%-4@ scene=%-4@\n", ssels[k],
         (stx != nil && [stx respondsToSelector:sl]) ? @"YES" : @"-",
         [scene respondsToSelector:sl] ? @"YES" : @"-"];
    }

    // ---- 0.9.1 新增：谁持有 deactivation manager ----
    // 下一版的目标是"用 assertion 让目标 scene 永不被 SpringBoard 去激活"
    // （那才是"闪屏"的彻底解法：现在只能事后拉回，所以必然闪一下）。
    // 拿 assertion 的前提是先拿到 UIApplicationSceneDeactivationManager 的实例，
    // 所以这里沿继承链把 UIApplication 的 ivar 全列出来（纯读元数据），一次定位持有者。
    id app = MFMsg(objc_getClass("UIApplication"), NSSelectorFromString(@"sharedApplication"));
    if (app != nil) {
        [s appendFormat:@"\n==== UIApplication.sharedApplication 的 ivar（找 *Deact* / *Assert*）====\n"];
        Class c = object_getClass(app);
        for (int up = 0; c != Nil && up < 4; up++, c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Ivar *ivs = class_copyIvarList(c, &n);
            [s appendFormat:@"   -- %@（%u 个）\n", NSStringFromClass(c), n];
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = ivar_getName(ivs[i]);
                const char *tp = ivar_getTypeEncoding(ivs[i]);
                [s appendFormat:@"      %-42s %s\n", nm ? nm : "?", tp ? tp : "?"];
            }
            if (ivs != NULL) free(ivs);
        }
        // KVC 直取（找不到 key 只会抛异常，@try 挡住；**不 acquire**，无副作用）
        const char *keys[] = { "_sceneDeactivationManager", "deactivationManager",
                               "sceneDeactivationManager", "_deactivationManager" };
        for (unsigned k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
            id got = nil;
            @try {
                got = ((id (*)(id, SEL, id))objc_msgSend)(app, NSSelectorFromString(@"valueForKey:"),
                                                          [NSString stringWithUTF8String:keys[k]]);
            } @catch (NSException *e) { got = nil; }
            [s appendFormat:@"   KVC %-28s -> %s\n", keys[k],
             got ? class_getName(object_getClass(got)) : "nil"];
        }
    }

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
/// 【0.8.0】浮窗被拖拽缩放后，把 scene 的渲染尺寸同步成新的内容区尺寸（保持画面比例）
- (void)syncContentGeometry;
- (void)refreshAppList;
- (void)toggleAppList;      // 【0.23.0】手势唤出：选择器 ↔ 当前承载画面
- (void)openOrHostBundleID:(NSString *)bundleID;   // 【0.24.0】未运行先启动再承载
@end

@interface MFFloatPanel : UIViewController
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *titleBar;
@property (nonatomic, strong) UIView *contentArea;
@property (nonatomic, strong) UIView *statusBar;      // 【0.25.0】已隐藏（保留对象兼容旧引用）
@property (nonatomic, strong) NSArray<UIView *> *edgeViews;    // 【0.25.0】外沿 4 边热区（移动 + 双击选择器）
@property (nonatomic, strong) NSArray<UIView *> *cornerViews;  // 【0.25.0】外沿 4 角热区（锚角缩放）
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIViewController *contentVC;
@property (nonatomic, assign) BOOL pickerVisible;     // 【0.23.0】内容区当前是否显示应用选择器
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

    // 【0.23.0】Stheno 风：窗口本体完全无框 —— 透明背景、无描边，看到的只有内容圆角。
    // 标题栏/状态条退化为"透明边缘条"：不可见但可触摸（移动手柄 + 选择器手势区）。
    self.view.backgroundColor = [UIColor clearColor];
    self.view.layer.cornerRadius = 16.0;
    self.view.layer.masksToBounds = YES;

    // 【0.25.0】Stheno 式外沿热区（一比一复刻 cardTrim/EdgeBarControlView 模型）：
    //      窗口 = 内容区 + 四周 18pt 透明外沿（trim）。手势全部挂在外沿上：
    //      四角 = 缩放（锚定对角）、四边 = 移动、外沿双击 = 唤出应用列表；
    //      中间内容区完全不挡，App 自行接收触摸。
    const CGFloat pad  = 18.0;                 // 外沿宽度（Stheno edgeWidth 同类参数）
    const CGFloat barH = 36.0;
    CGRect bounds = self.view.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;

    // ---- 内容区：内缩外沿宽度（contentArea.bounds 仍是 scene.frame 尺寸真源）----
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(pad, pad, w - 2 * pad, h - 2 * pad)];
    content.backgroundColor = [UIColor clearColor];
    content.clipsToBounds = YES;
    content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:content];
    self.contentArea = content;
    // 【0.26.0 归档28 修复】承载后窗口没有圆角 —— 外沿 pad 出来后内容区四角
    // 不在窗口圆角处，必须给内容区自己加圆角裁切。
    content.layer.cornerRadius = 16.0;
    content.layer.masksToBounds = YES;

    // ---- ↻ / ✕ 按钮：浮在内容区右上角内侧（缩小 + 低透明度，不占外沿手势区）----
    // 【0.26.0 归档28 修复】容器绝不能 userInteractionEnabled=NO —— 那会把整个子树
    // 的触摸全部掐死（按钮点不到的根因）。透明 UIView 默认就放行触摸，保持默认即可。
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(w - 2 * pad - 76, pad + 4, 70, 28)];
    bar.backgroundColor = [UIColor clearColor];
    bar.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:bar];
    self.titleBar = bar;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 96, barH)];
    title.hidden = YES;
    [bar addSubview:title];
    self.titleLabel = title;

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeCustom];
    reload.frame = CGRectMake(0, 0, 32, 28);
    [reload setTitle:@"↻" forState:UIControlStateNormal];
    [reload setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.40] forState:UIControlStateNormal];
    reload.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    reload.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    reload.userInteractionEnabled = YES;
    [reload addTarget:self action:@selector(onReloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:reload];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(36, 0, 32, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.40] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    close.userInteractionEnabled = YES;
    [close addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    // ---- 底部状态条：保留对象（statusLabel 有日志/状态用途）但隐藏、不挡触摸 ----
    UIView *statusBar = [[UIView alloc] initWithFrame:CGRectZero];
    statusBar.hidden = YES;
    statusBar.userInteractionEnabled = NO;
    [self.view addSubview:statusBar];
    self.statusBar = statusBar;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.hidden = YES;
    [statusBar addSubview:status];
    self.statusLabel = status;

    // ---- 外沿热区：4 边（移动 + 双击选择器）----
    NSMutableArray *edges = [NSMutableArray array];
    void (^mkEdge)(CGRect, UIViewAutoresizing, NSInteger) = ^(CGRect f, UIViewAutoresizing m, NSInteger tag) {
        UIView *e = [[UIView alloc] initWithFrame:f];
        e.backgroundColor = [UIColor clearColor];
        e.autoresizingMask = m;
        e.tag = tag;
        [e addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)]];
        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:[MFFloatManager shared] action:@selector(toggleAppList)];
        dbl.numberOfTapsRequired = 2;
        [e addGestureRecognizer:dbl];
        [self.view addSubview:e];
        [edges addObject:e];
    };
    mkEdge(CGRectMake(pad, 0, w - 2 * pad, pad),
           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin, 1);   // 上
    mkEdge(CGRectMake(pad, h - pad, w - 2 * pad, pad),
           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin, 2);     // 下
    mkEdge(CGRectMake(0, pad, pad, h - 2 * pad),
           UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleRightMargin, 3);  // 左
    mkEdge(CGRectMake(w - pad, pad, pad, h - 2 * pad),
           UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin, 4);   // 右

    // ---- 外沿热区：4 角（缩放，Stheno finalCardCorner 锚角式）----
    NSMutableArray *corners = [NSMutableArray array];
    void (^mkCorner)(CGRect, UIViewAutoresizing, NSInteger) = ^(CGRect f, UIViewAutoresizing m, NSInteger tag) {
        UIView *c = [[UIView alloc] initWithFrame:f];
        c.backgroundColor = [UIColor clearColor];
        c.autoresizingMask = m;
        c.tag = tag;                            // 11=左上 12=右上 13=左下 14=右下
        [c addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onResize:)]];
        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:[MFFloatManager shared] action:@selector(toggleAppList)];
        dbl.numberOfTapsRequired = 2;
        [c addGestureRecognizer:dbl];
        [self.view addSubview:c];
        [corners addObject:c];
    };
    mkCorner(CGRectMake(0, 0, pad, pad),
             0, 11);                                                                        // 左上
    mkCorner(CGRectMake(w - pad, 0, pad, pad),
             UIViewAutoresizingFlexibleLeftMargin, 12);                                     // 右上
    mkCorner(CGRectMake(0, h - pad, pad, pad),
             UIViewAutoresizingFlexibleTopMargin, 13);                                      // 左下
    mkCorner(CGRectMake(w - pad, h - pad, pad, pad),
             UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin, 14); // 右下

    self.edgeViews   = edges;
    self.cornerViews = corners;

    MFLog(@"[ui] 面板就绪 %.0fx%.0f（0.25.0 Stheno 外沿热区 pad=%.0f：4边移动/4角缩放/双击唤出）",
         w, h, pad);
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
    // 【0.9.0】浮窗都关了就别再守护了 —— 守护是"为了让已经挂上去的画面不掉"，
    // 画面都没了还一直改别人的 scene settings 属于越界。
    MFStopSceneKeepAlive(@"浮窗被关闭");
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

// 【0.20.0】resize 误触回滚状态（归档 21 钉死的问题）：
// 上滑/下滑回桌面的手指划过右下角 ◢，pan 手势把它当成拖动缩放 —— 浮窗被凭空
// 拉大/缩小，松手后 syncContentGeometry 把错误尺寸写进 scene.frame（日志实测
// 内容区在 448→605→367→432→340 之间乱跳），掉层恢复期间 App 常是挂起定格状态，
// 挂起的最后帧按放大后的尺寸显示 = 用户看到的"画面定格成一张放大的图片"。
// 【0.22.0】缩放改为"等比例"：手势起点锁定宽高比，平移沿对角线方向投影出
// 统一缩放量 —— 右下角向左上拖=缩小、向右下拖=放大，内容永不变形（用户需求）。
static CGRect     gMFResizeStartFrame = CGRectZero;
static NSDate    *gMFResizeStartDate  = nil;
static CGFloat    gMFResizeStartAR     = 0.0;   // 起点宽高比 w/h
static CGFloat    gMFResizeCurW        = 0.0;   // 【0.23.1】增量式当前宽
static NSInteger  gMFResizeTick        = 0;     // 【0.23.1】Changed 节流日志计数
static CGPoint    gMFResizeAnchor      = CGPointZero;  // 【0.25.0】锚角（拖动角的对角，固定不动）
static NSInteger  gMFResizeCorner      = 0;            // 【0.25.0】11=左上 12=右上 13=左下 14=右下
static NSDate    *gMFResizeLastSync    = nil;          // 【0.26.0】缩放中 scene.frame 节流同步时刻

- (void)onResize:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.hostWindow;
    if (win == nil) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        gMFResizeStartFrame = win.frame;
        gMFResizeStartDate  = [NSDate date];
        gMFResizeCurW       = win.frame.size.width;
        gMFResizeTick       = 0;
        if (gMFResizeStartFrame.size.height > 0)
            gMFResizeStartAR = gMFResizeStartFrame.size.width / gMFResizeStartFrame.size.height;
        if (gMFResizeStartAR < 0.2 || gMFResizeStartAR > 5.0) gMFResizeStartAR = 0.62;  // 兜底
        // 【0.25.0】Stheno finalCardCorner：锚角 = 被拖角的对角，缩放期间固定不动
        gMFResizeCorner = g.view.tag;
        if (gMFResizeCorner < 11 || gMFResizeCorner > 14) gMFResizeCorner = 14;  // 兜底=右下
        CGRect sf = gMFResizeStartFrame;
        BOOL right = (gMFResizeCorner == 12 || gMFResizeCorner == 14);
        BOOL down  = (gMFResizeCorner == 13 || gMFResizeCorner == 14);
        gMFResizeAnchor = CGPointMake(right ? sf.origin.x : CGRectGetMaxX(sf),
                                      down  ? sf.origin.y : CGRectGetMaxY(sf));
        // 【0.23.0】手势期间 + 结束后 1.5s：守护几何纠正全部让路（修复归档24"缩放失效"）
        gMFUserGestureUntil = [NSDate timeIntervalSinceReferenceDate] + 10.0;
        MFLog(@"[ui] resize 开始 corner=%ld anchor=(%.0f,%.0f) frame=%@ AR=%.3f",
             (long)gMFResizeCorner, gMFResizeAnchor.x, gMFResizeAnchor.y,
             NSStringFromCGRect(win.frame), gMFResizeStartAR);
    }

    // 【0.20.0】误触判定：手势开始后 0.8s 内累计变化"几乎纯竖直且幅度大"
    //（|dy|>60pt 且 |dy|>3|dx|）—— 正经拖角是斜向/横向的，快速上下滑才是这种形状。
    // 命中 => 立即回滚 win.frame 并废掉手势；**不调 syncContentGeometry**，
    // scene.frame 从头到尾不被污染（Changed 期间本来也不写 scene.frame）。
    if (gMFResizeStartDate != nil && gMFResizeStartFrame.size.width > 0) {
        NSTimeInterval el = -[gMFResizeStartDate timeIntervalSinceNow];
        CGFloat ddx = win.frame.size.width  - gMFResizeStartFrame.size.width;
        CGFloat ddy = win.frame.size.height - gMFResizeStartFrame.size.height;
        if (el < 0.8 && fabs(ddy) > 60.0 && fabs(ddy) > 3.0 * fabs(ddx)) {
            win.frame = gMFResizeStartFrame;
            gMFResizeStartDate = nil;
            gMFUserGestureUntil = [NSDate timeIntervalSinceReferenceDate] + 1.5;
            [g setEnabled:NO];   // 废掉本次手势，后续 Changed/Ended 不再来
            dispatch_async(dispatch_get_main_queue(), ^{ [g setEnabled:YES]; });
            MFLogS(@"[ui] resize 手势判定为划过误触 -> 已回滚浮窗尺寸（不同步 scene.frame）");
            return;
        }
    }

    // 【0.25.0】四角等比缩放（增量式 + 锚角推算 origin）：
    // 尺寸仍走 0.23.1 实证可用的增量累加（勿回退"起点锚定绝对尺寸"）；
    // origin 不再固定，而是从锚角反推 —— 拖哪个角，对角就钉在原地（Stheno 行为）。
    CGPoint t = [g translationInView:win];
    CGFloat sw = gMFResizeStartFrame.size.width, sh = gMFResizeStartFrame.size.height;
    CGFloat diag = sqrt(sw * sw + sh * sh);
    // 方向符号：拖右/下侧的角向外 = 放大；拖左/上侧的角向外 = 平移为负
    CGFloat sx = (gMFResizeCorner == 12 || gMFResizeCorner == 14) ? 1.0 : -1.0;
    CGFloat sy = (gMFResizeCorner == 13 || gMFResizeCorner == 14) ? 1.0 : -1.0;
    CGFloat dW = (t.x * sx * sw + t.y * sy * sh) / diag;   // 对角线方向投影（增量）

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat newW = gMFResizeCurW + dW;
    newW = MAX(150.0, newW);
    newW = MIN(newW, screen.size.width  - 2.0 * 18.0);
    CGFloat newH = newW / gMFResizeStartAR;           // ★ 锁比例：高度由宽度唯一决定
    newH = MIN(newH, screen.size.height - 2.0 * 18.0);
    if (newH < 150.0) { newH = 150.0; newW = newH * gMFResizeStartAR; }
    gMFResizeCurW = newW;

    // origin 由锚角反推（对角钉死）
    CGRect nf = gMFResizeStartFrame;
    switch (gMFResizeCorner) {
        case 11: nf = CGRectMake(gMFResizeAnchor.x - newW, gMFResizeAnchor.y - newH, newW, newH); break; // 左上
        case 12: nf = CGRectMake(gMFResizeStartFrame.origin.x, gMFResizeAnchor.y - newH, newW, newH); break; // 右上
        case 13: nf = CGRectMake(gMFResizeAnchor.x - newW, gMFResizeStartFrame.origin.y, newW, newH); break; // 左下
        default: nf = CGRectMake(gMFResizeStartFrame.origin.x, gMFResizeStartFrame.origin.y, newW, newH); break; // 右下
    }
    win.frame = nf;
    [g setTranslation:CGPointZero inView:win];

    // 【0.23.1】Changed 节流日志（每 4 拍 1 条）：下轮日志直接区分"没 Changed"还是
    // "Changed 但被写回"——归档25 的两种假设只有它能裁决。
    gMFResizeTick++;
    if (g.state == UIGestureRecognizerStateChanged && (gMFResizeTick % 4) == 1) {
        MFLog(@"[ui] resize 变化 #%ld corner=%ld t=(%.1f,%.1f) dW=%.1f -> W=%.0f H=%.0f origin=(%.0f,%.0f)",
             (long)gMFResizeTick, (long)gMFResizeCorner, t.x, t.y, dW, newW, newH,
             nf.origin.x, nf.origin.y);
    }

    // 【0.26.0 归档28 修复】缩放中出现"静态图片"、松手才回实时画面 ——
    // 根因：缩放中 win.frame 每拍变，但 scene.frame 只在 Ended 同步一次；
    // 掉层窗口期间垫底快照显示定格帧（且随窗口一起被拉伸）。
    // 修法：Changed 期间按 250ms 节流同步 scene.frame，让实时渲染跟上手指。
    // （updateSettings 每发=一帧重提交，但缩放时画面本来就在动，可接受。）
    if (g.state == UIGestureRecognizerStateChanged) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (gMFResizeLastSync == nil ||
            now - [gMFResizeLastSync timeIntervalSinceReferenceDate] > 0.25) {
            gMFResizeLastSync = [NSDate date];
            [[MFFloatManager shared] syncContentGeometry];
            MFLogS(@"[ui] resize 中 -> 节流同步 scene.frame（实时画面跟手）");
        }
    }

    // 【0.8.0】松手后把 scene 的渲染尺寸一起改掉 —— 否则浮窗变了形，里面还是老的宽高比，
    // 就是"画面比例不对"的另一个来源。拖动过程中不调，避免高频 updateSettingsWithBlock。
    if (g.state == UIGestureRecognizerStateEnded) {
        gMFResizeStartDate = nil;
        gMFResizeLastSync = nil;
        gMFUserGestureUntil = [NSDate timeIntervalSinceReferenceDate] + 1.5;
        MFLog(@"[ui] resize 结束 frame=%@ -> 同步 scene.frame", NSStringFromCGRect(win.frame));
        [[MFFloatManager shared] syncContentGeometry];
    } else if (g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        gMFResizeStartDate = nil;
        gMFResizeLastSync = nil;
        gMFUserGestureUntil = [NSDate timeIntervalSinceReferenceDate] + 1.5;
    }
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
    self.pickerVisible = NO;                  // 【0.23.0】内容区不再是选择器
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
    self.pickerVisible = NO;                  // 【0.23.0】内容区不再是选择器
    if (view == nil) return;

    view.frame = self.contentArea.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentArea addSubview:view];
    MFLog(@"[ui] 已挂载承载视图(view) %@ frame=%@",
         NSStringFromClass([view class]), NSStringFromCGRect(view.frame));
}

- (void)showMessage:(NSString *)message detail:(NSString *)detail {
    [self attachContentViewController:nil];
    // 【0.9.0】内容区要被提示信息顶掉了 => 不再守护那个已经不在显示的 scene
    MFStopSceneKeepAlive(@"内容区换成提示信息");
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
    self.pickerVisible = YES;                 // 【0.23.0】内容区当前是选择器
    // 【0.9.0】点 ↻ 拉列表 = 用户要重新选 App，旧画面已经不在显示 => 停守护
    MFStopSceneKeepAlive(@"拉取应用列表");
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
    [[MFFloatManager shared] openOrHostBundleID:bid];
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
    // 【0.25.0】w/h 是"内容区"目标尺寸；窗口额外外扩一圈 18pt 外沿热区（Stheno cardTrim）
    const CGFloat kTrimPad = 18.0;
    CGFloat w = MAX(230.0, screen.size.width * 0.62);
    CGFloat h = MIN(screen.size.height * 0.65, w * 1.48);
    w += 2 * kTrimPad;  h += 2 * kTrimPad;
    // 【0.22.0】按用户需求：浮窗默认打开在屏幕中心（原为右上角停靠）
    CGRect frame = CGRectMake((screen.size.width  - w) / 2.0,
                              (screen.size.height - h) / 2.0, w, h);

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

    // ---- 【0.25.0】双击唤出手势已在 viewDidLoad 挂到外沿热区（4 边 + 4 角）。
    //      pickerGesture=0 时这里移除它们（尊重关闭语义）；pg=2（长按）暂同 1。----
    {
        NSInteger pg = MFConfigInt(self.config, @"pickerGesture", 1);
        if (pg == 0) {
            for (UIView *v in self.panel.edgeViews)
                for (UIGestureRecognizer *gr in v.gestureRecognizers)
                    if ([gr isKindOfClass:[UITapGestureRecognizer class]]) [v removeGestureRecognizer:gr];
            for (UIView *v in self.panel.cornerViews)
                for (UIGestureRecognizer *gr in v.gestureRecognizers)
                    if ([gr isKindOfClass:[UITapGestureRecognizer class]]) [v removeGestureRecognizer:gr];
            MFLogS(@"[ui] 选择器手势已关闭（pickerGesture=0）");
        } else {
            MFLog(@"[ui] 选择器手势已挂（外沿热区双击，pickerGesture=%ld）", (long)pg);
        }
    }

    // ---- 【0.23.0】默认打开：defaultBundleID 非空 => 浮窗出现即自动承载 ----
    {
        NSString *defApp = MFConfigString(self.config, @"defaultBundleID");
        BOOL hostEnabled = MFConfigBool(self.config, @"hostEnabled", NO);
        if (defApp.length > 0 && hostEnabled) {
            MFLog(@"[ui] defaultBundleID=%@ -> 0.6s 后自动承载（默认打开）", defApp);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[MFFloatManager shared] openOrHostBundleID:defApp];
            });
        }
    }

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
    MFLog(@"[cfg] 本次生效配置：hostRoute=%ld forceForeground=%d resizesHosted=%d hostSceneFrame=%d allowRouteB=%d hostStep=%ld",
          (long)MFConfigInt(self.config, @"hostRoute", 3),
          (int)MFConfigBool(self.config, @"forceForeground", YES),
          (int)MFConfigBool(self.config, @"resizesHosted", YES),
          (int)MFConfigBool(self.config, @"hostSceneFrame", YES),
          (int)MFConfigBool(self.config, @"allowRouteB", NO),
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
    //
    // 【0.9.0】开始新一轮承载前，先把上一轮的 scene 守护停掉 ——
    // 否则守护定时器会继续摸一个马上要被换掉的 scene（换目标时 presenter 会被销毁，
    // 那种"半死"状态下再 updateSettings 只会制造噪声，甚至误判）。
    MFStopSceneKeepAlive(@"开始新一轮承载");
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
    // 【0.9.0】记下来给 P6 / keepalive 打印 processState 用：
    // 它是区分"App 进程被系统挂起"与"只是 scene 被去激活"的唯一直接证据。
    gMFKeepAliveApp = app;
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

    // ---------- 0.8.0：换承载目标时先把手里的东西收干净 ----------
    // 若手里还握着**别的 App** 的 presenter，必须先销毁：否则新的那次 createPresenter 会抛
    //   "Cannot create a presenter with this identifier as it's already in use."
    // 而旧代码一失败就静默退回 Route B（已知纯黑）=> 用户看到"再点一次画面就黑了"。
    NSString *targetViewID = [NSString stringWithFormat:@"MultiFloat-%@", bundleID];
    if (gMFPresenter != nil && ![gMFPresenterIdentifier isEqualToString:targetViewID]) {
        MFLog(@"[host] 承载目标变了（%@ -> %@），先销毁旧 presenter",
              gMFPresenterIdentifier ?: @"nil", targetViewID);
        MFTeardownPresenter();
    }

    // ---------- P0：让 scene 变成"可渲染"（只有 route 3 需要）----------
    // 【0.11.0】关键顺序：**先登记内容区目标尺寸，再做 P0**。
    // 归档(11) 的挂载序列是两次 settings 写：P0 写一次（那时还没登记目标尺寸 ⇒ 不含 frame）
    // → 紧接着 MFSyncSceneGeometry 再写一次补 frame。两次写 = 两次 SpringBoard 全量重算。
    // 现在 P0 之前就登记好，P0 的 block 里已经带了 setFrame:（frame 依然是 block 内最后一项），
    // 随后的 MFSyncSceneGeometry 会被 gMFFrameMemo* 拦住不再重复写。一次写搞定。
    if (route == 3 || route == 4) {
        MFSetDesiredContentSize(panel.contentArea.bounds.size);
    }
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

    // ---------- Route 4：拿到属于我们的 scene（0.8.0：复用优先，绝不建第二个）----------
    if (route == 4) {
        NSString *ownID = [NSString stringWithFormat:@"%@-multifloat", bundleID];
        MFLogS(@"[host] Route 4 是危险实验路线（0.7.0 曾因重复 identity 崩 SpringBoard 进安全模式）");
        MFLogS(@"[host] 本进程每个 App 只允许新建 1 次自有 scene，其余一律复用/接管");
        id ownScene = MFAcquireOwnSceneForApp(bundleID, ownID, panel.contentArea.bounds);
        if (ownScene != nil) {
            targetScene = ownScene;
            MFLogS(@"[host] Route 4 拿到自有 scene，改用它作为承载目标");
        } else {
            MFLogS(@"[host] Route 4 拿不到自有 scene -> 退回 route 3（接管已存在的 scene）");
            route = 3;
        }
    }

    // ---------- 0.8.0：把渲染尺寸对齐成浮窗内容区（画面比例正确的关键）----------
    // 【0.7.0 把这一步放在"可选"位置是错的】
    // presentationView 的自然尺寸 = scene.settings.frame。真实 App 的 scene 是整屏 430x932
    // （宽高比 0.461），而浮窗内容区是 267x336.6（宽高比 0.793）—— 塞进去必然拉伸变形。
    // 这正是归档(7) 里「route 3 出了画面但比例不对」的原因。
    // route 4 的 scene 在**创建**时就用内容区尺寸，这里再同步一次是为了"复用旧 scene + 窗口被改过尺寸"
    // 的情况（复用时 frame 可能已经过期）。
    if ((route == 3 || route == 4) && MFConfigBool(self.config, @"hostSceneFrame", YES)) {
        MFSyncSceneGeometry(targetScene, nil, panel.contentArea.bounds);
    } else if (route == 3 || route == 4) {
        MFLogS(@"[pres] hostSceneFrame=false -> 不改 scene.frame（画面比例可能不对，仅用于对照实验）");
    }

    if (route == 3 || route == 4) {
        NSString *pmSource = @"?";
        contentView = MFPresentScene(targetScene, targetViewID, self.config, &pmSource);
        MFLog(@"[host] Route %ld 结果 -> %@（manager 来源：%@）",
              (long)route, contentView ? @"拿到呈现视图" : @"失败", pmSource);
    } else if (route == 2) {
        contentView = MFTryPresenterRoute(scene, self.config);
        MFLog(@"[host] Route 2(旧 A2) -> %@", contentView ? @"拿到呈现视图" : @"失败");
    }

    // ---------- 兜底 Route B：0.8.0 起默认**不做** ----------
    // SBDeviceApplicationSceneViewController 是已被两次真机验证的**纯黑**宿主，
    // 把它挂上去只会把"失败"伪装成"成功"，让人以为画面在渲染。
    // 需要做 A/B 对照时把配置 allowRouteB 设成 <true/>。
    if (contentView == nil && MFConfigBool(self.config, @"allowRouteB", NO)) {
        hostVC = MFMsg(handle, NSSelectorFromString(@"newSceneViewController"));
        MFLog(@"[host] 兜底 Route B newSceneViewController=%@（allowRouteB=true 才走）",
              hostVC ? NSStringFromClass([hostVC class]) : @"nil");
        gMFHostVC = hostVC;   // 静态 strong 持有，否则出作用域就释放 -> 黑屏
    } else if (contentView == nil) {
        MFLogS(@"[host] presenter 路线失败，且 allowRouteB=false -> 不挂那个已知纯黑的宿主 VC");
    }
    MFWritePresenterReport(bundleID, scene, handle, hostVC);
    MFStepOk(kMFStepVC);

    if (contentView == nil && hostVC == nil) {
        [self fail:@"承载视图没拿到"
             detail:@"presenter 路线（route 3/4）没拿到可挂载的呈现视图。\n"
                    @"（route 1 的 SpringBoard 宿主 VC 自 0.8.0 起默认不再兜底 —— "
                    @"它是已知的纯黑宿主，挂上去只会把失败伪装成成功。\n"
                    @"要做 A/B 对照请把配置 allowRouteB 设成 <true/>。）\n\n"
                    @"请看 /var/mobile/MF-presenter-report.txt —— 里面记录了每个类的方法表、"
                    @"scene.settings 的真实取值、以及 presenter 的 isHosting。"];
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
        // Route 3/4：resizesHostedContext 已在 P2 写进呈现上下文。
        // 0.8.0 补充：真正让比例正确的是"scene.frame = 内容区尺寸"（route 3 在上面已做，
        // route 4 建 scene 时就是内容区尺寸），resizesHostedContext 只负责让 App 跟着重新布局。
        id sy = MFMsg(gMFPresenter, NSSelectorFromString(@"scene"));
        id st = MFMsg(sy, NSSelectorFromString(@"settings"));
        MFLog(@"[host] Route %ld 几何确认：scene.frame=%@ resizesHostedContext=%@",
              (long)route, MFKV(st, @"frame"),
              MFKV(MFMsg(gMFPresenter, NSSelectorFromString(@"presentationContext")),
                   @"resizesHostedContext"));
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

    // 记住这一轮的目标 scene / 承载视图 / 内容区，供用户拖 ◢ 缩放时重新同步几何，
    // 也供守护发现"承载侧掉了"时把视图放回内容区（0.11.0）。
    gMFCurrentScene = targetScene;
    gMFCurrentContentView = contentView ?: MFMsg(hostVC, NSSelectorFromString(@"view"));
    gMFCurrentContentArea = panel.contentArea;

    // 【0.15.0 消闪】剥掉承载视图的自带黑底（配合 P3b 的未承载背景色=透明 +
    // 垫底快照：切换 App 掉图层的那 200~400ms 里，用户看到的是"画面定格"而不是黑）。
    // 【0.19.0 修复】attachContentView -> clearContentArea 会把 gMFPadView 一起
    // removeFromSuperview，而旧代码只清 image、视图对象还活着（superview=nil），
    // 导致 MFSnapshotPadUpdate 永不重建、MFSnapshotPadRaise 永远静默早退 ——
    // 归档(20)：换 App 后 15 次真黑零遮盖的根因。这里显式置 nil 强制作废重建。
    if (gMFPadView != nil) {
        [gMFPadView removeFromSuperview];
        gMFPadView = nil;
        gMFPadRaised = NO;
        gMFHealthyTicks = 0;
    }
    MFStripPresentationBlack();

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

    // ---------- 【0.9.0】S7 之前：启动 scene 守护 ----------
    // 归档(8) 的"切到设置就黑屏"就是在这里输掉的：此刻画面是好的（P6: foreground=1 layers=2），
    // 但用户一换前台 App，SpringBoard 就把这套 settings 重算回去，图层掉光 => 黑。
    // 守护定时器会持续把 foreground/idle/deactivationReasons 拉回可渲染态，并把变化记进日志。
    MFStartSceneKeepAlive(targetScene, app, bundleID, self.config);

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
        // 【0.8.0】顺便把几何再对齐一次 —— updateSettingsWithBlock: 是异步的，
        // 而 presenter 建 presentationView 时可能还没吃到新的 frame（日志里 P0 后 foreground
        // 仍是 0，要到 P6 才变 1，就是同一个异步窗口）。
        if (MFConfigBool(self.config, @"hostSceneFrame", YES)) {
            MFSyncSceneGeometry(gMFCurrentScene, gMFCurrentContentView, panel.contentArea.bounds);
        }
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

/// 【0.8.0】用户拖右下角 ◢ 缩放浮窗后，把 scene 的渲染尺寸一起改掉。
/// 不做的话浮窗变宽变矮，画面还是老的宽高比 —— 就是"比例不对"的另一个来源。
- (void)syncContentGeometry {
    if (gMFCurrentScene == nil) return;
    if (!MFConfigBool(self.config, @"hostSceneFrame", YES)) return;
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;
    MFLogS(@"[ui] 浮窗尺寸变化 -> 同步 scene.frame（保持画面比例）");
    MFSyncSceneGeometry(gMFCurrentScene, gMFCurrentContentView, panel.contentArea.bounds);
}

/// 【0.23.0】手势唤出：内容区在"应用选择器 ↔ 当前承载画面"之间切换。
/// - 当前是选择器且有承载画面 => 贴回承载画面并同步几何（恢复守护）；
/// - 其它情况（没有画面/不是选择器）=> 拉应用列表。
/// 注意：贴回画面走 attachContentView（与承载链路同一挂载点），守护随后按需重启
/// —— 这里不主动 MFStartSceneKeepAlive，交由几何同步后的常规路径；若 scene 已死，
/// 用户重选一次即可（选择器永远可用）。
- (void)toggleAppList {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleAppList]; });
        return;
    }
    MFFloatPanel *panel = self.panel;
    if (panel == nil) return;
    MFLog(@"[ui] 选择器手势触发（pickerVisible=%d hostedView=%@）",
         (int)panel.pickerVisible, gMFCurrentContentView ? NSStringFromClass([gMFCurrentContentView class]) : @"nil");
    if (panel.pickerVisible && gMFCurrentContentView != nil) {
        [panel attachContentView:gMFCurrentContentView];
        [self syncContentGeometry];
        MFLogS(@"[ui] 选择器关闭 -> 贴回承载画面");
    } else {
        [self refreshAppList];
    }
}

/// 【0.24.0】选择列表行 = "打开或承载"：
///   App 已在运行 -> 直接走承载链路；
///   App 未运行   -> 先用 FBSOpenApplicationService 启动（进程内 SpringBoard 标准通道，
///                   respondsToSelector + @try 兜底），2s 后 scene 出现再自动承载。
/// 用户需求："应用没在后台运行也要能从浮窗打开"。
- (void)openOrHostBundleID:(NSString *)bundleID {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self openOrHostBundleID:bundleID]; });
        return;
    }
    if (bundleID.length == 0) return;

    // 1) 是否已在运行？
    BOOL isRunning = NO;
    @try {
        id controller = MFClassSharedInstance(@"SBApplicationController");
        NSArray *running = MFIterate(MFMsg(controller, NSSelectorFromString(@"runningApplications")));
        for (id app in running) {
            NSString *bid = MFStr(app, NSSelectorFromString(@"bundleIdentifier"));
            if ([bid isEqualToString:bundleID]) { isRunning = YES; break; }
        }
    } @catch (NSException *e) { /* 查不到就按未运行处理 */ }

    if (isRunning) {
        MFLog(@"[ui] %@ 已在运行 -> 直接承载", bundleID);
        [self hostBundleID:bundleID];
        return;
    }

    // 2) 未运行 -> 启动 -> 等 scene 出现 -> 承载
    // 【0.26.0 归档28 修复】FBSOpenApplicationService 两条路都不通（+sharedInstance 不存在、
    // alloc/init 实例也没有 openApplicationWithBundleID...）。
    // 改用 FrontBoardAppLauncher（SB 注入版）与 Stheno 同款通道：
    //   [UIApplication launchApplicationWithIdentifier:suspended:]
    // 注意 suspended:NO（launcher 源码注释：suspended 启动的 App 不会出现在前台）。
    MFLogS(@"[ui] 目标未运行 -> 先启动（UIApplication launchApplicationWithIdentifier:）-> 2s 后自动承载");
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            SEL launchSel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
            if (app == nil || ![app respondsToSelector:launchSel]) {
                MFLogS(@"[host] !! UIApplication.launchApplicationWithIdentifier: 通道不可用 -> 请先手动打开该 App");
                [self.panel showMessage:@"无法自动启动该 App"
                                 detail:@"请手动打开一次目标 App，再双击边缘条重新选择。"];
                return;
            }
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, launchSel, bundleID, NO);
            MFLog(@"[ui] 启动 %@ 已发起（suspended=NO）", bundleID);
        } @catch (NSException *e) {
            MFLog(@"[host] !! 启动异常：%@", e);
            [self.panel showMessage:@"自动启动失败" detail:[NSString stringWithFormat:@"%@", e]];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MFLog(@"[ui] 启动等待结束 -> 承载 %@", bundleID);
            [self hostBundleID:bundleID];
        });
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

    // 【0.24.0】用户需求："应用没在后台运行也要能选" —— 列表 = 全部已安装 App，
    // 运行中的加 "● " 前缀并排在最前；未运行的 "○ "，点它 = 先启动再承载。
    NSMutableSet *runningIDs = [NSMutableSet set];
    NSMutableArray *runningItems = [NSMutableArray array];
    for (id app in running) {
        NSString *bid = MFStr(app, NSSelectorFromString(@"bundleIdentifier"));
        if (bid == nil || [bid hasPrefix:@"com.apple.springboard"]) continue;
        NSString *name = MFStr(app, NSSelectorFromString(@"displayName"));
        [runningItems addObject:@[ [NSString stringWithFormat:@"● %@", name.length > 0 ? name : bid], bid ]];
        [runningIDs addObject:bid];
    }

    NSMutableArray *installedItems = [NSMutableArray array];
    @try {
        id ws = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("LSApplicationWorkspace"), NSSelectorFromString(@"defaultWorkspace"));
        NSArray *all = MFIterate(MFMsg(ws, NSSelectorFromString(@"allInstalledApplications")));
        MFLog(@"[ui] allInstalledApplications=%lu", (unsigned long)all.count);
        for (id proxy in all) {
            NSString *bid = MFStr(proxy, NSSelectorFromString(@"applicationIdentifier"));
            if (bid.length == 0 || [bid hasPrefix:@"com.apple.springboard"]) continue;
            if ([runningIDs containsObject:bid]) continue;    // 运行中的已在前面
            NSString *name = MFStr(proxy, NSSelectorFromString(@"localizedName"));
            if (name.length == 0) continue;                   // 无名系统件不进列表
            [installedItems addObject:@[ [NSString stringWithFormat:@"○ %@", name], bid ]];
        }
        [installedItems sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            return [a.firstObject localizedCaseInsensitiveCompare:b.firstObject];
        }];
    } @catch (NSException *e) {
        MFLog(@"[ui] !! LSApplicationWorkspace 不可用（%@）-> 只显示运行中列表", e);
    }

    NSMutableArray *items = [NSMutableArray arrayWithArray:runningItems];
    [items addObjectsFromArray:installedItems];
    MFLog(@"[ui] 应用列表：运行中 %lu + 已安装 %lu = %lu 项",
         (unsigned long)runningItems.count, (unsigned long)installedItems.count, (unsigned long)items.count);
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
    MFLog(@"[gate] %.1f 秒后显示浮窗（启动时不自动承载）", delay);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[MFFloatManager shared] startWithConfig:config];
    });
}
