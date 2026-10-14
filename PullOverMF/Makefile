# PullOverMF —— MultiFloat 项目对 PullOver-X 的个人化改造版
#
# 上游：https://github.com/mlgm66/PullOver-X （GPL-3.0，基于 c1d3rDev 的 PullOver Pro 改造）
# 本 fork 采用 **GPL-3.0**，仅个人使用；发行/分享时必须随附源码并保留版权声明。
#
# 构建说明（与上游差异）：
#   上游用 Xcode 工程（PullOverX.xcodeproj，ARC + -undefined dynamic_lookup + Theos 头文件路径）。
#   本地无 macOS、CI 为 roothide/theos，因此这里改成 **Theos tweak 工程**，
#   源文件保持上游目录结构（PullOverX/ 平铺 + 根级 POLocalization/POPPath），
#   从而所有 `#import "../POLocalization.h"` / `#import "POPPath.h"` 原样可用。
#
# 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide
ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide
MF_SDK_VERSION ?= 16.5
TARGET = iphone:clang:$(MF_SDK_VERSION):14.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PullOverMF
PullOverMF_FILES = $(wildcard PullOverX/*.m) $(wildcard PullOverX/*.mm) POLocalization.m
# ARC（上游 CLANG_ENABLE_OBJC_ARC=YES）；-w 关掉上游代码的告警（不引入新错误即可）
# -include 前缀头（上游 GCC_PRECOMPILE_PREFIX_HEADER=YES）
PullOverMF_CFLAGS = -fobjc-arc -w -IPullOverX -I. -include PullOverX/PullOverX-Prefix.pch
# 不显式链接系统/私有框架：
#   · tweak 的符号在运行时由宿主进程（SpringBoard 已加载 UIKit/CoreGraphics/QuartzCore）解析；
#   · Xcode 26 SDK 的 UIKit.tbd 会"再导出"私有框架（UIUtilities），显式 -framework UIKit
#     会导致 ld 报 "Could not find or use auto-linked framework 'UIUtilities'" 而链接失败。
PullOverMF_LDFLAGS = -Wl,-undefined,dynamic_lookup
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
