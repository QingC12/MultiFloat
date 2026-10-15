//
//  MFRingPicker.m
//  PullOverMF —— Stheno 风格「圆盘」呼出选择器（本 fork 新增）
//
//  ============================ 0.3.0 核心改动（用户指定）============================
//  圆盘手势逻辑**一处未动**（0.2.14 交互已获"非常完美"确认）。本版只做两件事：
//  ① **动画全面弹簧化（借鉴 Stheno）**：Stheno 逆向实证（analysis/stheno-ring-gesture-study.md）
//     其圆盘手感来自贯穿全场的 spring 弹性（`CustomSpringAnimation`/阻尼系数可配）+
//     选中图标缩放（`_scaleToIcon`/`_selected`）+ SwiftUI scale/opacity 过渡。落地：
//       · 呼出：0.15s 纯淡入 → 55% 缩放弹性放大 + 淡入（damping 0.68，0.45s）；
//       · 滑选图标：0.12s 线性 1.18 → 弹性放大 1.25（damping 0.5，明显过冲回弹），
//         滑走弹簧缩回（damping 0.65）；
//       · 停靠：0.16s ease-out → 弹簧滑入（damping 0.72，0.42s）；
//       · 收起：0.15s 淡出 → 缩小 0.7 + 淡出（0.18s，干脆收场）。
//     全部用公开 API animateWithDuration:usingSpringWithDamping:（iOS 7+），无私有依赖。
//  ② **右下侧呼出手势条改窄**：mfTriggerThickness 默认 56 → 28（用户实测"太宽，容易
//     误触"）。呼出主力是系统边缘手势（识别器区域 20pt + 带门外扩 60pt），判定不受影响。
//
//  ============================ 0.2.15 核心改动（log20 用户反馈）============================
//  0.2.14 交互已获用户确认"非常完美"，圆盘手势逻辑冻结不再动。本轮只删一个不合理行为：
//  **松手回退打开**——0.2.12 引入的"松手点无选中时，回退开时间窗内最近悬停选中的 App"
//  （releaseOpenBundleIdForPoint: 的②号分支）被用户实测否定：呼出圆盘后手势结束时停在
//  圆盘外，会自动打开一个 App，"很不合理"。按用户要求移除：
//    · 松手点压在图标上（实时选中还在）→ 照旧打开；
//    · 松手在圆盘外 / 无选中 → **只关闭圆盘，不打开任何应用**。
//  同步清理：lastSelectedBundleId / lastSelectionStamp 属性、applySelectionToButton 里的
//  记录逻辑、showAtPoint 里的重置、mfRingReleaseOpenWindow 配置键全部移除（无死代码）。
//  三条松手路径（onStripPan / mfEdgeSlid / onRingHoverPan）走同一函数，自动统一生效。
//
//  ============================ 0.2.14 核心改动（按用户硬性要求重做交互）============================
//  用户指定目标流程：手势呼出 → **跟随手指**到下半屏中心固定 → 手指不离开屏幕滑动选应用
//  （任意方向的图标都要能高亮）→ 手指离开屏幕 = **圆盘关闭 + 选中的应用以悬浮窗打开**。
//
//  ① **找到"只有右边能滑动选中"的真正元凶（自查代码发现，不是系统问题）**：
//     `mfEdgeSlid:` 在**展开后仍然要求触摸位置落在触发带 ±60pt 内**才处理 —— 呼出后
//     手指滑向圆盘左/上/下（离开触发带），事件全被自己丢掉 ⇒ 悬停只对右缘侧图标生效。
//     修法：**展开后去掉带门**——跟随/停靠/悬停/松手在全屏任意位置都处理；
//     带门只保留在"未展开"阶段（决定是否认领一次贴边触摸，防止误抢中部手势）。
//  ② **恢复跟随阶段**（撤销 0.2.13 的"呼出即停靠"）：呼出后圆盘跟随手指，
//     进停靠容差（72pt）或停顿 0.18s 才固定 —— 与桌面触发条路径一致。
//  ③ **松手必关圆盘**（撤销 0.2.13 的"无选中保留"）：松手时当前选中优先、
//     5 秒内最近悬停选中次之（0.2.12 回退，log19 实证 4 次全部成功打开），
//     都没有 = 直接收起。完整还原"松手 = 关圆盘 + 开应用"。
//
//  ============================ 0.2.13 核心改动 ============================
//  ① **呼出即停靠（log18 实证：0.2.12 回退窗口差 0.275 秒没够着 + 悬停事件流离边即断）**：
//     边缘手势的触摸流只在手指贴近边缘一带时可靠，手指滑到圆盘左/上/下后事件就断
//     （用户实证"只有右边能滑动选中"）—— 这是系统手势路由的固有行为，识别器层面修不了。
//     对策：**呼出那一刻直接把圆盘固定到停靠点**（跳过跟随阶段），后续交互不再依赖
//     呼出触摸的后续事件：圆盘停在那儿，用户直接点图标（直接点击）或用新触摸滑动
//     （onRingHoverPan，0.2.9），或继续用呼出触摸滑（事件还活着时照常悬停）。
//  ② **松手回退窗口 2.0 → 5.0 秒**：log18 实测"最后选中 48.432 → 松手 50.707"间隔
//     2.275 秒，刚好超出 2.0 秒窗口 0.275 秒 → 没回退 → 收起。5 秒覆盖真实操作节奏。
//  ③ **松手无选中不再收起圆盘**：保留在屏幕上（点空白/点图标才有下一步），用户
//     可以直接用新触摸继续选——消灭"手指离开屏幕后必须重新呼出"的挫败感。
//
//  ============================ 0.2.12 核心改动 ============================
//  ① **"松手即打开"最终修（log17 实证：桌面/全屏都要二次点击）**：
//     0.2.11 已修好 App 跟着滚，但松手仍常"未选中"。日志给出决定性规律：
//     边缘手势驱动的会话（桌面呼出现在也走它——`贴边松手未达阈值` 后紧跟
//     `>>> 系统手势呼出`），**松手点总是已经离开圆盘、回到边缘一带**
//     （(406,720)/(420,744) 都在触发条区域内），此时当前选中早已被清空
//     ⇒ "未选中，收起"。用户预期 = 松手时打开**刚才高亮过的**那个 App。
//     修法：新增 `releaseOpenBundleIdForPoint:` —— 松手时①当前选中优先；
//     ②无选中则回退开 `mfRingReleaseOpenWindow`（默认 2.0 秒）内最近悬停
//     选中的 App（`lastSelectedBundleId`，在 applySelectionToButton 里记录，
//     悬停离开不清除；每次呼出重置）。三条松手路径（onStripPan / mfEdgeSlid /
//     onRingHoverPan）统一走它。超过时间窗 = 用户早已移开另做他事 → 照旧收起。
//
//  ============================ 0.2.11 核心改动 ============================
//  ① **全屏"松手即打开"攻坚（log16 + 用户硬性要求：全屏操作逻辑必须和桌面一样）**：
//     log16 实证桌面已完美（20+ 条悬停流、松手即开），但全屏悬停事件稀疏、
//     松手常无选中。用户观察到决定性线索：**拖着圆盘时全屏 App 页面也跟着滚动** ——
//     0.2.8 给边缘识别器设的 `cancelsTouchesInView=NO` 让系统把触摸**同时**喂给
//     前台 App（App 滚动 = 触摸被分流），我们这边的识别器事件流被饿死。
//     修法：改回 **cancelsTouchesInView=YES**（识别器 Began 即独占触摸：
//     App 不再滚动、事件流完整 —— triggr 默认值，iOS 15~18 实证无此问题）。
//     桌面不受影响：长按编辑器靠"静止按下识别器 Possible 不拦截"；
//     触发条 pan 与边缘识别器双驱动本就幂等。
//  ② mfEdgeSlid: 增加 Began / Cancelled / Failed 诊断日志（下轮若仍有问题直接点名）。
//
//  ============================ 0.2.10 核心改动 ============================
//  ① **"松手即打开"可靠性修复（log15 实证 + 用户：全屏要和桌面一个逻辑，松手自动打开）**：
//     全屏下"悬停选中 → 几十毫秒后悬停离开 → 松手未选中收起"的元凶是
//     `updateSelectionForPoint:` 的**防误开 22pt 守卫**：停靠瞬间手指的位置
//     （latchFingerPoint）经常就在右侧图标 22pt 范围内（停靠点在下半屏中心、
//     呼出拖动路径恰好经过那一带），于是用户故意悬停在图标上的选中被守卫
//     反复清掉 —— 只有拖动残留选中恰好"活着"到松手那一下才会打开。
//     修法：**守卫只在首次"真移开"前生效** —— 一旦手指移出 22pt（用户真的开始
//     选择了），立即解除守卫（hasLatchFinger=NO），之后的微动/回移不再清选中。
//     防误开的本意（刚停靠时手指停在原地不算选）完整保留。
//
//  ============================ 0.2.9 核心改动 ============================
//  ① **全屏 App 内圆盘交互修复（log14 实证）**：0.2.8 后全屏呼出/固定都成功，
//     但"只能选择右侧部分图标、且要二次点击才打开"。两个根因：
//     a) 悬停选择只靠"呼出那次触摸"驱动（onStripPan 收不到、边缘识别器只盖边缘区），
//        展开容器自己**没有**任何手势驱动悬停 —— 中屏触摸只走按钮"直接点击"，
//        滑动手势完全无效 ⇒ 离右缘远的图标全都没反应；
//     b) 选中要靠呼出拖动的残留 + 再补一次真实点按 = 用户说的"需要二次点击"。
//     修法：**给展开容器挂一个悬停平移手势**（cancelsTouchesInView=YES）：
//     · 点按图标 → 手势保持 Possible，按钮照常 TouchUpInside =「直接点击」打开；
//     · 拖动（无论起点在圆盘哪里）→ 手势 Began → 按钮触摸被取消（不会误开），
//       驱动 跟随/停靠/悬停选中/松手打开 —— 与呼出路径完全无关，
//       **触摸能落到圆盘哪里，哪里就能交互**（桌面/全屏同一套）。
//     这同时恢复了"呼出后用新触摸长距离拖动圆盘"的能力。
//
//  ============================ 0.2.8 核心改动 ============================
//  ① **边缘手势呼出后圆盘"卡死"修复（log13 实证）**：
//     0.2.7 边缘手势**注册与呼出全部成功**（6 次呼出全中），但呼出后圆盘既不能跟随
//     也不能点图标 —— 根因：**呼出的那次触摸被系统手势识别器吃掉了**，它不会送到
//     `onStripPan:`（旧路径的全部交互都靠那个手势的触摸流驱动）。于是圆盘停在
//     "跟随手指"状态等一个永远不会来的触摸：不跟随、不停靠（日志里没有"圆盘已固定"）、
//     没有悬停选中；圆盘还卡在呼出点（夹取后靠右缘），用户去底部中心点 = 点空白收起。
//     修法：**让边缘手势识别器自己驱动完整交互** —— 它本来就持续收到那次触摸的
//     Began/Changed/Ended，把 `onStripPan:` 的同一套逻辑（跟随 → 进停靠容差或停顿 →
//     固定 → 悬停选中 → 松手打开/收起）搬进 `mfEdgeSlid:`，哪条路径抢到触摸就走哪套。
//  ② 识别器补 `cancelsTouchesInView=NO / delaysTouchesBegan=NO`：尽最大努力不干扰
//     桌面旧触发条路径（长按编辑器入口靠它，静止按下时识别器仍在 Possible 不拦截）。
//
//  ============================ 0.2.7 核心改动 ============================
//  ① **全屏 App 呼出圆盘 —— 换「SBSystemGestureManager 系统边缘手势」路线（triggr 实证）**：
//     0.2.5 的 Stheno 5 个候选手势类在 iOS 17.3.1 **全部不存在**（log11/12 实证），
//     而"SpringBoard 普通窗口在全屏 App 活跃时收不到屏幕触摸"（归档 38）是死结。
//     本版改用 **SpringBoard 系统手势管理器**（triggr 开源实证 iOS 15~18 同一实现、
//     覆盖 App 上/桌面/锁屏）：
//       · `SBSystemGestureManager.mainDisplayManager` 拿到管理器；
//       · `UIScreenEdgePanGestureRecognizer` 用 SpringBoard 同款私有 init
//         `-initWithTarget:action:type:options:`（type=2，真手指才认，合成触摸不认）；
//       · `[manager addGestureRecognizer:rec withType:0x7467000]`（自定义 type 号，
//         远离系统自己的 type 数字）；`_setEdgeRegionSize:20` 收窄起手区；
//       · 系统手势 hook 的两个放行开关（`_isGestureWithTypeAllowed:` /
//         `_shouldEnableSystemGestureWithType:`，在 PullOverX.mm）对自定义 type 直接放行。
//     只有触点落在**配置的贴边触发带 ±60pt 内**才接管呼出，带外立即 Failed 原样放行；
//     沿边滑出 ≥ `mfRingEdgePanDistance`（默认 40pt）即呼出圆盘。
//     兜底：即使 `_init` hook 没触发，启动 10 秒后再尝试安装一次（幂等）。
//     崩溃自解除沿用 gestureguard（见 PullOverX.mm）。
//
//  ============================ 0.2.6 核心改动 ============================
//  ① **编辑器过滤改用「桌面图标模型」判据（用户：又出现很多白图标/系统组件，
//     "只显示桌面图标，或设置中显示的 APP"）**：
//     0.2.5 按"取不到图标"过滤**实际一个都没滤掉**（日志实证：跳过无图标 0 个）—— 根因：
//     兜底路径 `UIImage _applicationIconImageForBundleIdentifier:format:scale:` 对**任何**
//     bundleID 都生成占位图标，系统组件也被判成"有图标"。
//     新判据 `MFRingHasHomeScreenIcon()` = `SBIconModel applicationIconForBundleIdentifier:`
//     非 nil —— **桌面上真的有它的图标**（与 PullOver 真图标同一条路，本机已验证）；
//     系统组件/插件不在这张表里 ⇒ 白图标从源头滤掉；设置/电话/信息等桌面系统 App 保留。
//     模型不可用时放行（宁多勿杀，只损失过滤），模型查询带进程内缓存。
//
//  ============================ 0.2.5 核心改动 ============================
//  ① **等距双圈求解（用户：内圈少、外圈多，两圈都不许出现巨大空隙）**：
//     对每个候选内圈个数 n_in 求 r_out：等距（r_in=r_out×n_in/n_out）+ 内圈塞得下
//     （r_in ≥ 1.15×icon）+ 外圈间距 ≤ 1.6×step，取外圈间距最小的解；单圈同样
//     收缩到间距 ≤ 1.6×step；底盘随**实际**外圈半径重画（否则图标缩在底盘里）。
//     （0.2.4 的"内圈先铺满"排出过 外7/内9，用户反馈不协调，已废。）
//  ② **图标尺寸按数量分档、不再随圆盘缩放**：≤12→44 / 13~20→40 / 21~24→36（基准
//     `mfRingIconSize`），间距不缩 —— 用户："图标太小了，要自适应圆盘大小"。
//  ③ **编辑器找回系统应用**：0.2.4 按 `applicationType` 过滤 System 是误伤（设置/电话/
//     信息也是 System，191 个全被踢）。改判据：只按"取不到图标"过滤。
//  ④ hook 目标改造见 PullOverX.mm：`SBReachabilityGestureRecognizer/_handlePullGesture:`
//     在 iOS 17.3.1 **不存在**（0.2.4 日志实证"不注册"）→ 改为按 Stheno 清单**多候选探测
//     注册**（存在哪个注册哪个），hook 内只在触点落在贴边触发带±60pt 时接管并呼出，
//     其余原样放行。
//
//  ============================ 0.2.4 核心改动 ============================
//  ① **宿主窗口默认退回 POXWindow**（`mfRingHostWindow` 默认 2 → **0**）。
//     0.2.3 实测（用户日志 log8）：找到的是 `SBStatusBarReusePoolWindow`（**level=0 的全屏窗口**），
//     我们塞进去的全屏覆盖层让这扇窗口的命中判定变成"触摸黑洞"—— 带内呼出正常，
//     **带外把桌面的触摸全吃掉 ⇒ 桌面无法滑动**（UIWindow 默认 hitTest 在所有子视图都不接时
//     返回窗口自身，SB 事件路由便认为这个点归这扇窗口）。方案保留可用（设 2 强行开），
//     但默认关闭，不再作为全屏 App 呼出的指望。
//  ② **系统手势呼出（唯一新增 hook，在 PullOverX.mm）**：hook `SBReachabilityGestureRecognizer
//     _handlePullGesture:`（便捷访问手势 = 屏幕底部边缘下滑；Stheno 实证路线）。
//     手势触发时若 `MFRingWantsSystemGestureSummon()` 允许 → 呼出圆盘并吞掉本次便捷访问；
//     否则原样放行。需要用户在 设置>辅助功能>触控 打开"便捷访问"（识别器才活跃）。
//     带**崩溃自解除**标记（/var/mobile/PullOverMF.gestureguard：注册前立标记、存活 20s 自动撤；
//     下次启动见标记则本轮不注册，删除文件可重试）。
//  ③ **缩放锚点按用户要求重定**（阶梯+线性）：count < 8 → 50%；count < 16 → 75%；
//     16~23 线性 75% → 100%；count ≥ 24 → 100%（`mfRingScaleCountLow/Base/High` 默认 8/16/24，
//     `mfRingScaleBase` 默认 0.85 → 0.75）。
//  ④ **多圈分配方向反转（用户指定）**：**内圈先铺满**，内圈装不下才往外圈填；
//     外圈只剩 1~2 个时从内圈匀上来凑 3 个。
//  ⑤ **应用编辑器过滤（用户反馈"好多白图标/应用不完整/混进系统里打不开的应用"）**：
//     · 过滤系统组件：`LSApplicationProxy.applicationType` 含 "User" 才进列表；
//     · 过滤无图标应用：取不到图标（`MFRingIconForBundleId` = nil）的不显示 —— 白图标的根源；
//     · 用户已选的 `ringApps` 无论过滤结果如何**强制可见**；
//     · 过滤后才截断到 200 上限（不再"先截断后过滤"导致漏 App）。
//
//  ============================ 0.2.3 核心改动 ============================
//  ① **宿主窗口改为「状态栏窗口」**（`mfRingHostWindow`，默认 2=自动优先，1=强制，0=只用 POXWindow）。
//     为什么（**实证，不是猜**）：归档 38 的证据表里，**挂在 `SBStatusBarWindow` 里的热区（tag 990042）
//     在全屏 App 活跃时收到过 3 次触摸**，而同一时刻 SB 自己普通窗口里的 8 个抓手一次都没收到 ——
//     两者唯一的差别就是"挂在哪个窗口"。Stheno 的字符串里同样是 `UIStatusBarWindowHook` +
//     `_statusBarGroup`（把视图挂进状态栏窗口，而不是自建普通窗口）。
//     ⇒ 所以本轮不再往 POXWindow 里挂，而是**优先把触发条+圆盘挂进状态栏窗口**（零 hook：
//       运行时扫窗口找它；找不到/不是全屏就自动退回 POXWindow，行为与 0.2.2 相同，不会更难用）。
//     ⚠️ 状态栏窗口的 hitTest 由我们的 `MFRingHostOverlayView` 接管：只认触发带/圆盘，**其余返回 nil 点透**，
//        所以状态栏、手柄、面板一切照旧（nil 会让 UIKit 继续问下一扇窗口）。
//  ② **圆盘大小随 App 数量自适应**（用户要求）：数量少 → 小、数量多 → 大。
//     `mfRingScaleMin`(0.50) / `mfRingScaleBase`(0.85) / `mfRingScaleMax`(1.00) 三个锚点，
//     由 `mfRingScaleCountLow`(4) / `CountBase`(14) / `CountHigh`(22) 做分段线性插值；
//     缩放同时作用于**半径 / 图标尺寸 / 间距**，即"整个圆盘等比大小"。
//     关键实现点：几何的容量目标从"固定 24"改成**实际数量** —— 否则半径会被自动放大到能装 24 个，
//     缩放就白做了（`MFRingComputeGeometry(bounds, count)`）。
//  ③ `[ring][diag]` 增加**宿主窗口类名**、并新增安装时**全窗口清单日志**（类名/level/尺寸/可见），
//     下次日志一眼就能看到"到底有没有找到状态栏窗口、它多大"。
//
//  ============================ 0.2.2 核心改动 ============================
//  ① **圆盘容量 16 → 24**（`mfRingMaxIcons` 默认 24）。做法不是"把图标挤小"，而是
//     `MFRingComputeGeometry()` 反向求解：先用配置半径算容量，装不下 24 就按 4% 步进
//     放大**有效外圈半径**（上限 = 底盘不出屏），底盘/视图尺寸跟着一起长。
//  ② **两圈排布重做（用户反馈"无论外圈还是内圈间隔都很大"）**：
//     · 分配：**外圈先铺满**，剩余才开内圈（0.2.1 按周长比例分 ⇒ 16 个时 外10/内6，
//       两圈都只填一半、弧上间隔 30pt+，正是"间隔很大"的来源）；内圈只剩 1~2 个时
//       从外圈匀到 3 个，免得单图标孤零零贴着圆心。
//     · 半径：内圈半径**按个数自适应** `r_in = R_out × (n_in / n_out)`（下限 0.42×外圈，
//       上限 = 规划半径），让两圈"弧上间距"一致 ⇒ 视觉上密度均匀。
//     · 图标间距 `mfRingIconGap` 默认 8 → 6（同半径下容量 +1~2，24 个刚好排满）。
//  ③ **停靠点下移**：`mfRingParkRatioY` 默认 0.72 → **0.78**（用户："固定后还是有点靠上"）。
//  ④ **呼出阈值 18 → 12pt**：贴着屏幕边缘时手指横向余量小，阈值太高容易在呼出前松手。
//  ⑤ **触摸到达诊断**（`[ring][diag]`，0.25s 最多一行）：记录"带内/临带"的触摸是否到达
//    我们窗口 + 当时的窗口状态。用于一次定性"全屏 App 内贴边滑动到底有没有触摸到我们"。
//  ⑥ 触发条几何说明（**重要背景**）：归档 38 / 第 42 轮定论 —— 全屏 App 活跃时，
//     SpringBoard 自己 scene 的普通视图拿不到"屏幕中间区域"的触摸，只有**屏幕边缘 /
//     状态栏这些系统保留区**仍会路由到 SB 的视图。所以：
//       · 右/左边缘条 x 紧贴屏幕边（已是如此）；
//       · **下边缘条改成贴死屏幕底边**（bottomInset 默认 0）——底部主屏手势带同为系统保留区，
//         是"零 hook 也盼着能在全屏 App 上收到触摸"的最后一块可用地（`mfTriggerEdge=bottom`）。
//     若 diag 证明"连贴边都没有触摸到达"，下一步只能走系统手势路线
//     （hook SBReachabilityGestureRecognizer / SBGrabberTongue，见
//      analysis/stheno-ring-gesture-study.md 第四节）。
//
//  ============================ 0.2.1 核心改动 ============================
//  ① **圆盘变双圈**（`mfRingRings` 默认 2）：图标沿「外圈 + 内圈」两层同心圆排布，
//     容量 `mfRingMaxIcons` 默认 8 → **16**（上限 24），外/内圈按各自周长按比例分图标，
//     内圈半径 = 外圈半径 × `mfRingInnerRatio`(0.62)。装得下时才用一圈（自动收敛）。
//  ② **用户自选圆盘 App（本轮重点）**：`MFRingPicker` 新增一个**全屏应用编辑器**。
//     · 入口：**长按贴边触发条约 0.7 秒**（不改动"贴边左滑呼出圆盘"的手势）。
//     · 面板：网格列出**全部已安装 App**（图标 + 中文名），点击即加入/移出圆盘，
//       「完成」把结果写入 `ringApps` 并立刻生效（下次呼出即为新列表）。
//     · 为什么不做 Stheno 那种「设置」面板：Stheno 用独立 `SthenoPreference.bundle`
//       （SwiftUI + PSListController），需要在「设置」里改完再 respring；本 fork 改成
//       **在 SpringBoard 里直接编辑**，改完即时可见，零 respring。
//     · 内容来源优先级：`ringApps`（**用户写过就用它，哪怕写的是空数组**）> `ringAppsAuto`。
//  ③ 图标默认尺寸维持 44pt；新增 `mfRingIconGap`(8) 参与"每圈能放几个"的间距估算。
//
//  ============================ 0.2.0 核心改动 ============================
//  **找到并修掉"边缘一滑就黑屏注销"的唯一根因：属性 setter 死递归。**（见第 1179 行注释）
//
//  病根：本文件既声明 `@property (nonatomic, weak) UIButton *selectedButton;`，
//        又手写了一个同名方法 `- (void)setSelectedButton:(UIButton *)button`，
//        而该方法内部执行 `self.selectedButton = button;`。
//        Objective-C 里属性赋值会被编译成 `objc_msgSend(self, @selector(setSelectedButton:), v)`，
//        于是它调用了**自己** → 无限递归 → 栈溢出 → SIGSEGV。
//        SIGSEGV **抓不住**（不是 NSException）、**不进安全模式**，SpringBoard 当场死 → 黑屏注销。
//
//  证据链（四版全中，且只有这四版）：
//    · 0.1.6 / 0.1.7 / 0.1.8 / 0.1.9 都新增了 `selectedButton` 属性 + 同名 setter，
//      且 `showRing…/showAtPoint:` 第一段都有一句 `self.selectedButton = nil;`；
//      0.1.5（唯一正常版）根本没有这个属性。
//    · 0.1.9 真机日志：`>>> 呼出圆盘` **有**、紧接着的 `>>> 建容器` **没有** ——
//      而 `self.selectedButton = nil;` 正是第 806 行，恰好夹在这两条日志之间。逐字吻合。
//    · 每次滑动必挂（确定性）、耗时极短（栈溢出是毫秒级）、无崩溃弹窗 —— 全部符合特征。
//
//  修法：自定义方法改名 `applySelectionToButton:`，内部**写 ivar** `_selectedButton`。
//  防线：新增 `scripts/setter_check.py`，任何"手写 setXxx: 与同名属性撞车"直接拦下。
//
//  ⚠️ 归因更正：0.1.9 曾把病因记成"自建窗口抢屏幕边缘触摸"，那是**误判**。
//     四版崩溃与窗口模型（自建窗口 / 全屏窗口 / 挂到 POXWindow）无关。
//     （0.1.9 改用 PullOver 窗口这件事本身是好事：少一扇窗口、少一层风险，故保留。）
//
//  ======================== 0.1.9 保留的架构 ==============================
//  **不自建 UIWindow**：圆盘与触发条挂在 PullOver 自己那扇窗口（POXWindow）上。
//  触摸路径：
//    POXWindow.hitTest:
//      → MFRingHitTestViewForWindowPoint()
//          ├─ 圆盘展开态 → 返回容器里最深的那层（图标按钮可直接点）或容器本身
//          ├─ 收起态、点落在贴边触发条内、且不在 PullOver 手柄上 → 返回 stripView
//          └─ 其余 → nil（原样交回 PullOver 控制器，既有行为零改变）
//  ======================================================================
//
//  设计依据（逆向自 Stheno 0.1.23，com.nx.stheno）：
//    · 圆盘本体：RingView / RingShape / RingType；文案 'RTSIF'=圆盘 / 'RTSIH'=半圆盘
//      几何键：Radius / IconWidth / RotationAngle / LastIconAngle / DampingFraction
//    · 圆盘内容：Stheno 走**应用搜索器**（遍历已安装 App），**不是**翻多任务切换器模型
//    · 呼出方式：Stheno 走"系统手势 hook + 既有宿主窗口"，所以全屏 App 之上也能呼出
//
//  交互（沿用 0.1.6 用户指定的形态）：
//    ① 贴边手势呼出后圆盘**跟随手指**；
//    ② 手指停住 / 靠近停靠点 → 圆盘**固定到屏幕下半屏中心**；
//    ③ 手指滑动 → 高亮离手指最近的图标（悬停选择）；
//    ④ **手指离开屏幕** → 收起圆盘；已选中 App → 立即以浮窗打开。
//
//  铁律（继续保持）：
//    · 触摸路径零 SpringBoard 查询：圆盘内容只读配置 / 进程内缓存；
//    · 真图标延后贴（圆盘先出来，图标随后补），每个图标 `>>> 取图标` / `<<<`；
//    · 崩溃自解除闸门 `/var/mobile/PullOverMF.ringguard`：危险动作前立、走完且存活才撤；
//      下次启动若发现标记还在 ⇒ 自动**降级模式**（不枚举不抓图标），删文件可重试；
//    · 全程 `>>> 步骤` / `<<< 步骤 ok`，万一还出问题，日志最后一行直接点名。
//
//  配置项（suite com.mlgm.pulloverx，改完 respring 生效）：
//    mfRingEnabled      BOOL   是否启用圆盘（默认 YES）
//    mfTriggerEdge      string 触发边：right(默认) / left / top / bottom
//    mfTriggerLength    number 触发区长度（默认 0 = 屏高 30%；显式设置 >0 生效，下限 80）
//    mfTriggerThickness number 触发区厚度（0.3.0 默认 28；0.2.x 曾 56，用户反馈太宽易误触）
//    mfTriggerCenterRatio number 触发区中心位置 0~1（默认 0.78）
//    mfTriggerBottomInset number 触发区距屏幕底边最少留白（默认 44；bottom 边默认 0 = 贴死底边）
//    mfRingSummonThreshold number 手势呼出阈值，pt（默认 12）
//    mfRingRadius       number 圆盘半径基准（默认 150；会随数量缩放、装不下时再自动放大）
//    mfRingIconSize     number 图标尺寸基准（默认 44；同样随数量缩放）
//    mfRingEdgeMargin   number 圆盘外沿距屏幕边的间距（默认 12）
//    mfRingRotation     number 图标整体旋转角，度（默认 0）
//    mfRingStartAngle   number 第一个图标的角度，度（默认 -90 = 正上方）
//    mfRingParkRatioY   number 停靠点纵向比例（默认 0.78 = 下半屏偏下）
//    mfRingLatchTolerance number 手指靠近停靠点多少 pt 即固定（默认 72）
//    mfRingSettleDelay  number 手指停住多久自动固定，秒（默认 0.18）
//    mfRingRings        number 圆盘圈数 1~3（默认 2；装得下时自动收敛为 1 圈）
//    mfRingInnerRatio   number 内圈半径比例上限 0.35~0.95（默认 0.62，仅多圈时生效）
//    mfRingIconGap      number 图标间距估算值，pt（默认 6；越大每圈能放越少）
//    mfRingMaxIcons     number 圆盘最多显示几个（默认 24，上限 24）
//    mfRingHostWindow   number 圆盘/触发条的宿主窗口：**0=只用 PullOver 窗口（0.2.4 默认）** /
//                              2=自动优先状态栏窗口 / 1=强制状态栏窗口
//                              （⚠️ 0.2.3 实测状态栏窗口路线会挡桌面滑动，仅供试验）
//    mfRingScaleMin     number 图标少时圆盘缩放下限（默认 0.50 = 50%）
//    mfRingScaleBase    number 常规数量的缩放基数（默认 0.75 = 75%）
//    mfRingScaleMax     number 图标多时的缩放上限（默认 1.00 = 100%）
//    mfRingScaleCountLow  number 数量 < 此值 → 用 mfRingScaleMin（默认 8）
//    mfRingScaleCountBase number 数量 < 此值 → 用 mfRingScaleBase（默认 16；此后线性涨到上限）
//    mfRingScaleCountHigh number 数量 ≥ 此值 → 用 mfRingScaleMax（默认 24）
//    mfRingGestureSummon BOOL  是否接管"便捷访问"手势呼出圆盘（默认 YES；hook 在 PullOverX.mm，
//                              关掉则系统手势原样放行）
//    mfRingEdgePanDistance number 0.2.8 系统边缘手势沿边滑出多少 pt 呼出圆盘（默认 40）
//    mfRingFetchIcons   BOOL   是否抓取真图标（默认 YES；关掉就只用首字母）
//    ringApps           array  bundleID 数组（**你自己指定圆盘内容，最优先**；
//                              长按边缘触发条打开编辑器即会写入这里）
//    ringAppsAuto       array  自动枚举出的 App 列表（本 fork 自己维护，别手改）
//
//  版本备注：0.1.4 及以前圆心在屏幕边缘（半圆出屏）；0.1.5 整圆可见；0.1.6 交互重做；
//  0.1.7 全屏窗口 + hitTest 点透；0.1.8 触摸路径零 SB 查询 + 图标延后 + 崩溃降级；
//  0.1.9 删掉自建窗口，改挂 PullOver 既有窗口（POXWindow，保留）；
//  0.2.0 修掉四版崩溃的真凶 —— setter 死递归（见文件头 0.2.0 段）；
//  0.2.1 双圈布局 + 圆盘应用编辑器（长按边缘触发条打开，自己挑 App）；
//  0.2.2 容量 24 + 两圈"外圈铺满 / 内圈自适应半径" + 停靠点下移 + 触摸到达诊断（diag）；
//  **0.2.3 宿主优先挂「状态栏窗口」（全屏 App 里也能收到触摸，见文件头 0.2.3 段）
//        + 圆盘大小随 App 数量自适应（50% / 85% / 100%）+ 全窗口清单诊断日志。
//  **0.2.4 宿主默认退回 POXWindow（状态栏窗口实测挡桌面滑动）+ 系统手势呼出
//        （hook SBReachabilityGestureRecognizer，唯一新增 hook，带崩溃自解除）
//        + 缩放锚点 8/16/24（50%/75%/100%）+ 内圈先铺满 + 编辑器过滤系统/无图标应用。**
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "POXWindow.h"
#import "PullOverViewController.h"
#import "POHandle.h"
#import "POApplicationHelper.h"

