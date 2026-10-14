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

## 0.1.4 改动（致命链接错误修复 —— 0.1.2/0.1.3 整个 tweak 不加载的真因）
17. **真因不是"constructor 崩溃"，而是 C++ 名字修饰导致的 dylib 加载失败**：
    `PullOverX.mm` 是 **ObjC++**，它调用没有 `extern "C"` 声明的跨文件 C 函数时，编译器生成的是
    C++ 修饰名。实测 0.1.3 产物的未定义符号：
    ```
    __Z9MFLogRawCPKc            ← MFLogRawC(char const*)
    __Z19MFRingPickerInstallv   ← MFRingPickerInstall()
    ```
    而 `MFDebugLog.m` / `MFRingPicker.m` 导出的是 C 名字 `_MFLogRawC` / `_MFRingPickerInstall`
    → **dyld 解析不到 → 拒绝加载整个 dylib** → 桌面手柄消失、日志文件不生成、圆盘装不上。
    （0.1.2 也是同一个原因：constructor 里调用了 `MFLog`。）
18. **修复**：prefix header 里把所有共享 C 接口用 `extern "C"` 包裹
    （`MFLogRawC` / `MFRingPickerInstall` / `MFLog`）。
    ⚠️ 新增校验步骤：每次构建后**解析 dylib 符号表**，确认不含 `__Z` 形式的自有未定义符号
    （已列入本项目的交付前检查）。
19. 与 MultiFloat 时期"给 Swift 调的 C 头必须 extern C"是同一条铁律：**任何被 .mm 调用的 C 接口都要 extern "C"**。

## 0.1.5 改动（圆盘几何修复：整圆显示 + 图标缩小）
20. **修复「只有半圆显示、另一半在屏幕外」**：0.1.4 及以前把圆心放在**屏幕边缘**
    （贴右缘时 `center.x = screenWidth`），于是半径 150 的圆有一半落在屏幕外。
    现在圆心内缩：`centerX = screenWidth - radius - mfRingEdgeMargin`（默认边距 12），
    **整圆完整显示在屏幕内**，背景由半圆路径改为完整椭圆路径。
21. **图标绕整圈排布**：360° 均匀分布，起点 `mfRingStartAngle`（默认 -90° = 正上方），
    仍受 `mfRingRotation` 整体旋转；图标半径 = `radius - iconSize/2 - 6`（外沿贴近圆周不越界）。
22. **图标默认缩小**：`mfRingIconSize` 56 → **44**（用户反馈偏大）。
23. 新增配置键：`mfRingEdgeMargin`(12)、`mfRingStartAngle`(-90)。
24. 实测确认（0.1.4 日志）：dylib 加载成功；圆盘在**全屏 App（设置）之上可正常呼出**；
    手柄位置跟随生效（关闭态屏幕 x=391..425 贴右缘 → 打开态 361..395 移到面板右侧）。

## 0.1.6 改动（圆盘交互重做：跟随手指 → 停靠下半屏中心 → 悬停选择 → 松手即开）
25. **只保留手势呼出**：去掉贴边触发区上的 `UITapGestureRecognizer`。
    0.1.5 及以前"在边缘点一下"就会弹出圆盘（日志里成片的 `触发区单击 -> 呼出圆盘`），
    用户反馈这属于"点击手柄呼出"，要去掉；现在**只有向内滑动 > `mfRingSummonThreshold`（默认 18pt）**才呼出。
    （边缘的**单击不再有任何作用**；`onTriggerTap:` 已删除。）
26. **圆盘不再固定在屏幕正中心**：新增停靠点概念 `parkCenter` = **屏幕下半屏中心**
    （`screenWidth/2, screenHeight × mfRingParkRatioY`，默认 0.72）；圆心一律**夹在合法范围内**
    （整圆不出屏 且 圆心 y ≥ 屏幕中线，即只在下半屏）。
27. **呼出后跟随手指**：`showAtPoint:` 以手指当下的**屏幕坐标**为圆盘初始圆心；
    手指继续滑动时 `moveRingToPoint:` 让圆盘实时跟着手指走（受上述夹取约束）。
    为此把圆盘做成一个固定尺寸的 `ringRoot` 容器（圆形底盘 + 图标都画在它的局部坐标里），
    "移动圆盘"退化成只改 `ringRoot.center` —— 不再每次都重建视图。
28. **停靠（固定）判定**（两种任一命中即固定，固定后手指再滑动只改变"选中"）：
    - 手指进入停靠点 `mfRingLatchTolerance`（默认 72pt）范围内 → 立刻固定；
    - 手指停住 `mfRingSettleDelay`（默认 0.18s）没有新事件 → 自动固定。
    固定时带 0.16s 缓动落到停靠点，并打印 `圆盘已固定到下半屏中心 (x, y)`。
