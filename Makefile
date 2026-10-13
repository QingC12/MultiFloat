# MultiFloat — 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
#
# 关键约定（勿改，除非设备环境变化）：
#   - ARCHS 只出 arm64e（设备为 A17，arm64e；不要再造 arm64 切片）
#   - THEOS_PACKAGE_SCHEME = roothide（文件按 roothide 布局，deb 架构为 iphoneos-arm64e）
#   - 需要 roothide/theos 才能识别 roothide scheme
#   - SDK 版本由 CI 经 MF_SDK_VERSION 传入
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