#define MF_RING_GUARD_PATH   "/var/mobile/PullOverMF.ringguard"

// 【0.2.1】圆盘应用编辑器（全屏网格）
#define MF_RING_EDITOR_TAG       991010   // 面板根视图
#define MF_RING_EDITOR_SCROLL    991011   // 滚动容器
#define MF_RING_EDITOR_ICON      991012   // cell 里的图标视图
#define MF_RING_EDITOR_LABEL     991013   // cell 里的名称标签
#define MF_RING_EDITOR_CHECK     991014   // cell 右上角"已选"角标
#define MF_RING_EDITOR_DONE      991015   // 「完成」按钮
#define MF_RING_EDITOR_MAX_APPS  200      // 编辑器最多列出多少个 App（防爆）

static char kMFRingBundleIdKey;

#pragma mark - 配置读取

static NSUserDefaults *MFRingDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverx"];
        if (defaults == nil) {
            defaults = [NSUserDefaults standardUserDefaults];
        }
    });
    return defaults;
}

static double MFRingNumber(NSString *key, double fallback) {
    id value = [MFRingDefaults() objectForKey:key];
    if (value == nil) {
        return fallback;
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double number = [value doubleValue];
        return isfinite(number) ? number : fallback;
    }
    return fallback;
}

static BOOL MFRingBool(NSString *key, BOOL fallback) {
    id value = [MFRingDefaults() objectForKey:key];
    if (value == nil) {
        return fallback;
    }
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return fallback;
}

static NSString *MFRingEdge(void) {
    NSString *edge = [MFRingDefaults() stringForKey:@"mfTriggerEdge"];
    if (![edge isKindOfClass:[NSString class]] || edge.length == 0) {
        return @"right";
    }
    return edge.lowercaseString;
}

/// 数值兜底：任何 NaN/Inf 都不允许进入几何计算（NaN frame = 渲染服务器直接带走进程）
static CGFloat MFRingSafe(CGFloat value, CGFloat fallback) {
    return isfinite(value) ? value : fallback;
}

#pragma mark - 崩溃自解除闸门（纯 C 文件 IO）

/// 危险动作（枚举 App / 抓图标）执行前立标记；动作**走完并存活**才撤。
/// 下次启动若发现标记还在 ⇒ 上回就是被这一步带走的 ⇒ 进入降级模式，绝不死循环。
static BOOL MFRingGuardArmed(void) {
    FILE *file = fopen(MF_RING_GUARD_PATH, "rb");
    if (file == NULL) {
        return NO;
    }
    fclose(file);
    return YES;
}

static void MFRingGuardArm(void) {
    FILE *file = fopen(MF_RING_GUARD_PATH, "wb");
    if (file != NULL) {
        fputs("1\n", file);
        fclose(file);
    }
}

static void MFRingGuardDisarm(void) {
    remove(MF_RING_GUARD_PATH);
}

#pragma mark - 进程内状态

static NSArray<NSString *> *gMFRingAutoBundleIds = nil;   // 自动枚举结果（进程内缓存）
static BOOL gMFRingListing = NO;                          // 枚举进行中
static NSUInteger gMFRingListGeneration = 0;              // 枚举代次
static BOOL gMFRingDegraded = NO;                         // 降级模式（上回被危险动作带走过）

#pragma mark - bundleID 校验

/// 是否是"可以喂给图标系统"的 bundleID。
/// ⚠️ SB 的最近使用列表里混有 SBDisplayItem 标识符（形如 "com.tencent.xin:default"）与
///    非 App 的字符串；把它们交给 SBIconModel / IconServices 会硬崩 SpringBoard。
static BOOL MFRingIsUsableBundleId(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *bundleId = (NSString *)value;
    if (bundleId.length == 0 || bundleId.length > 160) {
        return NO;
    }
    if ([bundleId rangeOfString:@":"].location != NSNotFound) {
        return NO;   // SBDisplayItem: "bundle:role"
    }
    if ([bundleId rangeOfString:@" "].location != NSNotFound) {
        return NO;
    }
    if ([bundleId rangeOfString:@"/"].location != NSNotFound) {
        return NO;
    }
    if ([bundleId rangeOfString:@"\n"].location != NSNotFound) {
        return NO;
    }
    return YES;
}

/// 过滤 + 去重（纯字符串处理，不查 SB）
static NSArray<NSString *> *MFRingFilterBundleIds(id raw, NSUInteger limit) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) {
        return ids;
    }
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *bundleId = (NSString *)item;
        if (!MFRingIsUsableBundleId(bundleId) || [ids containsObject:bundleId]) {
            continue;
        }
        if (limit > 0 && ids.count >= limit) {
            break;
        }
        [ids addObject:bundleId];
    }
    return ids;
}

#pragma mark - 已安装 App 的安全枚举

