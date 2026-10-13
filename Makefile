# MultiFloat — 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
#
# 关键约定（勿改，除非设备环境变化）：
#   - ARCHS 只出 arm64e（设备为 A17，arm64e；不要再造 arm64 切片）
#   - THEOS_PACKAGE_SCHEME = roothide（文件按 roothide 布局，deb 架构为 iphoneos-arm64e）
#   - 需要 roothide/theos 才能识别 roothide scheme
#   - SDK 版本由 CI 经 MF_SDK_VERSION 传入
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
