# MultiFloat — 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
#
# 关键约定（勿改，除非设备环境变化）：
#   - ARCHS 只出 arm64e（设备为 A17，arm64e；不要再造 arm64 切片）
#   - THEOS_PACKAGE_SCHEME = roothide（文件按 roothide 布局，deb 架构为 iphoneos-arm64e）
#   - 需要 roothide/theos 才能识别 roothide scheme
#   - SDK 版本由 CI 经 MF_SDK_VERSION 传入
#
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