/// 取对象上的一个字符串属性的第一个可用值（全部包 @try）
static NSString *MFRingStringProperty(id object, NSArray<NSString *> *selectorNames) {
    if (object == nil) {
        return nil;
    }
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return (NSString *)value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

/// 取对象上的一个数组属性的第一个可用值（全部包 @try）
static NSArray *MFRingArrayProperty(id object, NSArray<NSString *> *selectorNames) {
    if (object == nil) {
        return nil;
    }
    for (NSString *name in selectorNames) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
                return (NSArray *)value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

/// 安全枚举已安装 App：**只做扁平遍历**，逐个读 bundleIdentifier。
/// 绝不对多任务切换器对象图做 KVC 递归遍历（那是 0.1.6 崩溃的嫌疑路径）。
static NSArray<NSString *> *MFRingEnumerateInstalledBundleIds(NSUInteger limit) {
    NSArray *candidates = nil;

    // 主路径：SBApplicationController（SpringBoard 自己的 App 注册表）
    @try {
        Class controllerClass = NSClassFromString(@"SBApplicationController");
        id controller = nil;
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        if (controllerClass && [controllerClass respondsToSelector:sharedSelector]) {
            controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
        }
        candidates = MFRingArrayProperty(controller, @[ @"allApplications", @"applications" ]);
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! SBApplicationController 枚举异常：%@", exception);
        candidates = nil;
    }

    // 备路径：LSApplicationWorkspace（LaunchServices）
    if (candidates.count == 0) {
        @try {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            id workspace = nil;
            SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
            if (workspaceClass && [workspaceClass respondsToSelector:defaultSelector]) {
                workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
            }
            candidates = MFRingArrayProperty(workspace, @[ @"allInstalledApplications", @"allApplications" ]);
        } @catch (NSException *exception) {
            MFLog(@"[ring] !! LSApplicationWorkspace 枚举异常：%@", exception);
            candidates = nil;
        }
    }

    MFLog(@"[ring] <<< 枚举原始对象 %lu 个", (unsigned long)candidates.count);

    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id application in candidates) {
        if (limit > 0 && ids.count >= limit) {
            break;
        }
        @try {
            NSString *bundleId = MFRingStringProperty(application,
                @[ @"bundleIdentifier", @"displayIdentifier", @"applicationIdentifier" ]);
            if (!MFRingIsUsableBundleId(bundleId) || [ids containsObject:bundleId]) {
                continue;
            }
            [ids addObject:bundleId];
        } @catch (__unused NSException *exception) {
        }
    }
    return ids;
}

#pragma mark - 圆盘内容（触摸路径上只读缓存，绝不查 SB）

/// 圆盘最多显示几个（0.2.2：默认 16 → 24 —— 用户要求"圆盘总量 24"）
static NSUInteger MFRingMaxIcons(void) {
    return (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingMaxIcons", 24.0), 1.0), 24.0);
}

/// 用户是否**亲手设置过**圆盘内容。写过（哪怕写的是空数组）就必须尊重用户的选择，
/// 不再回落到自动枚举 —— 否则"我把圆盘清空"会变成"又冒出一堆你不想要的 App"。
static BOOL MFRingUserListSet(void) {
    return ([MFRingDefaults() objectForKey:@"ringApps"] != nil);
}

/// 你手动指定的圆盘内容（配置 ringApps）—— 纯字符串过滤，不查 SB
static NSArray<NSString *> *MFRingConfiguredBundleIds(void) {
    return MFRingFilterBundleIds([MFRingDefaults() arrayForKey:@"ringApps"], 0);
}

/// 最近一次算出的圆盘内容数量（0.2.3：几何缩放要用它；触摸路径上零开销）
static NSUInteger gMFRingCount = 0;

/// 圆盘最终内容：**用户配置 > 自动枚举缓存 > 空**。只读内存 / NSUserDefaults。
static NSArray<NSString *> *MFRingBundleIds(void) {
    NSUInteger limit = MFRingMaxIcons();
    NSArray<NSString *> *result = @[];
    if (MFRingUserListSet()) {
        // 写过就以用户为准（空数组 ⇒ 圆盘空，显示"长按边缘添加"提示）
        NSArray<NSString *> *configured = MFRingConfiguredBundleIds();
        result = (configured.count > limit) ? [configured subarrayWithRange:NSMakeRange(0, limit)]
                                            : configured;
    } else if (gMFRingAutoBundleIds.count > 0) {
        result = (gMFRingAutoBundleIds.count > limit)
            ? [gMFRingAutoBundleIds subarrayWithRange:NSMakeRange(0, limit)]
            : gMFRingAutoBundleIds;
    }
    gMFRingCount = result.count;   // 【0.2.3】记录数量 —— 几何缩放与夹取都用它
    return result;
}

/// App 的中文/本地化名称（取不到就退化成 bundleID 末段）。全部包 @try。
static NSString *MFRingDisplayNameForBundleId(NSString *bundleId) {
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        return @"?";
    }
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, bundleId);
            for (NSString *name in @[ @"localizedShortName", @"localizedName", @"itemName" ]) {
                SEL selector = NSSelectorFromString(name);
                if (![proxy respondsToSelector:selector]) {
                    continue;
                }
                id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    return (NSString *)value;
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return [bundleId lastPathComponent];
}

/// 编辑器用的"全部已安装 App"列表：数组元素 = @{ @"id": bundleID, @"name": 显示名 }。
/// 只用扁平枚举（见 MFRingEnumerateInstalledBundleIds），按显示名排序。
/// ⚠️ 会查 SB 私有数据 ⇒ 调用方必须自己 `MFRingGuardArm/Disarm`。
///
/// 【0.2.6 修正】0.2.5 按"取不到图标"过滤**实际一个都没滤掉**（日志实证：跳过无图标 0 个）。
/// 根因：图标的兜底路径 `UIImage _applicationIconImageForBundleIdentifier:format:scale:`
/// 对**任何** bundleID（含系统组件）都返回占位图标 ⇒ "有没有图标"这个判据永远为真。
/// 新判据：**桌面图标模型**（用户："只显示桌面图标，或设置中显示的 APP"）——
///   `MFRingHasHomeScreenIcon()` = `SBIconModel applicationIconForBundleIdentifier:` 非 nil；
///   与 PullOver 真图标同一条路（本机验证可用）。设置/电话/信息在桌面上有图标，保留；
///   系统组件/插件不在 ⇒ 白图标从源头滤掉。
/// 前置声明（实现在下方"图标缓存"段）
static BOOL MFRingHasHomeScreenIcon(NSString *bundleId);

static NSArray<NSDictionary<NSString *, NSString *> *> *MFRingInstalledAppsForEditor(NSUInteger limit) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    // ① 用户已选的优先入列（强制可见，不做桌面过滤 —— 用户亲手选的必须出现）
    for (NSString *bid in MFRingConfiguredBundleIds()) {
        if (MFRingIsUsableBundleId(bid) && ![ids containsObject:bid]) {
            [ids addObject:bid];
        }
    }
    // ② 枚举全部安装项（limit=0 不截断），过滤后再截断
    NSArray<NSString *> *enumerated = MFRingEnumerateInstalledBundleIds(0);
    NSUInteger offDesktopSkipped = 0;
    for (NSString *bundleId in enumerated) {
        if (limit > 0 && ids.count >= limit) {
            break;
        }
        if ([ids containsObject:bundleId]) {
            continue;
        }
        @try {
            // 【0.2.6】桌面图标模型过滤：桌面上没有它的图标 ⇒ 不显示（白图标/系统组件的根源）
            if (!MFRingHasHomeScreenIcon(bundleId)) {
                offDesktopSkipped++;
                continue;
            }
            [ids addObject:bundleId];
        } @catch (__unused NSException *exception) {
        }
    }
    MFLog(@"[ring] 编辑器过滤：跳过非桌面应用 %lu 个，入列 %lu 个",
          (unsigned long)offDesktopSkipped, (unsigned long)ids.count);
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *apps = [NSMutableArray array];
    for (NSString *bundleId in ids) {
        NSString *name = MFRingDisplayNameForBundleId(bundleId);
        [apps addObject:@{ @"id": bundleId, @"name": (name.length > 0 ? name : bundleId) }];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return apps;
}


/// 把自动枚举结果固化：进程内缓存 + 落盘到 ringAppsAuto（下次启动免枚举）
static void MFRingStoreAutoBundleIds(NSArray<NSString *> *ids) {
    gMFRingAutoBundleIds = [ids copy];
    NSUserDefaults *defaults = MFRingDefaults();
    [defaults setObject:ids ?: @[] forKey:@"ringAppsAuto"];
    MFLog(@"[ring] ringAppsAuto 已保存 %lu 项", (unsigned long)ids.count);
}

static void MFRingWriteBundleIds(NSArray<NSString *> *ids) {
    NSUserDefaults *defaults = MFRingDefaults();
    [defaults setObject:ids ?: @[] forKey:@"ringApps"];
    MFLog(@"[ring] ringApps 已保存 %lu 项", (unsigned long)ids.count);
}

#pragma mark - 图标缓存

/// 图标缓存（进程内；respring 后重建）。减少对 SBIconModel / IconServices 的重复调用。
static NSMutableDictionary<NSString *, UIImage *> *MFRingIconCache(void) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

/// 取图标。调用方负责日志与闸门；这里只保证"不合法一律不查、异常一律降级为 nil"。
static UIImage *MFRingIconForBundleId(NSString *bundleId) {
    if (!MFRingIsUsableBundleId(bundleId)) {
        return nil;
    }
    UIImage *cached = MFRingIconCache()[bundleId];
    if (cached != nil) {
        return cached;
    }
    UIImage *icon = nil;
    @try {
        icon = [POApplicationHelper imageForBundleId:bundleId];
    } @catch (NSException *exception) {
        icon = nil;
    }
    if (icon != nil) {
        MFRingIconCache()[bundleId] = icon;
    }
    return icon;
}

/// 【0.2.6】该 bundleID 是否在**桌面图标模型**里（= 桌面上真的有它的图标）。
/// 用户要求："编辑器只显示桌面图标，或设置中显示的 APP"。
/// 判据 = `SBIconModel applicationIconForBundleIdentifier:` 非 nil —— 与 PullOver 真图标
/// 走同一条路（SBIconController.sharedInstance -> iconModel/model，本机验证可用）。
/// ⚠️ 不能用 `UIImage _applicationIconImageForBundleIdentifier:format:scale:` 当判据 ——
///    它对**任何** bundleID 都生成占位图（0.2.5"跳过无图标 0 个"的根因）。
/// 结果带进程内缓存（一次打开编辑器要判 200+ 个）；模型不可用时**放行**（宁多勿杀，
/// 只损失过滤，不让整个列表消失）。⚠️ 会查 SB 私有数据，调用方必须在 guard 闸门内。
static BOOL MFRingHasHomeScreenIcon(NSString *bundleId) {
    if (!MFRingIsUsableBundleId(bundleId)) {
        return NO;
    }
    static NSMutableSet<NSString *> *gMFRingHomeScreenCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMFRingHomeScreenCache = [NSMutableSet set];
    });
    if ([gMFRingHomeScreenCache containsObject:bundleId]) {
        return YES;
    }
    @try {
        Class controllerClass = NSClassFromString(@"SBIconController");
        id controller = controllerClass
            ? ((id (*)(id, SEL))objc_msgSend)(controllerClass, NSSelectorFromString(@"sharedInstance"))
            : nil;
        if (controller == nil) {
            return YES;   // 模型不可用：放行（宁多勿杀）
        }
        SEL modelSelector = NSSelectorFromString(@"iconModel");
        if (![controller respondsToSelector:modelSelector]) {
            modelSelector = NSSelectorFromString(@"model");   // iOS 26 之前叫 model
        }
        if (![controller respondsToSelector:modelSelector]) {
            return YES;
        }
        id model = ((id (*)(id, SEL))objc_msgSend)(controller, modelSelector);
        SEL iconSelector = NSSelectorFromString(@"applicationIconForBundleIdentifier:");
        if (model == nil || ![model respondsToSelector:iconSelector]) {
            return YES;
        }
        id icon = ((id (*)(id, SEL, id))objc_msgSend)(model, iconSelector, bundleId);
        if (icon != nil) {
            [gMFRingHomeScreenCache addObject:bundleId];
            return YES;
        }
        return NO;
    } @catch (__unused NSException *exception) {
        return YES;   // 查询本身出异常：放行，不做误杀
    }
}

#pragma mark - 圆盘几何（0.2.3）

/// 【0.2.2】圆盘几何：由配置统一算出"有效外圈半径 / 底盘半径 / 视图半边长 / 圈数"。
///
/// 为什么需要"有效半径"：**容量**（能放几个图标）只由外圈半径与图标间距决定，
/// 而用户要"圆盘总量 24 个"——配置半径(150)+图标(44)+间距(8) 时 两圈只有 23 个位置。
/// 于是这里反过来算：先用配置半径求容量，不够就按 4% 步进放大半径，
/// 上限是屏幕内安全值（底盘 + 图标外沿不出屏）。这样 `mfRingMaxIcons=24` 一定装得下。
///
/// 【0.2.3 重要】容量目标从"固定 24"改成**实际数量 `count`**，并乘以 `scale`：
///   数量少时圆盘整体变小（半径/图标/间距一起缩），数量多时才长大 —— 即用户要的
///   "圆盘大小随着添加应用数量而变大变小"。若仍按 24 求容量，半径会被自动放大到能装 24 个，
///   缩放就完全失效（这是本轮最容易踩的坑）。
/// 几何是"触摸路径无关"的纯计算，只读配置。
typedef struct {
    CGFloat outerRadius;   // 最外圈图标圆心所在半径
    CGFloat dialRadius;    // 底盘（深色圆）半径
    CGFloat extent;        // ringRoot 半边长（含图标外沿余量）
    CGFloat iconSize;      // 图标直径
    CGFloat step;          // 同圈相邻图标的最小圆心距（= 图标宽 + 间距）
    CGFloat innerRatio;    // 内圈 / 外圈 的固定比例（上限）
    NSUInteger rings;      // 实际可用圈数（>= 1）
    CGFloat scale;         // 【0.2.3】整体缩放（由数量决定，1.0 = 配置原尺寸）
    NSUInteger count;      // 【0.2.3】本次几何是按几个图标算的
} MFRingGeometry;

/// 【0.2.5】图标尺寸**按数量分档**（不再乘圆盘缩放 —— 用户："图标太小了，要自适应"）：
///   数量少 → 图标大（看得清），数量多 → 图标略小（挤得下）。默认基准 44。
///   ≤12 个 → 44pt；13~20 个 → 40pt；21~24 个 → 36pt。
static CGFloat MFRingIconSizeForCount(NSUInteger count) {
    CGFloat base = MAX(24.0, MFRingNumber(@"mfRingIconSize", 44.0));
    if (count <= 12) {
        return base;
    }
    if (count <= 20) {
        return MAX(30.0, base - 4.0);
    }
    return MAX(30.0, base - 8.0);
}

/// 【0.2.4】"几个 App ⇒ 圆盘多大"（按用户要求重定锚点，阶梯 + 线性）：
///   count <  CountLow  (默认 8)  → Min  (0.50)
///   count <  CountBase (默认 16) → Base (0.75)
///   CountBase ≤ count < CountHigh(默认 24) → 线性 Base → Max
///   count ≥ CountHigh → Max (1.00)
/// 端点值都做了合法性夹取（min ≤ base ≤ max，锚点递增），配置写错也不会算出 NaN/负半径。
static CGFloat MFRingScaleForCount(NSUInteger count) {
    CGFloat lo = MIN(MAX(MFRingNumber(@"mfRingScaleMin", 0.50), 0.20), 1.00);
    CGFloat base = MIN(MAX(MFRingNumber(@"mfRingScaleBase", 0.75), lo), 1.00);
    CGFloat hi = MIN(MAX(MFRingNumber(@"mfRingScaleMax", 1.00), base), 1.00);
    NSUInteger nLow = (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingScaleCountLow", 8.0), 1.0), 24.0);
    NSUInteger nBase = (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingScaleCountBase", 16.0), (CGFloat)nLow), 24.0);
    NSUInteger nHigh = (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingScaleCountHigh", 24.0), (CGFloat)nBase), 24.0);
    CGFloat n = (CGFloat)count;
    if (n < (CGFloat)nLow) {
        return lo;
    }
    if (n < (CGFloat)nBase) {
        return base;
    }
    if (n >= (CGFloat)nHigh) {
        return hi;
    }
    CGFloat t = (n - (CGFloat)nBase) / MAX((CGFloat)(nHigh - nBase), 1.0);
    return base + (hi - base) * t;
}

/// 缩放纯文本（日志用）：`19个 -> 94%`
static NSString *MFRingScaleDescription(NSUInteger count) {
    return [NSString stringWithFormat:@"%lu个 -> %.0f%%（下限%.0f%% 基数%.0f%% 上限%.0f%%）",
            (unsigned long)count, MFRingScaleForCount(count) * 100.0,
            MIN(MAX(MFRingNumber(@"mfRingScaleMin", 0.50), 0.20), 1.00) * 100.0,
            MIN(MAX(MFRingNumber(@"mfRingScaleBase", 0.75), 0.20), 1.00) * 100.0,
            MIN(MAX(MFRingNumber(@"mfRingScaleMax", 1.00), 0.20), 1.00) * 100.0];
}

static MFRingGeometry MFRingComputeGeometry(CGRect bounds, NSUInteger count) {
    MFRingGeometry geo = (MFRingGeometry){ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1, 1.0, 0 };

    // 【0.2.3】容量目标 = 本次真实数量（夹到 [1, mfRingMaxIcons]）
    NSUInteger want = MIN(MAX(count, (NSUInteger)1), MFRingMaxIcons());
    CGFloat scale = MFRingScaleForCount(want);
    geo.count = want;
    geo.scale = scale;

    CGFloat radius = MAX(60.0, MFRingNumber(@"mfRingRadius", 150.0)) * scale;
    // 【0.2.5】图标尺寸按数量分档、不随圆盘缩放（用户："图标太小了"）；间距固定不缩
    CGFloat iconSize = MFRingIconSizeForCount(want);
    CGFloat gap = MAX(0.0, MFRingNumber(@"mfRingIconGap", 6.0));
    CGFloat innerRatio = MIN(MAX(MFRingNumber(@"mfRingInnerRatio", 0.62), 0.35), 0.95);
    NSUInteger desiredRings = (NSUInteger)MIN(MAX(MFRingNumber(@"mfRingRings", 2.0), 1.0), 3.0);
    NSUInteger targetCap = want;

    CGFloat step = MAX(iconSize + gap, 1.0);
    CGFloat outer = MAX(iconSize, radius - iconSize * 0.5 - 6.0);

    CGFloat half = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)) * 0.5;
    if (half <= 0.0) {
        half = 215.0;
    }
    CGFloat maxDial = MAX(60.0, half - 8.0);                 // 底盘不出屏
    CGFloat maxOuter = MAX(outer, maxDial - iconSize * 0.5 - 6.0);

    for (NSUInteger guard = 0; guard < 60; guard++) {
        CGFloat sum = 0.0;
        CGFloat r = outer;
        for (NSUInteger ring = 0; ring < desiredRings; ring++) {
            if (ring > 0) {
                r *= innerRatio;
                if (r < iconSize * 1.15) {
                    break;
                }
            }
            sum += floor((2.0 * M_PI * r) / step);
        }
        if ((NSUInteger)sum >= targetCap || outer >= maxOuter) {
            break;
        }
        outer = MIN(outer * 1.04 + 0.5, maxOuter);
    }

    geo.outerRadius = outer;
    geo.dialRadius = outer + iconSize * 0.5 + 6.0;
    geo.extent = geo.dialRadius + iconSize * 0.5 + 10.0;
    geo.iconSize = iconSize;
    geo.step = step;
    geo.innerRatio = innerRatio;

    NSUInteger rings = 0;
    CGFloat r = outer;
    for (NSUInteger ring = 0; ring < desiredRings; ring++) {
        if (ring > 0) {
            r *= innerRatio;
            if (r < iconSize * 1.15) {
                break;
            }
        }
        if ((NSUInteger)floor((2.0 * M_PI * r) / step) < 1) {
            break;
        }
        rings++;
    }
    geo.rings = MAX(rings, (NSUInteger)1);
    return geo;
}

/// 拿"当前内容数量"算几何（触摸路径上的夹取用；数量由 MFRingBundleIds 记录）
static MFRingGeometry MFRingCurrentGeometry(CGRect bounds) {
    return MFRingComputeGeometry(bounds, gMFRingCount);
}

#pragma mark - 触摸到达诊断（0.2.2）

/// 【0.2.2 诊断】"触摸到底有没有到达我们窗口"—— 一次测试就能定性的关键日志。
///
/// 归档 38 的定论是：**全屏 App 活跃时，SB 自己 scene 的普通视图在"屏幕中间区域"收不到触摸**。
/// 如果下一次日志里，在 App 内贴边滑动时**一条 `[ring][diag]` 都没有**，
/// 就证明"连贴边也拿不到触摸" ⇒ 只能走系统手势路线（hook SBReachability/GrabberTongue，
/// 见 analysis/stheno-ring-gesture-study.md）。
/// 反之如果有 diag 行却没呼出，就说明是阈值/几何判定问题，改配置即可。
///
/// 只在"触发带内、或距带 40pt 内"记，且 0.25s 最多一条 —— 不刷屏、不影响触摸路径性能。
static void MFRingDiagTouch(CGPoint point, CGRect band, UIWindow *window) {
    static CFTimeInterval lastDiag = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastDiag < 0.25) {
        return;
    }
    lastDiag = now;
    if (window == nil) {
        return;
    }
    CGRect full = window.bounds;
    CGFloat nearestEdge = MIN(MIN(point.x, point.y),
                              MIN(MAX(CGRectGetWidth(full) - point.x, 0.0),
                                  MAX(CGRectGetHeight(full) - point.y, 0.0)));
    MFLog(@"[ring][diag] 触摸到达宿主窗口 屏幕(%.0f,%.0f) 距最近屏边 %.0fpt 带内=%@ 带=%@ | "
          @"窗口=%@ level=%.0f hidden=%d 交互=%d hiddenRC=%d 键窗口=%d",
          point.x, point.y, nearestEdge,
          CGRectContainsPoint(band, point) ? @"是" : @"否",
          NSStringFromCGRect(band),
          NSStringFromClass([window class]), window.windowLevel,
          (int)window.hidden, (int)window.userInteractionEnabled,
          (int)window.rootViewController.view.hidden,
          (int)window.isKeyWindow);
}

