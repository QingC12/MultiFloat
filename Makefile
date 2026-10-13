# MultiFloat — 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
#
# 关键约定（勿改，除非设备环境变化）：
#   - ARCHS 只出 arm64e（设备为 A17，arm64e；不要再造 arm64 切片）
#   - THEOS_PACKAGE_SCHEME = roothide（文件按 roothide 布局，deb 架构为 iphoneos-arm64e）
#   - 需要 roothide/theos 才能识别 roothide scheme
#   - SDK 版本由 CI 经 MF_SDK_VERSION 传入
#
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
