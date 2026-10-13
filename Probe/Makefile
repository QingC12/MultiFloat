# MultiFloatProbe — SpringBoard 运行期探针（独立 Theos 工程）
# 目标环境：[CONFIRMED] iOS 17.3.1 / arm64e / roothide (Relaxin)
# 只读采样：把本机真实的私有 API 归属/签名/ivar 写入 /var/mobile 下的日志。
#
# v0.5.0：安全闸门版。
#         - 自动段只保留两轮验证过安全的（env/类清单/selector 归属/第三方类/结构 dump）
#         - 新增纯静态「关键 selector 全镜像归属搜索」
#         - 活体段改为闸门文件控制 + 主线程执行 + 逐调用落盘 + 崩溃自解除
#         - hook 段同样加闸门（默认不装）
#         闸门文件：/var/mobile/MFProbe-live-gate.txt（内容 1..4）
#                   /var/mobile/MFProbe-hooks-gate.txt（存在即装 hook）

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