#pragma mark - 宿主窗口选择（0.2.3：优先"状态栏窗口"）

/// 【0.2.3】把当前所有窗口打一份清单（类名 / level / 尺寸 / 可见）—— 只读、只在安装时打一次。
/// 下次日志里一眼能看出"有没有找到状态栏窗口、它多大、我们的窗口在哪一层"。
static void MFRingLogWindowInventory(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSArray<UIWindow *> *windows = (app != nil) ? app.windows : nil;
        MFLog(@"[ring] 窗口清单（共 %lu 扇）：", (unsigned long)windows.count);
        NSUInteger index = 0;
        for (UIWindow *w in windows) {
            if (++index > 16) {   // 只打前 16 扇，避免刷屏
                MFLog(@"[ring]   ...（其余略）");
                break;
            }
            MFLog(@"[ring]   [%lu] %@ level=%.0f frame=%@ hidden=%d 交互=%d",
                  (unsigned long)index, NSStringFromClass([w class]), w.windowLevel,
                  NSStringFromCGRect(w.bounds), (int)w.hidden,
                  (int)w.userInteractionEnabled);
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] 窗口清单异常：%@", exception);
    }
}

/// 【0.2.3】取"屏幕全尺寸的窗口列表"（优先状态栏窗口）。只用**公开**入口：
/// `UIApplication.windows`；拿不到再退一步试私有的
/// `+[UIWindow _allWindowsIncludingInternalWindows:onlyVisibleWindows:]`（先 respondsToSelector + @try）。
/// ⚠️ 不 hook 任何东西 —— 用户明令"前期不要多个 hook，确保不卡开机"。
static NSArray<UIWindow *> *MFRingAllScreenWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    @try {
        NSArray<UIWindow *> *regular = [UIApplication sharedApplication].windows;
        if ([regular isKindOfClass:[NSArray class]]) {
            [result addObjectsFromArray:regular];
        }
    } @catch (__unused NSException *exception) {
    }
    // 私有兜底：包含"内部窗口"（状态栏窗口往往只在这个列表里）
    @try {
        Class windowClass = [UIWindow class];
        SEL internalSelector = NSSelectorFromString(@"_allWindowsIncludingInternalWindows:onlyVisibleWindows:");
        if ([windowClass respondsToSelector:internalSelector]) {
            NSArray *internal = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(windowClass,
                                                                             internalSelector, YES, NO);
            if ([internal isKindOfClass:[NSArray class]]) {
                for (UIWindow *w in internal) {
                    if ([w isKindOfClass:[UIWindow class]] && ![result containsObject:w]) {
                        [result addObject:w];
                    }
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return result;
}

/// 【0.2.3】找状态栏窗口。实证依据（归档 38 证据表）：
///   挂在 `SBStatusBarWindow` 里的热区（tag 990042）在**全屏 App 活跃时收到过 3 次触摸**，
///   而同一时刻 SB 自己普通窗口里的 8 个抓手一次都没收到 —— 差别只在"挂在哪个窗口"。
///   Stheno 里同样是 `UIStatusBarWindowHook` + `_statusBarGroup`（挂状态栏窗口，不自建普通窗口）。
/// 判定：类名含 "StatusBar"，且**尺寸接近全屏**（否则挂上去也覆盖不到屏幕右侧的触发带）。
static UIWindow *MFRingFindStatusBarWindow(CGRect screenBounds, BOOL requireFullScreen) {
    CGFloat minHeight = CGRectGetHeight(screenBounds) * 0.9;   // 必须几乎全屏，否则右侧触发带会落在它外面
    UIWindow *fallback = nil;
    for (UIWindow *w in MFRingAllScreenWindows()) {
        @try {
            NSString *name = NSStringFromClass([w class]);
            if (name.length == 0 || ![name containsString:@"StatusBar"]) {
                continue;
            }
            if (CGRectGetHeight(w.bounds) >= minHeight) {
                return w;
            }
            if (fallback == nil) {
                fallback = w;   // 尺寸不够也记着（强制模式用）
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return requireFullScreen ? nil : fallback;
}

#pragma mark - 宿主覆盖层：接管状态栏窗口的 hitTest（点透）

/// 覆盖层：加在**宿主窗口的最上层**，只把"触发带 / 圆盘"的触摸留下，其余**返回 nil 点透**。
///
/// 为什么需要它：状态栏窗口原本的 hitTest 只会问它自己的子视图；我们的条是**最后加的子视图**，
/// 于是 UIKit 一定先问我们 —— 我们返回 nil 就等于"这一下不是我"，UIKit 继续问下一扇窗口
/// （状态栏、POXWindow、手柄、面板全部照旧）。全程零 hook。
@interface MFRingHostOverlayView : UIView
@end

/// 覆盖层的命中入口（在 MFRingPicker 实现之后定义；这里先声明）
UIView *MFRingHitTestViewForHostPoint(UIWindow *window, CGPoint point);

#pragma mark - 圆盘选择器

@interface MFRingPicker : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIWindow *hostWindow;              // 宿主窗口（状态栏窗口 或 POXWindow）
@property (nonatomic, weak) UIWindow *pullOverWindow;          // PullOver 自己的窗口（手柄/面板仍在这里）
@property (nonatomic, strong) UIView *hostContainerView;       // 加子视图用：覆盖层 或 窗口本身
@property (nonatomic, strong) MFRingHostOverlayView *overlayView;  // 仅当宿主=状态栏窗口时非 nil
@property (nonatomic, copy) NSString *hostClassName;           // 宿主窗口类名（日志用）
@property (nonatomic, weak) PullOverViewController *hostController;
@property (nonatomic, strong) UIView *stripView;               // 贴边透明触发条（宿主子视图）
@property (nonatomic, strong) UIPanGestureRecognizer *stripPan;
@property (nonatomic, assign) CGRect hostBounds;               // 宿主窗口尺寸（变化时重建几何）
@property (nonatomic, assign) CGRect triggerFrame;             // 触发区（窗口坐标）
@property (nonatomic, strong) UIView *container;               // 展开态根视图（轻遮罩 + 圆盘）
@property (nonatomic, strong) UIView *ringRoot;                // 圆盘整体（移动它 = 移动圆盘）
@property (nonatomic, strong) CAShapeLayer *dialLayer;         // 圆形底盘
@property (nonatomic, strong) NSMutableArray<UIButton *> *iconButtons;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) NSUInteger buildGeneration;      // 构建代次（作废过期回调）
@property (nonatomic, assign) BOOL ringLatched;                // 圆盘是否已固定在停靠点
@property (nonatomic, assign) CGPoint parkCenter;              // 停靠点（屏幕下半屏中心）
@property (nonatomic, weak) UIButton *selectedButton;          // 悬停选中的图标
@property (nonatomic, assign) CGPoint lastFingerPoint;         // 最近一次手指屏幕坐标
@property (nonatomic, assign) CGPoint latchFingerPoint;        // 固定那一刻的手指坐标
@property (nonatomic, assign) BOOL hasLatchFinger;             // 是否已记录固定时的手指位置
@property (nonatomic, assign) NSUInteger settleGeneration;     // 手指停住计时器代次
// 【0.2.1】圆盘应用编辑器（长按边缘触发条打开）
@property (nonatomic, strong) UIView *editorPanel;             // 全屏编辑面板
@property (nonatomic, strong) UIScrollView *editorScroll;      // 面板里的滚动容器
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *editorSelection;  // 已选 bundleID（有序）
@property (nonatomic, strong) NSMutableArray<UIView *> *editorCells;             // 网格 cell（顺序填图标）
@property (nonatomic, strong) UILabel *editorCountLabel;       // "已选 N 个"
@property (nonatomic, assign) NSUInteger editorIconGeneration;  // 编辑器图标填充代次
@property (nonatomic, strong) UILongPressGestureRecognizer *stripLongPress;
+ (instancetype)shared;
- (void)install;
- (void)teardownHostViews;
- (UIView *)hitTestViewForPoint:(CGPoint)point inWindow:(UIWindow *)window;
- (void)refreshHostGeometryIfNeeded;
- (CGRect)triggerFrameForBounds:(CGRect)bounds;
- (BOOL)pointBelongsToPullOverHandle:(CGPoint)point;
- (void)onStripPan:(UIPanGestureRecognizer *)gesture;
- (void)onRingHoverPan:(UIPanGestureRecognizer *)gesture;
- (void)onStripLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)showAtPoint:(CGPoint)point;
- (void)moveRingToPoint:(CGPoint)point;
- (void)latchToParkAnimated:(BOOL)animated;
- (void)scheduleSettle;
- (void)buildRingInContainer:(UIView *)container;
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation;
- (void)refreshRingContentsIfVisible;
- (void)scheduleAutoBundleIdEnumeration;
- (void)updateSelectionForPoint:(CGPoint)point;
/// 【0.2.15】松手时该打开哪个 App：仅松手点压在图标上的当前选中；否则 nil（收起，不开）
- (NSString *)releaseOpenBundleIdForPoint:(CGPoint)point;
/// ⚠️ 注意：**绝不能**命名为 setSelectedButton:（详见实现处 0.2.0 血案注释）
- (void)applySelectionToButton:(UIButton *)button;
- (void)applySelectionVisual:(UIButton *)button selected:(BOOL)selected;
- (void)openFloatWithBundleId:(NSString *)bundleId;
- (CGPoint)clampRingCenter:(CGPoint)point;
- (void)hide;
// 【0.2.1】应用编辑器
- (void)openEditor;
- (void)buildEditorPanelWithApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps;
- (void)fillEditorIcons:(NSArray<UIView *> *)cells
              fromIndex:(NSUInteger)index
             generation:(NSUInteger)generation;
- (void)onEditorCellTapped:(UIButton *)button;
- (void)onEditorDone:(UIButton *)sender;
- (void)applyEditorCellVisual:(UIView *)cell selected:(BOOL)selected;
- (void)refreshEditorCount;
- (void)closeEditorSaving:(BOOL)saving;
@end

#pragma mark - 容器（展开态）：点空白收起

/// 展开态的整屏容器。它自己处理触摸：新触摸（不是在触发条上开始的那次）落下再抬起 = 点空白。
@interface MFRingContainerView : UIView
@end

@implementation MFRingContainerView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 必须实现：不实现的话这次触摸序列不会落到我们手里
    (void)touches;
    (void)event;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    MFLog(@"[ring] 点空白 -> 收起圆盘");
    [[MFRingPicker shared] hide];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
}

@end

#pragma mark - 宿主覆盖层实现（0.2.3）

@implementation MFRingHostOverlayView

/// 只认"触发带 / 圆盘"，其余一律 nil —— nil 会让 UIKit 继续问下一扇窗口，
/// 所以状态栏、手柄、面板、App 的触摸都不会被我们吃掉。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    @try {
        UIView *target = MFRingHitTestViewForHostPoint(self.window, point);
        if (target != nil) {
            return target;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

@end

@implementation MFRingPicker

+ (instancetype)shared {
    static MFRingPicker *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MFRingPicker alloc] init];
    });
    return instance;
}

#pragma mark 安装

- (void)install {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }
    if (self.stripView != nil) {
        return;   // 幂等
    }
    if (!MFRingBool(@"mfRingEnabled", YES)) {
        MFLog(@"[ring] 圆盘已按配置关闭（mfRingEnabled=false）");
        return;
    }
    @try {
        // ---------- ① PullOver 自己的窗口（永远需要：手柄/面板/pin/open 都在它上面） ----------
        UIWindow *pullOverWindow = nil;
        id sharedWindow = [POXWindow sharedWindow];
        if ([sharedWindow isKindOfClass:[UIWindow class]]) {
            pullOverWindow = (UIWindow *)sharedWindow;
        }
        if (pullOverWindow == nil) {
            MFLog(@"[ring] !! PullOver 窗口不可用，1 秒后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self install]; });
            return;
        }
        CGRect screenBounds = pullOverWindow.bounds;
        if (CGRectIsEmpty(screenBounds)) {
            screenBounds = [UIScreen mainScreen].bounds;
        }
        if (CGRectIsEmpty(screenBounds)) {
            MFLog(@"[ring] !! 屏幕未就绪，1 秒后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self install]; });
            return;
        }
        self.pullOverWindow = pullOverWindow;

        // ---------- ② 【0.2.3】选宿主窗口 ----------
        // 归档 38 实证：全屏 App 活跃时，**挂在状态栏窗口里的热区仍能收到触摸**，
        // 而 SB 自己普通窗口（=POXWindow 所在地）里的视图在屏幕中间/右侧一次都收不到。
        // 所以优先挂状态栏窗口；找不到、或它不是全屏（挂上去也盖不住右侧触发带）就退回 POXWindow。
        MFRingLogWindowInventory();
        // 【0.2.4】默认 2 → **0**：0.2.3 实测找到的是 SBStatusBarReusePoolWindow（level=0 全屏窗口），
        // 全屏覆盖层让它变成"触摸黑洞"（带外吃掉桌面触摸 ⇒ 桌面无法滑动）。方案保留、默认关闭。
        NSInteger hostMode = (NSInteger)MFRingNumber(@"mfRingHostWindow", 0.0);   // 0=只用 POXWindow（默认） 2=自动 1=强制
        UIWindow *host = nil;
        if (hostMode != 0) {
            host = MFRingFindStatusBarWindow(screenBounds, hostMode != 1);
            if (host == nil) {
                MFLog(@"[ring] 未找到可用的状态栏窗口（mfRingHostWindow=%ld）-> 退回 PullOver 窗口",
                      (long)hostMode);
            } else {
                MFLog(@"[ring] ⚠️ mfRingHostWindow=%ld：宿主用状态栏窗口（0.2.3 实测会挡桌面滑动，仅供试验）",
                      (long)hostMode);
            }
        }
        BOOL usingStatusBar = (host != nil);
        if (host == nil) {
            host = pullOverWindow;
        }

        self.hostWindow = host;
        self.hostClassName = NSStringFromClass([host class]);
        CGRect bounds = host.bounds;
        if (CGRectIsEmpty(bounds)) {
            bounds = screenBounds;
        }
        self.hostBounds = bounds;
        self.triggerFrame = [self triggerFrameForBounds:bounds];
        if (host.hidden) {
            host.hidden = NO;
            MFLog(@"[ring] 宿主窗口原为隐藏 -> 已置为可见");
        }

        id controller = nil;
        @try {
            controller = [(POXWindow *)pullOverWindow controller];
        } @catch (__unused NSException *exception) {
            controller = nil;
        }
        if ([controller isKindOfClass:[PullOverViewController class]]) {
            self.hostController = (PullOverViewController *)controller;
        }

        // 覆盖层：宿主不是 POXWindow（它自己有 hitTest 覆写）时，由我们接管宿主的命中判定。
        UIView *hostContainer = host;
        if (usingStatusBar) {
            MFRingHostOverlayView *overlay = [[MFRingHostOverlayView alloc] initWithFrame:bounds];
            overlay.backgroundColor = [UIColor clearColor];
            overlay.opaque = NO;
            overlay.userInteractionEnabled = YES;
            overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            overlay.tag = 991000;
            [host addSubview:overlay];
            self.overlayView = overlay;
            hostContainer = overlay;
        } else {
            self.overlayView = nil;
        }
        self.hostContainerView = hostContainer;

        // 崩溃降级判定：上次的标记还在 ⇒ 上回就是被"枚举 App / 抓图标"带走的
        gMFRingDegraded = MFRingGuardArmed();
        if (gMFRingDegraded) {
            MFLog(@"[ring] ⚠️ 检测到崩溃标记 %s —— 进入**降级模式**：不再枚举 App、不抓图标，"
                  @"只用配置/缓存 + 首字母图标。删除该文件可重新尝试。", MF_RING_GUARD_PATH);
        }
        gMFRingAutoBundleIds = MFRingFilterBundleIds([MFRingDefaults() arrayForKey:@"ringAppsAuto"], 24);
        if (gMFRingAutoBundleIds.count > 0) {
            MFLog(@"[ring] 载入上次的自动列表：%lu 项", (unsigned long)gMFRingAutoBundleIds.count);
        }

        // 贴边触发条：宿主的最上层子视图（不是自己的窗口）
        UIView *strip = [[UIView alloc] initWithFrame:bounds];
        strip.backgroundColor = [UIColor clearColor];
        strip.opaque = NO;
        strip.userInteractionEnabled = YES;
        strip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        strip.tag = 991001;
        [hostContainer addSubview:strip];
        self.stripView = strip;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(onStripPan:)];
        pan.delegate = self;
        [strip addGestureRecognizer:pan];
        self.stripPan = pan;

        // 【0.2.1】长按触发条 = 打开「选择圆盘应用」编辑器。
        // 与 pan 互不干扰：手指不动 → pan 不会 begin（pan 需要位移），长按 0.7s 胜出。
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(onStripLongPress:)];
        longPress.minimumPressDuration = 0.7;
        longPress.delegate = self;
        [strip addGestureRecognizer:longPress];
        self.stripLongPress = longPress;

        self.iconButtons = [NSMutableArray array];

        MFLog(@"[ring] 0.3.18 圆盘宿主=%@（%@，配置=%ld）%@ level=%.0f frame=%@ hidden=%d "
              @"交互=%d | 触发边=%@ 触发条=%@ 覆盖层=%@ | 配置项=%lu 自动列表=%lu 降级=%@",
              self.hostClassName,
              usingStatusBar ? @"状态栏窗口" : @"PullOver 窗口",
              (long)hostMode,
              usingStatusBar ? @"" : @"【注意：全屏 App 上可能收不到触摸】",
              host.windowLevel, NSStringFromCGRect(bounds), (int)host.hidden,
              (int)host.userInteractionEnabled,
              MFRingEdge(), NSStringFromCGRect(self.triggerFrame),
              self.overlayView != nil ? @"已装" : @"无",
              (unsigned long)MFRingConfiguredBundleIds().count,
              (unsigned long)gMFRingAutoBundleIds.count,
              gMFRingDegraded ? @"是" : @"否");
        if (!CGRectContainsRect(bounds, self.triggerFrame)) {
            MFLog(@"[ring] ⚠️ 触发带 %@ 超出宿主 %@ —— 越界部分收不到触摸（可调 mfTriggerCenterRatio / "
                  @"mfTriggerThickness / mfTriggerEdge，或设 mfRingHostWindow=0 退回 PullOver 窗口）",
                  NSStringFromCGRect(self.triggerFrame), NSStringFromCGRect(bounds));
        }
        // 先算一次内容数量（几何缩放要用它），再打几何 —— 数量少时圆盘会自动变小
        NSUInteger ringCount = MFRingBundleIds().count;
        {
            MFRingGeometry geo = MFRingComputeGeometry(bounds, ringCount);
            MFLog(@"[ring] 圆盘几何：数量=%lu 缩放=%@ 圈数=%lu 有效外圈半径=%.0f 底盘=%.0f 图标=%.0f "
                  @"步距=%.0f 停靠比例Y=%.2f | 编辑器入口：长按贴边触发条 0.7 秒（最多 %lu 个图标）",
                  (unsigned long)ringCount, MFRingScaleDescription(ringCount),
                  (unsigned long)geo.rings, geo.outerRadius, geo.dialRadius,
                  geo.iconSize, geo.step,
                  MIN(MAX(MFRingNumber(@"mfRingParkRatioY", 0.78), 0.5), 0.92),
                  (unsigned long)MFRingMaxIcons());
            MFLog(@"[ring] 呼出阈值=%.0fpt | 归档38 提醒：全屏 App 上只有'屏幕边缘/状态栏'这些系统保留区"
                  @"的触摸会路由到我们窗口；`[ring][diag]` 行就是用来判定触摸到底有没有到的",
                  MAX(6.0, MFRingNumber(@"mfRingSummonThreshold", 12.0)));
        }

        // 触摸路径零 SB 查询 ⇒ 列表在安装后延后算一次
        [self scheduleAutoBundleIdEnumeration];
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 安装异常：%@", exception);
    }
}

