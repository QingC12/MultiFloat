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
#
# ===== 【0.4.7】★ 体积精简的真凶与关键修正：DEBUG 必须在 include common.mk **之前** 设为 0 =====
# 0.4.6 用 `messages = yes` 抓到真实编译命令行，其**末尾**是：
#     clang -c ... -Os -fobjc-arc -w -IPullOverX -I. -include PullOverX-Prefix.pch -Os  -DDEBUG -O0  -DTHEOS_INSTANCE_NAME="PullOverMF" ...
#   ⇒ Theos 在 DEBUG=1（**roothide fork 的默认值**）时会**最后**追加 `-DDEBUG -O0`，
#     把前面所有 `-Os` 全部覆盖（clang 取最后一个 -O 选项）—— 这才是"优化级别怎么改都不动"的真因：
#     0.4.2~0.4.6 的 __TEXT 一直是 835584 B（__text 662760 B），即**未优化的 -O0 产物**。
#   ⇒ 修正：`DEBUG = 0` 必须写在 `include common.mk` **之前**（写在其后无效，因为 Theos 早已据此展开 CFLAGS）。
# ★ 安全性：已全工程 grep 确认**没有任何 `#ifdef DEBUG` / `#ifndef DEBUG` / `NDEBUG` 条件编译**，
#   MFLog 是无条件定义的 ⇒ `DEBUG = 0` 不会关掉任何日志，只去掉 `-DDEBUG -O0`
#   （顺带：产物名不再被追加 `+debug` 后缀）。
DEBUG = 0

ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide
MF_SDK_VERSION ?= 16.5
# 诊断（0.4.6 临时用过 `messages = yes` 抓命令行，0.4.8 已撤掉恢复安静构建）。

TARGET = iphone:clang:$(MF_SDK_VERSION):14.0
include $(THEOS)/makefiles/common.mk

# ===== 【0.4.4】体积优先优化级别（**正面覆盖** Theos 默认 -O2）=====
# ★ 教训（0.4.3 实测）：只在 `xxx_CFLAGS += -Os` 里写是**没用的** ——
#   Theos 的优化级别由它自己的 `OPTFLAGS` / `TARGET_CFLAGS` 提供，位置排在用户 CFLAGS 之后，
#   clang 取**最后**一个 -O 选项 ⇒ 用户那个 -Os 被 -O2 吃掉。
#   实证：0.4.3 与 0.4.2 的 `PullOverMF.dylib` 的 __TEXT 段及 13 个子节**逐字节完全相同**
#   （835584 B / __text 662760 B ……），而链接期 strip 生效（__LINKEDIT 341088 → 32032 B）。
# ⇒ 必须覆盖这两个变量：OPTFLAGS（common.mk 定义的优化级别）+ TARGET_CFLAGS（可能已内联 -O*）。
#   用 `:=` 立即展开，把任何已存在的 -O* 过滤掉，只留末尾一个 -Os。
OPTFLAGS = -Os
TARGET_CFLAGS := $(filter-out -O0 -O1 -O2 -O3 -Ofast -Oz,$(TARGET_CFLAGS)) -Os

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

# ===== 【0.4.3】体积精简（只减体积，不改任何功能逻辑）=====
# 背景（0.4.2 产物实测，用 .workbuddy-ai/tmp/macho_seg.py 解析）：
#   主 dylib 未压缩 1258592 B，其中 __LINKEDIT 341088 B —— 内含 LC_SYMTAB
#   **9478 个符号（151648 B）+ 字符串表（167648 B）= 319296 B 纯符号**，
#   而 Theos 默认**不做 strip** ⇒ 这 319 KB 白白随包发行（tweak 是给 dyld 在宿主
#   进程里解析的，`-undefined dynamic_lookup`，**一个符号都不需要导出**）。
# 做法（全部是编译/链接期开关，不动一行业务代码）：
#   ① `-Wl,-x`：链接期不把**局部符号**写进符号表（ld 的 strip 局部符号）。
#   ② `-Wl,-S`：不写**调试符号**。
#   ③ `-Wl,-dead_strip`：删链上未被引用的函数/数据。
#   ④ `-Wl,-dead_strip`：删链上未被引用的函数/数据。
#   ⑤ 优化级别 -Os：见文件顶部【0.4.7】——真凶是 DEBUG=1 在命令行**末尾**追加的 `-DDEBUG -O0`，
#      在顶部把它设成 0 之后，下面各处注入的 `-Os` 才真正生效。
# 实测收益（0.4.2 → 0.4.3）：主 dylib 1258592 → 949536 B（-24.6%，__LINKEDIT 341088 → 32032 B，
# 符号 9478 → 306）；相机 dylib 76672 → 71456 B；DEB 319754 → 275046 B（-14.0%）。
PullOverMF_LDFLAGS += -Wl,-x -Wl,-S -Wl,-dead_strip
POCaptureCompat_LDFLAGS += -Wl,-x -Wl,-S -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/tweak.mk

# ===== 【0.4.8】优化级别注入（保留；0.4.7 起已实测生效）=====
# 生效前提 = 文件顶部的 `DEBUG = 0`（否则 Theos 在 DEBUG=1 时会于命令行末尾追加 `-DDEBUG -O0` 覆盖掉这些 -Os）。
# 多处冗余注入（OPTFLAGS / TARGET_CFLAGS / xxx_CFLAGS / ADDITIONAL_CFLAGS / _THEOS_INTERNAL_CFLAGS）
# 是有意为之：Theos 各版本把这些变量拼进命令行的位置不同，全都放一份，任何一个位置生效即可。
PullOverMF_CFLAGS += -Os
POCaptureCompat_CFLAGS += -Os
ADDITIONAL_CFLAGS += -Os
ifneq ($(_THEOS_INTERNAL_CFLAGS),)
_THEOS_INTERNAL_CFLAGS := $(filter-out -O0 -O1 -O2 -O3 -Ofast,$(_THEOS_INTERNAL_CFLAGS)) -Os
endif
