# MultiFloat — 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
#
# 关键约定（勿改，除非设备环境变化）：
#   - ARCHS 只出 arm64e（设备为 A17，arm64e；不要再造 arm64 切片）
#   - THEOS_PACKAGE_SCHEME = roothide（文件按 roothide 布局，deb 架构为 iphoneos-arm64e）
#   - 需要 roothide/theos 才能识别 roothide scheme
#   - SDK 版本由 CI 经 MF_SDK_VERSION 传入
#
# 0.13.0 变更（修 0.10.0~0.12.0 的回归：切 App / 回桌面悬浮窗黑屏）：
#   - 用户原话（归档(13)）："切换应用时悬浮窗依旧黑屏。"（0.12.0 装上去之后）
#   - 归档(13) 日志 + 能力报告把根因钉死在**一个开关**上：
#       · 日志（Safari 轮，pid 21860）：`deact 0->32`（此刻 cs=2 layers=2 hosted=2，画面还好）
#         → 我们的"预防写"确实发出去了 → **同一秒** `cs 2->0`，下一拍 `layers 2->0`，此后永不恢复；
#       · 能力报告（最后挂载时写的）：
#         `scene.settings.foreground = 1`，但
#         `目标 App processState = taskState: Suspended; visibility: Background`
#         ⇒ **App 进程被挂起了**。被挂起的进程不可能出图，写多少 settings 都没用
#           （这就是"81 次全量写、layers 恒为 0"的原因）。
#   - 把 0.9.1 与 0.10.0+ 的写操作逐项对齐，只剩**一项**差别：
#       · 0.9.1：`hardDown` ⇒ `forceAll=YES` ⇒ `doFg = forceAll || … = **YES**`
#         ⇒ 每一拍都发 `setForeground:YES`；
#       · 0.10.0 起：`doFg = p0 || MFConfigBool(cfg, @"keepAliveForeground", NO)`，
#         而这一项默认 NO，依据是 0.9.x 留下的一句注释（"本机没有 foreground / setForeground:，
#         responds 守卫静默跳过"）⇒ **除了承载前的 P0，再没发过它**。
#   - 那句注释**是错的，错在问错了对象**：它只问了 `FBScene` 的 respondsToSelector（=NO）。
#     归档(13) 的存在性矩阵问的是 settings 对象，结果是
#       `foreground (getter) = -`、**`setForeground: (setter) = YES`**
#     —— 它是个"只写"的前台开关，正是 0.9.1 用来让 App 不被挂起的那一项。
#   - 0.13.0 的三条改法：
#     ① `keepAliveForeground` 默认 **true**（并把真黑/预防两条写路径都带上 setForeground:YES）；
#     ② 判据加入 `FBScene.foreground == 0`（KVC 读得到时才算）——"App 要进后台"的直接信号；
#     ③ 预防档改成**差量写**：先把能读到的当前值全读出来，只发**真的不一样**的那几项；
#        一项差量都没有就**连 updateSettingsWithBlock: 都不调**（零写入 = 零重排 = 零闪）。
#        再加"回读验证 + 连败 3 次停手"，防止 setForeground: 万一无效时变成"每拍写一次 = 每拍闪一次"。
#   - 三条写路径的定位（这一版的核心）：
#       0.9.1        = 预防 + 每拍全量写（不掉图层，但每次都闪）
#       0.10.0/0.11  = 不预防 + 全量写（不闪，但图层掉光 = 永久黑）
#       0.12.0       = 预防 + 只写 idle/deact（不闪，但按不住，照样黑）
#       0.13.0       = **预防 + 差量写（含 setForeground:）** ⇒ 一次事件只写一次
#   - 另加：预防档也做退避（连续 40 拍后间隔翻倍至 2 s 上限，**永不放弃**）；
#     能力报告新增 `FBScene.foreground` 与"可变 settings 上的 setter 实况"两行证据。
#   - 0.12.0 变更（历史，加回预防档）：
#   - 归档(12) 日志的因果链（两轮都复现）：
#       Filza 轮：挂载时就带着 deact=33，1 秒后 layers 2 -> 0，此后写了十几次全灭；
#       Safari 轮：按 Home 后 deact 变 32（此刻 cs=2 layers=2 hosted=2，画面还是好的），
#                 约 1 秒后 layers 2 -> 0；随后**连着 81 次全量写**，layers 始终为 0。
#     ⇒ 结论：**图层掉光 = 不可逆**。唯一有效的时机是"deact!=0 而图层还在"的那一秒。
#   - 为什么 0.9.1 不掉图层：它的 MFHealthIsBad 把 deact!=0 / cs!=2 / idle 也算作"要动手"，
#     所以那一秒里它已经把 deact 清回去了。0.10.0 把这一档降级成"软警告（永不动手）"，
#     0.11.0 沿用 —— 于是只能等图层掉完再救，必然黑。
#   - 为什么 0.9.1 会闪：它每一拍都写，而且写的是**全量**（含 setDisplayConfiguration:）；
#     归档(10) 已测到那一帧黑正是 setDisplayConfiguration: 把 frame 打回整屏 + 随后的 setFrame:。
#   - 0.12.0 = 把"预防档"加回来，但只写 idleModeEnabled + deactivationReasons 两个纯状态量，
#     **不写 level / displayConfiguration / frame** ⇒ 没有任何几何变化，不该产生可见的一帧黑。
#     目标：既不黑（像 0.9.1），也不闪（比 0.9.1 更好）。
#   - 预防档参数：keepAlivePrevent=true / keepAlivePreventMs=250（远小于约 1 秒的死线）/
#     keepAlivePreventHard=false（按不住时带上 setLevel:1 做 A/B）。
#   - 顺带修的三处：
#     ① 承载视图尺寸纠正从"差 0.5 点就掰"改成"容差 8% + 节流 500 ms"（>25% 时无视节流）。
#        0.11.0 在 keepAliveMs=50 时每秒掰 20 次，等于跟 presenter 自己的布局对拉，
#        日志被刷到 7 万字节 —— 也很可能就是 hosting 掉线的原因之一。
#     ② MFSyncSceneGeometry 加**重入保护**：MF-crash-attribution 指向 crashedStep=P7-geom，
#        而 MF-host-step.txt 里 P7-geom 在 S7-settle 之后连着出现 3 次；
#        `v.frame = bounds` 会触发布局，布局回调里再进本函数就是递归 ⇒ 会崩。
#     ③ 修一个误导性日志：dc= 打的是我自己格式化字符串的类名（__NSCFConstantString），
#        跟 scene.displayConfiguration 毫无关系；现在改打 **dc 的来源类名**，
#        这样才能看出 setDisplayConfiguration: 到底有没有被调用。
#   - 0.11.0 变更（历史，修 0.10.0 的回归）：
#   - 0.10.0 真机（归档(11)）：**这一版不稳定，悬浮窗大概率黑屏** —— 比 0.9.1 还差。
#     日志事实：承载成功后约 1 秒内 hostedLayers/layers 掉到 0，然后**再也没回来** ——
#       [keepalive] 真掉出（第 1/10/20/.../220 拍：layers=0 hosted=0 ...）
#     期间我们写了十几次 settings，**一次都没拉回来**（P6+3s / P6+20s 始终 layers=0）。
#   - 根因（把 0.9.1 与 0.10.0 的拉回动作并排看，一眼就出来）：
#       0.9.1 的 MFApplySceneFix 里有 doLevel => `setLevel:1` + `setDisplayConfiguration:`
#       0.10.0 把它们当成"重排元凶"删掉了，真黑时只剩"最小写"（idle + deact + frame）
#     ⇒ 判据是对的（只有 layers<=0 才算黑，这条保留），**但顺手把救命的那一笔删了**。
#       这两项恰恰是让 render server 重新给 scene 建图层的开关 —— 少了它们，真黑救不回来。
#     ⇒ 教训：减少副作用时，先确认"去掉的那一步不是必要条件"；
#       同一个动作健康时是副作用、故障时可能是唯一解 —— 要**按状态分档**，不是一刀砍掉。
#   - 第二处错误：0.10.0 的 keepAliveGiveUpAfter=30 ⇒ 真黑 6 秒后**永久停止重试**。
#     真黑是"必须救"的状态，对它踩刹车 = 主动选择永久黑屏。改成**退避**（间隔翻倍、有上限），永不停止。
#   - 第三处发现：**黑有两种，0.10.0 只认一种。**
#     归档(11) 的 Filza 轮：scene 自己完全健康（contentState=2 layers=2），但
#     presenter.isHosting=0、hostContainer=nil、presentationView 被改成整屏 430x932
#     —— 这是**承载侧**掉了，写 scene settings 完全打不中，只会白送一次全量重排。
#     ⇒ 现在先分类：layers>0 && hosted<=0 ⇒ 只修承载（re-activate + 视图放回内容区）；
#       layers<=0 ⇒ 才去写 settings。
#   - 修法汇总：
#     ① 真黑一律**全量写**（keepAliveHardWrite，默认 true；设 false 可复现 0.10.0 的黑屏）；
#     ② 用退避代替放弃（keepAliveGiveUpAfter 默认 0 = 永不放弃；新增 keepAliveBackoffAfter=50
#        / keepAliveBackoffMaxMs=2000）；
#     ③ 承载侧修复每拍可做（几乎零成本，不写 settings）；
#     ④ 挂载时把两次 settings 写合并成一次（P0 之前先登记目标尺寸，frame 进同一个 block，
#        并用"刚写过同一 frame"的备忘挡住随后的重复写）；
#     ⑤ 宽限期 1500 -> 600 ms；写入日志不再被 verbose 门控（否则看不到真实的写入序列）；
#     ⑥ cfgVersion 11 -> 12（只纠正"还停在旧默认值"的项）。
#   - 判据本身**不动**：仍然只有 layers<=0 || hosted<=0 才算黑；deact/cs/idle 只记日志。
#
# 0.10.0 变更：
#   - 0.9.1 真机（归档(10)）：不再黑屏，但**切换 App 时仍会闪一下**，而且
#     —— 这是整轮的钥匙 —— **把 keepAliveMs 调到 100 / 50 后，闪烁反而更快**。
#     若黑是 SpringBoard 造成的，调小周期只会让黑窗更短，绝不会更频繁；
#     频率跟着我们的周期走 => **那一帧黑是我们自己写的**。日志逐条吻合（同 pid 20257）：
#       · deact=32/33/8/1 出现 20+ 次，绝大多数与 layers=2 hosted=2 同时成立（画面是好的）
#       · cs=0 出现 11 次，其中 8 次 layers/hosted 完好（cs 只是 settings 提交途中的瞬时值）
#       · layers=0（真黑）只出现 4 次，**4 次全在我们写完 settings 之后 0~2 秒内**
#     机制：updateSettingsWithBlock:（尤其 setDisplayConfiguration:）让 SpringBoard 重算整份 settings、
#     App 的 scene 重新提交（contentState 2->0->1->2、图层重建）= 屏幕上闪一下。
#     0.9.1 的判据 `deact!=0` 在真机上几乎一直成立 => 每拍写一次 => 闪的频率 = 1 / keepAliveMs。
#   - 修法：① 判据收紧成**唯一一条**：layers<=0 || presenter 宿主 hosted<=0；
#     ② 写操作分档：默认只写 idle+deact(+frame)，setLevel/setDisplayConfiguration 降级为默认关闭的升级写；
#     ③ 三重刹车：挂载宽限期 / 两次写入最小间隔 / 连续 N 拍救不回来就停止写入；
#     ④ scene.frame 真源改成 panel.contentArea.bounds（0.9.x 读 presentationView.bounds，
#        而它在 hosting 掉线时会被系统改成整屏 430x932 => 正反馈闭环 + 比例崩）；
#     ⑤ 修 %s 打中文的乱码、修 ps= 的 32 位 ABI 假值。
#     【0.11.0 复盘】②③ 就是这一版的两处回归：② 删掉了必要条件，③ 把刹车做成了放弃。
#   - 0.9.1 变更（历史）：
#   - 0.9.0 真机（归档(9)）：**不再黑屏了，但切换 App 时会闪一下**。
#     日志给出精确时序（同一 pid 19856、同一轮承载，每行前缀是 Unix 秒）：
#       +8488  状态变化 -> deact=33                        ← 去激活原因出现（此刻画面还在！）
#       +8489  状态变化 -> deact=0 cs=0 layers=0 hosted=0   ← 掉出（黑）
#       +8490  状态变化 -> cs=1 -> cs=2 layers=2            ← 我们拉回后恢复
#     => 黑窗 ≈ 一个守护周期（1000 ms），这就是"闪一下"的全部；
#        而且 deact 比掉出早约 1 秒出现，是一次干净的预警。
#   - 同时揭开一个更深的坑：`fg` 在整份日志里**从头到尾都是 0**（含 P0 刚设完后）。
#     真相是 UIMutableApplicationSceneSettings 上**没有 setForeground: / foreground**，
#     而所有 helper 都有 respondsToSelector 守卫 => 0.7.0 起这段逻辑一直是空转，
#     0.9.0 的判定 `(!fg && fixFg)` 因此恒为真，每秒都在无谓地发一次 updateSettings。
#   - 修法：① 判定只用**本机确认存在**的量（layers / contentState / deactivationReasons /
#     idleModeEnabled），foreground 降级为纯日志字段；② 周期 1000 ms -> 200 ms；
#     ③ 只有真的坏了才发 updateSettings（不再每秒空拉）；④ 拉回按项可选
#     （keepAliveDeact / keepAliveIdle / keepAliveLevel / keepAliveForeground）；
#     ⑤ 每次掉出记录持续了几个周期并换算成毫秒写日志（量化"闪了多久"）。
#   - 能力报告新增：判定相关属性的 responds 矩阵（settings 与 FBScene 两侧）+ UIApplication
#     的完整 ivar 列表 —— 下一版要靠 UIApplicationSceneDeactivationAssertion 让目标 scene
#     根本不被 SpringBoard 去激活（那才是"零闪烁"的解法；现在只能事后拉回，必然闪一下）。
#
# 0.9.0 变更：
#   - 0.8.0 真机（归档(8)）：**浮窗全程正常了** —— 内容对、拖 ◢ 缩放时比例也对、没触发安全模式。
#     唯一剩下的问题：在桌面主屏时浮窗里 Safari 画面正常，一切到"设置"就变黑。
#   - 日志给出的事故链（同一个 pid 19432，同一轮承载）：
#       P6      : foreground=1 contentState=2 layerManager.layers=2 hostedLayers=2   ← 正常出画面
#       P6+20s  : foreground=0 contentState=0 layerManager.layers=0 hostedLayers=0   ← 内容没了 => 黑
#     根因：P0（把 scene settings 拉成 foreground=YES/level=1）是**一次性**动作；
#     前台 App 一换人，SpringBoard 就把目标 App 的 scene settings 重算回去并写回 foreground=NO
#     （同时极可能打开 idleModeEnabled、加上 deactivationReasons），App 的 layerManager 随之丢光图层，
#     _UIScenePresentationView 没东西可承载 => 黑。
#   - 修法：新增 scene 守护（keepAlive，默认 1 秒一次）。承载成功后反复把
#       foreground=YES / level=1 / idleModeEnabled=NO / deactivationReasons=0
#     拉回，并同步 scene.frame 到内容区尺寸；presenter 掉了 hosting 就重新 activate。
#     两个新 setter 的存在性由归档(8) 的 MF-presenter-report.txt 确认：
#       UIMutableApplicationSceneSettings - setDeactivationReasons: v24@0:8Q16
#       UIMutableApplicationSceneSettings - setIdleModeEnabled:     v20@0:8B16
#   - 日志策略：状态签名变化才记一行（`[keepalive] 状态变化 旧 -> 新`），其余每 20 拍一行心跳，
#     连续掉出时第 1 次与每 10 次记明细 —— 否则一秒一行，用户没法回传。
#   - 仍然【一个 hook 都不装】：用的还是 updateSettingsWithBlock: 这个 0.7.0 已验证能让画面出来的
#     非侵入手段，只是从"打一枪"改成"持续按住"。
#   - 新增配置 keepAlive / keepAliveMs / keepAliveIdle，cfgVersion 升到 9（8->9 只新增键，不改旧值）。
#
# 0.8.0 变更：
#   - 0.7.0 真机（归档(7)）：**第一次真的出画面了**（route 3 出画面但比例不对；route 4 出画面但崩）
#   - 缺陷 1 画面比例：presentationView 的自然尺寸 = scene.settings.frame；
#     真实 App 的 scene 是整屏 430x932（宽高比 0.461），浮窗内容区是 267x336.6（0.793）=> 拉伸变形。
#     route 4 比例正常正是因为它建 scene 时就把 frame 设成了 contentArea.bounds。
#     => hostSceneFrame 默认 YES：承载前把 scene.frame 设成内容区尺寸，挂载后 3 秒再同步一次
#        （updateSettingsWithBlock: 是异步的），用户拖 ◢ 缩放后再同步一次。新增步骤 P7-geom。
#   - 缺陷 2 安全模式：route 4 对**同一个 identity** 第二次 createSceneWithDefinition =>
#     FBSceneManager 断言 => SpringBoard 挂（归因 crashedStep=P4-scene，同 pid 19006）。
#     => 自有 scene 一律经 MFAcquireOwnSceneForApp 获取：同 App 复用 / sceneWithIdentifier: 接管 /
#        换 App 先 destroyScene:withTransitionContext:（配非空 _createTransitionContext）/
#        每进程每 App 硬上限 1 次新建。新增步骤 P4a-del。
#   - 缺陷 3 静默黑屏：二次 createPresenter 抛 "already in use" 后旧代码静默退 Route B（已知纯黑），
#     "重试 = 画面变黑"。=> presenter 同 scene+identifier 复用，换目标时 deactivate+invalidate
#     再重建；presenter 失败不再兜底 Route B（除非 allowRouteB=true）。新增步骤 P3a-reuse / P3c-void。
#   - 配置迁移到 cfgVersion=8（只做一次）：hostRoute 4 -> 3、hostSceneFrame false -> true。
# 0.7.0 变更：
#   - 0.6.0 真机：presenter 链 P1..P5 全通、拿到真 _UIScenePresentationView、不崩 —— 但内容区纯黑
#   - 根因：0.6.0 用 [[UIScenePresentationManager alloc] _initWithScene:] 自造 manager，
#     它不在 scene 自己的 presenter owner 体系里 => presenter 永远进不了 hosting =>
#     _UIScenePresentationView 一直画 backgroundColorWhileNotHosting（黑）
#   - 对照 khanhduytran0/FrontBoardAppLauncher（LiveContainer 多任务同款源码）：
#     manager 必须来自 scene 自己 —— [scene.uiPresentationManager createPresenterWithIdentifier:]
#     并且要在 createPresenter 之后 modifyPresentationContext:{ appearanceStyle = 2 }
#   - hostRoute 四路：3=接管已存在 scene（默认）/ 4=自建 scene（FrontBoardAppLauncher 原版）
#                     / 2=旧的 _initWithScene:（A/B）/ 1=SB 宿主 VC（兜底）
#   - 新增 P0 步：承载前把 scene settings 拉成 foreground=YES / level=1 / portrait
#     （被切到后台的 scene foreground=NO，App 不会再往里渲染）
#   - 删除 forceActivate：真机实测它会让 SpringBoard 在 20 秒存活窗口内挂掉（归因 S7-settle）
#   - 配置改为"每次承载重新读盘"，调参不用 respring
#   - 新增 P3b（appearanceStyle）/ P6（presenter isHosting + 图层计数）两处插桩
# 0.6.0 变更：
#   - 0.5.0 真机：浮窗出现、S1..S7 全通、不崩，但内容区纯黑（sceneIfExists active=1 contentState=0）
#   - 根因：Route B 的 SBDeviceApplicationSceneViewController 是给 SpringBoard 自己布局系统用的，
#     光挂它的 view 没有 presenter 就只是黑底
#   - 新增 Route A2：自建 UIScenePresentationManager（-_initWithScene:）
#     → createPresenterWithIdentifier: → activate → presentationView（Stheno/TrollOpen 同款）
#   - hostRoute 配置项：2=自建 presenter（默认）/ 1=SpringBoard 宿主 VC（兜底）
#   - forceActivate 配置项（默认关）：用 FBScene -_createTransitionContext 的非空上下文强制激活
#   - 新增 /var/mobile/MF-presenter-report.txt 能力报告（方法表 + responds 矩阵）
# 0.5.0 变更：
#   - 修 0.4.0 的配置坑：总开关 enabled 默认 false 导致"改了 hostEnabled 却无任何画面"
#   - 默认 enabled=true（装上就显示外壳）；新增"enabled=false 且 hostEnabled=true"自修复
#   - enabled=false 时的日志直接点明"只改 hostEnabled 没用"
#   - 承载链路 S1..S7 与 0.4.0 完全一致，未改动
# 0.4.0 变更：
#   - 修 0.3.0 的"崩→重启→再崩→安全模式"循环（三处独立缺陷，详见 MFFloat.xm 头部注释）
#   - 启动不再自动承载；行为开关全部改成布尔（hostEnabled），字符串不再参与判断
#   - 承载链路逐步插桩（S1..S7），崩溃可归因到具体一步
#   - 删掉 FBScene -activateWithTransitionContext:nil（0.3.0 的崩点）
# 0.3.0 变更：
#   - 从"纯空壳"变为第一个真实功能版（默认关闭）
#   - 编译单元收敛为纯 Objective-C + Logos：Swift 骨架暂时移出构建
#     （Swift 进 SpringBoard 是又一个未验证变量，等承载链路跑通再迁回来）
#   - 不链接任何 substrate / ellekit：本版不装 hook

ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide

# CI 传入 runner Xcode 的 SDK 版本；16.5 为本地后备
MF_SDK_VERSION ?= 16.5
TARGET = iphone:clang:$(MF_SDK_VERSION):15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MultiFloat

MultiFloat_FILES = \
    Logos/HookBridge.xm \
    Logos/MFCore.xm \
    Logos/MFFloat.xm

# 显式开启 ARC，避免 Theos 默认值在不同版本间摇摆导致内存语义不确定
MultiFloat_CFLAGS = -fobjc-arc

# [CONFIRMED] 分析的主库注入 SpringBoard
INSTALL_TARGET_PROCESSES = SpringBoard

# QuartzCore 用于 CALayer 圆角/边框
MultiFloat_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