/// 拆掉挂到宿主上的视图（宿主窗口失效时自愈用）
- (void)teardownHostViews {
    @try {
        [self.container removeFromSuperview];
        [self.stripView removeFromSuperview];
        [self.overlayView removeFromSuperview];
    } @catch (__unused NSException *exception) {
    }
    self.container = nil;
    self.stripView = nil;
    self.stripPan = nil;
    self.stripLongPress = nil;
    self.overlayView = nil;
    self.hostContainerView = nil;
    self.dialLayer = nil;
    self.ringRoot = nil;
    self.expanded = NO;
}

/// 宿主窗口尺寸变化（旋转等）时同步几何。回调里只做一次 rect 比较，开销可忽略。
/// 【0.2.3】顺带做两件自愈：宿主窗口被系统回收（weak 变 nil）→ 清状态重装；
/// 覆盖层被移出宿主（状态栏窗口偶尔会重排子视图）→ 补回去。都在触摸路径上，只做指针/rect 判断。
- (void)refreshHostGeometryIfNeeded {
    UIWindow *window = self.hostWindow;
    if (window == nil) {
        if (self.stripView != nil) {
            MFLog(@"[ring] 宿主窗口已失效 -> 重新安装");
            [self teardownHostViews];
            [self install];
        }
        return;
    }
    MFRingHostOverlayView *overlay = self.overlayView;
    if (overlay != nil && overlay.superview == nil) {
        [window addSubview:overlay];
        MFLog(@"[ring] 覆盖层被移出宿主窗口 -> 已补回 %@", self.hostClassName);
    }
    CGRect bounds = window.bounds;
    if (CGRectIsEmpty(bounds) || CGRectEqualToRect(bounds, self.hostBounds)) {
        return;
    }
    self.hostBounds = bounds;
    self.triggerFrame = [self triggerFrameForBounds:bounds];
    if (self.stripView != nil) {
        self.stripView.frame = bounds;      // 命中区由 triggerFrame 决定，不是 frame
    }
    if (overlay != nil) {
        overlay.frame = bounds;
    }
    if (self.container != nil) {
        self.container.frame = bounds;
    }
    MFLog(@"[ring] 宿主尺寸更新 %@ -> 触发条 %@",
          NSStringFromCGRect(bounds), NSStringFromCGRect(self.triggerFrame));
}

/// 收起态的触发区（贴边一条）。
///
/// 【0.2.2 重要背景】归档 38 / 第 42 轮定论：**全屏 App 活跃时，SpringBoard 自己 scene
/// 的普通视图拿不到"屏幕中间区域"的触摸**（触点归属前台 App 的 scene），
/// 只有**屏幕边缘 / 状态栏这些系统保留区**仍会路由到 SB 的视图。
/// 所以触发条必须**贴死在屏幕边缘**（inner 侧越靠外越好）：
///   · 右/左边缘条：x 紧贴屏幕右/左边（宽度 = mfTriggerThickness）；
///   · 下边缘条：**贴屏幕底边**（bottomInset 默认 0）——底部主屏手势带同样是系统保留区，
///     是"零 hook 也能在全屏 App 上收到触摸"的最后一块可用地。
/// 顶部条无所谓 inset。左右条的纵向范围仍避开底部 44pt，免得跟主屏手势打架。
- (CGRect)triggerFrameForBounds:(CGRect)bounds {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    // 【0.3.0】厚度 56 → 28：用户实测"太宽，容易误触"。窄一半仍够用：
    //   呼出主力是系统边缘手势（识别器自身区域 20pt + 带门外扩 60pt），判定不受厚度影响。
    CGFloat thickness = MAX(16.0, MFRingNumber(@"mfTriggerThickness", 28.0));
    // 【0.3.18】长度默认 0 = 动态屏高 30%（用户指定：触发条只占屏幕边缘约 30%，
    //   减少与全屏 App 手势的重叠冲突——抖音左滑个人主页 / iOS 右缘返回同属右缘区域，
    //   跨进程手势无法互斥，缩窄触发带是系统限制下最有效的缓解）。
    //   显式设置 mfTriggerLength（>0）仍生效，下限 80。
    CGFloat lengthRaw = MFRingNumber(@"mfTriggerLength", 0.0);
    CGFloat length = lengthRaw > 0.0 ? MAX(80.0, lengthRaw) : MAX(80.0, height * 0.30);
    CGFloat centerRatio = MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.95);
    NSString *edge = MFRingEdge();
    // 下边缘条默认**不留底边距**（贴死屏幕底边）；其余方向沿用 44pt 避让主屏手势区
    CGFloat insetFallback = [edge isEqualToString:@"bottom"] ? 0.0 : 44.0;
    CGFloat bottomInset = MAX(0.0, MFRingNumber(@"mfTriggerBottomInset", insetFallback));
    if ([edge isEqualToString:@"bottom"]) {
        bottomInset = MIN(bottomInset, MAX(height - thickness, 0.0));
    }

    if ([edge isEqualToString:@"top"] || [edge isEqualToString:@"bottom"]) {
        CGFloat originX = MIN(MAX(width * centerRatio - length / 2.0, 0.0), MAX(width - length, 0.0));
        return ([edge isEqualToString:@"top"]) ? CGRectMake(originX, 0.0, length, thickness)
                                               : CGRectMake(originX, MAX(height - thickness - bottomInset, 0.0),
                                                            length, thickness);
    }
    CGFloat originY = MIN(MAX(height * centerRatio - length / 2.0, 0.0), MAX(height - length, 0.0));
    // 只对贴底的那一段做上移（左/右边缘条同样受这条约束）
    originY = MIN(originY, MAX(height - length - bottomInset, 0.0));
    if ([edge isEqualToString:@"left"]) {
        return CGRectMake(0.0, originY, thickness, length);
    }
    return CGRectMake(width - thickness, originY, thickness, length);   // right（默认）
}

#pragma mark 命中判定（由托管窗口的 hitTest 调用）

/// PullOver 手柄优先：手柄是个方形小把件（默认约 50x50pt 命中区），
/// 命中它时把这次触摸**原样让给 PullOver**，保证浮窗手柄依旧能拖。
/// 【0.2.3】point 是**宿主窗口**坐标；宿主可能是状态栏窗口，手柄却还在 POXWindow 里，
/// 所以这里先做一次窗口间换算（同一台设备两扇窗口都是全屏同原点，换算后数值通常一样）。
- (BOOL)pointBelongsToPullOverHandle:(CGPoint)point {
    PullOverViewController *controller = self.hostController;
    if (controller == nil || !controller.isViewLoaded) {
        return NO;
    }
    POHandle *handle = controller.handle;
    if (handle == nil || handle.hidden || handle.alpha <= 0.01) {
        return NO;
    }
    @try {
        UIWindow *fromWindow = self.hostWindow;
        UIWindow *targetWindow = self.pullOverWindow;
        CGPoint inTarget = point;
        if (targetWindow != nil && fromWindow != nil && targetWindow != fromWindow) {
            inTarget = [fromWindow convertPoint:point toWindow:targetWindow];
        }
        CGPoint inHandle = [handle convertPoint:inTarget fromView:targetWindow ?: fromWindow];
        return [handle pointInside:inHandle withEvent:nil];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

/// 返回本次触摸该落到的视图；返回 nil = 原样交回（既有行为零改变）。
/// 【0.2.3】window 参数是"问我们的那扇窗口"：只有它 == 我们的宿主才接管，
/// 否则一律 nil —— 这样即使圆盘改挂状态栏窗口，POXWindow 那条老路径也不会重复响应。
- (UIView *)hitTestViewForPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (window == nil || window != self.hostWindow) {
        return nil;
    }
    [self refreshHostGeometryIfNeeded];

    // 【0.2.1】编辑器面板优先（覆盖全屏的模态层）：
    // 返回**最深**命中视图 —— cell 按钮靠 target/action 被点到；
    // 滚动视图的 pan 手势挂在祖先上，仍能收到落在子视图上的触摸，所以滚动不受影响。
    UIView *panel = self.editorPanel;
    if (panel != nil) {
        @try {
            CGPoint inPanel = [panel convertPoint:point fromView:window];
            UIView *deep = [panel hitTest:inPanel withEvent:nil];
            return deep ?: panel;
        } @catch (__unused NSException *exception) {
            return panel;
        }
    }

    if (self.expanded) {
        UIView *container = self.container;
        if (container == nil) {
            return nil;
        }
        // 展开态：返回容器里最深的那层 —— 圆盘图标是 UIButton（可点），
        // 其余（含圆盘底盘）落到容器 = "空白"，抬手即收起。
        @try {
            CGPoint inContainer = [container convertPoint:point fromView:window];
            UIView *deep = [container hitTest:inContainer withEvent:nil];
            if (deep != nil) {
                return deep;
            }
        } @catch (__unused NSException *exception) {
        }
        return container;
    }

    UIView *strip = self.stripView;
    if (strip == nil || strip.hidden || CGRectIsEmpty(self.triggerFrame)) {
        return nil;
    }
    // 【0.2.2 诊断】带内 / 临带 40pt 的触摸都记一行 —— 见 MFRingDiagTouch 注释
    if (CGRectContainsPoint(CGRectInset(self.triggerFrame, -40.0, -40.0), point)) {
        MFRingDiagTouch(point, self.triggerFrame, window);
    }
    if (!CGRectContainsPoint(self.triggerFrame, point)) {
        return nil;
    }
    if ([self pointBelongsToPullOverHandle:point]) {
        return nil;   // 手柄优先
    }
    return strip;
}

#pragma mark - 触发（仅手势）

- (void)onStripPan:(UIPanGestureRecognizer *)gesture {
    UIWindow *window = self.hostWindow;
    if (window == nil || self.stripView == nil) {
        return;
    }
    CGPoint finger = [gesture locationInView:window];
    self.lastFingerPoint = finger;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGRect full = window.bounds;
        CGFloat edgeGap = MIN(MIN(finger.x, finger.y),
                              MIN(MAX(CGRectGetWidth(full) - finger.x, 0.0),
                                  MAX(CGRectGetHeight(full) - finger.y, 0.0)));
        MFLog(@"[ring] 贴边按下(POXWindow 子视图 tag=%ld) 屏幕(%.0f,%.0f) 距最近屏边 %.0fpt",
              (long)gesture.view.tag, finger.x, finger.y, edgeGap);
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (!self.expanded) {
            CGPoint translation = [gesture translationInView:gesture.view];
            // 【0.2.2】阈值 18 → 12：贴着边缘时手指能走的横向余量很小，
            // 阈值太高会让"贴边轻扫"被系统手势吃掉之前就松手
            CGFloat threshold = MAX(6.0, MFRingNumber(@"mfRingSummonThreshold", 12.0));
            if (fabs(translation.x) > threshold || fabs(translation.y) > threshold) {
                [self showAtPoint:finger];
            }
            return;
        }

        if (!self.ringLatched) {
            [self moveRingToPoint:finger];
            CGFloat tolerance = MAX(12.0, MFRingNumber(@"mfRingLatchTolerance", 72.0));
            if (hypot(finger.x - self.parkCenter.x, finger.y - self.parkCenter.y) <= tolerance) {
                [self latchToParkAnimated:YES];
            } else {
                [self scheduleSettle];
            }
        }
        [self updateSelectionForPoint:finger];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        if (!self.expanded) {
            MFLog(@"[ring] 贴边松手（未达到呼出阈值，不呼出）");
            return;
        }
        // 【0.2.15】仅松手点压在图标上才打开；圆盘外/无选中 = 只收起（用户指定：不开任何应用）
        NSString *bundleId = [self releaseOpenBundleIdForPoint:finger];
        if (bundleId.length > 0) {
            MFLog(@"[ring] 手指离开屏幕 -> 打开 %@ 浮窗", bundleId);
            [self hide];
            [self openFloatWithBundleId:bundleId];
        } else {
            // 【0.2.14 恢复】松手无选中 = 关闭圆盘（用户指定：手指离开屏幕自动关闭）
            MFLog(@"[ring] 手指离开屏幕 -> 未选中，收起圆盘");
            [self hide];
        }
        return;
    }
}

#pragma mark - 展开态悬停手势（0.2.9）

/// 挂在展开容器上的平移手势：**任何**落到圆盘/容器上的触摸都从这里驱动交互。
/// 与呼出路径（onStripPan: / mfEdgeSlid:）完全无关 —— log14 实证全屏 App 里
/// 呼出触摸结束后就再没有任何东西能驱动悬停 ⇒ 离右缘远的图标全部没法选。
///   · 点按：手势不动（Possible），按钮 TouchUpInside 照常「直接点击」打开；
///   · 拖动：Began 起取消按钮触摸（不误开），驱动 跟随→停靠→悬停→松手打开/收起。
- (void)onRingHoverPan:(UIPanGestureRecognizer *)gesture {
    @try {
        UIWindow *window = self.hostWindow;
        if (window == nil || !self.expanded) {
            return;
        }
        CGPoint finger = [gesture locationInView:window];
        if (!isfinite(finger.x) || !isfinite(finger.y)) {
            return;
        }
        self.lastFingerPoint = finger;

        if (gesture.state == UIGestureRecognizerStateChanged) {
            if (!self.ringLatched) {
                [self moveRingToPoint:finger];
                CGFloat tolerance = MAX(12.0, MFRingNumber(@"mfRingLatchTolerance", 72.0));
                if (hypot(finger.x - self.parkCenter.x, finger.y - self.parkCenter.y) <= tolerance) {
                    [self latchToParkAnimated:YES];
                } else {
                    [self scheduleSettle];
                }
            }
            [self updateSelectionForPoint:finger];
            return;
        }
        if (gesture.state == UIGestureRecognizerStateEnded) {
            // 【0.2.15】仅松手点压在图标上才打开；圆盘外/无选中 = 只收起
            NSString *bundleId = [self releaseOpenBundleIdForPoint:finger];
            if (bundleId.length > 0) {
                MFLog(@"[ring] 悬停松手 -> 打开 %@ 浮窗", bundleId);
                [self hide];
                [self openFloatWithBundleId:bundleId];
            } else {
                // 【0.2.14】松手无选中 = 关闭（用户指定：手指离开屏幕自动关闭圆盘）
                [self hide];
            }
            return;
        }
        // Began / Cancelled / Failed：不做事
    } @catch (NSException *hoverException) {
        MFLog(@"[ring] !! 悬停手势异常：%@", hoverException);
    }
}

#pragma mark - 应用编辑器入口（长按触发条）

/// 长按贴边触发条 → 打开「选择圆盘应用」编辑器。
/// 与"贴边左滑呼出圆盘"完全并存：手指不动 0.7s 才会走到这里。
- (void)onStripLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    MFLog(@"[ring] 长按触发条 -> 打开应用编辑器");
    [self openEditor];
}

#pragma mark 坐标辅助

/// 把圆心夹到合法范围：整圆不出屏，且**只在下半屏**；NaN/Inf 一律兜底
- (CGPoint)clampRingCenter:(CGPoint)point {
    CGRect bounds = self.hostBounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }
    if (CGRectIsEmpty(bounds)) {
        return CGPointZero;
    }
    // 【0.2.2】用"有效几何"而不是配置半径做夹取 —— 半径可能被容量 24 自动放大过
    // 【0.2.3】几何现在"按数量缩放"，所以取当前数量的几何（数量由 MFRingBundleIds 记录）
    CGFloat margin = MAX(0.0, MFRingNumber(@"mfRingEdgeMargin", 12.0));
    CGFloat extent = MFRingCurrentGeometry(bounds).extent + margin;
    CGFloat minX = extent;
    CGFloat maxX = MAX(CGRectGetMaxX(bounds) - extent, minX);
    CGFloat minY = CGRectGetMidY(bounds);                       // 下半屏
    CGFloat maxY = MAX(CGRectGetMaxY(bounds) - extent, minY);
    CGFloat x = MIN(MAX(MFRingSafe(point.x, CGRectGetMidX(bounds)), minX), maxX);
    CGFloat y = MIN(MAX(MFRingSafe(point.y, CGRectGetMidY(bounds)), minY), maxY);
    return CGPointMake(x, y);
}

#pragma mark 展开 / 收起

/// 展开圆盘。anchor = 圆盘初始圆心（= 手指位置）。
/// 0.1.9 起**同步构建**：与 PullOver 手柄一样在手势回调里直接改视图（那是已验证可用的做法）。
- (void)showAtPoint:(CGPoint)point {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showAtPoint:point]; });
        return;
    }
    if (self.hostWindow == nil || self.stripView == nil) {
        MFLog(@"[ring] 尚未安装，忽略呼出");
        return;
    }
    if (self.expanded) {
        return;
    }
    CGRect bounds = self.hostBounds;
    if (CGRectIsEmpty(bounds)) {
        MFLog(@"[ring] !! 宿主尺寸为空，忽略呼出");
        return;
    }

    MFLog(@"[ring] >>> 呼出圆盘 起点(%.0f,%.0f)", point.x, point.y);
    @try {
        // ⚠️ 0.1.6~0.1.9 就是死在这里：下面这句属性赋值当时会递归调用自身
        //    （手写 setSelectedButton: 与 @property selectedButton 撞名），
        //    栈溢出 → SIGSEGV → SpringBoard 硬重启。0.2.0 已改名 + 改走 ivar。
        self.expanded = YES;
        self.buildGeneration += 1;
        self.ringLatched = NO;
        self.selectedButton = nil;
        self.hasLatchFinger = NO;
        self.settleGeneration += 1;

        // 【0.2.2】停靠点下移：0.72 → 0.78（用户反馈"固定后还是有点靠上"）
        CGFloat ratio = MIN(MAX(MFRingNumber(@"mfRingParkRatioY", 0.78), 0.5), 0.92);
        self.parkCenter = [self clampRingCenter:CGPointMake(CGRectGetMidX(bounds),
                                                            CGRectGetHeight(bounds) * ratio)];
        MFLog(@"[ring] 呼出前置 ok（0.2.0：setter 死递归已修）");

        MFLog(@"[ring] >>> 建容器");
        MFRingContainerView *container = [[MFRingContainerView alloc] initWithFrame:bounds];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];   // 轻遮罩
        container.opaque = NO;
        container.userInteractionEnabled = YES;
        // 【0.2.9】悬停平移手势：展开后**任何**落在容器上的触摸都能驱动交互 ——
        //   点按 = 手势保持 Possible，按钮照常「直接点击」打开；
        //   拖动 = 手势 Began（默认 cancelsTouchesInView=YES 会取消按钮触摸，不误开），
        //          驱动 跟随/停靠/悬停/松手打开。log14 实证：全屏 App 里没有它，
        //          只有呼出那次触摸能驱动悬停 ⇒ 离右缘远的图标全部没反应。
        UIPanGestureRecognizer *hoverPan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onRingHoverPan:)];
        hoverPan.cancelsTouchesInView = YES;
        hoverPan.delaysTouchesBegan = NO;
        hoverPan.delaysTouchesEnded = NO;
        [container addGestureRecognizer:hoverPan];
        // 【0.2.3】挂到"宿主容器"（状态栏窗口时是覆盖层）—— 这样才能在全屏 App 之上显示
        UIView *hostContainer = self.hostContainerView ?: self.hostWindow;
        [hostContainer addSubview:container];
        self.container = container;
        MFLog(@"[ring] <<< 建容器 ok（0.2.9 悬停手势已挂）");

        MFLog(@"[ring] >>> 建圆盘");
        [self buildRingInContainer:container];
        MFLog(@"[ring] <<< 建圆盘 ok：%lu 个图标", (unsigned long)self.iconButtons.count);

        self.ringRoot.center = [self clampRingCenter:point];

        // 【0.3.0】呼出动画借鉴 Stheno（逆向实证：SwiftUI AnyTransition.scale + opacity +
        //   spring 弹性，`CustomSpringAnimation`/阻尼系数是其标志）：圆盘从 55% 缩放 + 全透明
        //   弹性放大到原尺寸 + 淡入。AllowUserInteraction 保证弹出过程中就能跟手/点按。
        container.alpha = 0.0;
        container.transform = CGAffineTransformMakeScale(0.55, 0.55);
        [UIView animateWithDuration:0.45
                              delay:0.0
             usingSpringWithDamping:0.68
              initialSpringVelocity:0.4
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:^{
            container.alpha = 1.0;
            container.transform = CGAffineTransformIdentity;
        } completion:nil];

        MFLog(@"[ring] <<< 呼出完成：跟随手指(%.0f,%.0f) -> 停靠点(%.0f,%.0f)",
              point.x, point.y, self.parkCenter.x, self.parkCenter.y);

        if (self.iconButtons.count == 0) {
            [self scheduleAutoBundleIdEnumeration];
        } else {
            // 图标延后抓取：先把圆盘显示出来，再慢慢贴真图标（触摸路径零图标查询）
            [self scheduleIconFillWithGeneration:self.buildGeneration];
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 展开异常：%@", exception);
        [self hide];
    }
}

