# MultiFloatProbe — SpringBoard 运行期探针（独立 Theos 工程）
# 目标环境：[CONFIRMED] iOS 17.3.1 / arm64e / roothide (Relaxin)
# 只读采样：把本机真实的私有 API 归属/签名/ivar 写入 /var/mobile 下的日志。
#
# v0.4.0：新增「第三方浮窗类定位」「呈现链路结构 dump」「活体只读探测」
#         「open 入口纯日志 hook」。hook 后端通过 dlsym(RTLD_DEFAULT) 运行期解析，
#         因此**不链接**任何 substrate / ellekit 库。

ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide

MF_SDK_VERSION ?= 16.5
TARGET = iphone:clang:$(MF_SDK_VERSION):15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MultiFloatProbe

MultiFloatProbe_FILES = Probe.xm
MultiFloatProbe_FRAMEWORKS = Foundation UIKit

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
