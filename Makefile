# MultiFloat — 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
#
# 关键约定（勿改，除非设备环境变化）：
#   - ARCHS 只出 arm64e（设备为 A17，arm64e；不要再造 arm64 切片）
#   - THEOS_PACKAGE_SCHEME = roothide（文件按 roothide 布局，deb 架构为 iphoneos-arm64e）
#   - 需要 roothide/theos 才能识别 roothide scheme
#   - SDK 版本由 CI 经 MF_SDK_VERSION 传入

ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide

# CI 传入 runner Xcode 的 SDK 版本；16.5 为本地后备
MF_SDK_VERSION ?= 16.5
TARGET = iphone:clang:$(MF_SDK_VERSION):15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MultiFloat

MultiFloat_FILES = \
    Logos/SpringBoardHooks.xm \
    Logos/HookBridge.xm \
    Swift/MultiFloatCore.swift \
    Swift/WindowManager.swift \
    Swift/FloatingWindow.swift \
    Swift/SceneManager.swift \
    Swift/LayoutEngine.swift \
    Swift/GestureController.swift \
    Swift/StateMachine.swift \
    Swift/AppRegistry.swift \
    Swift/Preferences.swift

# [CONFIRMED] 分析的主库注入 SpringBoard
INSTALL_TARGET_PROCESSES = SpringBoard

# [VERIFY] 确认所选 SDK 中框架可用
MultiFloat_FRAMEWORKS = Foundation UIKit CoreGraphics

# [VERIFY] Theos Swift 集成变量名取决于所用 Theos/工具链
# MultiFloat_SWIFT_BRIDGING_HEADER = Bridge/MultiFloat-Bridging-Header.h
# MultiFloat_SWIFTFLAGS += -module-name MultiFloatCore

# [VERIFY] 环境验证后再决定 Hook 后端
# MultiFloat_LIBRARIES = substrate
# MultiFloat_LIBRARIES = ellekit

include $(THEOS_MAKE_PATH)/tweak.mk