29. **悬停选择**：固定后每次手指移动都算一次"离手指最近的图标"，
    命中半径 = `iconSize × 0.95 + 14`（44pt 图标 ≈ 56pt）；命中者放大 1.18 倍 + 提亮描边，
    日志打印 `悬停选中 <bundleID>` / `悬停离开（当前无选中）`。
30. **手指离开屏幕 = 确认**：`UIGestureRecognizerStateEnded` 时若已选中 App →
    自动收起圆盘并 `pinAppWithBundleId:` + `open` 以浮窗打开；未选中 → 只收起。
    （直接点图标 `onIconTapped:` 的老入口保留，作为停靠后单点操作的后备；
    拖动过程中图标收不到触摸，因为整段触摸归属贴边触发区，不会与抬手逻辑重复触发。）
31. 新增配置键：`mfRingParkRatioY`(0.72)、`mfRingLatchTolerance`(72)、`mfRingSettleDelay`(0.18)、
    `mfRingSummonThreshold`(18)。
32. 顺带把每帧 `dx/dy` 的刷屏日志去掉（0.1.5 日志一次滑动上千行），
    改为只打印关键状态：呼出（起点→停靠点）、固定、悬停选中变化、松手结果。

## 0.1.7 改动（修复「从右下边缘触发圆盘 → SpringBoard 自动注销且不进安全模式」）
33. **症状与证据**：0.1.6 日志里，每次 `[ring] 贴边按下 ...` 之后**再没有任何圆盘日志**，
    紧接着出现新的 `===== 日志会话开始 =====`（0.4~0.5s 后）——即 SpringBoard 被硬重启。
    由于 `MFLog` 是无缓冲写入（`setvbuf _IONBF`），最后一条日志一定在盘上，
    所以崩溃点必然落在 `贴边按下` 与 `展开完成` 之间，也就是 `showRingWithAnchor:` 的同步构建段。
    对 0.1.5（可用版本）与 0.1.6 逐行 diff 后，该区间内**唯一新增的实质动作**是：
    ① 手腕内的窗口几何改动（展开时把窗口 frame 从"触发条"改成全屏）；
    ② 把 SB 最近使用列表里的 bundleID **未经校验**直接交给 `SBIconModel` / `IconServices` 取图标。
34. **修复一：窗口始终全屏，命中交给 `hitTest`（PullOver 同款"点透"模型）**。
    `MFRingWindow` 覆写 `hitTest:withEvent:`：收起态只认「贴边触发条」，条外一律返回 `nil`
    （触摸点透给下层 App / 桌面）；展开态整窗接管。
    窗口 frame 在 `install` 时一次定好（全屏），**展开/收起全程不再改动窗口几何**，
    只切换标志位与子视图 —— 0.1.5/0.1.6 那种"在手势进行中改窗口 frame"的扰动彻底消失。
35. **修复二：bundleID 必须校验后才能喂给图标系统**。
    SB 的最近使用列表里混有 `SBDisplayItem` 的标识符（形如 `com.xxx:default`）与其他非 App 字符串；
    把它们交给 `SBIconModel` / IconServices 取图标会**硬崩 SpringBoard**
    （`os_crash`/`trap`，不是 `NSException`，`@try` 抓不住 → 现象正是"一触发就注销、却不进安全模式"）。
    现在 `MFRingIsUsableBundleId()` 只放行：字符串、非空、不含 `:`/空格/`/`、
    且通过 `+[POApplicationHelper isUserFacingApplicationBundleId:]`（`SBApplicationController` 认可的真 App）。
    配置的 `ringApps` 同样走这套校验（防止一个坏值把 SB 拖崩）。
    取图标改为 `MFRingIconForBundleId()`：先查进程内缓存 → 再调用 → 失败退化为首字母图标；
    原始候选按 `mfRingMaxIcons × 3` 多取，过滤后截断，保证圆盘里仍是满的。
36. **修复三：展开改为下一轮 runloop 构建**（`buildGeneration` 代次 + `pendingBuild` 闸门）。
    不再在手势回调里同步建视图/查 App/取图标；期间若被收起则代次作废。
37. **可归因的步骤日志**：构建路径改为 `>>> 步骤` / `<<< 步骤 ok` 配对输出
    （放行展开 / 建容器 / 建圆盘 / 取圆盘内容 / 取图标 <bundleID> / 图标铺好 / 展开完成），
    万一还有崩溃，日志最后一行就能指出是哪一步、哪个 bundleID。
38. **几何兜底**：所有进入几何计算的数值经 `MFRingSafe()` 过滤（NaN/Inf 一律回退），
    杜绝 NaN frame 这种会直接带走渲染服务器的输入；早期返回也全部留痕（不再静默早退）。

