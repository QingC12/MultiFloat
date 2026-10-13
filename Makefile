# MultiFloat Phase 0 build skeleton.
# Do not run before Phase 1 environment verification.

# [VERIFY] Confirm device/SDK support before selecting architectures.
ARCHS = arm64 arm64e

# [VERIFY] Confirm the installed Theos SDK and deployment target.
TARGET = iphone:clang:latest:15.0

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

# [CONFIRMED] The analyzed main libraries are injected into SpringBoard.
INSTALL_TARGET_PROCESSES = SpringBoard

# [VERIFY] Confirm framework availability in the selected SDK.
MultiFloat_FRAMEWORKS = Foundation UIKit CoreGraphics

# [VERIFY] Theos Swift integration variable names depend on the installed Theos/toolchain.
# MultiFloat_SWIFT_BRIDGING_HEADER = Bridge/MultiFloat-Bridging-Header.h
# MultiFloat_SWIFTFLAGS += -module-name MultiFloatCore

# [VERIFY] Select exactly one hook backend after environment validation.
# MultiFloat_LIBRARIES = substrate
# MultiFloat_LIBRARIES = ellekit

include $(THEOS_MAKE_PATH)/tweak.mk