- (void)hide {
    self.buildGeneration += 1;   // 作废尚未执行的图标填充
    if (self.editorPanel != nil) {
        [self closeEditorSaving:NO];   // 【0.2.1】编辑器开着就一并收起（不保存）
    }
    if (!self.expanded) {
        return;
    }
    UIView *container = self.container;
    self.container = nil;
    self.dialLayer = nil;
    self.ringRoot = nil;
    self.selectedButton = nil;
    self.ringLatched = NO;
    self.hasLatchFinger = NO;
    self.settleGeneration += 1;
    self.expanded = NO;
    [self.iconButtons removeAllObjects];

    if (container == nil) {
        return;
    }
    // 【0.3.0】收起 = 缩小 + 淡出（Stheno scale+opacity 反向过渡），干脆利落不拖泥带水
    [UIView animateWithDuration:0.18
                          delay:0.0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.6
                        options:(UIViewAnimationOptionCurveEaseIn |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        container.alpha = 0.0;
        container.transform = CGAffineTransformMakeScale(0.7, 0.7);
    } completion:^(__unused BOOL finished) {
        [container removeFromSuperview];
    }];
    MFLog(@"[ring] 圆盘已收起（贴边手势恢复）");
}

#pragma mark 跟随 / 停靠

- (void)moveRingToPoint:(CGPoint)point {
    if (self.ringRoot == nil) {
        return;
    }
    self.ringRoot.center = [self clampRingCenter:point];
}

/// 手指停住一小会儿就把圆盘固定到停靠点（用户自然会在停靠点附近有个停顿）
- (void)scheduleSettle {
    self.settleGeneration += 1;
    NSUInteger generation = self.settleGeneration;
    NSTimeInterval delay = MAX(0.05, MFRingNumber(@"mfRingSettleDelay", 0.18));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf.settleGeneration) {
            return;
        }
        if (!strongSelf.expanded || strongSelf.ringLatched) {
            return;
        }
        [strongSelf latchToParkAnimated:YES];
    });
}

/// 固定到下半屏中心 —— 之后手指滑动只改变"选中"，圆盘不再跟着动
- (void)latchToParkAnimated:(BOOL)animated {
    if (self.ringRoot == nil || self.ringLatched) {
        return;
    }
    self.ringLatched = YES;
    self.settleGeneration += 1;
    // 记录"固定那一刻手指在哪"：手指还没动之前不产生选中，避免刚停靠就误开某个 App
    self.latchFingerPoint = self.lastFingerPoint;
    self.hasLatchFinger = YES;
    CGPoint park = self.parkCenter;
    if (animated) {
        // 【0.3.0】停靠改弹簧滑入（Stheno spring 惯例）：到点后带一点柔性回稳，不再是生硬的 ease-out
        [UIView animateWithDuration:0.42
                              delay:0.0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.3
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:^{
            self.ringRoot.center = park;
        } completion:nil];
    } else {
        self.ringRoot.center = park;
    }
    MFLog(@"[ring] 圆盘已固定到下半屏中心 (%.0f, %.0f) —— 滑动到图标上选择，松手即打开", park.x, park.y);
}

#pragma mark 圆盘构建

- (void)buildRingInContainer:(UIView *)container {
    // 【0.2.3】几何按**实际数量**算 + 按数量缩放（数量少圆盘小、数量多圆盘大）：
    //   · 容量目标 = 本次数量（不再固定 24），否则半径会被自动放大到装 24 个、缩放失效；
    //   · 配置半径装不下该数量时才自动放大半径；
    //   · 底盘半径 / 视图半边长都以"有效外圈半径"为准，图标永不顶出屏幕。
    NSArray<NSString *> *ringBundleIds = MFRingBundleIds();   // 顺带把数量记进 gMFRingCount
    MFRingGeometry geo = MFRingComputeGeometry(container.bounds, ringBundleIds.count);
    CGFloat iconSize = geo.iconSize;
    CGFloat step = geo.step;
    CGFloat extent = geo.extent;
    CGFloat dialRadius = geo.dialRadius;
    CGFloat outerRadius = geo.outerRadius;
    CGFloat innerRatio = geo.innerRatio;
    CGFloat rotation = MFRingNumber(@"mfRingRotation", 0.0);
    MFLog(@"[ring] 圆盘缩放 %@ -> 图标 %.0f 半径 %.0f",
          MFRingScaleDescription(geo.count), iconSize, outerRadius);

    // 圆盘整体放在一个固定尺寸的容器里 —— 移动圆盘 = 改 ringRoot.center
    UIView *ringRoot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, extent * 2.0, extent * 2.0)];
    ringRoot.backgroundColor = [UIColor clearColor];
    ringRoot.opaque = NO;
    ringRoot.userInteractionEnabled = YES;
    ringRoot.tag = 991002;
    [container addSubview:ringRoot];
    self.ringRoot = ringRoot;

    // 完整圆形底盘
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:
                          CGRectMake(extent - dialRadius, extent - dialRadius,
                                     dialRadius * 2.0, dialRadius * 2.0)];
    CAShapeLayer *dial = [CAShapeLayer layer];
    dial.path = path.CGPath;
    dial.fillColor = [UIColor colorWithWhite:0.12 alpha:0.55].CGColor;
    dial.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    dial.lineWidth = 1.0;
    [ringRoot.layer addSublayer:dial];
    self.dialLayer = dial;

    MFLog(@"[ring] >>> 取圆盘内容（只读配置/缓存，不查 SB）");
    NSArray<NSString *> *bundleIds = ringBundleIds;   // 上面已经取过（同一份内容，避免重复读配置）
    NSUInteger count = bundleIds.count;
    MFLog(@"[ring] <<< 取圆盘内容 ok：%lu 项", (unsigned long)count);

    if (count == 0) {
        NSString *text = gMFRingDegraded
            ? @"圆盘里还没有 App\n（降级模式：自动枚举已停用）\n长按屏幕边缘可自己挑选 App"
            : @"圆盘里还没有 App\n长按屏幕边缘（触发条）约 1 秒\n即可自己挑选要放在圆盘上的 App";
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, outerRadius * 1.9, 110.0)];
        hint.numberOfLines = 0;
        hint.textAlignment = NSTextAlignmentCenter;
        hint.text = text;
        hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        hint.font = [UIFont systemFontOfSize:12.0];
        hint.center = CGPointMake(extent, extent);
        [ringRoot addSubview:hint];
        return;
    }

    // 【0.2.2】多圈（同心圆）布局：**先铺"首字母"占位**，真图标延后贴
    CGFloat startAngle = MFRingNumber(@"mfRingStartAngle", -90.0);   // 默认从正上方开始
    CGPoint localCenter = CGPointMake(extent, extent);

    // ① 算出每一圈的规划半径（由外到内）与该圈最多能放几个
    NSMutableArray<NSNumber *> *ringRadii = [NSMutableArray array];
    NSMutableArray<NSNumber *> *ringCaps = [NSMutableArray array];
    for (NSUInteger ring = 0; ring < geo.rings; ring++) {
        CGFloat ringRadius = (ring == 0) ? outerRadius
                                        : [ringRadii[ring - 1] doubleValue] * innerRatio;
        if (ring > 0 && ringRadius < iconSize * 1.15) {
            break;   // 内圈塞不下图标就不再加圈
        }
        [ringRadii addObject:@(ringRadius)];
        [ringCaps addObject:@(MAX(floor((2.0 * M_PI * ringRadius) / step), 1.0))];
    }
    NSUInteger rings = ringRadii.count;

    // ② 收敛单圈的判定（0.2.5）：数量装得下单圈、**或**"恰好步距"的单圈半径（snug =
    //    count×step/2π）没超过规划外圈的 1.15 倍 —— 单圈贴步距比双圈稀排更匀；
    //    再大的量就走等距双圈（24 个仍保持"外多内少"两圈观感）
    CGFloat snugAll = (CGFloat)count * step / (2.0 * M_PI);
    if (count <= [ringCaps[0] unsignedIntegerValue] || snugAll <= outerRadius * 1.15) {
        if (rings > 1) {
            [ringRadii removeObjectsInRange:NSMakeRange(1, rings - 1)];
            [ringCaps removeObjectsInRange:NSMakeRange(1, rings - 1)];
            rings = 1;
        }
    } else {
        while (rings > 1 && [ringCaps[rings - 1] unsignedIntegerValue] < 3) {
            [ringRadii removeLastObject];
            [ringCaps removeLastObject];
            rings--;
        }
    }
    NSUInteger totalCap = 0;
    for (NSNumber *cap in ringCaps) {
        totalCap += [cap unsignedIntegerValue];
    }
    if (count > totalCap && totalCap > 0) {
        count = totalCap;   // 兜底：超出所有圈的总容量时截断
    }

    // ③【0.2.5】等距双圈求解（用户：**内圈少、外圈多，两圈弧上间距一致，都不许出现巨大空隙**）。
    //    对每个候选 n_in（内圈个数，从多到少），令 n_out = count − n_in：
    //      · 等距 ⇒ r_in = r_out × n_in/n_out；
    //      · 内圈塞得下 ⇒ r_in ≥ iconSize×1.15 ⇒ r_out ≥ 1.15×icon×n_out/n_in；
    //      · 外圈不许有大空隙 ⇒ 间距 ≤ 1.6×step ⇒ r_out ≤ 1.6×step×n_out/2π（且 ≤ 规划外圈×1.5）。
    //    在可行解里取**外圈间距最小**的 n_in（外圈尽量满），r_out 取 min(规划外圈, 上限)。
    //    无可行解才退回"外圈铺满、剩余进内圈 + 内圈半径自适应"。
    NSMutableArray<NSNumber *> *perRing = [NSMutableArray arrayWithCapacity:rings];
    for (NSUInteger ring = 0; ring < rings; ring++) {
        [perRing addObject:@(0)];
    }
    NSMutableArray<NSNumber *> *drawnRadii = [NSMutableArray arrayWithCapacity:rings];
    BOOL solvedEqualSpacing = NO;
    if (rings >= 2) {
        CGFloat minInnerRadius = iconSize * 1.15;
        NSUInteger maxInner = (NSUInteger)MAX(floor((2.0 * M_PI * minInnerRadius) / step), 1.0);
        CGFloat bestSpacing = 0.0;
        CGFloat bestOuterRadius = 0.0;
        NSUInteger bestInner = 0;
        NSUInteger bestOuter = 0;
        for (NSUInteger nIn = MIN(maxInner, count - 1); nIn >= 1; nIn--) {
            NSUInteger nOut = count - nIn;
            if (nOut <= nIn) {
                break;   // 用户要求：内圈少、外圈多
            }
            CGFloat rOutMin = minInnerRadius * ((CGFloat)nOut / (CGFloat)nIn);
            CGFloat rOutMax = MIN(1.6 * step * ((CGFloat)nOut / (2.0 * M_PI)),
                                  outerRadius * 1.5);
            if (rOutMin > rOutMax) {
                continue;   // 这个 n_in 撑不出均匀解
            }
            CGFloat rOut = MIN(outerRadius, rOutMax);
            if (rOut < rOutMin) {
                rOut = rOutMin;
            }
            CGFloat spacing = (2.0 * M_PI * rOut) / (CGFloat)nOut;
            if (bestInner == 0 || spacing < bestSpacing) {
                bestSpacing = spacing;
                bestOuterRadius = rOut;
                bestInner = nIn;
                bestOuter = nOut;
            }
        }
        if (bestInner > 0) {
            perRing[0] = @(bestOuter);
            perRing[1] = @(bestInner);
            [drawnRadii addObject:@(bestOuterRadius)];
            [drawnRadii addObject:@(bestOuterRadius * ((CGFloat)bestInner / (CGFloat)bestOuter))];
            if (rings > 2) {
                rings = 2;   // 等距解只做两圈
            }
            solvedEqualSpacing = YES;
            MFLog(@"[ring] 等距双圈：外 %lu 个 @ r=%.0f（间距 %.1f）、内 %lu 个 @ r=%.0f（等距）",
                  (unsigned long)bestOuter, bestOuterRadius, bestSpacing,
                  (unsigned long)bestInner, bestOuterRadius * ((CGFloat)bestInner / (CGFloat)bestOuter));
        }
    }
    if (!solvedEqualSpacing) {
        // 退路：**外圈先铺满**，剩余进内圈；内圈半径按个数自适应（下限 0.42×外圈）
        NSUInteger left = count;
        for (NSInteger ring = (NSInteger)rings - 1; ring >= 0 && left > 0; ring--) {
            NSUInteger cap = [ringCaps[(NSUInteger)ring] unsignedIntegerValue];
            NSUInteger take = MIN(cap, left);
            perRing[(NSUInteger)ring] = @(take);
            left -= take;
        }
        CGFloat outerCount = MAX((CGFloat)[perRing[0] doubleValue], 1.0);
        for (NSUInteger ring = 0; ring < rings; ring++) {
            CGFloat drawn = [ringRadii[ring] doubleValue];
            if (ring == 0 && rings == 1) {
                // 【0.2.5】单圈半径 = "恰好步距"（最均匀）：r = count×step/2π；
                // 下限 1.15×icon（图标塞得下），上限规划外圈×1.35（配合 ② 的收敛条件）
                CGFloat snug = (CGFloat)count * step / (2.0 * M_PI);
                drawn = MIN(MAX(snug, iconSize * 1.15), outerRadius * 1.35);
            }
            if (ring > 0) {
                CGFloat innerCount = (CGFloat)[perRing[ring] doubleValue];
                if (innerCount > 0.5) {
                    drawn = MIN(MAX(outerRadius * (innerCount / outerCount), outerRadius * 0.42), drawn);
                }
            }
            [drawnRadii addObject:@(drawn)];
        }
    }

    // 【0.2.5】底盘随"实际外圈半径"重画 —— 等距解 / 单圈收缩可能比规划半径小，
    // 不重画的话图标会缩在底盘里面，观感很差。
    CGFloat actualOuterRadius = [drawnRadii.firstObject doubleValue];
    CGFloat actualDialRadius = actualOuterRadius + iconSize * 0.5 + 6.0;
    @try {
        UIBezierPath *dialPath = [UIBezierPath bezierPathWithOvalInRect:
                                  CGRectMake(extent - actualDialRadius, extent - actualDialRadius,
                                             actualDialRadius * 2.0, actualDialRadius * 2.0)];
        self.dialLayer.path = dialPath.CGPath;
    } @catch (__unused NSException *exception) {
    }

    // ⑤ 逐圈铺图标 —— 先铺"首字母"占位，真图标延后贴
    NSUInteger placed = 0;
    NSMutableArray<NSString *> *layoutLog = [NSMutableArray array];
    for (NSUInteger ring = 0; ring < rings && placed < count; ring++) {
        CGFloat iconRadius = [drawnRadii[ring] doubleValue];
        NSUInteger ringCount = [perRing[ring] unsignedIntegerValue];
        for (NSUInteger slot = 0; slot < ringCount && placed < count; slot++, placed++) {
            NSString *bundleId = bundleIds[placed];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.bounds = CGRectMake(0.0, 0.0, iconSize, iconSize);
            button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
            button.layer.cornerRadius = iconSize / 2.0;
            button.layer.masksToBounds = YES;
            button.layer.borderWidth = 1.0;
            button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

            NSString *initial = (bundleId.length > 0)
                ? [[bundleId lastPathComponent] substringToIndex:1].uppercaseString : @"?";
            [button setTitle:initial forState:UIControlStateNormal];
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont boldSystemFontOfSize:iconSize * 0.4];

            objc_setAssociatedObject(button, &kMFRingBundleIdKey, bundleId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [button addTarget:self action:@selector(onIconTapped:) forControlEvents:UIControlEventTouchUpInside];
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
                initWithTarget:self action:@selector(onIconLongPressed:)];
            longPress.minimumPressDuration = 0.5;
            [button addGestureRecognizer:longPress];

            // 内圈错开半格，视觉上更匀称
            CGFloat stagger = (ring % 2 == 1) ? (180.0 / (CGFloat)MAX(ringCount, (NSUInteger)1)) : 0.0;
            CGFloat angleDegrees = startAngle + stagger
                + 360.0 * (CGFloat)slot / (CGFloat)MAX(ringCount, (NSUInteger)1)
                + rotation;
            CGFloat angle = angleDegrees * M_PI / 180.0;
            button.center = CGPointMake(localCenter.x + iconRadius * cos(angle),
                                       localCenter.y + iconRadius * sin(angle));

            [ringRoot addSubview:button];
            [self.iconButtons addObject:button];
        }
        [layoutLog addObject:[NSString stringWithFormat:@"第%lu圈(r=%.0f/%lu个)",
                              (unsigned long)(ring + 1), iconRadius, (unsigned long)ringCount]];
    }
    MFLog(@"[ring] <<< 图标铺好：%.0f 个图标 / %lu 圈 [%@] 图标 %.0f 步距 %.0f "
          @"(缩放 %.0f%% 实际外圈半径 %.0f 底盘 %.0f 上限 %lu)",
          (double)placed, (unsigned long)rings,
          [layoutLog componentsJoinedByString:@" "], iconSize, step,
          geo.scale * 100.0, actualOuterRadius, actualDialRadius, (unsigned long)MFRingMaxIcons());
}

