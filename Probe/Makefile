# MultiFloatProbe — SpringBoard 运行期探针（独立 Theos 工程）
# 只读采样：把本机真实的私有 API 归属/签名/ivar 写入日志文件。

ARCHS = arm64 arm64e

# 与主工程一致：CI 传入 runner Xcode 的 SDK 版本；16.5 为本地后备
MF_SDK_VERSION ?= 16.5
TARGET = iphone:clang:$(MF_SDK_VERSION):15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MultiFloatProbe

MultiFloatProbe_FILES = Probe.xm
MultiFloatProbe_FRAMEWORKS = Foundation UIKit

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
