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

# ===== 【0.4.0】两个 dylib =====
# ① PullOverMF.dylib（主）：只注入 SpringBoard（plist: Filter → Bundles → com.apple.springboard）。
# ② POCaptureCompat.dylib（相机兼容）：**独立极小 dylib**，只注入相机守护进程
#    （plist: Filter → Executables → cameracaptured / mediaserverd）。
#
# 为什么必须拆（0.4.0 的取证结论，别再合回去）：
#   PullOver 让浮窗里的 App 画面能用，但那个 App 自身仍是后台 ⇒ 相机服务 cameracaptured
#   拒绝为它出帧（微信扫一扫 / QQ 拍照黑屏）。修法只能往相机守护进程注入、放宽判定。
#   而主 dylib 的未定义符号里有 `_OBJC_CLASS_$_UIApplication`、
#   `_UIApplicationLaunchOptionsSourceApplicationKey`、`_kCACornerCurveContinuous` 等
#   **加载期即绑定**（non-lazy）的 UIKit / QuartzCore 符号 —— 相机守护进程不加载这两个
#   框架，注入主 dylib 会在 dyld 绑定阶段 "Symbol not found" 直接崩掉相机服务。
#   ⇒ 相机兼容代码单独成一个**零 UIKit / 零 QuartzCore 依赖**的 dylib。
#   （主 dylib 里 POCameraCompatibility.m 用 filter-out 排除，绝不重复编进去。）
#   探测方法：`.workbuddy-ai/tmp/probe_undef.py <deb>` 列未定义符号并标出加载期绑定的全局量。
TWEAK_NAME = PullOverMF POCaptureCompat

PullOverMF_FILES = $(filter-out PullOverX/POCameraCompatibility.m,$(wildcard PullOverX/*.m)) $(wildcard PullOverX/*.mm) POLocalization.m
# ARC（上游 CLANG_ENABLE_OBJC_ARC=YES）；-w 关掉上游代码的告警（不引入新错误即可）
# -include 前缀头（上游 GCC_PRECOMPILE_PREFIX_HEADER=YES）
PullOverMF_CFLAGS = -fobjc-arc -w -IPullOverX -I. -include PullOverX/PullOverX-Prefix.pch

POCaptureCompat_FILES = PullOverX/POCameraCompatibility.m
# 刻意**不**带 -include PullOverX-Prefix.pch（那里面 import 了 UIKit）
POCaptureCompat_CFLAGS = -fobjc-arc -w -IPullOverX -I.
# 不显式链接系统/私有框架：
#   · tweak 的符号在运行时由宿主进程（SpringBoard 已加载 UIKit/CoreGraphics/QuartzCore）解析；
#   · Xcode 26 SDK 的 UIKit.tbd 会"再导出"私有框架（UIUtilities），显式 -framework UIKit
#     会导致 ld 报 "Could not find or use auto-linked framework 'UIUtilities'" 而链接失败。
PullOverMF_LDFLAGS = -Wl,-undefined,dynamic_lookup
POCaptureCompat_LDFLAGS = -Wl,-undefined,dynamic_lookup
# 保底：即使手写/自定义 plist 都没被采用，主 dylib 也只会注入 SpringBoard
#（绝不外溢到相机守护进程 —— 那会崩）。POCaptureCompat 的目标进程由
# POCaptureCompat.plist（项目根自定义模板）+ layout 里的 plist 指定。
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