/// 延后抓取真图标。危险动作 ⇒ 立闸门，走完并存活才撤。
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation {
    if (self.iconButtons.count == 0) {
        return;
    }
    if (!MFRingBool(@"mfRingFetchIcons", YES)) {
        MFLog(@"[ring] 按配置跳过图标抓取（mfRingFetchIcons=false，仅首字母）");
        return;
    }
    if (gMFRingDegraded) {
        MFLog(@"[ring] 降级模式：跳过图标抓取（仅首字母）。删除 %s 可重试", MF_RING_GUARD_PATH);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (generation != strongSelf.buildGeneration || !strongSelf.expanded) {
            MFLog(@"[ring] 图标填充已作废 gen=%lu", (unsigned long)generation);
            return;
        }
        NSArray<UIButton *> *buttons = [strongSelf.iconButtons copy];
        MFLog(@"[ring] >>> 抓取图标 %lu 个（逐个记录）", (unsigned long)buttons.count);
        MFRingGuardArm();
        BOOL anyIcon = NO;
        for (UIButton *button in buttons) {
            if (generation != strongSelf.buildGeneration || !strongSelf.expanded) {
                break;
            }
            if (button.superview == nil) {
                continue;
            }
            NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
            if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
                continue;
            }
            MFLog(@"[ring] >>> 取图标 %@", bundleId);
            UIImage *icon = MFRingIconForBundleId(bundleId);
            MFLog(@"[ring] <<< 取图标 %@ ok=%@", bundleId, icon != nil ? @"是" : @"否");
            if (icon != nil && generation == strongSelf.buildGeneration) {
                [button setImage:icon forState:UIControlStateNormal];
                button.imageView.contentMode = UIViewContentModeScaleAspectFill;
                [button setTitle:nil forState:UIControlStateNormal];
                anyIcon = YES;
            }
        }
        MFRingGuardDisarm();   // 整趟走完且存活 ⇒ 撤标记
        MFLog(@"[ring] <<< 图标抓取完成（%lu 个，取到图标=%@），崩溃标记已撤除",
              (unsigned long)buttons.count, anyIcon ? @"是" : @"否");
    });
}

/// 列表迟到（枚举完成）时，若圆盘正开着就原地重建内容
- (void)refreshRingContentsIfVisible {
    if (!self.expanded || self.container == nil || self.ringRoot == nil) {
        return;
    }
    CGPoint center = self.ringRoot.center;
    [self.ringRoot removeFromSuperview];
    self.ringRoot = nil;
    self.dialLayer = nil;
    self.selectedButton = nil;
    [self.iconButtons removeAllObjects];
    [self buildRingInContainer:self.container];
    self.ringRoot.center = center;
    MFLog(@"[ring] 圆盘内容已刷新：%lu 个图标", (unsigned long)self.iconButtons.count);
    [self scheduleIconFillWithGeneration:self.buildGeneration];
}

#pragma mark - 圆盘应用编辑器（0.2.1）

/// 打开「选择圆盘应用」。会做一次已安装 App 枚举 + 名称查询 —— 属危险动作，全程闸门保护。
- (void)openEditor {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self openEditor]; });
        return;
    }
    if (self.editorPanel != nil) {
        return;   // 已开着
    }
    UIWindow *window = self.hostWindow;
    if (window == nil || self.stripView == nil) {
        MFLog(@"[ring] 尚未安装，忽略打开编辑器");
        return;
    }
    MFLog(@"[ring] >>> 打开应用编辑器：枚举已安装 App（最多 %d 个）", (int)MF_RING_EDITOR_MAX_APPS);
    MFRingGuardArm();
    NSArray<NSDictionary<NSString *, NSString *> *> *apps = MFRingInstalledAppsForEditor(MF_RING_EDITOR_MAX_APPS);
    MFRingGuardDisarm();
    MFLog(@"[ring] <<< 编辑器 App 列表：%lu 个", (unsigned long)apps.count);
    if (apps.count == 0) {
        MFLog(@"[ring] !! 枚举为空，无法打开编辑器");
        return;
    }
    // 以"当前圆盘实际显示的内容"作为初始勾选（所见即所选）
    self.editorSelection = [NSMutableOrderedSet orderedSetWithArray:MFRingBundleIds()];
    [self buildEditorPanelWithApps:apps];
}

/// 构建全屏编辑面板：标题 + 计数 + 网格（图标/名称/勾选角标）+「完成」。
- (void)buildEditorPanelWithApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps {
    UIWindow *window = self.hostWindow;
    if (window == nil) {
        return;
    }
    CGRect bounds = self.hostBounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = window.bounds;
    }
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        MFLog(@"[ring] !! 编辑器：宿主尺寸无效，放弃");
        return;
    }

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, height)];
    panel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.87];
    panel.opaque = NO;
    panel.userInteractionEnabled = YES;
    panel.tag = MF_RING_EDITOR_TAG;
    // 【0.2.3】同样挂到宿主容器（状态栏窗口时是覆盖层），全屏 App 之上也能看到/操作
    [(self.hostContainerView ?: window) addSubview:panel];
    self.editorPanel = panel;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 46.0, width - 130.0, 30.0)];
    title.text = @"选择圆盘中的应用";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:19.0];
    [panel addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeCustom];
    done.tag = MF_RING_EDITOR_DONE;
    done.frame = CGRectMake(width - 86.0, 44.0, 70.0, 34.0);
    done.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    done.layer.cornerRadius = 17.0;
    done.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [done addTarget:self action:@selector(onEditorDone:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:done];

    UILabel *countLabel = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 78.0, width - 36.0, 18.0)];
    countLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    countLabel.font = [UIFont systemFontOfSize:11.5];
    [panel addSubview:countLabel];
    self.editorCountLabel = countLabel;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0.0, 100.0, width, height - 100.0)];
    scroll.backgroundColor = [UIColor clearColor];
    scroll.opaque = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.tag = MF_RING_EDITOR_SCROLL;
    [panel addSubview:scroll];
    self.editorScroll = scroll;

    const NSUInteger columns = 4;
    const CGFloat sideInset = 8.0;
    const CGFloat cellW = floor((width - sideInset * 2.0) / (CGFloat)columns);
    const CGFloat cellH = 100.0;
    const CGFloat iconSize = 62.0;
    self.editorCells = [NSMutableArray array];

    NSMutableOrderedSet<NSString *> *selection = self.editorSelection;
    for (NSUInteger index = 0; index < apps.count; index++) {
        NSDictionary<NSString *, NSString *> *app = apps[index];
        NSString *bundleId = app[@"id"];
        NSString *name = app[@"name"];

        NSUInteger column = index % columns;
        NSUInteger row = index / columns;
        UIButton *cell = [UIButton buttonWithType:UIButtonTypeCustom];
        cell.frame = CGRectMake(sideInset + column * cellW, row * cellH, cellW, cellH);
        cell.backgroundColor = [UIColor clearColor];
        cell.layer.cornerRadius = 12.0;
        cell.layer.masksToBounds = YES;
        objc_setAssociatedObject(cell, &kMFRingBundleIdKey, bundleId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell addTarget:self action:@selector(onEditorCellTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0, 0.0, iconSize, iconSize)];
        iconView.tag = MF_RING_EDITOR_ICON;
        iconView.center = CGPointMake(cellW / 2.0, 6.0 + iconSize / 2.0);
        iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        iconView.layer.cornerRadius = 14.0;
        iconView.layer.masksToBounds = YES;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [cell addSubview:iconView];

        UILabel *placeholder = [[UILabel alloc] initWithFrame:iconView.bounds];
        placeholder.tag = MF_RING_EDITOR_LABEL;
        placeholder.text = (name.length > 0) ? [name substringToIndex:1] : @"?";
        placeholder.textAlignment = NSTextAlignmentCenter;
        placeholder.textColor = [UIColor whiteColor];
        placeholder.font = [UIFont boldSystemFontOfSize:24.0];
        [iconView addSubview:placeholder];

        UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(1.0, 6.0 + iconSize + 3.0,
                                                                      cellW - 2.0, 28.0)];
        nameLabel.text = name;
        nameLabel.textAlignment = NSTextAlignmentCenter;
        nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        nameLabel.font = [UIFont systemFontOfSize:10.5];
        nameLabel.numberOfLines = 2;
        [cell addSubview:nameLabel];

        UIView *check = [[UIView alloc] initWithFrame:CGRectMake(iconView.center.x + iconSize / 2.0 - 11.0,
                                                                 3.0, 22.0, 22.0)];
        check.tag = MF_RING_EDITOR_CHECK;
        check.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        check.layer.cornerRadius = 11.0;
        check.userInteractionEnabled = NO;
        UILabel *tick = [[UILabel alloc] initWithFrame:check.bounds];
        tick.text = @"✓";
        tick.textAlignment = NSTextAlignmentCenter;
        tick.textColor = [UIColor whiteColor];
        tick.font = [UIFont boldSystemFontOfSize:14.0];
        [check addSubview:tick];
        [cell addSubview:check];

        [scroll addSubview:cell];
        [self.editorCells addObject:cell];
        [self applyEditorCellVisual:cell selected:[selection containsObject:bundleId]];
    }

    NSUInteger rows = (apps.count + columns - 1) / columns;
    scroll.contentSize = CGSizeMake(width, (CGFloat)rows * cellH + 24.0);
    [self refreshEditorCount];
    MFLog(@"[ring] 编辑器已打开：%lu 个 App / %lu 行 × %lu 列，当前已选 %lu 个",
          (unsigned long)apps.count, (unsigned long)rows, (unsigned long)columns,
          (unsigned long)selection.count);

    // 真图标延后分批抓（先"首字母"占位，避免一次性拉几百张图标卡住 SpringBoard）
    if (MFRingBool(@"mfRingFetchIcons", YES) && !gMFRingDegraded) {
        self.editorIconGeneration += 1;
        NSUInteger generation = self.editorIconGeneration;
        [self fillEditorIcons:[self.editorCells copy] fromIndex:0 generation:generation];
    } else {
        MFLog(@"[ring] 编辑器跳过图标抓取（mfRingFetchIcons=false 或降级模式）");
    }
}

/// 分批（每轮 8 个）抓取编辑器图标。闸门逐批 arm/disarm，任何一批崩了下次进降级模式。
- (void)fillEditorIcons:(NSArray<UIView *> *)cells
              fromIndex:(NSUInteger)index
             generation:(NSUInteger)generation {
    if (self.editorPanel == nil || generation != self.editorIconGeneration) {
        return;   // 编辑器已关 / 已被更新的填充取代
    }
    NSUInteger total = cells.count;
    if (index >= total) {
        MFLog(@"[ring] <<< 编辑器图标抓取完成（%lu 个）", (unsigned long)total);
        return;
    }
    NSUInteger end = MIN(index + 8, total);
    MFRingGuardArm();
    for (NSUInteger i = index; i < end; i++) {
        UIView *cell = cells[i];
        if (cell.superview == nil) {
            continue;
        }
        NSString *bundleId = objc_getAssociatedObject(cell, &kMFRingBundleIdKey);
        UIImage *icon = MFRingIconForBundleId(bundleId);
        if (icon == nil) {
            continue;
        }
        UIImageView *iconView = (UIImageView *)[cell viewWithTag:MF_RING_EDITOR_ICON];
        if (iconView == nil) {
            continue;
        }
        iconView.image = icon;
        [cell viewWithTag:MF_RING_EDITOR_LABEL].hidden = YES;
    }
    MFRingGuardDisarm();
    if (end >= total) {
        MFLog(@"[ring] <<< 编辑器图标抓取完成（%lu 个）", (unsigned long)total);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf fillEditorIcons:cells fromIndex:end generation:generation];
    });
}

/// 点击 cell = 加入 / 移出圆盘
- (void)onEditorCellTapped:(UIButton *)button {
    NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        return;
    }
    NSMutableOrderedSet<NSString *> *selection = self.editorSelection;
    if (selection == nil) {
        return;
    }
    BOOL selected;
    if ([selection containsObject:bundleId]) {
        [selection removeObject:bundleId];
        selected = NO;
        MFLog(@"[ring] 编辑器移出 %@（剩 %lu）", bundleId, (unsigned long)selection.count);
    } else {
        NSUInteger cap = MFRingMaxIcons();
        if (selection.count >= cap) {
            MFLog(@"[ring] 编辑器已达上限 %lu 个，先移出一些再加", (unsigned long)cap);
            @try {
                UIImpactFeedbackGenerator *feedback =
                    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback impactOccurred];
            } @catch (__unused NSException *exception) {
            }
            return;
        }
        [selection addObject:bundleId];
        selected = YES;
        MFLog(@"[ring] 编辑器加入 %@（共 %lu）", bundleId, (unsigned long)selection.count);
    }
    [self applyEditorCellVisual:button selected:selected];
    [self refreshEditorCount];
}

- (void)applyEditorCellVisual:(UIView *)cell selected:(BOOL)selected {
    if (cell == nil) {
        return;
    }
    [cell viewWithTag:MF_RING_EDITOR_CHECK].hidden = !selected;
    cell.backgroundColor = selected ? [UIColor colorWithWhite:1.0 alpha:0.10] : [UIColor clearColor];
    UIView *iconView = [cell viewWithTag:MF_RING_EDITOR_ICON];
    iconView.layer.borderWidth = selected ? 2.0 : 0.0;
    iconView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0].CGColor;
}

- (void)refreshEditorCount {
    UILabel *label = self.editorCountLabel;
    if (label == nil) {
        return;
    }
    label.text = [NSString stringWithFormat:@"已选 %lu 个（最多 %lu 个）· 点图标加入/移出",
                  (unsigned long)self.editorSelection.count, (unsigned long)MFRingMaxIcons()];
}

- (void)onEditorDone:(UIButton *)sender {
    (void)sender;
    [self closeEditorSaving:YES];
}

/// 关闭编辑器。saving=YES ⇒ 把当前勾选写入 `ringApps`（下次呼出即为新列表）。
- (void)closeEditorSaving:(BOOL)saving {
    UIView *panel = self.editorPanel;
    if (panel == nil) {
        return;
    }
    self.editorIconGeneration += 1;   // 作废尚未执行的图标填充
    if (saving) {
        NSArray<NSString *> *selected = [self.editorSelection.array copy];
        MFRingWriteBundleIds(selected);
        MFLog(@"[ring] 编辑器已保存：圆盘应用 %lu 个 -> %@",
              (unsigned long)selected.count,
              selected.count > 0 ? [selected componentsJoinedByString:@", "] : @"(空)");
        MFLog(@"[ring] 下次呼出圆盘即使用新列表（不用 respring）");
    } else {
        MFLog(@"[ring] 编辑器已关闭（未保存）");
    }
    self.editorPanel = nil;
    self.editorScroll = nil;
    self.editorCountLabel = nil;
    self.editorSelection = nil;
    self.editorCells = nil;
    [panel removeFromSuperview];
}

#pragma mark 自动枚举（安装后延后执行，绝不在触摸路径）

- (void)scheduleAutoBundleIdEnumeration {
    if (gMFRingDegraded) {
        MFLog(@"[ring] 降级模式：跳过自动枚举");
        return;
    }
    if (gMFRingListing) {
        return;
    }
    if (MFRingUserListSet()) {
        MFLog(@"[ring] 用户已设置过 ringApps，跳过自动枚举");
        return;
    }
    if (gMFRingAutoBundleIds.count > 0) {
        return;   // 已有缓存
    }
    gMFRingListing = YES;
    gMFRingListGeneration += 1;
    NSUInteger generation = (NSUInteger)gMFRingListGeneration;
    __weak typeof(self) weakSelf = self;
    // 延后 0.6 秒：确保这次安装/呼出事件已经处理完，且 SpringBoard 已经稳定
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || generation != (NSUInteger)gMFRingListGeneration) {
            gMFRingListing = NO;
            return;
        }
        NSUInteger limit = MFRingMaxIcons();
        MFLog(@"[ring] >>> 枚举已安装 App（扁平遍历，最多 %lu 项）", (unsigned long)limit);
        MFRingGuardArm();
        NSArray<NSString *> *ids = MFRingEnumerateInstalledBundleIds(limit);
        MFRingGuardDisarm();   // 走完且存活 ⇒ 撤标记
        gMFRingListing = NO;
        if (generation != (NSUInteger)gMFRingListGeneration) {
            return;
        }
        if (ids.count == 0) {
            MFLog(@"[ring] !! 枚举结果为空（不写缓存）");
            return;
        }
        MFRingStoreAutoBundleIds(ids);
        MFLog(@"[ring] <<< 枚举完成：%lu 项 -> %@",
              (unsigned long)ids.count, [ids componentsJoinedByString:@", "]);
        [strongSelf refreshRingContentsIfVisible];
    });
}

#pragma mark 悬停选择

- (void)updateSelectionForPoint:(CGPoint)point {
    UIView *container = self.container;
    if (container == nil || self.iconButtons.count == 0) {
        return;
    }
    // 刚固定时手指还停在原地 —— 必须真的滑动一下才算"选择"（防误开）。
    // 【0.2.10】守卫只在首次"真移开"前生效：一旦移出 22pt 就解除（hasLatchFinger=NO）。
    //   log15 实证：停靠点在下半屏中心、呼出拖动路径恰好经过右侧图标一带，
    //   latchFingerPoint 常常就在图标 22pt 内 —— 守卫反复清掉用户故意悬停的选中，
    //   造成"悬停选中 → 悬停离开 → 松手未选中"= 全屏下松手打不开、要二次点击。
    if (self.hasLatchFinger) {
        CGFloat fromLatch = hypot(point.x - self.latchFingerPoint.x, point.y - self.latchFingerPoint.y);
        if (fromLatch < 22.0) {
            [self applySelectionToButton:nil];
            return;
        }
        self.hasLatchFinger = NO;   // 真移开过 = 开始选择了，守卫使命完成
    }
    // 【0.2.3】用**当前缩放后的**图标尺寸算命中半径 —— 圆盘会随数量变小，命中区跟着一起缩
    CGFloat iconSize = MFRingCurrentGeometry(self.hostBounds).iconSize;
    CGFloat hitRadius = MAX(26.0, iconSize * 0.85 + 10.0);

    UIButton *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (UIButton *button in self.iconButtons) {
        if (button.superview == nil) {
            continue;
        }
        CGPoint center = [button.superview convertPoint:button.center toView:self.hostWindow];
        CGFloat distance = hypot(center.x - point.x, center.y - point.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = button;
        }
    }
    if (bestDistance > hitRadius) {
        best = nil;
    }
    if (best == self.selectedButton) {
        return;
    }
    [self applySelectionToButton:best];
}

/// 悬停选中的**应用**（不是属性的 setter —— 名字绝不能叫 setSelectedButton:）
///
/// 【0.2.0 血案 · 必读】
/// `selectedButton` 是个 @property，编译器会替它合成 `-setSelectedButton:`。
/// 如果我们再手写一个同名方法，那么**属性赋值** `self.selectedButton = x`
/// 在编译后就变成 `objc_msgSend(self, @selector(setSelectedButton:), x)` ——
/// 也就是调用它**自己**，于是无限递归 → 栈溢出 → SIGSEGV。
///
/// SIGSEGV 有两个致命特性：
///   ① `@try/@catch` **抓不住**（不是 NSException）；
///   ② 不产生"安全模式"，进程直接死 → 用户看到"黑屏 + 自动注销"。
///
/// 这正是 0.1.6 / 0.1.7 / 0.1.8 / 0.1.9 **连续四版"右边缘一滑就注销"的唯一根因**：
/// 每一版的 `showRing…/showAtPoint:` 里都有一句 `self.selectedButton = nil;`，
/// 而它恰好排在"第一条日志之后、第二条日志之前"——
/// 0.1.9 具体在第 806 行，与真机日志（`>>> 呼出圆盘` 有、`>>> 建容器` 无）**逐字吻合**。
/// 0.1.5 之所以正常，只是因为那一版还没有 `selectedButton` 这个属性。
///
/// 铁律：这个函数**写 ivar**（`_selectedButton = button;`），**永不自赋值属性**。
- (void)applySelectionToButton:(UIButton *)button {
    UIButton *previous = self.selectedButton;   // 读：走编译器合成的 getter，安全
    _selectedButton = button;                   // 写：直接写 ivar，绝不触发 setter
    if (previous != nil && previous != button) {
        [self applySelectionVisual:previous selected:NO];
    }
    if (button != nil) {
        [self applySelectionVisual:button selected:YES];
        NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
        MFLog(@"[ring] 悬停选中 %@", bundleId ?: @"?");
    } else if (previous != nil) {
        MFLog(@"[ring] 悬停离开（当前无选中）");
    }
}

