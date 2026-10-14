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
5. 外部 API（`POXExternalAPI`）与上游一致，未改动。

## 0.1.1 改动（Stheno 风格面板几何）
6. **面板缩小 + 居中显示**（对应需求："浮窗非常大且紧贴屏幕边缘 → 打开后停在屏幕正中"）：
   - 上游：卡片宽 ≈ 整屏宽（`scale` 上限 1.0），从右缘滑入后基本铺满屏幕；
   - 本 fork：`scale` 上限改为 `MFPanelWidthRatio()`（默认 **0.78**）→ 卡片按比例缩小，
     `normalCardFrame` 的 y 本来就居中，于是整体停在屏幕正中；
   - 并在 `scrollView.contentSize` 上加了**居中补偿**（`mfCenteringInset`），使"滑到底 =
     打开态"时卡片左右留白完全相等，而不是贴住右缘。
7. **圆角加大**：`CONTENT_CORNER_RADIUS` 20 → `MFPanelCornerRadius()`（默认 **44**），
   且沿用 `kCACornerCurveContinuous`（连续曲率，视觉更圆润）。阴影路径同步跟随新半径。
8. **两个参数都做成可配置**（写进 `NSUserDefaults` suite `com.mlgm.pulloverx`，改完 respring 生效，无需重编译）：
   - `mfPanelWidthRatio`（0.30 ~ 1.00，默认 0.78）
   - `mfPanelCornerRadius`（0 ~ 80，默认 44）
9. 面板内承载的 App 内容由 `layoutContextView` 按 `contentView.bounds` 自动等比缩放并居中，
   卡片变小不会造成拉伸。
10. 新增几何诊断日志：尺寸变化时打印
    `[MF] 面板几何: 卡片 WxH @y | 屏幕 WxH | 比例 | 左右留白 | 圆角`。

## 0.1.2 改动（文件日志 + 手柄跟随到浮窗右侧）
12. **新增文件日志 `MFLog()`**（`PullOverX/MFDebugLog.m`，声明在 prefix header）：
    上游全项目几乎没有日志、且只进系统 syslog，设备上根本取不到，排查等于盲人摸象。
    现在所有关键事件写入 **`/var/mobile/PullOverMF.log`**（Filza 直接打开看），
    启动时超过 2MB 自动轮转为 `.old`，无缓冲写入（崩溃前最后一条也在盘上）。
    已插桩：版本加载、视图就绪、面板几何、open()/close()、吸附请求/完成、
    手柄单击/拖动/长按、承载成功（场景发布）/失败（无法承载）。
13. **面板打开后手柄移到浮窗右侧**（对应需求"以便右手操作"）：
    - 上游竖屏把手柄 rail 固定在**内容坐标**的屏幕右缘，面板滑入时会被 scrollView
      一起带走 → 打开后手柄实际跑到了屏幕左侧；
    - 本 fork 新增 `mfVerticalHandleRailScreenX` / `mfUpdateVerticalHandleRailPosition`：
      按打开进度插值，关闭态贴屏幕右缘（上游行为），**打开态平移到卡片右边缘外侧**，
      使 nub **完整显示在浮窗右边**；在 `applyLayoutPreservingHandlePosition:` 与
      `scrollViewDidScroll:` 两处刷新（与上游 landscape 分支同一思路）。
    - 新增配置键 `mfPanelHandleGap`（手柄与卡片右边缘的间距，默认 6pt，0~40）。

## 0.1.3 改动（崩溃修复 + Stheno 风格圆盘选择器）
14. **修复 0.1.2 的致命崩溃**（表现为"装上后桌面连手柄都不显示"）：
    0.1.2 在 dylib 的 constructor 里调用 MFLog，内部用了 `NSDateFormatter` 与 `[UIDevice currentDevice]`；
    constructor 在 SpringBoard 极早期执行，Foundation/UIKit 尚未就绪 → 崩 → 整个 tweak 加载失败。
    现在日志分两条通道：
    - `MFLogRawC(const char *)`：**纯 C**（`clock_gettime` + `strftime` + `fopen`），constructor 阶段唯一安全入口；
    - `MFLog(NSString *, ...)`：正常运行期使用，内部也不再用 NSDateFormatter，且对 Foundation 调用加 `@try`。
    文件打开改为纯 C（`fopen`/`rename`），不再依赖 NSFileManager。

15. **新增 Stheno 风格「圆盘」选择器**（`PullOverX/MFRingPicker.m`）：
    设计依据来自对 Stheno 0.1.23 的逆向（`com.nx.stheno` 的 `Stheno.dylib` 字符串 + 本地化文案）：
    - 圆盘本体类型：`RingView` / `RingShape` / `RingType` / `RingTypeSwitchView` / `RingModifySlidersView`；
    - 形状文案：`RTSIF`=承载形状::圆盘、`RTSIH`=承载形状::半圆盘、`RTSIQ`=承载形状::直角盘、
      `RTSIZ`=承载形状::任意(拖拽旋转最后一个图标)；几何键：`IconWidth`/`Radius`/`HeightFraction`/
      `IntersectionHeightFraction`(键盘避让)/`RotationAngle`(旋转角)/`LastIconAngle`(尾角)/`DampingFraction`；
    - 呼出方式：`EBCI`=触发边(可调节)、`AppearEdge`、`EdgeBarControlView`、`EgdeGestureView`、
      `EdgeGestureShape`，并 hook 了 SpringBoard 手势链（`SBReachabilityGestureRecognizerHook` /
      `SBReachabilityManagerHook` / `SBGrabberTongueHook` / `SBFluidSwitcherGestureManagerHook` /
      `_SBFluidSwitcherPanGestureRecognizerHook`，处理 `_handlePullGesture:` 下拉）。
    本 fork 的第一阶段实现（**零 hook**）：贴边半圆盘 + 图标沿弧排布（角度区间 90°→270°，
    保证全部落在屏幕内）+ 点图标 `pinAppWithBundleId:` 后 `open` 浮窗 + 长按图标移出（写 `ringApps`）。
    呼出：可配置边缘上的一条透明触发区，**任意方向滑动 >18pt 或单击**都能呼出。

16. 新增配置项（suite `com.mlgm.pulloverx`，respring 生效）：
    `mfRingEnabled`(默认 YES) / `mfTriggerEdge`(right|left|top|bottom，默认 right) /
    `mfTriggerLength`(380) / `mfTriggerThickness`(56) / `mfTriggerCenterRatio`(0.78，避开手柄常驻的中部) /
    `mfRingRadius`(150) / `mfRingIconSize`(56) / `mfRingRotation`(0) / `mfRingMaxIcons`(8) /
    `ringApps`(bundleID 数组，圆盘自定义内容)。

11. 后续改动（UI/交互/分屏能力）将逐条记录在此。