## 0.1.8 改动（根治「右下边缘一滑就黑屏注销」—— 触摸路径与 SpringBoard 私有数据彻底解耦）
39. **症状仍在 + 事实链复盘**：0.1.7 之后用户反馈仍是"右下边缘滑动就黑屏注销"。
    把三份源码放在一起逐行比对后得到关键事实：
    - **0.1.3 真机日志（17:53）证明**：同一份"取最近使用 App + 取图标"的代码当时**是跑得通的**
      （`圆盘已展开：5 个 App`、`选中 com.tencent.xin -> 打开浮窗`）；
    - 0.1.3 → 0.1.5 的 diff 只有几何/图标尺寸等**纯绘制**改动，不可能是元凶；
    - 0.1.5 → 0.1.6 在触摸路径上新增的也全是纯数学与视图结构。
    ⇒ 结论：崩溃点是**数据相关**的，而不是某一行代码写错。
    嫌疑路径落在 `+[POApplicationHelper recentAppsWithCount:]`：它对
    `SBMainSwitcherViewController / SBFluidSwitcherViewController / SBAppSwitcherModel …`
    这些多任务切换器对象做 **KVC 递归遍历**（`displayItems`/`allItems`/`items`/`application`… 深度 4），
    而"切换器里当前有哪些卡片"每时每刻都在变 —— 遍历到某个对象组合时会踩到
    **不可捕获的 trap**（`@try` 无效），恰好表现为"一滑就注销、不进安全模式"。
    **反证就摆在 Stheno 里**：Stheno 的圆盘内容来自 `AppSearcher`/`AppCellVew`（遍历**已安装应用**），
    根本不去翻切换器模型 —— 这就是我们要的实证答案。
40. **改造一：圆盘内容改用"扁平枚举已安装 App"**。
    新增 `MFRingEnumerateInstalledBundleIds()`：只拿一个 App 对象数组，
    逐个读 `bundleIdentifier` / `displayIdentifier` / `applicationIdentifier`（全部包 `@try`），
    **绝不使用 `valueForKey:` 对切换器对象图做递归遍历**。
    数据源优先 `SBApplicationController.sharedInstance.allApplications`，
    退化到 `LSApplicationWorkspace.defaultWorkspace.allInstalledApplications`。
41. **改造二：触摸路径零 SpringBoard 查询**。
    新增 `MFRingBundleIds()`，只读「配置 `ringApps`」或「进程内缓存 `gMFRingAutoBundleIds`」，
    **绝不查 SB**。缓存由 `scheduleAutoBundleIdEnumeration()` 在**安装后延后 0.6s** 执行一次，
    成功后落盘到 `ringAppsAuto`（下次启动直接载入，连枚举都不用做）。
    用户显式配置的 `ringApps` 优先级最高，配置过就完全跳过枚举。
42. **改造三：图标也移出触摸路径**。
    圆盘先用**首字母占位**铺好并显示出来，之后由 `scheduleIconFillWithGeneration:` 延后把真图标贴上去；
    每个图标都有 `>>> 取图标 <id>` / `<<< 取图标 <id> ok=是/否` 日志，真出问题能点名到具体 App。
    可用 `mfRingFetchIcons=false` 完全关掉图标抓取。
43. **改造四：崩溃自解除闸门（关键安全网）**。
    新增 `/var/mobile/PullOverMF.ringguard`：**危险动作（枚举 App / 抓图标）前立标记，
    整趟走完并存活才撤**（沿用项目既有铁律：绝不按时间无条件清）。
    `install` 时若发现标记还在 ⇒ 上回就是被这一步带走的 ⇒
    **自动进入降级模式**：不再枚举、不再抓图标，只用配置/缓存 + 首字母图标，
    并打印醒目告警。删掉该文件即可重新尝试。
    **这样最坏情况是"圆盘朴素但可用"，绝不会陷入"一滑就注销"的死循环。**
44. **改造五：触发条避开底部手势区**。
    `mfTriggerLength` 默认 380 → **300**，并新增 `mfTriggerBottomInset`（默认 44）——
    触发条任何情况下都离屏幕底边至少 44pt，不再与"主屏手势（Home Indicator）"区重叠。
45. 其他：窗口 / 容器 / 触发条统一 `opaque = NO`；`mfRingMaxIcons` 上限 12；
    降级模式下圆盘中央的提示文案会明确写出"当前为降级模式"。

## 待办（用户指定的下一版）
46. **悬浮窗四周贴边手势区**（用户已说明"先不要推进"→ 暂缓）：在浮窗四周加贴边热区用于移动/缩放浮窗
    （PullOver 已有 `applyCardScaleTarget:` 可做缩放；移动需接卡片的垂直锚点机制）。
    依据：0.1.5 日志已实证「全屏 App 之上，屏幕边缘区仍能收到本 tweak 窗口的触摸」；
    0.1.7 的 `hitTest` 点透模型进一步保证了"窗口全屏也不会挡住系统手势"。

47. 后续改动（UI/交互/分屏能力）将逐条记录在此。