/// 【0.2.15 修订】松手时该打开哪个 App：
///   松手点仍压在图标上（实时选中还在）→ 当前选中；
///   否则 → nil（= 收起圆盘，不打开任何应用）。
///   【0.2.12~0.2.14 曾有"时间窗内回退开最近悬停选中"的分支，log20 用户实测
///   反馈"松手停在圆盘外会自动打开一个 App，很不合理"——按用户要求整体移除：
///   手势在圆盘外松手 = 只关圆盘，什么都不开。】
- (NSString *)releaseOpenBundleIdForPoint:(CGPoint)point {
    [self updateSelectionForPoint:point];
    UIButton *selected = self.selectedButton;
    NSString *current = selected ? objc_getAssociatedObject(selected, &kMFRingBundleIdKey) : nil;
    if ([current isKindOfClass:[NSString class]] && current.length > 0) {
        return current;
    }
    return nil;
}

- (void)applySelectionVisual:(UIButton *)button selected:(BOOL)selected {
    if (button == nil) {
        return;
    }
    // 【0.3.0】借鉴 Stheno 的滑选图标动画（逆向实证：`_scaleToIcon`/`_selected` 选中缩放
    //   + `CustomSpringAnimation`/阻尼系数贯穿）：选中图标**弹性**放大到 1.25 并加亮，
    //   手指滑走时弹簧缩回。damping 0.5 = 明显的过冲回弹，正是 Stheno 圆盘的手感来源。
    [UIView animateWithDuration:0.38
                          delay:0.0
         usingSpringWithDamping:(selected ? 0.5 : 0.65)
          initialSpringVelocity:(selected ? 0.5 : 0.0)
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        button.transform = selected ? CGAffineTransformMakeScale(1.25, 1.25) : CGAffineTransformIdentity;
        button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:selected ? 0.45 : 0.14];
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:selected ? 0.95 : 0.35].CGColor;
    } completion:nil];
}

#pragma mark 图标交互

- (void)onIconTapped:(UIButton *)button {
    NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
    MFLog(@"[ring] 直接点击 %@ -> 打开浮窗", bundleId ?: @"(nil)");
    if (bundleId.length == 0) {
        [self hide];
        return;
    }
    [self hide];
    [self openFloatWithBundleId:bundleId];
}

- (void)onIconLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    NSString *bundleId = objc_getAssociatedObject(gesture.view, &kMFRingBundleIdKey);
    if (bundleId.length == 0) {
        return;
    }
    // 以"当前显示集"为基准物化，再移除 —— 保证自动枚举来的项也能真正移出
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSString *item in MFRingBundleIds()) {
        if (![item isEqualToString:bundleId] && ![ids containsObject:item]) {
            [ids addObject:item];
        }
    }
    MFRingWriteBundleIds(ids);
    MFLog(@"[ring] 长按移出 %@ -> 剩 %lu 项", bundleId, (unsigned long)ids.count);

    // 原地重建，并直接停靠在下半屏中心
    CGPoint park = self.parkCenter;
    [self hide];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self showAtPoint:park];
        [self latchToParkAnimated:NO];
    });
}

#pragma mark 打开浮窗

- (void)openFloatWithBundleId:(NSString *)bundleId {
    @try {
        id sharedWindow = [POXWindow sharedWindow];
        if (![sharedWindow isKindOfClass:[UIWindow class]]) {
            MFLog(@"[ring] !! 浮窗窗口不存在，无法打开 %@", bundleId);
            return;
        }
        PullOverViewController *controller = [(POXWindow *)sharedWindow controller];
        if (controller == nil) {
            MFLog(@"[ring] !! 找不到 PullOver 控制器，无法打开浮窗");
            return;
        }
        SEL pinSelector = NSSelectorFromString(@"pinAppWithBundleId:");
        if ([controller respondsToSelector:pinSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, pinSelector, bundleId);
            MFLog(@"[ring] 已 pin App：%@", bundleId);
        } else {
            MFLog(@"[ring] !! 控制器不支持 pinAppWithBundleId:");
        }
        SEL openSelector = NSSelectorFromString(@"open");
        if ([controller respondsToSelector:openSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, openSelector);
            MFLog(@"[ring] 已请求打开浮窗");
        } else {
            MFLog(@"[ring] !! 控制器不支持 open");
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 打开浮窗异常：%@", exception);
    }
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

#pragma mark - 命中判定入口（供 POXWindow.hitTest 调用）

/// 窗口命中判定：圆盘展开态整窗接管、收起态只认贴边触发条；其余返回 nil，
/// 由 POXWindow 原样交回 PullOver 控制器 —— 对既有手柄/面板行为零改变。
/// 命中判定的统一入口（两个调用方：POXWindow.hitTest 与状态栏窗口的覆盖层）。
/// 内部会核对"问我们的那扇窗口是不是我们的宿主"，所以两条路径永远不会重复响应。
static UIView *MFRingHitTestShared(UIWindow *window, CGPoint point) {
    if (window == nil) {
        return nil;
    }
    @try {
        return [[MFRingPicker shared] hitTestViewForPoint:point inWindow:window];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

UIView *MFRingHitTestViewForWindowPoint(UIWindow *window, CGPoint point) {
    return MFRingHitTestShared(window, point);
}

UIView *MFRingHitTestViewForHostPoint(UIWindow *window, CGPoint point) {
    return MFRingHitTestShared(window, point);
}

#pragma mark - 安装入口

/// 由 PullOverX.mm 的 constructor 延迟调用（避免在 SpringBoard 极早期碰 UIKit）
void MFRingPickerInstall(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MFRingPickerInstall(); });
        return;
    }
    @try {
        [[MFRingPicker shared] install];
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! MFRingPickerInstall 异常：%@", exception);
    }
}

#pragma mark - 系统手势呼出（0.2.5，供 PullOverX.mm 的多候选手势 hook 调用）

/// hook 回调入口①：这次系统手势回调要不要接管？
/// 条件：圆盘开着 + 手势呼出开着 + 已安装 + 当前没展开/编辑器没开。
/// ⚠️ 从 hook 里调用（手势线程=主线程），全程 @try，绝不能把异常抛回系统手势代码。
BOOL MFRingWantsSystemGestureSummon(void) {
    @try {
        if (!MFRingBool(@"mfRingEnabled", YES)) {
            return NO;
        }
        if (!MFRingBool(@"mfRingGestureSummon", YES)) {
            return NO;   // 用户配置了"别接管系统手势" → 原样放行
        }
        MFRingPicker *picker = [MFRingPicker shared];
        if (picker.hostWindow == nil || picker.stripView == nil) {
            return NO;   // 还没安装好
        }
        if (picker.expanded || picker.editorPanel != nil) {
            return NO;   // 已经开着了，让系统手势照常（避免状态打架）
        }
        return YES;
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

/// hook 回调入口①b：触点是否在"配置的贴边触发带"内或临带 60pt 内。
/// 只有边缘手势才接管 —— 手势起自屏幕中部时一律放行，系统手势（回桌面/多任务）不受影响。
/// point 是窗口坐标（locationInView:nil）；宿主与 POXWindow 同为全屏同原点，直接比即可。
BOOL MFRingPointNearTriggerEdge(CGPoint point) {
    @try {
        MFRingPicker *picker = [MFRingPicker shared];
        CGRect band = picker.triggerFrame;
        if (CGRectIsEmpty(band)) {
            return NO;
        }
        return CGRectContainsPoint(CGRectInset(band, -60.0, -60.0), point);
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

/// hook 回调入口②：在触点处呼出圆盘（随后自动固定到停靠点）。
/// 系统手势是持续手势，后续移动不归我们管 —— 圆盘 0.18s 后自动停靠，用户再点图标。
void MFRingSummonFromSystemGestureAtPoint(CGPoint point) {
    @try {
        MFRingPicker *picker = [MFRingPicker shared];
        if (picker.hostWindow == nil) {
            return;
        }
        MFLog(@"[ring] >>> 系统手势呼出（触点 %.0f,%.0f）", point.x, point.y);
        // 【0.2.14】恢复跟随：呼出后圆盘跟随手指，进容差/停顿才停靠
        //   （0.2.13 的"呼出即停靠"不是用户要的交互，已撤销）。
        [picker showAtPoint:point];
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 系统手势呼出异常：%@", exception);
    }
}

#pragma mark - 系统边缘手势呼出（0.2.7 注册 / 0.2.8 完整驱动，triggr 实证路线）

// SpringBoard 系统手势管理器：iOS 15~18 同一实现（triggr 实证），它把边缘触摸
// 路由给注册进来的手势识别器 —— **在全屏 App 上也有效**（这正是归档 38 死结的解法）。
@interface SBSystemGestureManager : NSObject
+ (instancetype)mainDisplayManager;
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer withType:(unsigned long long)type;
@end

// SpringBoard 自己创建边缘手势用的私有 init（type=2）：系统手势路由只给这种
// 识别器持续喂触摸 —— 普通公开 init 建的识别器收不到 App 上的触摸（triggr 实证）。
@interface UIScreenEdgePanGestureRecognizer (MFRingPrivateEdge)
- (instancetype)initWithTarget:(id)target action:(SEL)action type:(long long)type options:(unsigned long long)options;
- (void)_setEdgeRegionSize:(double)size;
@end

// 自定义手势 type 号：取一个离系统自己 type 数字很远的值（triggr 同款）
static const unsigned long long MFRingEdgeGestureType = 0x7467000ULL;

// 自定义 type 的放行判定（PullOverX.mm 的 hook 会引用这个范围）
BOOL MFRingIsEdgeGestureType(unsigned long long type) {
    return type >= MFRingEdgeGestureType && type < MFRingEdgeGestureType + 4ULL;
}

// 动作目标：识别器只做识别，动作全部走这里（@try 全包，绝不能把异常抛回系统手势路由）
@interface MFRingEdgePanTarget : NSObject
@end
@implementation MFRingEdgePanTarget
/// 边缘手势的完整驱动（0.2.8）：呼出前的"滑出阈值"判定 + 呼出后的
/// **跟随 → 停靠 → 悬停选中 → 松手打开/收起**（与 onStripPan: 同一套逻辑）。
/// 0.2.7 的教训（log13 实证）：呼出的那次触摸被系统手势识别器吃掉，onStripPan:
/// 收不到 ⇒ 圆盘卡在"跟随手指"等一个永远不来的触摸流。识别器自己就在收这份
/// 触摸流（Began/Changed/Ended），直接在这里驱动即可，哪条路径抢到触摸走哪套。
- (void)mfEdgeSlid:(UIScreenEdgePanGestureRecognizer *)recognizer {
    @try {
        if (recognizer == nil) {
            return;
        }
        MFRingPicker *picker = [MFRingPicker shared];
        CGRect band = picker.triggerFrame;
        if (CGRectIsEmpty(band)) {
            [self mfFailRecognizer:recognizer];
            return;
        }
        CGPoint location = [recognizer locationInView:nil];
        if (!isfinite(location.x) || !isfinite(location.y)) {
            location = CGPointMake(CGRectGetMidX(band), CGRectGetMidY(band));   // 兜底：触发带中心
        }
        UIGestureRecognizerState state = recognizer.state;
        BOOL inBand = CGRectContainsPoint(CGRectInset(band, -60.0, -60.0), location);

        // ---------- ① 未展开：带门在这里（只认领贴边触摸，防误抢中部手势） ----------
        if (!picker.expanded) {
            if (!inBand) {
                [self mfFailRecognizer:recognizer];   // 带外起手的手势与我们无关，尽早放行
                return;
            }
            if (!MFRingWantsSystemGestureSummon()) {
                [self mfFailRecognizer:recognizer];   // 圆盘关了/没装好 → 越早放行越不干扰
                return;
            }
            if (state != UIGestureRecognizerStateChanged &&
                state != UIGestureRecognizerStateEnded) {
                return;   // Began 不做事，等滑出距离
            }
            CGPoint translation = [recognizer translationInView:nil];
            if (!isfinite(translation.x) || !isfinite(translation.y)) {
                return;
            }
            UIRectEdge edge = recognizer.edges;
            CGFloat along = 0.0;
            if (edge == UIRectEdgeRight) {
                along = -translation.x;          // 右缘往左滑 = 离边
            } else if (edge == UIRectEdgeLeft) {
                along = translation.x;
            } else if (edge == UIRectEdgeTop) {
                along = translation.y;
            } else if (edge == UIRectEdgeBottom) {
                along = -translation.y;
            } else {
                along = MAX(fabs(translation.x), fabs(translation.y));
            }
            double distance = MFRingNumber(@"mfRingEdgePanDistance", 40.0);
            if (distance < 12.0) {
                distance = 12.0;
            }
            if (along < (CGFloat)distance) {
                return;
            }
            picker.lastFingerPoint = location;
            MFRingSummonFromSystemGestureAtPoint(location);
            return;
        }

        // ---------- ② 已展开：全屏任意位置都处理（0.2.14 关键修复）----------
        // 0.2.12 及之前这里还有带门：呼出后手指滑向圆盘左/上/下（离开触发带），
        // 事件全被自己丢掉 —— 这才是"只有右边能滑动选中"的真正元凶。
        if (state == UIGestureRecognizerStateChanged) {
            picker.lastFingerPoint = location;
            if (!picker.ringLatched) {
                [picker moveRingToPoint:location];   // 【0.2.14 恢复】跟随手指
                CGFloat tolerance = MAX(12.0, MFRingNumber(@"mfRingLatchTolerance", 72.0));
                if (hypot(location.x - picker.parkCenter.x,
                          location.y - picker.parkCenter.y) <= tolerance) {
                    [picker latchToParkAnimated:YES];
                } else {
                    [picker scheduleSettle];
                }
            }
            [picker updateSelectionForPoint:location];
            return;
        }
        if (state == UIGestureRecognizerStateEnded) {
            picker.lastFingerPoint = location;
            // 松手：仅当前选中（松手点压在图标上）才打开；否则 = 收起，不开任何应用（0.2.15）
            NSString *bundleId = [picker releaseOpenBundleIdForPoint:location];
            if ([bundleId isKindOfClass:[NSString class]] && bundleId.length > 0) {
                MFLog(@"[ring] 手指离开屏幕 -> 打开 %@ 浮窗", bundleId);
                [picker hide];
                [picker openFloatWithBundleId:bundleId];
            } else {
                MFLog(@"[ring] 手指离开屏幕 -> 未选中，收起圆盘（松手点 %.0f,%.0f）", location.x, location.y);
                [picker hide];
            }
            return;
        }
        // 【0.2.11】诊断：Began / Cancelled / Failed 各记一行 —— 全屏事件流若再出问题，
        // 日志直接点名是"没开始"还是"被系统半路取消"
        if (state == UIGestureRecognizerStateBegan) {
            MFLog(@"[ring][edge] 手势开始（%.0f,%.0f）", location.x, location.y);
        } else if (state == UIGestureRecognizerStateCancelled ||
                   state == UIGestureRecognizerStateFailed) {
            MFLog(@"[ring][edge] !! 手势被%@（%.0f,%.0f）",
                  (state == UIGestureRecognizerStateCancelled ? @"系统取消" : @"识别失败"),
                  location.x, location.y);
        }
        // Began / Cancelled / Failed：不改变圆盘状态
    } @catch (NSException *edgeException) {
        (void)edgeException;   // 失败放行
    }
}

/// 帮手：圆盘没开时的尽早放行（识别器越早 Failed，系统行为越不受影响）
- (void)mfFailRecognizer:(UIGestureRecognizer *)recognizer {
    @try {
        if (recognizer.state == UIGestureRecognizerStatePossible ||
            recognizer.state == UIGestureRecognizerStateBegan) {
            recognizer.state = UIGestureRecognizerStateFailed;
        }
    } @catch (__unused NSException *exception) {
    }
}
@end

/// 由 PullOverX.mm 调用：向 SBSystemGestureManager 注册贴边识别器（幂等，可重试）。
/// 时机 = SpringBoard 建好自己的手势管理器之后（_init hook 或启动 10s 兜底）。
/// ⚠️ 不能替 SpringBoard 先建管理器（iOS 17 实测会 abort，triggr 同款教训）。
void MFRingInstallEdgePanGesture(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MFRingInstallEdgePanGesture(); });
        return;
    }
    static BOOL installed = NO;
    if (installed) {
        return;
    }
    @try {
        if (!MFRingBool(@"mfRingGestureSummon", YES)) {
            return;   // 用户关了系统手势呼出 → 不注册
        }
        Class managerClass = objc_getClass("SBSystemGestureManager");
        if (managerClass == nil) {
            MFLog(@"[ring] 0.3.18 边缘手势：SBSystemGestureManager 不存在 -> 放弃（iOS 版本差异）");
            return;
        }
        if (![managerClass respondsToSelector:@selector(mainDisplayManager)]) {
            MFLog(@"[ring] 0.3.18 边缘手势：+mainDisplayManager 不存在 -> 放弃");
            return;
        }
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(mainDisplayManager));
        if (manager == nil) {
            MFLog(@"[ring] 0.3.18 边缘手势：管理器还没就绪 -> 稍后重试");
            return;
        }
        SEL addSelector = @selector(addGestureRecognizer:withType:);
        if (![manager respondsToSelector:addSelector]) {
            MFLog(@"[ring] 0.3.18 边缘手势：addGestureRecognizer:withType: 不存在 -> 放弃");
            return;
        }
        Class panClass = objc_getClass("UIScreenEdgePanGestureRecognizer");
        SEL privateInit = @selector(initWithTarget:action:type:options:);
        if (panClass == nil || ![panClass instancesRespondToSelector:privateInit]) {
            MFLog(@"[ring] 0.3.18 边缘手势：私有 init 不存在 -> 放弃");
            return;
        }
        // 配置的触发边（与可见触发条同一边，默认 right）
        UIRectEdge edge = UIRectEdgeRight;
        NSString *edgeName = MFRingEdge();
        if ([edgeName isEqualToString:@"left"]) {
            edge = UIRectEdgeLeft;
        } else if ([edgeName isEqualToString:@"top"]) {
            edge = UIRectEdgeTop;
        } else if ([edgeName isEqualToString:@"bottom"]) {
            edge = UIRectEdgeBottom;
        }
        static MFRingEdgePanTarget *edgeTarget;
        if (edgeTarget == nil) {
            edgeTarget = [[MFRingEdgePanTarget alloc] init];
        }
        UIScreenEdgePanGestureRecognizer *recognizer =
            [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:edgeTarget
                                                              action:@selector(mfEdgeSlid:)
                                                                type:(long long)2
                                                             options:(unsigned long long)0];
        recognizer.edges = edge;
        recognizer.minimumNumberOfTouches = 1;
        recognizer.maximumNumberOfTouches = 1;
        // 【0.2.11】cancelsTouchesInView 必须为 YES（UIGestureRecognizer 默认值）：
        //   0.2.8 设 NO 的代价（log16 实证）= 系统把触摸同时喂给前台 App —— 用户拖着
        //   圆盘、App 页面跟着滚，我们的识别器事件流被饿死 ⇒ 全屏悬停稀疏、松手无选中。
        //   YES = 识别器 Began 即独占触摸：App 不滚、事件流完整（triggr 默认同款）。
        //   delaysTouchesBegan 保持 NO：桌面长按编辑器入口靠静止按下（Possible 不拦截）。
        recognizer.cancelsTouchesInView = YES;
        recognizer.delaysTouchesBegan = NO;
        recognizer.delaysTouchesEnded = NO;
        if ([recognizer respondsToSelector:@selector(_setEdgeRegionSize:)]) {
            [recognizer _setEdgeRegionSize:20.0];   // 起手区贴边 20pt（triggr 同款）
        }
        ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(manager, addSelector,
                                                                  recognizer, MFRingEdgeGestureType);
        installed = YES;
        MFLog(@"[ring] 0.3.18 边缘手势已注册：SBSystemGestureManager edge=%@ type=%llu（全屏 App 内贴边滑出呼出）",
              edgeName, (unsigned long long)MFRingEdgeGestureType);
    } @catch (NSException *installException) {
        MFLog(@"[ring] !! 0.2.7 边缘手势注册异常：%@ -> 不影响圆盘本体", installException);
    }
}
