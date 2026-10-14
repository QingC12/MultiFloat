# PullOverMF —— 来源与许可声明（GPL-3.0 合规）

本目录是 **PullOver-X 的个人改造分支**，用于 MultiFloat 项目的多任务悬浮窗/分屏实验。

## 上游与版权
- 本 fork 的基础：**PullOver X**（作者 mlgm，https://github.com/mlgm66/PullOver-X ，GPL-3.0）
- PullOver X 又基于：**PullOver Pro**（作者 c1d3rDev）
- 原始版权归上述作者所有；本目录保留其全部版权与许可声明（见 `LICENSE`，GPL-3.0 全文）。

## 本 fork 的许可
**GPL-3.0**（与上游一致）。仅个人使用；如需分发（含发布 deb / 分享给他人），
必须同时提供完整对应源码、保留版权声明，并以 GPL-3.0 授权。

## 本 fork 相对上游的改动（持续更新）
1. **构建系统**：`PullOverX.xcodeproj`（Xcode 工程）→ **Theos tweak 工程**（`Makefile`）。
   原因：本地无 macOS，CI 使用 roothide/theos；源文件目录结构保持与上游一致以兼容相对 include。
2. 包名/标识：`com.mlgm.pulloverx` → `com.qingc12.pullovermf`；dylib 名 `PullOverX` → `PullOverMF`；
   注入过滤仍为 `com.apple.springboard`。
3. 仅构建 SpringBoard 侧源码（上游的相机兼容 dylib 过滤器 `PullOverXCamera.plist`
   指向 mediaserverd/cameracaptured；其源码 `POCameraCompatibility.m` 自带进程名判断，仍随本包编译）。
4. 暂不构建偏好设置 bundle（`PullOverXPreferences`）；设置仍走
   `NSUserDefaults suite = com.mlgm.pulloverx`（`registerDefaults` 已提供默认值，可直接用）。
5. 后续改动（UI/交互/分屏能力）将逐条记录在此。
