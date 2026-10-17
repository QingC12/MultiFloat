//
//  MFRingPicker.m
//  PullOverMF —— Stheno 风格「圆盘」呼出选择器（本 fork 新增）
//
//  ============================ 0.6.9 核心改动（与"左滑返回"类插件冲突修复）============================
//  用户反馈：装了左滑返回（leftPan，注入所有 UIKit 进程、hook
//  _UINavigationInteractiveTransition 的手势仲裁方法并给导航容器挂全屏 pan）后，
//  有时在全屏 App 里呼不出圆盘。取证（analysis 过程）：
//    · leftPan 把"自己的全屏 pan 抬成最高仲裁优先级"（hook 了
//      gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer: 等光束仲裁方法），
//      贴边单指触摸一旦漏到 App 进程就被它吃掉 → 返回上一页而不是呼出圆盘；
//    · 我们注入不到 App 进程（只注 SpringBoard），单指贴边这条路上没有仲裁权可抢。
//  修法（triggr 1.5 同款思路：双指边缘滑入，App 端单指手势从规则上抢不走）：
//  ① **双指贴边呼出**：新增 min=max=2 的边缘识别器（type=基号+1，仍在既有放行 hook
//     范围内，**零新增 hook**）。双指起步时所有单指识别器强制 Failed —— leftPan 的
//     全屏 pan、系统返回手势都是单指起步，双指呼出必中。
//  ② **单指让位规则**（MFRingEdgeRecognizer.touchesBegan 覆写）：圆盘未展开时手指超编
//     主动 Failed（单指版被双指压住让位）；展开跟手阶段多指搭手不打断（0.2.11 教训）。
//  ③ **起手区加深**：单指 20 → 28pt、双指 40pt —— App 自己的返回手势只认屏缘约 20pt，
//     加深不侵占它；带内贴边起手更容易被我们收到。开关：mfRingTwoFingerSummon（默认开）。
//
//  ============================ 0.6.11 核心改动（用户四项指令）============================
//  ① **ACR 快捷方式扩编**：新增 录屏 / 控制中心 / 通知中心（mfsys.record / controlcenter /
//     notificationcenter，实现见 MFSystemActions.m —— 与截屏同套"多候选 + 运行时扫描"兜底，
//     命中哪条 API 写日志）；编辑器条目改名「· ACR」；未添加 tab 网格**分区展示**
//     （ACR 快捷方式 / 桌面应用 两个区块标题）。
//  ② **已添加排序改平铺网格**：自动换行一屏看全所有已选 App（不再横向滑动找），
//     拖拽换位改二维最近邻；预览/网格高度按行数动态分配。
//  ③ **触发条可贴底**：位置比例上限 0.95 → 0.98，左右条底部避让 44 → 10pt。
//  （④ 贴片还原连续变形动画在 PullOverViewController.m —— mfStripMorph* 三件套。）
//
//  ============================ 0.4.12 核心改动（用户 log38）============================
//  用户原话："关于添加arc功能，按照方案A推进，可以只添加截屏和翻译"（另有一条 bug：
//  "我打开设置时调整了窗口大小，当我点击某一个二级菜单时，悬浮窗会恢复默认大小" ——
//  那条在 PullOverViewController.m 的 applyLayoutPreservingHandlePosition: 里修）。
//  ① **圆盘支持"系统动作"**（用户选定方案 A = 进程内直调系统私有接口，**零新增 hook**）：
//     动作的"主人"本来就都在 SpringBoard 里，而本插件也住在 SpringBoard ⇒ 点一下直接调，
//     延迟为零、开机不受影响（符合"不要在 SpringBoard 里堆 hook"的项目明令）。
//  ② **动作用伪 bundleID 表示**（前缀 `mfsys.`）：`mfsys.screenshot`（截屏）、
//     `mfsys.translate`（翻译）。伪 ID 与真 App 的 bundleID 天然不冲突 ⇒ **整套现成机制
//     原样复用**：编辑器勾选、长按移出、「已添加」排序条调位置、图标贴图缓存、
//     呼出后悬停选中 —— 一行 UI 都不用另写。实现见 MFSystemActions.m。
//  ③ 三处接入点（改完就全覆盖）：
//     · `MFRingIconForBundleId()`：动作图标 = SF Symbol 自绘（带底圆的位图），不查 SB/图标缓存；
//     · `MFRingInstalledAppsForEditor()`：两个动作**置顶**列在编辑器最前面；
//     · `openFloatWithBundleId:`：所有"打开"入口（点图标 / 悬停松手 / 贴边松手）都汇聚到这里，
//       是动作就转 `MFSystemActionPerform`（不 pin App、不开浮窗），否则走原来的浮窗打开。
//  ④ 动作为什么延后 0.35s：调用方都已先 `hide`（收起动画 0.22s），截图类动作若立即执行
//     会把正在收起的圆盘截进图里。
//
//  ============================ 0.4.2 核心改动（用户 log37）============================
//  用户原话："为什么这一版不在像之前一样从圆盘触发条那里出现圆盘，然后跟随手指到屏幕中下
//  中心后固定呢？而是中固定点出现圆盘，我只是说取消跟随手指移动，没有说改变圆盘出现的位置，
//  继续修改"
//  ① **呼出起点回归「触发条位置」**：0.4.1 让 10% 小圆盘直接在屏幕中下中心原地冒出来 ——
//     用户明确说这不叫"取消跟随手指移动"，而是"改掉了圆盘出现的位置"。本版起点 =
//     **手指在触发条上按下的那个点**（`self.ringIntroStartCenter` = 触发点按 10% 缩放夹取，
//     贴边），圆盘**从触发条那里出现**。
//  ② **中段跟手位移 = 从触发点插值到屏幕中下中心**：手指滑动推进进度，圆心沿「起点 → 中下
//     中心」直线插值（`ringIntroCenterForProgress:`）—— 观感就是"圆盘被手指从触发条一路带到
//     屏幕中下中心"，而不是 0.3.27 那种"手指到哪圆盘到哪、满屏幕漫游"。
//  ③ **抵达中下中心即固定**：进度 100%（圆心已到 `mfRingParkCenterForBounds:`）⇒ 固定；
//     手指停住 1.0s 也自动补满并固定在同一处（`mfRingLatchDwell`）。
//  ④ 缩放仍由**手指累计滑动距离**驱动（0.4.1 已改对，保持）：滑得快 ⇒ 到 100% 快。
//     **位移与缩放共用同一个进度** ⇒ "走到中下中心"与"长到 100%"是同一个时刻。
//
//  ============================ 0.4.1 核心改动（用户 log36）============================
//  用户原话："现在有一个圆盘的问题，圆盘放大动画非常慢，应该是 2 秒时间限制，取消时间限制；
//  然后还是将圆盘固定在屏幕中下中心点，划到哪里停留 1 秒自动固定，圆盘不再随手指满屏幕移动了；
//  然后放大过渡动画修改一下，从划出到固定，从 10% 到 100%（如果手指滑动的快，那么它到 100%
//  的速度越快，随手指移动速度决定），现在的动画太慢了。"
//  ① **圆心回归「屏幕中下中心」固定点**（`parkCenter` 复活）= 屏宽中线 × 屏高 × `mfRingParkRatioY`
//     （老值 0.78）。0.3.27 的"圆心全程跟着手指满屏漫游"整个作废 —— 圆盘**只长大、不移动**。
//  ② **取消 2 秒时间上限：缩放改由「手指累计滑动距离」驱动**（10% → 100%）。
//     手指滑得快 ⇒ 单位时间走过的距离多 ⇒ 同一份进度用时更短 ⇒ **越快滑完越快 100%**；
//     中途停住就停在当时大小（这才是用户要的"跟手"）；回滑不回退（进度单调递增）。
//     进度基准 `ringIntroSpan` = **触发点到固定点的城市街区距离**（下限 100pt）⇒
//     "手指滑到圆盘所在位置"正好 100%。
//  ③ **停留 1.0 秒自动固定**：`mfRingLatchDwell` 2.0 → **1.0**（用户："划到哪里停留 1 秒自动固定"）。
//     手指一动就重新计时（>3pt 才算动）；到点 ⇒ `latchToParkCenterAnimated:` 弹簧补满到 100%
//     并进入"可选中"状态。滑满 100% 也会立刻固定（两条路等价）。
//  ④ CADisplayLink 逐帧推进（0.3.27 的时间驱动）**整段删除** —— 位置不再移动，缩放只跟手指走，
//     逐帧重算圆心那套理由（怕小圆盘在屏边长出屏）也不存在了。
//
//  ============================ 0.3.27 核心改动（用户 log34 后期）============================
//  用户原话："圆盘不在屏幕中下中心一个点固定，而是修改成划出圆盘后随手指移动，如果手指在
//  一个地方停留超过 2 秒，那么圆盘中心点固定在此。同时更新划出动画，并且圆盘在 2 秒内慢慢
//  放大到 100%（从触发滑动手势开始计时），刚划出时圆盘大小可以为 10%，然后位置随着滑动距离
//  而逐渐变大，最后圆盘的背景颜色可以在透明一点，这样在白色背景下不会显得特别黑。"
//  ⚠️ 其中"跟手漫游 + 2 秒时间驱动"已在 0.4.1 被用户否定并回退，此处仅作历史记录。
//  ① **停靠点作废 → 圆盘全程跟随手指，停留 2 秒就地固定**：
//     删掉 `parkCenter`（原来硬编码"屏幕下半屏 78% 处"那个固定点）与"进停靠容差 72pt 即固定"，
//     改成：跟随期间每次手指移动都重置一个 2.0s 停留计时器（`mfRingLatchDwell`），计时到点
//     就 `latchToCurrentCenterAnimated:` —— **固定在手指停下的那个位置**（= 当前圆心，按满尺寸
//     再夹一次保证整圆不出屏）。固定后仍照旧"滑动到图标上选择、松手即打开"。
//     夹取范围也顺势放开：原来圆盘被锁在下半屏（`minY = 屏中线`），现在整屏都能去（整圆不出屏）。
//  ② **划出动画 = 时间驱动长大（2.0s，10% → 100%）**：
//     0.3.25/0.3.26 都是"位移距离 → 缩放"（手指滑多远就长多大），用户要的是**时间驱动**：
//     从触发那一刻开始计时，2 秒内从 10% 线性长大到 100%；位置则完全跟着手指走。
//     实现换成 **CADisplayLink 逐帧推进**（不能用一次性 UIView 动画：手指停在屏边不动时
//     圆盘一边长大一边可能长出屏，逐帧才能同时把"缩放 + 夹取圆心"一起算对）。
//  ③ **底盘更透**：`dialLayer.fillColor` 0.12 白 / 0.55 alpha → 0.10 / 0.30，
//     白色背景下不再是一块深灰。
//
//  ============================ 0.3.26 核心改动（用户 log35）============================
//  ① **呼出跟手放大再修一处**。用户原话："手指停留右侧边缘时圆盘也会变成 100%，修改为
//     只有拖到屏幕中间固定时才能 100%；如果在中途停留，那么保持当时的大小不变"
//     log35 实证两个元凶（都在"手指停下没动"时被触发）：
//       · 元凶一 `scheduleSettle`（停顿 0.18s 即锁定）：贴边按下后手指只动了一下就停住，
//         0.18s 后就被判"想固定" ⇒ 弹簧把圆盘拉到停靠点并复位成 100%。
//         日志：`呼出跟手… 01:03:18.173` → `圆盘已固定到下半屏中心 01:03:18.354`（差 181ms）。
//         修法：**跟手期间不再排 settle** —— 只有手指真的进到停靠容差（默认 72pt）才固定。
//       · 元凶二 0.55s 的"兜底补间到 100%"（0.3.25 为"怕 App 吞事件流卡在 30%"加的）：
//         日志里 `呼出跟手：手指未继续滑动 → 兜底补间到 100%` 就是它。用户明确要求中途停留
//         保持当时大小 ⇒ **整个删掉**。真被吞事件流时手指一抬、屏幕上任意点一下即可收起
//         （展开态容器的 touchesEnded 就是"点空白收起"，不需要靠放大来救）。
//       · 进度基准改成 `ringIntroSpan` = **触发点到停靠点的城市街区距离**（原来写死 120pt）。
//         于是"拖到停靠点"与"刚好 100%"是同一个时刻：中途停在哪儿就停在哪儿的大小（单调不回退）。
//  ② **编辑器「已添加」排序条**。用户原话："圆盘内添加的自选应用无法自定义位置，所以在添加
//     自选应用页面为已添加应用排序"。编辑器顶部新增横滑排序条，按**圆盘真实顺序**列出已添加
//     App（左上角序号 + 图标 + 名称），每格 ◀ / ▶ 各点一下 = 前移 / 后移一格；
//     顺序即 `ringApps` 的顺序（点「完成」写盘，下次呼出立刻生效）。排序条与下方网格双向同步。
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
//  交互（0.4.2 定案）：
//    ① 贴边手势呼出后圆盘从**触发条位置**出现（10% 小圆盘，贴手指按下的那道边）；
//    ② 手指向屏幕内滑动 → 圆盘沿「触发点 → 屏幕中下中心」被**手指带着移动**，同时按
//       **累计滑动距离**从 10% 长大到 100%（滑得快长得快）；抵达中下中心即固定，
//       手指停住 1.0s 也自动补满并固定在同一处；
//    ③ 固定后手指滑动 → 高亮离手指最近的图标（悬停选择）；
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
//    mfRingLatchDwell   number 【0.4.2】手指停留多久就自动固定，秒（默认 1.0）
//    mfRingIntroMinScale number 【0.4.2】刚划出（在触发条处）时的圆盘缩放（默认 0.10 = 10%）
//    mfRingParkRatioY   number 【0.4.2】固定/位移终点圆心纵向 = 屏高 × 该值（默认 0.78 = 屏幕中下中心）
//    mfRingRings        number 圆盘圈数 1~3（默认 2；装得下时自动收敛为 1 圈）
//    mfRingRingGap      number 【0.6.21】内外圈可见间距，pt（默认 6）——**恒定值**，不随 App 数量变；
//                              相邻圈圆心距 = 图标直径 + 本值（越大两圈离得越开）
//    （mfRingInnerRatio 【0.6.21 起停用】旧的内圈半径比例，已由 mfRingRingGap 取代）
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
#import "MFSystemActions.h"   // 【0.4.12】圆盘系统动作（截屏 / 翻译）

#define MF_RING_GUARD_PATH   "/var/mobile/PullOverMF.ringguard"

// 【0.2.1】圆盘应用编辑器（全屏网格）
#define MF_RING_EDITOR_TAG       991010   // 面板根视图
#define MF_RING_EDITOR_SCROLL    991011   // 滚动容器
#define MF_RING_EDITOR_ICON      991012   // cell 里的图标视图
#define MF_RING_EDITOR_LABEL     991013   // cell 里的名称标签
#define MF_RING_EDITOR_CHECK     991014   // cell 右上角"已选"角标
#define MF_RING_EDITOR_DONE      991015   // 「完成」按钮
#define MF_RING_EDITOR_MAX_APPS  200      // 编辑器最多列出多少个 App（防爆）
// 【0.3.26 用户 log35】「已添加」排序条（自定义圆盘内应用位置）
// 【0.6.8 用户 log51 后】编辑器重做（简约/快捷/效率）：设置区折叠进「触发条」按钮；
//   排序条改长按拖拽（◀ ▶ 逐格点击已删）。
#define MF_RING_EDITOR_ORDER_INDEX   991016   // 排序条格子左上角序号
#define MF_RING_EDITOR_ROW_CHEVRON   991017   // 一级菜单行右侧箭头（布局时定位）
// 【0.7.5 用户指令】「点通知进悬浮窗」二级页（总开关 / 适用范围 / 应用名单）
#define MF_RING_NOTIFY_MARK          991018   // 名单行右侧勾选圈
#define MF_RING_NOTIFY_ROW_H         50.0     // 名单每行高
#define MF_RING_NOTIFY_ROW_GAP       8.0      // 名单行间距
#define MF_RING_ORDER_CELL_W 76.0             // 排序条格子宽
#define MF_RING_ORDER_CELL_H 102.0            // 排序条格子高
#define MF_RING_ORDER_CELL_GAP 6.0            // 格子间距
#define MF_RING_ORDER_INSET 10.0              // 排序条左右内边距
#define MF_RING_ORDER_SWAP_DEAD_ZONE 6.0      // 【0.6.17】拖拽换位死区：必须压进目标格内部才换位（防边界抖动）

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

/// 【0.3.22】写配置（编辑器滑杆用）。立即 synchronize，避免 SpringBoard 被杀导致设置丢失。
static void MFRingSetNumber(NSString *key, double value) {
    if (key.length == 0 || !isfinite(value)) {
        return;
    }
    [MFRingDefaults() setObject:@(value) forKey:key];
    [MFRingDefaults() synchronize];
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

/// 最近一次算出的圆盘内容数量（0.2.3：几何缩放要用它；触摸路径上零开销）
static NSUInteger gMFRingCount = 0;

/// 【0.6.16 用户 log56-① 重点修复】"圆盘里已添加的应用被重置" —— **列表保命三层通道**。
///
///   现场（log56 实证）：log54 用户刚保存了 19 项（启动读到 18 项有效），同一 SpringBoard
///   进程里**第一次**呼出圆盘仍是 18 项，**第二次**呼出就只剩 8 项 —— 正好等于 ringAppsAuto
///   （自动枚举列表）的数量。即：`ringApps` 中途读成了空 ⇒ 内容来源退化到自动列表，
///   用户看到的就是"新版本把我加的应用重置了"。
///
///   本版把列表**写三条通道**，读的时候逐条兜底 + 自动回写修复：
///     ① NSUserDefaults `ringApps`        —— 主通道（沿用原键名，老配置无损升级）
///     ② NSUserDefaults `ringAppsBackup`  —— 同域备份键（同一份内容）
///     ③ 独立文件 /var/mobile/Library/Preferences/com.mlgm.pulloverx.ring.json
///        —— 不走 NSUserDefaults，域级覆写/缓存失效都伤不到它
///   任何一条读到内容都会**立即回写**其余通道（自愈），并打一行点名日志
///   （`ringApps 主通道为空 → 从备份键/独立文件恢复 N 项`）⇒ 下一轮日志直接钉死元凶。
///   ★ 并且：一旦用户设置过（三通道任一命中，或本进程保存过），**永不**回落到自动列表
///     —— 这是"被重置"最直接的止血点。
static NSString * const kMFRingAppsBackupKey = @"ringAppsBackup";
static NSString * const kMFRingAppsStampKey  = @"ringAppsStamp";
static NSString * const kMFRingAppsFilePath  =
    @"/var/mobile/Library/Preferences/com.mlgm.pulloverx.ring.json";

static BOOL gMFRingUserEverSet = NO;             // 用户设置过（含只在文件通道里）
static NSString *gMFRingContentSource = @"空";    // 【0.6.16】本次内容来源（诊断日志用）

/// ③ 文件通道：写（原子写；失败只写日志）
static void MFRingWriteAppsFile(NSArray<NSString *> *ids) {
    @try {
        NSData *data = [NSJSONSerialization dataWithJSONObject:(ids ?: @[]) options:0 error:NULL];
        if (data == nil) {
            MFLog(@"[ring] !! 列表文件通道序列化失败");
            return;
        }
        if (![data writeToFile:kMFRingAppsFilePath atomically:YES]) {
            MFLog(@"[ring] !! 列表文件通道写入失败：%@", kMFRingAppsFilePath);
        }
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 列表文件通道写入异常：%@", exception);
    }
}

/// ③ 文件通道：读（不存在 / 解析失败 → nil）
static NSArray<NSString *> *MFRingReadAppsFile(void) {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:kMFRingAppsFilePath];
        if (data == nil) {
            return nil;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        return [json isKindOfClass:[NSArray class]] ? (NSArray *)json : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// 三通道解析（优先级 ①→②→③）。返回过滤后的列表；`outSource` 回传命中通道名，
/// `outHadAny` 回传"用户是否设置过"（三通道任一存在即算）。非主通道命中 ⇒ 立刻回写主通道。
static NSArray<NSString *> *MFRingConfiguredBundleIdsWithSource(NSString **outSource, BOOL *outHadAny) {
    NSUserDefaults *defaults = MFRingDefaults();
    id raw = nil;
    NSString *source = @"默认域";
    @try {
        raw = [defaults objectForKey:@"ringApps"];
    } @catch (__unused NSException *exception) {
        raw = nil;
    }
    if (raw == nil) {
        @try {
            raw = [defaults objectForKey:kMFRingAppsBackupKey];
        } @catch (__unused NSException *exception) {
            raw = nil;
        }
        if (raw != nil) {
            source = @"备份键";
        }
    }
    if (raw == nil) {
        raw = MFRingReadAppsFile();
        if (raw != nil) {
            source = @"独立文件";
        }
    }
    if (raw == nil) {
        if (outSource != NULL) {
            *outSource = @"无";
        }
        if (outHadAny != NULL) {
            *outHadAny = gMFRingUserEverSet;
        }
        gMFRingContentSource = gMFRingUserEverSet ? @"用户清空" : @"空（从未设置）";
        return @[];
    }
    NSArray<NSString *> *ids = MFRingFilterBundleIds(raw, 0);
    if (outSource != NULL) {
        *outSource = source;
    }
    if (outHadAny != NULL) {
        *outHadAny = YES;
    }
    gMFRingUserEverSet = YES;
    gMFRingContentSource = (ids.count > 0) ? [NSString stringWithFormat:@"用户列表·%@", source]
                                           : @"用户清空";
    if (![source isEqualToString:@"默认域"]) {
        // 自愈：救回来的那份立刻写回主通道 + 文件通道，下一轮读就走主通道
        MFLog(@"[ring] ringApps 主通道为空 → 从「%@」恢复 %lu 项并回写（列表被重置的现场）",
              source, (unsigned long)ids.count);
        @try {
            [defaults setObject:ids forKey:@"ringApps"];
            [defaults setObject:ids forKey:kMFRingAppsBackupKey];
            [defaults synchronize];
        } @catch (NSException *exception) {
            MFLog(@"[ring] !! ringApps 回写默认域异常：%@", exception);
        }
        MFRingWriteAppsFile(ids);
    }
    return ids;
}

/// 用户是否**亲手设置过**圆盘内容（三通道任一命中即算）。写过就必须尊重用户的选择，
/// 不再回落到自动枚举 —— 否则"我把圆盘清空"会变成"又冒出一堆你不想要的 App"。
static BOOL MFRingUserListSet(void) {
    BOOL hadAny = NO;
    MFRingConfiguredBundleIdsWithSource(NULL, &hadAny);
    return hadAny;
}

/// 用户手动指定的圆盘内容 —— 纯字符串过滤，不查 SB
static NSArray<NSString *> *MFRingConfiguredBundleIds(void) {
    return MFRingConfiguredBundleIdsWithSource(NULL, NULL);
}

/// 圆盘最终内容：**用户列表 > 自动枚举缓存 > 空**。
/// 【0.6.16】关键止血：只要用户设置过（含"清空"），就**只看用户列表**，
/// 绝不再因为主通道读空而退化到自动列表（log56 的"被重置"正是这条退路造成的）。
/// 只读内存 / NSUserDefaults / 一个 json 文件。
static NSArray<NSString *> *MFRingBundleIds(void) {
    NSUInteger limit = MFRingMaxIcons();
    NSString *source = nil;
    BOOL hadAny = NO;
    NSArray<NSString *> *configured = MFRingConfiguredBundleIdsWithSource(&source, &hadAny);
    NSArray<NSString *> *result = @[];
    if (hadAny) {
        // 写过就以用户为准（空数组 ⇒ 圆盘空，显示"长按边缘添加"提示）
        result = (configured.count > limit) ? [configured subarrayWithRange:NSMakeRange(0, limit)]
                                            : configured;
        gMFRingContentSource = (result.count > 0)
            ? [NSString stringWithFormat:@"用户列表·%@", source]
            : @"用户清空";
    } else if (gMFRingAutoBundleIds.count > 0) {
        result = (gMFRingAutoBundleIds.count > limit)
            ? [gMFRingAutoBundleIds subarrayWithRange:NSMakeRange(0, limit)]
            : gMFRingAutoBundleIds;
        gMFRingContentSource = @"自动列表";
    } else {
        gMFRingContentSource = @"空";
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
    // 【0.4.12 用户 log38 → 0.6.11 扩编】ACR 快捷方式（截屏/翻译/录屏/控制中心/通知中心）
    //   **置顶**展示 —— 它们不是"已安装 App"，不参与上面的中文名排序；
    //   伪 bundleID（mfsys.*）与真 App 不冲突，可以直接混着勾选。
    //   【0.6.11 用户指令】未添加 tab 网格里 ACR 与桌面应用分区展示（见 relayoutEditorGridAnimated）。
    NSArray<NSDictionary<NSString *, NSString *> *> *systemActions = MFSystemActionEditorEntries();
    if (systemActions.count > 0) {
        [apps insertObjects:systemActions
                  atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, systemActions.count)]];
        MFLog(@"[ring] 编辑器已置顶 %lu 个 ACR 快捷方式", (unsigned long)systemActions.count);
    }
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
    // 【0.6.16】三通道一起写：主键 + 备份键 + 独立文件（任何一条活着，列表就不会丢）
    NSUserDefaults *defaults = MFRingDefaults();
    NSArray<NSString *> *payload = ids ?: @[];
    @try {
        [defaults setObject:payload forKey:@"ringApps"];
        [defaults setObject:payload forKey:kMFRingAppsBackupKey];
        [defaults setObject:@([[NSDate date] timeIntervalSince1970]) forKey:kMFRingAppsStampKey];
        [defaults synchronize];   // 【0.3.22】立即落盘，避免 SpringBoard 被杀导致设置丢失
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! ringApps 写默认域异常：%@", exception);
    }
    MFRingWriteAppsFile(payload);
    gMFRingUserEverSet = YES;
    MFLog(@"[ring] ringApps 已保存 %lu 项（三通道：默认域 + 备份键 + 独立文件）",
          (unsigned long)payload.count);
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
    // 【0.4.12】系统动作（mfsys.*）：图标是 SF Symbol 自绘的，**不查任何 SB / 图标缓存**。
    //   与真 App 图标共用同一个缓存字典（key 是伪 bundleID，天然不冲突）。
    if (MFSystemActionIsActionId(bundleId)) {
        UIImage *cachedAction = MFRingIconCache()[bundleId];
        if (cachedAction != nil) {
            return cachedAction;
        }
        UIImage *actionIcon = MFSystemActionIcon(bundleId, 72.0);
        if (actionIcon != nil) {
            MFRingIconCache()[bundleId] = actionIcon;
        }
        return actionIcon;
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
    CGFloat ringPitch;     // 【0.6.21】相邻圈圆心距：固定 = 图标直径 + mfRingRingGap
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
    // 【0.6.21 用户 log60】内外圈间距**固定**：相邻圈圆心距 = 图标直径 + mfRingRingGap（默认 6pt）。
    //   旧的 mfRingInnerRatio 只影响"规划阶段"的容量估算，真正绘制的内圈半径来自下面的等距解
    //   （内圈 = 外圈 × 内圈数/外圈数）⇒ 数量越多内圈越往里缩 ⇒ 内外圈间距越来越大。现改为固定圆心距。
    CGFloat ringGap = MAX(0.0, MFRingNumber(@"mfRingRingGap", 6.0));
    CGFloat ringPitch = iconSize + ringGap;
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
                r -= ringPitch;
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
    geo.ringPitch = ringPitch;

    NSUInteger rings = 0;
    CGFloat r = outer;
    for (NSUInteger ring = 0; ring < desiredRings; ring++) {
        if (ring > 0) {
            r -= ringPitch;
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
/// 【0.6.21 用户 log60】内外圈**固定间距**布局解（呼出圆盘与编辑器实时预览共用，保证排布一致）。
///
/// 旧算法：绘制内圈半径 = 外圈半径 × (内圈图标数 / 外圈图标数) ⇒ App 越多 nIn/nOut 越小 ⇒
///   内圈相对越往中心缩 ⇒ 内外圈间距随数量变大（log60 实测 18 个≈48pt、20 个≈61pt）。
/// 新算法：相邻圈圆心距 pitch = 图标直径 + mfRingRingGap（默认 6，**固定值**）；
///   内圈半径 = 外圈半径 − pitch；再按"两圈弧上间距一致"反解外圈半径：
///     nIn/nOut = rIn/rOut 且 rIn = rOut − pitch  ⇒  rOut = pitch × nOut/(nOut − nIn)。
///   于是无论圆盘里有多少个 App，内外圈的**可见间距恒等于 mfRingRingGap**。
typedef struct {
    NSUInteger rings;         // 实际圈数（1 或 2）
    NSUInteger counts[3];     // 每圈图标数（由外到内）
    CGFloat radii[3];         // 每圈图标圆心半径（由外到内）
    NSUInteger total;         // 实际摆放总数（可能被"所有圈总容量"截断）
} MFRingLayout;

static MFRingLayout MFRingSolveLayout(MFRingGeometry geo, NSUInteger count) {
    MFRingLayout lay = (MFRingLayout){ 0, { 0, 0, 0 }, { 0.0, 0.0, 0.0 }, 0 };
    if (count == 0) {
        return lay;
    }
    CGFloat outerRadius = geo.outerRadius;
    CGFloat iconSize = geo.iconSize;
    CGFloat step = geo.step;
    CGFloat pitch = MAX(geo.ringPitch, 1.0);
    NSUInteger maxRings = MIN(MAX(geo.rings, (NSUInteger)1), (NSUInteger)3);

    // ① 规划每圈半径 / 容量（由外到内）：半径按**固定** pitch 递减（不再等比收缩）
    CGFloat planRadii[3] = { 0.0, 0.0, 0.0 };
    NSUInteger planCaps[3] = { 0, 0, 0 };
    NSUInteger rings = 0;
    for (NSUInteger ring = 0; ring < maxRings; ring++) {
        CGFloat rr = (ring == 0) ? outerRadius : (planRadii[ring - 1] - pitch);
        if (ring > 0 && rr < iconSize * 1.15) {
            break;   // 内圈塞不下图标就不再加圈
        }
        planRadii[ring] = rr;
        planCaps[ring] = (NSUInteger)MAX(floor((2.0 * M_PI * rr) / step), 1.0);
        rings++;
    }
    if (rings == 0) {
        planRadii[0] = outerRadius;
        planCaps[0] = 1;
        rings = 1;
    }

    // ② 单圈收敛（0.2.5 规则不变）：装得下单圈、或"恰好步距"的单圈半径没超规划外圈×1.15
    CGFloat snugAll = (CGFloat)count * step / (2.0 * M_PI);
    if (count <= planCaps[0] || snugAll <= outerRadius * 1.15) {
        rings = 1;
    } else {
        while (rings > 1 && planCaps[rings - 1] < 3) {
            rings--;
        }
    }
    // ③ 单圈：半径按"恰好步距"反算。**不按规划容量截断** —— 规划容量是在规划半径上算的，
    //   而单圈实际画在 snug 半径（可能更大）上，容量必然 ≥ count。这里顺带修掉老问题：
    //   App 数 13/14 时会被截成 12 个（加了 App 圆盘却没变化）。
    if (rings == 1) {
        lay.rings = 1;
        lay.total = count;
        lay.counts[0] = count;
        CGFloat snug = (CGFloat)count * step / (2.0 * M_PI);
        lay.radii[0] = MIN(MAX(snug, iconSize * 1.15), outerRadius * 1.35);
        return lay;
    }

    NSUInteger totalCap = 0;
    for (NSUInteger ring = 0; ring < rings; ring++) {
        totalCap += planCaps[ring];
    }
    NSUInteger want = count;
    if (totalCap > 0 && want > totalCap) {
        want = totalCap;   // 兜底：超出所有圈总容量时截断
    }
    lay.total = want;

    // ④ 双圈：内圈半径 = 外圈 − pitch（圆心距固定）。**优先用规划外圈半径本身** ——
    //    保持"圆盘大小随数量变化"的既有观感，不为了让图标不重叠而无谓撑大圆盘；
    //    图标数按两圈半径比例分配（外圈多、内圈少），两圈弧距接近一致。
    CGFloat maxOuter = MIN(outerRadius * 1.5, outerRadius + iconSize * 0.5 + 16.0);
    CGFloat planInnerRadius = outerRadius - pitch;
    if (planInnerRadius >= iconSize * 1.15) {
        NSUInteger nOut = (NSUInteger)floor((double)want * outerRadius /
                                            (outerRadius + planInnerRadius) + 0.5);
        if (nOut > want - 1) {
            nOut = want - 1;
        }
        if (nOut < 1) {
            nOut = 1;
        }
        NSUInteger nIn = want - nOut;
        CGFloat sOut = (2.0 * M_PI * outerRadius) / (CGFloat)nOut;
        CGFloat sIn = (nIn > 0) ? (2.0 * M_PI * planInnerRadius) / (CGFloat)nIn : 0.0;
        if (nIn >= 1 && nOut > nIn && sOut >= step && sIn >= step) {
            lay.rings = 2;
            lay.counts[0] = nOut;
            lay.counts[1] = nIn;
            lay.radii[0] = outerRadius;
            lay.radii[1] = planInnerRadius;
            MFLog(@"[ring] 内外圈固定间距：外 %lu 个 @ r=%.0f、内 %lu 个 @ r=%.0f"
                  @"（圆心距 %.0f 固定 = 图标 %.0f + 间距 %.0f）",
                  (unsigned long)nOut, outerRadius, (unsigned long)nIn, planInnerRadius,
                  pitch, iconSize, pitch - iconSize);
            return lay;
        }
    }

    //  兜底搜索：固定 pitch 下 rOut 由 (nIn, nOut) 唯一确定（rOut = pitch×nOut/(nOut−nIn)），
    //    取"弧距 ≥ 步距 且最小"的解（外圈尽量满）
    CGFloat bestOuterRadius = 0.0;
    CGFloat bestSpacing = 0.0;
    NSUInteger bestInner = 0;
    NSUInteger bestOuter = 0;
    for (NSUInteger nOut = want - 1; nOut >= 2; nOut--) {
        NSUInteger nIn = want - nOut;
        if (nIn < 1 || nOut <= nIn) {
            continue;   // 用户要求：内圈少、外圈多
        }
        CGFloat rOut = pitch * (CGFloat)nOut / (CGFloat)(nOut - nIn);
        if (rOut > maxOuter) {
            continue;   // 外圈不许顶出底盘安全上限
        }
        if (rOut - pitch < iconSize * 1.15) {
            continue;   // 内圈塞不下图标
        }
        CGFloat spacing = (2.0 * M_PI * rOut) / (CGFloat)nOut;   // 等弧距下两圈共用
        if (spacing < step) {
            continue;   // 相邻图标不许重叠
        }
        if (bestOuter == 0 || spacing < bestSpacing) {
            bestSpacing = spacing;
            bestOuterRadius = rOut;
            bestInner = nIn;
            bestOuter = nOut;
        }
    }
    if (bestOuter > 0) {
        lay.rings = 2;
        lay.counts[0] = bestOuter;
        lay.counts[1] = bestInner;
        lay.radii[0] = bestOuterRadius;
        lay.radii[1] = bestOuterRadius - pitch;
        MFLog(@"[ring] 固定间距兜底解：外 %lu 个 @ r=%.0f、内 %lu 个 @ r=%.0f（弧距 %.1f 圆心距 %.0f 固定）",
              (unsigned long)bestOuter, bestOuterRadius,
              (unsigned long)bestInner, bestOuterRadius - pitch,
              bestSpacing, pitch);
        return lay;
    }

    // 退路：外圈先铺满、剩余进内圈；内圈半径 = 外圈 − pitch（间距仍然固定）
    NSUInteger left = want;
    for (NSInteger ring = (NSInteger)rings - 1; ring >= 0 && left > 0; ring--) {
        NSUInteger take = MIN(planCaps[(NSUInteger)ring], left);
        lay.counts[(NSUInteger)ring] = take;
        left -= take;
    }
    lay.rings = (lay.counts[1] > 0) ? 2 : 1;
    lay.radii[0] = outerRadius;
    if (lay.rings == 2) {
        lay.radii[1] = MAX(outerRadius - pitch, iconSize * 1.15);
    }
    MFLog(@"[ring] 固定间距退路：外 %lu 个 @ r=%.0f、内 %lu 个 @ r=%.0f（圆心距 %.0f）",
          (unsigned long)lay.counts[0], lay.radii[0],
          (unsigned long)lay.counts[1], lay.rings == 2 ? lay.radii[1] : 0.0, pitch);
    return lay;
}


// 【0.6.10】圆盘槽位计算 —— 呼出布局算法的纯函数版（等距双圈求解 / 单圈收敛 / 退路分配 /
// 内圈错半格，全部与真实呼出一致），编辑器实时预览用它画出"圆盘真实排布"。
typedef struct {
    CGFloat angleDegrees;   // -90 = 正上方起，顺时针
    CGFloat radius;
} MFRingSlotPos;

static NSUInteger MFRingComputeRingSlots(CGRect hostBounds, NSUInteger count, CGFloat rotation,
                                         MFRingSlotPos *outSlots, NSUInteger maxSlots) {
    if (outSlots == NULL || maxSlots == 0 || count == 0) {
        return 0;
    }
    MFRingGeometry geo = MFRingComputeGeometry(hostBounds, count);
    NSUInteger want = MIN(count, maxSlots);
    CGFloat outerRadius = geo.outerRadius;
    CGFloat iconSize = geo.iconSize;
    CGFloat step = geo.step;
    CGFloat startAngle = MFRingNumber(@"mfRingStartAngle", -90.0);

    // ①–③【0.6.21 用户 log60】统一"内外圈固定间距"布局解（与呼出圆盘共用 MFRingSolveLayout，
    //   保证编辑器实时预览与真实圆盘排布完全一致）。
    MFRingLayout layout = MFRingSolveLayout(geo, count);
    NSUInteger rings = layout.rings;
    want = MIN(layout.total, maxSlots);
    CGFloat ringRadiiArr[3] = { 0.0, 0.0, 0.0 };
    NSUInteger perRingArr[3] = { 0, 0, 0 };
    for (NSUInteger ring = 0; ring < rings && ring < 3; ring++) {
        ringRadiiArr[ring] = layout.radii[ring];
        perRingArr[ring] = layout.counts[ring];
    }
    // ④ 逐圈产出槽位（内圈错半格）—— 同呼出布局 ⑤
    NSUInteger placed = 0;
    for (NSUInteger ring = 0; ring < rings && placed < want; ring++) {
        CGFloat iconRadius = (ring < 3) ? ringRadiiArr[ring] : outerRadius;
        NSUInteger ringCount = (ring < 3) ? perRingArr[ring] : 0;
        for (NSUInteger slot = 0; slot < ringCount && placed < want; slot++, placed++) {
            CGFloat stagger = (ring % 2 == 1) ? (180.0 / (CGFloat)MAX(ringCount, (NSUInteger)1)) : 0.0;
            outSlots[placed].angleDegrees = startAngle + stagger
                + 360.0 * (CGFloat)slot / (CGFloat)MAX(ringCount, (NSUInteger)1)
                + rotation;
            outSlots[placed].radius = iconRadius;
        }
    }
    return placed;
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
@property (nonatomic, assign) BOOL ringLatched;                // 圆盘是否已固定（屏幕中下中心 · 停留 1s 或滑满自动固定）
@property (nonatomic, weak) UIButton *selectedButton;          // 悬停选中的图标
@property (nonatomic, assign) CGPoint lastFingerPoint;         // 最近一次手指屏幕坐标
@property (nonatomic, assign) CGPoint latchFingerPoint;        // 固定那一刻的手指坐标
@property (nonatomic, assign) BOOL hasLatchFinger;             // 是否已记录固定时的手指位置
// 【0.2.1】圆盘应用编辑器（长按边缘触发条打开）
@property (nonatomic, strong) UIView *editorPanel;             // 全屏编辑面板
@property (nonatomic, strong) UIScrollView *editorScroll;      // 面板里的滚动容器
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *editorSelection;  // 已选 bundleID（有序）
@property (nonatomic, strong) NSMutableArray<UIView *> *editorCells;             // 网格 cell（顺序填图标）
@property (nonatomic, strong) UILabel *editorCountLabel;       // "已选 N 个"
@property (nonatomic, assign) NSUInteger editorIconGeneration;  // 编辑器图标填充代次
// 【0.3.26 用户 log35】「已添加」排序条（横滑；顺序 = 圆盘上图标的位置）
@property (nonatomic, strong) UILabel *editorOrderTitle;           // 排序条标题（含"已添加 N 个"）
@property (nonatomic, strong) UIScrollView *editorOrderScroll;     // 排序条滚动容器
@property (nonatomic, strong) NSMutableArray<UIView *> *editorOrderCells;  // 排序条格子
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *editorAppNames;  // bundleID→显示名（枚举时一次性取好）
// 【0.6.8 用户指令】编辑器重做：设置折叠 + 拖拽排序
@property (nonatomic, strong) UIView *triggerSettingsBox;          // 触发条设置折叠容器（默认收起）
@property (nonatomic, assign) BOOL editorSettingsExpanded;         // 设置区当前展开？
@property (nonatomic, strong) UIButton *editorSettingsToggle;      // 「触发条 ▸/▾」切换按钮
@property (nonatomic, assign) CGFloat editorContentBaseTop;        // 折叠态内容起始 Y（设置区下方基线）
@property (nonatomic, strong) UIView *editorOrderDraggingCell;     // 拖拽中的排序格子（layout 跳过它）
@property (nonatomic, assign) NSUInteger editorOrderDragIndex;     // 拖拽中格子的当前 index
@property (nonatomic, assign) NSUInteger editorOrderDragSwapCount;  // 【0.6.16】本场拖拽换位次数（诊断）
@property (nonatomic, assign) CGFloat editorOrderDragGrabOffset;   // 按下点相对格子中心的偏移
@property (nonatomic, assign) CGFloat editorOrderDragGrabOffsetY;  // 【0.6.11】平铺网格拖拽：Y 向提起偏移
// 【0.6.10 用户指令】编辑器二级菜单：一级只留菜单行（应用管理/触发条/其他选项），
//   全部 App 收进二级「应用管理」（已添加 / 未添加 两个 tab）；已添加 tab 顶部有
//   圆盘实时预览 —— 拖动排序/加/减成员时图标位置即时跟随，所见即圆盘真实排布。
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *editorApps;  // 枚举结果留存（二级页数据源）
@property (nonatomic, strong) UIView *editorMenuBox;               // 一级菜单容器
@property (nonatomic, strong) UIView *editorAppsBox;               // 二级「应用管理」页容器
@property (nonatomic, assign) BOOL editorLevel2Visible;            // 当前在二级页？
@property (nonatomic, assign) BOOL editorTabAdded;                 // 二级页当前 tab：YES=已添加 / NO=未添加
@property (nonatomic, strong) UIView *editorPreviewBox;            // 圆盘实时预览容器（已添加 tab 顶部）
@property (nonatomic, strong) UIView *otherSettingsBox;            // 「其他选项」折叠容器
@property (nonatomic, assign) BOOL editorOtherExpanded;            // 其他选项当前展开？
@property (nonatomic, strong) UILabel *editorRadiusValueLabel;     // 圆盘大小滑杆数值标签
@property (nonatomic, strong) UIButton *editorRowApps;             // 一级行：应用管理
@property (nonatomic, strong) UIButton *editorRowTrigger;          // 一级行：触发条
@property (nonatomic, strong) UIButton *editorRowOther;            // 一级行：其他选项
// 【0.7.5 用户指令】「点通知进悬浮窗」独立成一级行 + 二级页（总开关 / 全部应用 或 仅选中的应用）
@property (nonatomic, strong) UIButton *editorRowNotify;           // 一级行：点通知进悬浮窗
@property (nonatomic, strong) UIView *editorNotifyBox;             // 二级「点通知进悬浮窗」页容器
@property (nonatomic, weak) UIView *editorVisiblePage;             // 当前可见的二级页（nil = 一级菜单）
@property (nonatomic, strong) UIButton *editorNotifyBackButton;    // 通知页返回按钮
@property (nonatomic, strong) UILabel *editorNotifyTitleLabel;     // 通知页标题
@property (nonatomic, strong) UIView *editorNotifySwitchBox;       // 总开关行底板
@property (nonatomic, strong) UILabel *editorNotifySwitchLabel;    // 总开关行文字
@property (nonatomic, strong) UISwitch *editorNotifySwitch;        // 总开关
@property (nonatomic, strong) UILabel *editorNotifyScopeLabel;     // 「适用范围」小标题
@property (nonatomic, strong) UIButton *editorNotifyAllButton;     // 范围：全部应用
@property (nonatomic, strong) UIButton *editorNotifyPickButton;    // 范围：仅选中的应用
@property (nonatomic, strong) UILabel *editorNotifyHintLabel;      // 状态提示
@property (nonatomic, strong) UIScrollView *editorNotifyScroll;    // 应用名单滚动容器
@property (nonatomic, strong) NSMutableArray<UIButton *> *editorNotifyRows;          // 名单行
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *editorNotifySelected; // 勾选的 bundleID
@property (nonatomic, strong) UIButton *editorBackButton;          // 二级页返回按钮
@property (nonatomic, strong) UIButton *editorTabAddedButton;      // 分段按钮：已添加
@property (nonatomic, strong) UIButton *editorTabAllButton;        // 分段按钮：未添加
// 【0.3.22】触发条自调（用户 log31：触发条要能自己控制大小；且右侧屏幕中段也会呼出 ⇒ 容易误触）
@property (nonatomic, strong) UIView *triggerPreviewView;      // 编辑器开着时的触发条高亮预览
@property (nonatomic, strong) NSMutableArray<UILabel *> *triggerValueLabels;  // 三根滑杆的数值标签
@property (nonatomic, strong) UILongPressGestureRecognizer *stripLongPress;
// 【0.4.2 用户 log37】呼出 = **从触发条出现 → 跟手位移到中下中心 → 固定**：
//   起点圆心 = 手指按下的触发点（含 10% 缩放夹取，贴边）；
//   手指滑动推进进度，圆心沿「起点 → 中下中心」插值、缩放 10% → 100%；
//   抵达中下中心（进度 100%）或手指停住 1.0s ⇒ 自动固定（0.4.1 的"原地冒出来"作废）。
#define MF_RING_INTRO_MIN_SCALE 0.10          // 呼出瞬间的圆盘缩放（用户指定 10%）
#define MF_RING_INTRO_MIN_SPAN 100.0          // 进度基准（触发点到中下中心的距离）下限，pt
#define MF_RING_INTRO_EASE 1.6                // 【0.4.13】进度→观感缓动指数（1=线性旧行为；>1 前期长得快、临终点自然减速）
#define MF_RING_PARK_RATIO_Y 0.78             // 位移终点/固定圆心纵向 = 屏高 × 该值（屏幕中下中心）
#define MF_RING_LATCH_DWELL 1.0               // 手指停留多久就自动固定（秒，用户指定 1s）
@property (nonatomic, assign) CGFloat ringIntroProgress;               // 呼出进度 0~1（累计距离 / 基准）
@property (nonatomic, assign) CGFloat ringIntroTravel;                 // 本次呼出累计滑动距离（pt，单调递增）
@property (nonatomic, assign) CGFloat ringIntroSpan;                   // 本次呼出的进度基准（pt）
@property (nonatomic, assign) CGPoint ringIntroLastPoint;              // 上次累计距离用的触点
@property (nonatomic, assign) CGPoint ringIntroStartCenter;            // 【0.4.2】呼出起点圆心（触发点，按 10% 夹取）
@property (nonatomic, assign) CGPoint ringIntroParkCenter;             // 【0.4.2】本次呼出的终点圆心（屏幕中下中心）
@property (nonatomic, assign) CGFloat ringIntroMinScale;               // 本次呼出的起始缩放（配置键读取一次）
@property (nonatomic, assign) CGPoint ringDwellAnchorPoint;            // 上次重置"停留计时"时的触点（抖动阈值用）
@property (nonatomic, assign) NSUInteger ringDwellGeneration;          // 停留计时器代次
@property (nonatomic, assign) NSTimeInterval ringDwellStartedAt;       // 本次停留起点（日志用）
+ (instancetype)shared;
- (void)install;
- (void)teardownHostViews;
- (UIView *)hitTestViewForPoint:(CGPoint)point inWindow:(UIWindow *)window;
- (void)refreshHostGeometryIfNeeded;
- (CGRect)triggerFrameForBounds:(CGRect)bounds;
/// 【0.3.23】触发条"外侧边到屏幕边"的距离（应恒为 0 = 贴边），日志核对用
- (CGFloat)triggerOuterEdgeGapForBounds:(CGRect)bounds;
- (BOOL)pointBelongsToPullOverHandle:(CGPoint)point;
- (void)onStripPan:(UIPanGestureRecognizer *)gesture;
- (void)onRingHoverPan:(UIPanGestureRecognizer *)gesture;
- (void)onStripLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)showAtPoint:(CGPoint)point;
- (void)moveRingToPoint:(CGPoint)point;
/// 【0.4.2】固定 = 圆心收在「屏幕中下中心」（进度 100% 时圆盘已走到那儿，这里弹簧补满收尾）
- (void)latchToParkCenterAnimated:(BOOL)animated;
/// 【0.4.2】呼出位移终点 / 固定圆心：屏幕中下中心（屏宽中线 × 屏高 × mfRingParkRatioY）
- (CGPoint)mfRingParkCenterForBounds:(CGRect)bounds;
- (void)buildRingInContainer:(UIView *)container;
/// 【0.3.25】同步贴真图标（呼出时用，避免"先看 0.4s 首字母占位"）
- (NSUInteger)fillIconsSynchronouslyForGeneration:(NSUInteger)generation;
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation delay:(NSTimeInterval)delay;
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation;
/// 【0.3.24】收起动画的起点圆心：贴着**触发条所在的那条屏幕边**，让圆盘"缩回边缘"
- (CGPoint)ringIntroStartCenterForBounds:(CGRect)bounds target:(CGPoint)target;
/// 【0.4.2】滑动距离驱动的长大（+ 起点→中下中心位移）+ 停留自动固定
- (CGFloat)mfRingIntroCurrentScale;
/// 【0.4.13】进度→观感缓动（easeOut 幂曲线，`mfRingIntroEase` 可调）
- (CGFloat)mfRingIntroEasedT;
/// 【0.4.2】当前进度对应的圆心：起点（触发条）→ 终点（屏幕中下中心）线性插值，再按缩放夹取
- (CGPoint)ringIntroCenterForProgress:(CGFloat)progress;
- (void)mfApplyRingIntroFrame;
- (void)mfScheduleLatchDwell;
- (CGPoint)mfClampRingCenter:(CGPoint)point scale:(CGFloat)scale;
- (void)refreshRingContentsIfVisible;
- (void)scheduleAutoBundleIdEnumeration;
- (void)updateSelectionForPoint:(CGPoint)point;
/// 【0.2.15】松手时该打开哪个 App：仅松手点压在图标上的当前选中；否则 nil（收起，不开）
- (NSString *)releaseOpenBundleIdForPoint:(CGPoint)point;
/// ⚠️ 注意：**绝不能**命名为 setSelectedButton:（详见实现处 0.2.0 血案注释）
- (void)applySelectionToButton:(UIButton *)button;
- (void)applySelectionVisual:(UIButton *)button selected:(BOOL)selected;
- (void)openFloatWithBundleId:(NSString *)bundleId;
// 【0.3.27】clampRingCenter:（满尺寸夹取）已无调用方，删除以免留死代码 —— 一律走 mfClampRingCenter:scale:
- (void)hide;
// 【0.2.1】应用编辑器
- (void)openEditor;
- (void)buildEditorPanelWithApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps;
- (void)fillEditorIcons:(NSArray<UIView *> *)cells
              fromIndex:(NSUInteger)index
             generation:(NSUInteger)generation;
- (void)onEditorCellTapped:(UIButton *)button;
- (void)onEditorDone:(UIButton *)sender;
// 【0.3.26 用户 log35】「已添加」排序条（自定义圆盘内应用位置）
- (void)rebuildEditorOrderStrip;
- (void)layoutEditorOrderCellsAnimated:(BOOL)animated;
- (NSUInteger)mfEditorOrderColumnsForWidth:(CGFloat)width;   // 【0.6.11】排序网格每行列数
- (void)applyEditorOrderCellDecorations:(UIView *)cell index:(NSUInteger)index total:(NSUInteger)total;
// 【0.6.8 用户指令】拖拽排序（长按提起 → 跟手换位 → 松手落位）
- (void)onEditorOrderDrag:(UILongPressGestureRecognizer *)gesture;
- (void)moveEditorOrderCellFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
// 【0.6.8 用户指令】设置区折叠（0.6.10 起布局走 layoutEditorMenuAnimated）
- (void)onEditorSettingsToggle:(UIButton *)sender;
// 【0.3.22】触发条几何自调（编辑器顶部滑杆，装进折叠容器）
- (void)buildTriggerSettingsInPanel:(UIView *)panel top:(CGFloat)top;
- (void)onTriggerSliderChanged:(UISlider *)slider;
- (void)refreshTriggerGeometryAfterPrefsChange;
- (void)syncTriggerValueLabels;
- (void)applyEditorCellVisual:(UIView *)cell selected:(BOOL)selected;
- (void)refreshEditorCount;
- (void)closeEditorSaving:(BOOL)saving;
// 【0.6.10 用户指令】二级菜单 + 圆盘实时预览
- (UIButton *)makeEditorMenuRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)layoutEditorMenuAnimated:(BOOL)animated;
- (void)layoutEditorAppsAnimated:(BOOL)animated;
- (void)showEditorLevel2:(BOOL)level2;
- (void)onEditorRowAppsTapped:(UIButton *)sender;
- (void)onEditorBackTapped:(UIButton *)sender;
- (void)onEditorTabChanged:(UIButton *)sender;
- (void)onEditorOtherToggle:(UIButton *)sender;
- (void)onEditorOtherSwitchChanged:(UISwitch *)switchView;
- (void)onEditorRadiusSliderChanged:(UISlider *)slider;
- (void)onEditorOrderStripTap:(UITapGestureRecognizer *)tap;
// 【0.7.5 用户指令】点通知进悬浮窗：独立一级行 + 二级页（总开关 / 全部应用 或 仅选中的应用）
- (void)showEditorPage:(UIView *)page animated:(BOOL)animated;
- (void)onEditorRowNotifyTapped:(UIButton *)sender;
- (void)buildEditorNotifyPageInPanel:(UIView *)panel width:(CGFloat)width height:(CGFloat)height;
- (void)layoutEditorNotifyPage;
- (void)refreshEditorNotifyVisuals;
- (void)onEditorNotifySwitchChanged:(UISwitch *)switchView;
- (void)onEditorNotifyScopeTapped:(UIButton *)sender;
- (void)onEditorNotifyAppTapped:(UIButton *)sender;
- (void)relayoutEditorGridAnimated:(BOOL)animated;
- (void)rebuildEditorRingPreview;
// 【0.6.14 用户 log54-①】录屏状态提示（图标红点徽章 + 开/关提示条）
- (void)mfApplyRecordBadge;
- (void)mfShowRecordToastActive:(BOOL)active;
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

        MFLog(@"[ring] 0.3.19 圆盘宿主=%@（%@，配置=%ld）%@ level=%.0f frame=%@ hidden=%d "
              @"交互=%d | 触发边=%@ 触发条=%@ 覆盖层=%@ | 配置项=%lu 自动列表=%lu 降级=%@ "
              @"内容来源=%@",
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
              gMFRingDegraded ? @"是" : @"否",
              gMFRingContentSource);
        if (!CGRectContainsRect(bounds, self.triggerFrame)) {
            MFLog(@"[ring] ⚠️ 触发带 %@ 超出宿主 %@ —— 越界部分收不到触摸（可调 mfTriggerCenterRatio / "
                  @"mfTriggerThickness / mfTriggerEdge，或设 mfRingHostWindow=0 退回 PullOver 窗口）",
                  NSStringFromCGRect(self.triggerFrame), NSStringFromCGRect(bounds));
        }
        // 【0.3.23】贴边核对：外侧边到屏幕边的距离（应恒为 0）
        MFLog(@"[ring] 触发条贴边核对：外侧边距屏幕边 %.1fpt（0=完全贴合）| 触发条=%@ 宿主=%@ 厚度=%.0fpt",
              [self triggerOuterEdgeGapForBounds:bounds], NSStringFromCGRect(self.triggerFrame),
              NSStringFromCGRect(bounds), CGRectGetWidth(self.triggerFrame) > 0 &&
              CGRectGetWidth(self.triggerFrame) <= 64.0 ? CGRectGetWidth(self.triggerFrame)
                                                        : CGRectGetHeight(self.triggerFrame));
        // 先算一次内容数量（几何缩放要用它），再打几何 —— 数量少时圆盘会自动变小
        NSUInteger ringCount = MFRingBundleIds().count;
        {
            MFRingGeometry geo = MFRingComputeGeometry(bounds, ringCount);
            MFLog(@"[ring] 圆盘几何：数量=%lu 缩放=%@ 圈数=%lu 有效外圈半径=%.0f 底盘=%.0f 图标=%.0f "
                  @"步距=%.0f 内外圈间距=%.0f（固定，不随数量变） 停留固定=%.1fs | "
                  @"编辑器入口：长按贴边触发条 0.7 秒（最多 %lu 个图标）",
                  (unsigned long)ringCount, MFRingScaleDescription(ringCount),
                  (unsigned long)geo.rings, geo.outerRadius, geo.dialRadius,
                  geo.iconSize, geo.step, geo.ringPitch - geo.iconSize,
                  MAX(0.4, MFRingNumber(@"mfRingLatchDwell", MF_RING_LATCH_DWELL)),
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
    // 【0.4.2】顺手作废"停留自动固定"计时器（宿主都没了，别让它继续跑）
    self.ringDwellGeneration += 1;
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
/// 顶部条无所谓 inset。左右条的纵向范围只避开底部 10pt（【0.6.11 用户指令】44 → 10：
/// 位置比例上限 0.98，触发条可以贴近屏幕底部；10pt 只防配置极端时越出屏外）。
- (CGRect)triggerFrameForBounds:(CGRect)bounds {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    // 【0.3.0】厚度 56 → 28：用户实测"太宽，容易误触"。窄一半仍够用：
    //   呼出主力是系统边缘手势（识别器自身区域 20pt + 带门外扩 60pt），判定不受厚度影响。
    CGFloat thickness = MAX(16.0, MFRingNumber(@"mfTriggerThickness", 28.0));
    // 【0.3.19】长度默认 0 = 动态屏高 30%（用户指定：触发条只占屏幕边缘约 30%，
    //   减少与全屏 App 手势的重叠冲突——抖音左滑个人主页 / iOS 右缘返回同属右缘区域，
    //   跨进程手势无法互斥，缩窄触发带是系统限制下最有效的缓解）。
    //   显式设置 mfTriggerLength（>0）仍生效，下限 80。
    CGFloat lengthRaw = MFRingNumber(@"mfTriggerLength", 0.0);
    CGFloat length = lengthRaw > 0.0 ? MAX(80.0, lengthRaw) : MAX(80.0, height * 0.30);
    CGFloat centerRatio = MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.98);
    NSString *edge = MFRingEdge();
    // 下边缘条默认**不留底边距**（贴死屏幕底边）；
    // 【0.6.11 用户指令】左右条底部避让 44 → 10pt：位置比例上限提到 0.98 后，
    //   触发条下沿可以贴到屏幕底部 98% 左右（更贴近底部；只让开最后 10pt 防误出屏）。
    CGFloat insetFallback = [edge isEqualToString:@"bottom"] ? 0.0 : 10.0;
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
    // 【0.3.23 用户 log32】"触发条没有紧贴屏幕边缘" ⇒ 这里**显式钉死**：厚度只向屏内延伸，
    //   外侧边恒等于屏幕边（右条：x = width - thickness ⇒ maxX ≡ width；左条：x ≡ 0）。
    //   用 `MIN/MAX` 兜住极端配置（thickness 比屏宽还大 / 负值），保证结果永远贴边且不越界。
    CGFloat thicknessClamped = MIN(MAX(thickness, 8.0), ([edge isEqualToString:@"left"] ||
                                                         [edge isEqualToString:@"right"]
                                                         ? MAX(width, 8.0) : MAX(height, 8.0)));
    if ([edge isEqualToString:@"left"]) {
        return CGRectMake(0.0, originY, thicknessClamped, length);            // maxX = thickness，minX ≡ 0（贴左边）
    }
    return CGRectMake(width - thicknessClamped, originY, thicknessClamped, length);   // minX+厚度 ≡ width（贴右边）
}

/// 【0.3.23】触发条贴边核对：把"外侧边到屏幕边"的距离算出来（应当恒为 0），
/// 供日志验证"触发条贴死屏幕边缘"这件事真的成立（用户 log32 提的第 4 条）。
- (CGFloat)triggerOuterEdgeGapForBounds:(CGRect)bounds {
    CGRect band = [self triggerFrameForBounds:bounds];
    if (CGRectIsEmpty(band)) {
        return 0.0;
    }
    NSString *edge = MFRingEdge();
    if ([edge isEqualToString:@"left"]) {
        return CGRectGetMinX(band);
    }
    if ([edge isEqualToString:@"right"]) {
        return CGRectGetWidth(bounds) - CGRectGetMaxX(band);
    }
    if ([edge isEqualToString:@"top"]) {
        return CGRectGetMinY(band);
    }
    return CGRectGetHeight(bounds) - CGRectGetMaxY(band);
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
            // 【0.4.2 用户 log37】这里把**手指累计滑动距离**喂给进度 ⇒ 圆盘沿「触发条 → 中下中心」
            //   跟手位移 + 长大；手指停住 1.0s 就走"停留自动固定"（计时器同样在 moveRingToPoint: 里重置）。
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
///   · 拖动：Began 起取消按钮触摸（不误开），驱动 跟随→停留固定→悬停→松手打开/收起。
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
                // 【0.4.2】同上：累计滑动距离 ⇒ 跟手位移到中下中心 + 长大；固定靠"抵达终点"或"停留 1.0s 自动固定"
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

/// 【0.4.2 用户 log37】按缩放夹取：呼出**起点**（10% 小圆盘，贴触发条那道边）与中途位移
/// 都靠它保证整圆不出屏。圆心不再被钉死在中下中心 —— 中下中心只是**位移终点**
/// （由 `ringIntroCenterForProgress:` 在「触发点 → 中下中心」之间插值）。
- (CGPoint)mfClampRingCenter:(CGPoint)point scale:(CGFloat)scale {
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
    CGFloat factor = (isfinite(scale) && scale > 0.0) ? scale : 1.0;
    CGFloat extent = MFRingCurrentGeometry(bounds).extent * factor + margin;
    CGFloat minX = extent;
    CGFloat maxX = MAX(CGRectGetMaxX(bounds) - extent, minX);
    CGFloat minY = extent;                                      // 【0.3.27】整屏都能去（原来锁在下半屏）
    CGFloat maxY = MAX(CGRectGetMaxY(bounds) - extent, minY);
    CGFloat x = MIN(MAX(MFRingSafe(point.x, CGRectGetMidX(bounds)), minX), maxX);
    CGFloat y = MIN(MAX(MFRingSafe(point.y, CGRectGetMidY(bounds)), minY), maxY);
    return CGPointMake(x, y);
}

/// 【0.4.2 用户 log37】呼出位移**终点** / 固定圆心 = **屏幕中下中心**：屏宽中线 × 屏高 ×
/// `mfRingParkRatioY`（默认 0.78 ⇒ 本机 430×932 上是 (215,727)，圆盘下沿 871、离底边 61pt）。
/// 圆盘从触发条出现后，圆心沿「触发点 → 此点」插值过来，到点即固定。
- (CGPoint)mfRingParkCenterForBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }
    if (CGRectIsEmpty(bounds)) {
        return CGPointZero;
    }
    CGFloat ratio = MIN(MAX(MFRingNumber(@"mfRingParkRatioY", MF_RING_PARK_RATIO_Y), 0.30), 0.95);
    return CGPointMake(CGRectGetMidX(bounds), CGRectGetMinY(bounds) + CGRectGetHeight(bounds) * ratio);
}

#pragma mark 展开 / 收起

/// 【0.3.24】呼出动画的起点圆心：贴着**触发条所在的那条屏幕边**。
/// 右缘呼出 → 起点圆心落在屏右缘内侧一点点（配合小圆盘缩放，看起来就是"从右边被拖出来"）；
/// 左/上/下同理。纵向（或横向）沿用目标圆心，只把"垂直于边"的那一维移到边上。
- (CGPoint)ringIntroStartCenterForBounds:(CGRect)bounds target:(CGPoint)target {
    if (CGRectIsEmpty(bounds)) {
        return target;
    }
    CGFloat margin = MAX(0.0, MFRingNumber(@"mfRingEdgeMargin", 12.0));
    CGFloat extent = MFRingCurrentGeometry(bounds).extent + margin;   // 与 mfClampRingCenter:scale: 同一套几何
    CGPoint p = target;
    CGFloat inset = MAX(8.0, extent * 0.18);                          // 起点圆心离屏边一点点
    NSString *edge = MFRingEdge();
    if ([edge isEqualToString:@"left"]) {
        p.x = CGRectGetMinX(bounds) + inset;
    } else if ([edge isEqualToString:@"top"]) {
        p.y = CGRectGetMidY(bounds) - inset;   // 圆盘只在下半屏，顶部条同样从"上缘方向"出来
    } else if ([edge isEqualToString:@"bottom"]) {
        p.y = CGRectGetMaxY(bounds) - inset;
    } else {
        p.x = CGRectGetMaxX(bounds) - inset;   // right（默认）
    }
    return p;
}

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

        // 【0.4.2 用户 log37】呼出起点 = 触发条位置，终点 = 屏幕中下中心（`mfRingParkCenterForBounds:`，
        //   `mfRingParkRatioY` 默认 0.78）；手指滑动驱动"位移 + 长大"，停住 1.0s 自动固定到终点。
        MFLog(@"[ring] 呼出前置 ok（0.2.0：setter 死递归已修）");

        MFLog(@"[ring] >>> 建容器");
        MFRingContainerView *container = [[MFRingContainerView alloc] initWithFrame:bounds];
        // 【0.3.23 用户 log32】原来这里是 `colorWithWhite:0.0 alpha:0.18` 的"轻遮罩" ——
        //   那就是用户看到的"呼出圆盘时整个屏幕有一层浅黑色透明层"。圆盘的底盘已经由 dialLayer
        //   自己画（【0.3.27】0.10 白 30% 填充，已比原来更透），不需要整屏再压一层黑；而且透明背景**不影响命中判定**
        //   （UIView 的 hitTest 只看 pointInside/hidden/alpha，与 backgroundColor 无关），
        //   所以"点空白收起"照旧有效。
        container.backgroundColor = [UIColor clearColor];
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

        // 【0.4.2 用户 log37】呼出动画第 6 版 = **从触发条出现 → 跟手位移到中下中心 → 固定**。
        //   0.4.1 的错在于"起点就是中下中心"（小圆盘原地冒出来），用户原话："我只是说取消跟随
        //   手指移动，没有说改变圆盘出现的位置"。本版三要素：
        //   ★ 起点 = **手指在触发条上按下的那个点**（按 10% 缩放夹取 ⇒ 小圆盘贴边出现）；
        //   ★ 位移 = 起点 → 屏幕中下中心（`mfRingParkCenterForBounds:`）直线插值，进度 = 手指
        //     累计滑动距离 / 基准（滑动驱动 ⇒ 滑得快就都到得快，中途停住就停在半路）；
        //   ★ 缩放 = 10% → 100%，与位移**共用同一进度**（"走到中下中心"与"长到 100%"同一时刻）。
        //   前几版为什么不对（免得再走回头路）：
        //   ★ 0.3.23：只缩放 ringRoot，圆心被满半径顶到离屏边 129pt ⇒ 看着"从屏幕中间长出来"。
        //   ★ 0.3.24：位移 + 自动弹大，位移终点是停靠点、0.38s 自己跑完 ⇒ 与手指无关。
        //   ★ 0.3.25/0.3.26：位移→缩放（手指滑多远就多大）⇒ 圆心被手指带着满屏跑。
        //   ★ 0.3.27：时间驱动（触发起 2s 线性到 100%）⇒ 用户反馈"太慢"、"取消时间限制"。
        //   ★ 0.4.1：圆心钉死在中下中心、只长大不移动 ⇒ 用户反馈"改了出现的位置"。
        //   ★ 未固定期间**禁止选中**（见 updateSelectionForPoint:）——手指只是把圆盘划出来，不能误开 App。
        CGPoint targetCenter = [self mfRingParkCenterForBounds:bounds];
        self.ringIntroMinScale = MIN(MAX(MFRingNumber(@"mfRingIntroMinScale", MF_RING_INTRO_MIN_SCALE), 0.05), 0.9);
        self.ringIntroProgress = 0.0;
        self.ringIntroTravel = 0.0;
        self.ringIntroLastPoint = point;
        // 进度基准 = **触发点到中下中心的城市街区距离**（下限 100pt）：
        //   "手指从触发条滑到圆盘该在的位置"正好 = 100%，中途松劲儿就停在当时的大小/位置（跟手）。
        CGFloat span = hypot(point.x - targetCenter.x, point.y - targetCenter.y);
        self.ringIntroSpan = MAX(span, MF_RING_INTRO_MIN_SPAN);
        self.ringIntroParkCenter = targetCenter;
        CGFloat introMin = self.ringIntroMinScale;
        // 【0.4.13】登场微动画：小圆盘不再是硬切冒出 —— alpha 淡入 + 从 82% 起始档微弹到位。
        //   图标已同步贴好（0.3.25 起），淡入不会再出现"透明占位"；BeginFromCurrentState
        //   保证手指立刻开划时，第一帧跟手映射无缝接管，不打架。
        self.ringRoot.alpha = 0.0;
        CGFloat popFrom = introMin * 0.82;
        self.ringRoot.transform = CGAffineTransformMakeScale(popFrom, popFrom);
        // 【0.7.2·P1】登场微动画 0.16→0.18、阻尼 0.85→0.80（起手多一点弹性），
        //   BeginFromCurrentState 保留 ⇒ 手指立刻开划时第一帧照旧无缝接管。
        [UIView animateWithDuration:0.18
                              delay:0.0
             usingSpringWithDamping:0.80
              initialSpringVelocity:0.5
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:^{
            self.ringRoot.alpha = 1.0;
            self.ringRoot.transform = CGAffineTransformMakeScale(introMin, introMin);
        } completion:nil];
        // 【0.4.2】起点圆心 = **触发点**（按 10% 缩放夹取：整圆不出屏，同时仍是"贴着触发条出现"）
        CGPoint startCenter = [self mfClampRingCenter:point scale:introMin];
        self.ringIntroStartCenter = startCenter;
        self.ringRoot.center = startCenter;
        // 【0.4.2】"停留自动固定"计时器**在这里就先排一次**：手指若一动都不动（甚至系统手势
        //   后续事件完全不来），1.0s 后照样会就地补满并固定，圆盘不会卡成"永远选不了图标"。
        self.ringDwellAnchorPoint = point;
        [self mfScheduleLatchDwell];
        MFLog(@"[ring] 呼出动画（0.4.17）：%@ 起点=触发条(%.0f,%.0f) 小圆盘 %.0f%% → 跟手位移到屏幕中下中心(%.0f,%.0f) 并长到 100%%（easeOut%.1f·滑得快就都快），停留 %.1f 秒自动固定",
              MFRingEdge(), startCenter.x, startCenter.y, introMin * 100.0,
              targetCenter.x, targetCenter.y,
              MAX(1.0, MFRingNumber(@"mfRingIntroEase", MF_RING_INTRO_EASE)),
              MAX(0.4, MFRingNumber(@"mfRingLatchDwell", MF_RING_LATCH_DWELL)));

        MFLog(@"[ring] <<< 呼出完成：圆心从触发条(%.0f,%.0f) 出发，跟手指位移，终点(%.0f,%.0f)",
              startCenter.x, startCenter.y, targetCenter.x, targetCenter.y);

        if (self.iconButtons.count == 0) {
            [self scheduleAutoBundleIdEnumeration];
        } else {
            // 【0.3.25 用户 log34】真图标**同步**贴好再放动画。
            //   ★ 0.3.24 是 `delay:0.42` 延后抓图（为了不让抓图切碎动画），结果用户看到
            //     "刚呼出是首字母透明占位、0.5 秒后才变成真图标"—— log34 实证：图标铺好 14.206
            //     → 抓取图标 14.644，正好差 0.44s。
            //   ★ 现在改同步：图标有内存缓存（`MFRingIconCache()`）⇒ 第二次起是纯字典命中；
            //     首次 17 个约 40ms（log34 实证 14.644→14.681），放在"建完圆盘、放动画前"，
            //     动画首帧就是真图标，也就不需要 alpha 淡入了。
            NSUInteger filled = [self fillIconsSynchronouslyForGeneration:self.buildGeneration];
            MFLog(@"[ring] 呼出即贴真图标：%lu/%lu（不再有首字母占位阶段）",
                  (unsigned long)filled, (unsigned long)self.iconButtons.count);
        }

        // 【0.6.14 用户 log54-①】录屏状态：展开即向系统 isRecording 对齐 + 贴红点徽章；
        //   观察者首次呼出时注册（开/关变化 → 提示条 + 红点刷新）。
        static dispatch_once_t recordObserverOnce;
        dispatch_once(&recordObserverOnce, ^{
            __weak typeof(self) weakSelf = self;
            MFSystemActionSetRecordStateObserver(^(BOOL active) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                [strongSelf mfShowRecordToastActive:active];
                [strongSelf mfApplyRecordBadge];
            });
            MFLog(@"[ring] 0.7.5 录屏状态观察者已注册（开/关提示条 + 红点徽章）");
        });
        MFSystemActionRecordSyncState();
        [self mfApplyRecordBadge];

        // 【0.6.14 用户 log54-③】呼出跟手期间整盘**栅格化**：跟手阶段每帧都在改
        //   transform/center，不栅格化时每次都要重排版整个圆盘（底盘层 + N 个图标按钮），
        //   图标多时就是掉帧来源；栅格化后每帧只合成一张缓存位图 = 丝滑跟手。
        //   固定（latch）时关掉，恢复实时渲染（选中高亮要逐图标变化）。
        self.ringRoot.layer.shouldRasterize = YES;
        self.ringRoot.layer.rasterizationScale = UIScreen.mainScreen.scale;
    } @catch (NSException *exception) {
        MFLog(@"[ring] !! 展开异常：%@", exception);
        [self hide];
    }
}

- (void)hide {
    self.buildGeneration += 1;   // 作废尚未执行的图标填充
    // 【0.4.2】作废"停留自动固定"计时器 —— 否则它可能在收起后去动已脱离视图的 ringRoot
    self.ringDwellGeneration += 1;
    if (self.editorPanel != nil) {
        [self closeEditorSaving:NO];   // 【0.2.1】编辑器开着就一并收起（不保存）
    }
    if (!self.expanded) {
        return;
    }
    UIView *container = self.container;
    UIView *collapseRoot = self.ringRoot;   // 【0.3.23】收起动画要缩的是圆盘本体（容器现在无背景）
    self.container = nil;
    self.dialLayer = nil;
    self.ringRoot = nil;
    self.selectedButton = nil;
    self.ringLatched = NO;
    self.hasLatchFinger = NO;
    self.expanded = NO;
    [self.iconButtons removeAllObjects];

    if (container == nil) {
        return;
    }
    // 【0.3.23】收起 = 圆盘本体缩回 + 淡出（与呼出动画对称：也是"从边缘收回"的观感），
    //   容器本身全透明，只负责在动画结束后把自己摘掉。
    // 【0.3.24】再加"缩回边缘"的位移：与呼出（从边缘滑出）严格对称，一来一回都像 Stheno。
    CGPoint collapseCenter = [self ringIntroStartCenterForBounds:self.hostBounds
                                                          target:collapseRoot.center];
    // 【0.7.2·P1】收起 0.22→0.24、阻尼 0.88→0.84（与呼出侧同一档弹性，一来一回对称）
    [UIView animateWithDuration:0.24
                          delay:0.0
         usingSpringWithDamping:0.84
          initialSpringVelocity:0.55
                        options:(UIViewAnimationOptionCurveEaseIn |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        container.alpha = 0.0;
        collapseRoot.alpha = 0.0;
        collapseRoot.center = collapseCenter;
        collapseRoot.transform = CGAffineTransformMakeScale(0.45, 0.45);
    } completion:^(__unused BOOL finished) {
        [container removeFromSuperview];
    }];
    MFLog(@"[ring] 圆盘已收起（贴边手势恢复）");
}

#pragma mark 长大 / 固定

/// 【0.4.2 用户 log37】手指动了 ⇒ ① 累计滑动距离 → 推进进度（10% → 100%，**无时间上限**）；
/// ② 按进度把圆心沿「触发点 → 屏幕中下中心」插值（**跟手位移**，不是满屏漫游）+ 同步缩放；
/// ③ 重置"停留自动固定"计时（停住 1.0s 就补满并固定在中下中心）。
- (void)moveRingToPoint:(CGPoint)point {
    if (self.ringRoot == nil || self.ringLatched) {
        return;
    }
    // ① 累计滑动距离（单调递增：回滑不缩）—— 手指滑得快 ⇒ 单位时间走过的距离多 ⇒ 同一份进度
    //    用时更短 ⇒ "到 100% 的速度由手指移动速度决定"（用户原话）。中途停住 = 停在当时大小/位置。
    CGFloat step = hypot(point.x - self.ringIntroLastPoint.x, point.y - self.ringIntroLastPoint.y);
    self.ringIntroLastPoint = point;
    BOOL reachedFull = NO;
    if (step > 0.5) {
        self.ringIntroTravel += step;
        CGFloat span = MAX(self.ringIntroSpan, 1.0);
        CGFloat progress = MIN(self.ringIntroTravel / span, 1.0);
        if (progress > self.ringIntroProgress) {
            self.ringIntroProgress = progress;
            [self mfApplyRingIntroFrame];   // 【0.4.2】缩放 + 圆心（插值）一起贴
            reachedFull = (progress >= 1.0);
        }
    }
    // ② 停留计时：一动就从零开始计。阈值 3pt：有些 App 会为"按着不动"的手指持续发微量抖动的
    //    Changed 事件，若不加阈值，计时器会被这些抖动静默地无限推迟（0.3.27 的教训）。
    CGFloat moved = hypot(point.x - self.ringDwellAnchorPoint.x, point.y - self.ringDwellAnchorPoint.y);
    if (self.ringDwellGeneration == 0 || moved > 3.0) {
        self.ringDwellAnchorPoint = point;
        [self mfScheduleLatchDwell];
    }
    if (reachedFull) {
        MFLog(@"[ring] 呼出长大完成：100%%（手指累计滑动 %.0fpt / 基准 %.0fpt，圆心已到 %@(%.0f,%.0f)）",
              self.ringIntroTravel, self.ringIntroSpan, MFRingEdge(),
              self.ringRoot.center.x, self.ringRoot.center.y);
        [self latchToParkCenterAnimated:YES];   // 抵达中下中心也直接固定（与"停留自动固定"等价的两条路）
    }
}

/// 【0.4.13】进度→观感缓动：easeOut 幂曲线 `t = 1-(1-p)^e`（e=1.6）。
///   线性映射的毛病：刚起步时手指动了圆盘几乎没反应，观感"机械、别扭"；easeOut 让
///   前期一点点滑动就有明显的长大/位移反馈，临近中下中心自然减速——符合"划出来"的直觉。
///   仍是**纯距离驱动映射**（不加任何时间驱动）；`mfRingIntroEase` 可调，设 1.0 = 旧行为。
- (CGFloat)mfRingIntroEasedT {
    CGFloat p = MIN(MAX(self.ringIntroProgress, 0.0), 1.0);
    CGFloat e = MAX(MFRingNumber(@"mfRingIntroEase", MF_RING_INTRO_EASE), 1.0);
    return 1.0 - pow(1.0 - p, e);
}

/// 【0.4.2】当前缩放 = 起始缩放 + (1 - 起始缩放) × 观感进度（0.4.13 起走 easeOut，无时间上限）
- (CGFloat)mfRingIntroCurrentScale {
    CGFloat t = [self mfRingIntroEasedT];
    return self.ringIntroMinScale + (1.0 - self.ringIntroMinScale) * t;
}

/// 【0.4.2 用户 log37】当前进度对应的圆心 = **起点（触发条）→ 终点（屏幕中下中心）线性插值**，
/// 再按**当前缩放**夹一次（10% 的小圆盘能贴边，长大过程中始终整圆不出屏）。
/// 这就是"圆盘被手指从触发条一路带到屏幕中下中心"那一段。
- (CGPoint)ringIntroCenterForProgress:(CGFloat)progress {
    // 【0.4.13】位移与缩放共用同一**观感进度**（easeOut）——两者同步走到终点，不打架
    CGFloat t = [self mfRingIntroEasedT];
    CGPoint start = self.ringIntroStartCenter;
    CGPoint end = self.ringIntroParkCenter;
    CGPoint p = CGPointMake(start.x + (end.x - start.x) * t,
                            start.y + (end.y - start.y) * t);
    CGFloat scale = self.ringIntroMinScale + (1.0 - self.ringIntroMinScale) * t;
    return [self mfClampRingCenter:p scale:scale];
}

/// 【0.4.2】把当前进度的**缩放 + 圆心**一起贴到圆盘上（位移与长大共用同一进度）
- (void)mfApplyRingIntroFrame {
    if (self.ringRoot == nil) {
        return;
    }
    CGFloat scale = [self mfRingIntroCurrentScale];
    self.ringRoot.transform = CGAffineTransformMakeScale(scale, scale);
    self.ringRoot.center = [self ringIntroCenterForProgress:self.ringIntroProgress];
}

/// 【0.4.2】"停留自动固定"计时器：手指停在一个地方 1.0s（`mfRingLatchDwell`）
/// ⇒ 圆盘自动补满到 100% 并固定（用户："划到哪里停留 1 秒自动固定"）。
/// 每次手指移动都会重排（代次递增作废上一个），所以只有真正停住 1s 才会触发。
- (void)mfScheduleLatchDwell {
    self.ringDwellGeneration += 1;
    NSUInteger generation = self.ringDwellGeneration;
    self.ringDwellStartedAt = CACurrentMediaTime();
    NSTimeInterval dwell = MAX(0.4, MFRingNumber(@"mfRingLatchDwell", MF_RING_LATCH_DWELL));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dwell * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf.ringDwellGeneration) {
            return;   // 手指又动了 / 已收起：这次停留作废
        }
        if (!strongSelf.expanded || strongSelf.ringLatched || strongSelf.ringRoot == nil) {
            return;
        }
        [strongSelf latchToParkCenterAnimated:YES];
    });
}

/// 【0.4.2 用户 log37】固定 = 圆心收在**屏幕中下中心**（手指滑够时圆盘已经走到那儿了；只滑一点点
/// 就停住时，这一步把"位移到中下中心 + 缩放到 100%"一起弹簧补上）。固定后手指滑动只改变"选中"，
/// 圆心不再动。
- (void)latchToParkCenterAnimated:(BOOL)animated {
    if (self.ringRoot == nil || self.ringLatched) {
        return;
    }
    self.ringDwellGeneration += 1;   // 撤掉"停留自动固定"计时器
    self.ringLatched = YES;
    self.ringIntroProgress = 1.0;
    // 【0.6.14】固定后恢复实时渲染：呼出跟手期的整盘栅格化撤掉（选中高亮要逐图标变化）
    self.ringRoot.layer.shouldRasterize = NO;
    // 记录"固定那一刻手指在哪"：手指还没动之前不产生选中，避免刚固定就误开某个 App
    self.latchFingerPoint = self.lastFingerPoint;
    self.hasLatchFinger = YES;
    // 按**满尺寸**再夹一次：固定点本来就在合法范围内，这一步只是保险（整圆必不出屏）
    CGPoint center = [self mfClampRingCenter:[self mfRingParkCenterForBounds:self.hostBounds] scale:1.0];
    void (^changes)(void) = ^{
        self.ringRoot.center = center;
        self.ringRoot.transform = CGAffineTransformIdentity;
    };
    if (animated) {
        // 【0.4.13】弹簧收尾调稳：0.72 阻尼会明显晃两下才停（用户"别扭"来源之一），
        //   0.82 + 更小初速 = 一次轻微回稳就落定；BeginFromCurrentState 保留（跟手途中补满不跳帧）。
        // 【0.7.2·P1】固定收尾 0.46→0.42、阻尼 0.82→0.80、初速 0.18→0.22：
        //   原来"补满"这一下偏慢，手指停住后要等近半秒才落定；现在更跟手。
        [UIView animateWithDuration:0.42
                              delay:0.0
             usingSpringWithDamping:0.80
              initialSpringVelocity:0.22
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
    NSTimeInterval dwelled = CACurrentMediaTime() - self.ringDwellStartedAt;
    MFLog(@"[ring] 圆盘已固定（屏幕中下中心，距上次手指移动 %.1fs）圆心(%.0f,%.0f) 缩放100%% —— 滑动到图标上选择，松手即打开",
          dwelled, center.x, center.y);
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
    // 【0.3.27 用户 log36】底盘更透：0.12 白 / 0.55 alpha → 0.10 白 / 0.30 alpha
    //   （用户："圆盘的背景颜色可以再透明一点，这样在白色背景下不会显得特别黑"）
    // 【0.6.12 用户 log52】浅色模式下底盘还是显眼：alpha 0.30 → 0.16、描边 0.28 → 0.18
    dial.fillColor = [UIColor colorWithWhite:0.10 alpha:0.16].CGColor;
    dial.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    dial.lineWidth = 1.0;
    [ringRoot.layer addSublayer:dial];
    self.dialLayer = dial;

    MFLog(@"[ring] >>> 取圆盘内容（只读配置/缓存，不查 SB）");
    NSArray<NSString *> *bundleIds = ringBundleIds;   // 上面已经取过（同一份内容，避免重复读配置）
    NSUInteger count = bundleIds.count;
    MFLog(@"[ring] <<< 取圆盘内容 ok：%lu 项（来源=%@）", (unsigned long)count,
          gMFRingContentSource);

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

    // ①–③【0.6.21 用户 log60】统一"内外圈固定间距"布局解：内圈半径 = 外圈半径 − ringPitch，
    //   无论多少个 App，内外圈的可见间距恒为 mfRingRingGap（默认 6pt）。
    MFRingLayout layout = MFRingSolveLayout(geo, count);
    NSUInteger rings = layout.rings;
    count = layout.total;
    NSMutableArray<NSNumber *> *perRing = [NSMutableArray arrayWithCapacity:rings];
    NSMutableArray<NSNumber *> *drawnRadii = [NSMutableArray arrayWithCapacity:rings];
    for (NSUInteger ring = 0; ring < rings; ring++) {
        [perRing addObject:@(layout.counts[ring])];
        [drawnRadii addObject:@(layout.radii[ring])];
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

/// 【0.3.25 用户 log34】同步贴真图标：把当前 iconButtons 里的按钮**立刻**换成真图标，
/// 返回成功贴上的个数。呼出路径用它（见 showAtPoint:），这样动画首帧就是真图标、
/// 不存在"先看 0.4 秒首字母占位"的阶段。图标有内存缓存（`MFRingIconCache()`）⇒
/// 第二次起是纯字典命中；首次 17 个约 40ms（log34 实证 14.644→14.681），可接受。
- (NSUInteger)fillIconsSynchronouslyForGeneration:(NSUInteger)generation {
    if (!MFRingBool(@"mfRingFetchIcons", YES)) {
        MFLog(@"[ring] 按配置跳过图标抓取（mfRingFetchIcons=false，仅首字母）");
        return 0;
    }
    if (gMFRingDegraded) {
        MFLog(@"[ring] 降级模式：跳过图标抓取（仅首字母）。删除 %s 可重试", MF_RING_GUARD_PATH);
        return 0;
    }
    NSArray<UIButton *> *buttons = [self.iconButtons copy];
    if (buttons.count == 0) {
        return 0;
    }
    MFLog(@"[ring] >>> 取图标 %lu 个（同步，呼出即贴）", (unsigned long)buttons.count);
    MFRingGuardArm();
    NSUInteger filled = 0;
    for (UIButton *button in buttons) {
        if (generation != self.buildGeneration || !self.expanded) {
            break;
        }
        if (button.superview == nil) {
            continue;
        }
        NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
        if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
            continue;
        }
        UIImage *icon = MFRingIconForBundleId(bundleId);
        if (icon != nil && generation == self.buildGeneration) {
            [button setImage:icon forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFill;
            [button setTitle:nil forState:UIControlStateNormal];
            filled += 1;
        }
    }
    MFRingGuardDisarm();   // 整趟走完且存活 ⇒ 撤标记
    return filled;
}

#pragma mark - 【0.6.15 用户 log54-①】录屏状态提示

#define MF_RING_RECORD_BADGE_TAG 35861
#define MF_RING_RECORD_TOAST_TAG 35862

/// 录屏图标右上角红点徽章：录制中亮红点，空闲熄灭。
/// 状态源 = MFSystemActionRecordIsActive()（我方记账 + 系统 isRecording 对齐）。
- (void)mfApplyRecordBadge {
    for (UIButton *button in self.iconButtons) {
        if (button.superview == nil) {
            continue;
        }
        NSString *bundleId = objc_getAssociatedObject(button, &kMFRingBundleIdKey);
        BOOL isRecord = [bundleId isKindOfClass:[NSString class]] &&
            [bundleId isEqualToString:@"mfsys.record"];
        UIView *badge = [button viewWithTag:MF_RING_RECORD_BADGE_TAG];
        if (!isRecord) {
            if (badge != nil) {
                [badge removeFromSuperview];
            }
            continue;
        }
        BOOL active = MFSystemActionRecordIsActive();
        if (active && badge == nil) {
            CGFloat side = button.bounds.size.width;
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(side - 11.0, 2.0, 9.0, 9.0)];
            dot.tag = MF_RING_RECORD_BADGE_TAG;
            dot.backgroundColor = [UIColor colorWithRed:0.92 green:0.20 blue:0.20 alpha:1.0];
            dot.layer.cornerRadius = 4.5;
            dot.layer.borderColor = [UIColor whiteColor].CGColor;
            dot.layer.borderWidth = 1.5;
            dot.userInteractionEnabled = NO;
            [button addSubview:dot];
            MFLog(@"[ring] 录屏红点亮起（录制中）");
        } else if (!active && badge != nil) {
            [badge removeFromSuperview];
            MFLog(@"[ring] 录屏红点熄灭（空闲）");
        }
    }
}

/// 录屏开/关提示条：宿主窗口顶部居中弹出，1.6s 自动淡出（连续触发不叠加）。
- (void)mfShowRecordToastActive:(BOOL)active {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self mfShowRecordToastActive:active]; });
        return;
    }
    UIWindow *window = self.hostWindow;
    if (window == nil) {
        return;
    }
    UIView *previous = [window viewWithTag:MF_RING_RECORD_TOAST_TAG];
    if (previous != nil) {
        [previous removeFromSuperview];
    }
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 176.0, 40.0)];
    toast.tag = MF_RING_RECORD_TOAST_TAG;
    toast.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.88];
    toast.layer.cornerRadius = 20.0;
    toast.layer.masksToBounds = YES;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    toast.text = active ? @"● 录屏已开始" : @"录屏已停止";
    toast.textColor = active
        ? [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0]
        : [UIColor colorWithWhite:1.0 alpha:0.85];
    toast.center = CGPointMake(window.center.x, 96.0);
    toast.alpha = 0.0;
    [window addSubview:toast];
    [UIView animateWithDuration:0.18 animations:^{ toast.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.24
                              animations:^{ toast.alpha = 0.0; }
                              completion:^(__unused BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
    MFLog(@"[ring] 录屏提示条：%@", active ? @"已开始" : @"已停止");
}

/// 延后抓取真图标（非呼出路径用：内容刷新、编辑器等）。危险动作 ⇒ 立闸门，走完并存活才撤。
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation {
    [self scheduleIconFillWithGeneration:generation delay:0.05];
}

/// delay = 推迟抓图的秒数。
- (void)scheduleIconFillWithGeneration:(NSUInteger)generation delay:(NSTimeInterval)delay {
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
    NSTimeInterval wait = MAX(0.0, isfinite(delay) ? delay : 0.05);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (generation != strongSelf.buildGeneration || !strongSelf.expanded) {
            MFLog(@"[ring] 图标填充已作废 gen=%lu", (unsigned long)generation);
            return;
        }
        MFLog(@"[ring] >>> 抓取图标 %lu 个（逐个记录）", (unsigned long)strongSelf.iconButtons.count);
        NSUInteger filled = [strongSelf fillIconsSynchronouslyForGeneration:generation];
        MFLog(@"[ring] <<< 图标抓取完成（贴 %lu/%lu 个），崩溃标记已撤除",
              (unsigned long)filled, (unsigned long)strongSelf.iconButtons.count);
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
    [self mfApplyRecordBadge];   // 【0.6.15】重建后补录屏红点徽章
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

/// 构建全屏编辑面板（【0.6.10 用户指令】二级菜单版）：
///   一级 = 三行菜单（应用管理 / 触发条 / 其他选项），保证主菜单简洁不满；
///   二级「应用管理」= 已添加（圆盘实时预览 + 拖拽排序条）/ 未添加（网格点按加入）两个 tab；
///   已添加排序时预览即时跟随 —— 所见即圆盘真实排布。
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
    self.editorApps = apps;

    static BOOL mfLoggedEditorNotifyPage = NO;
    if (!mfLoggedEditorNotifyPage) {
        mfLoggedEditorNotifyPage = YES;
        MFLog(@"[ring] 0.7.5 已启用：点通知进悬浮窗 = 独立一级行 + 二级页"
              "（总开关 / 全部应用 或 仅选中的应用 / 应用勾选名单）");
    }

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, height)];
    panel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.87];
    panel.opaque = NO;
    panel.userInteractionEnabled = YES;
    panel.tag = MF_RING_EDITOR_TAG;
    // 【0.2.3】同样挂到宿主容器（状态栏窗口时是覆盖层），全屏 App 之上也能看到/操作
    [(self.hostContainerView ?: window) addSubview:panel];
    self.editorPanel = panel;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 46.0, 150.0, 30.0)];
    title.text = @"圆盘";
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

    // ---- 一级菜单（0.6.10：只有三行，其余全收进二级页）----
    UIView *menuBox = [[UIView alloc] initWithFrame:CGRectMake(0.0, 92.0, width, height - 92.0)];
    menuBox.backgroundColor = [UIColor clearColor];
    [panel addSubview:menuBox];
    self.editorMenuBox = menuBox;

    UIButton *rowApps = [self makeEditorMenuRowWithTitle:@"应用管理"
                                                subtitle:@"添加应用 · 拖动排序 · 实时预览圆盘"];
    [rowApps addTarget:self action:@selector(onEditorRowAppsTapped:)
      forControlEvents:UIControlEventTouchUpInside];
    [menuBox addSubview:rowApps];
    self.editorRowApps = rowApps;

    UIButton *rowTrigger = [self makeEditorMenuRowWithTitle:@"触发条"
                                                   subtitle:@"长度 · 位置 · 呼出灵敏度"];
    [rowTrigger addTarget:self action:@selector(onEditorSettingsToggle:)
         forControlEvents:UIControlEventTouchUpInside];
    [menuBox addSubview:rowTrigger];
    self.editorRowTrigger = rowTrigger;

    UIButton *rowOther = [self makeEditorMenuRowWithTitle:@"其他选项"
                                                 subtitle:@"双指呼出 · 圆盘大小 · 图标抓取"];
    [rowOther addTarget:self action:@selector(onEditorOtherToggle:)
      forControlEvents:UIControlEventTouchUpInside];
    [menuBox addSubview:rowOther];
    self.editorRowOther = rowOther;

    // 【0.7.5 用户指令】点通知进悬浮窗独立成一级行（二级页里选哪些应用）
    UIButton *rowNotify = [self makeEditorMenuRowWithTitle:@"点通知进悬浮窗"
                                                  subtitle:@"开关 · 选择哪些应用"];
    [rowNotify addTarget:self action:@selector(onEditorRowNotifyTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [menuBox addSubview:rowNotify];
    self.editorRowNotify = rowNotify;

    // 【0.6.8】触发条自调区：折叠容器改挂一级菜单盒（0.6.10 行号由 layoutEditorMenuAnimated 统一排）
    const CGFloat rowHeight = 32.0;
    const CGFloat settingsRows = 3.0;
    const CGFloat settingsBoxHeight = settingsRows * rowHeight + 20.0;   // 3 行滑杆 + 提示行
    UIView *settingsBox = [[UIView alloc] initWithFrame:CGRectMake(12.0, 0.0, width - 24.0, settingsBoxHeight)];
    settingsBox.hidden = YES;
    settingsBox.userInteractionEnabled = YES;
    [menuBox addSubview:settingsBox];
    self.triggerSettingsBox = settingsBox;
    [self buildTriggerSettingsInPanel:settingsBox top:0.0];
    self.editorSettingsExpanded = NO;

    // 【0.6.10】其他选项折叠容器（默认收起）：双指呼出开关 / 圆盘大小滑杆 / 图标抓取开关
    const CGFloat otherBoxHeight = 3.0 * 44.0 + 12.0;   // 【0.7.5】点通知开关独立成一级行 ⇒ 回到 3 行
    UIView *otherBox = [[UIView alloc] initWithFrame:CGRectMake(12.0, 0.0, width - 24.0, otherBoxHeight)];
    otherBox.hidden = YES;
    otherBox.userInteractionEnabled = YES;
    otherBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    otherBox.layer.cornerRadius = 14.0;
    [menuBox addSubview:otherBox];
    self.otherSettingsBox = otherBox;

    // 【0.7.5 用户指令】「点通知进悬浮窗」已独立成一级菜单行 ⇒ 这里回到 2 项
    NSArray<NSString *> *switchTitles = @[ @"双指贴边呼出（全屏 App 内必中）", @"抓取真实应用图标" ];
    NSArray<NSString *> *switchKeys = @[ @"mfRingTwoFingerSummon", @"mfRingFetchIcons" ];
    for (NSUInteger index = 0; index < switchTitles.count; index++) {
        CGFloat rowY = (CGFloat)index * 44.0 + 6.0;
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(16.0, rowY, otherBox.bounds.size.width - 96.0, 32.0)];
        name.text = switchTitles[index];
        name.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        name.font = [UIFont systemFontOfSize:13.0];
        [otherBox addSubview:name];
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.tag = (NSInteger)index + 1;
        toggle.on = MFRingBool(switchKeys[index], YES);
        toggle.onTintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        toggle.frame = CGRectMake(otherBox.bounds.size.width - 68.0, rowY + 0.5, 51.0, 31.0);
        [toggle addTarget:self action:@selector(onEditorOtherSwitchChanged:)
         forControlEvents:UIControlEventValueChanged];
        [otherBox addSubview:toggle];
    }
    CGFloat radiusRowY = 2.0 * 44.0 + 6.0;   // 【0.7.5】前面 2 行开关
    UILabel *radiusName = [[UILabel alloc] initWithFrame:CGRectMake(16.0, radiusRowY, 96.0, 32.0)];
    radiusName.text = @"圆盘大小";
    radiusName.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    radiusName.font = [UIFont systemFontOfSize:13.0];
    [otherBox addSubview:radiusName];
    UISlider *radiusSlider = [[UISlider alloc] initWithFrame:CGRectMake(112.0, radiusRowY + 3.0,
                                                                        otherBox.bounds.size.width - 200.0, 24.0)];
    radiusSlider.minimumValue = 80.0;
    radiusSlider.maximumValue = 240.0;
    radiusSlider.value = (float)MAX(80.0, MFRingNumber(@"mfRingRadius", 150.0));
    radiusSlider.minimumTrackTintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    [radiusSlider addTarget:self action:@selector(onEditorRadiusSliderChanged:)
         forControlEvents:UIControlEventValueChanged];
    [otherBox addSubview:radiusSlider];
    UILabel *radiusValue = [[UILabel alloc] initWithFrame:CGRectMake(otherBox.bounds.size.width - 78.0, radiusRowY, 62.0, 32.0)];
    radiusValue.textAlignment = NSTextAlignmentRight;
    radiusValue.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    radiusValue.font = [UIFont systemFontOfSize:11.0];
    radiusValue.text = [NSString stringWithFormat:@"%.0f pt", radiusSlider.value];
    [otherBox addSubview:radiusValue];
    self.editorRadiusValueLabel = radiusValue;
    self.editorOtherExpanded = NO;

    // ---- 二级页「点通知进悬浮窗」容器【0.7.5】----
    [self buildEditorNotifyPageInPanel:panel width:width height:height];

    // ---- 二级页「应用管理」容器 ----
    UIView *appsBox = [[UIView alloc] initWithFrame:CGRectMake(0.0, 92.0, width, height - 92.0)];
    appsBox.hidden = YES;
    appsBox.userInteractionEnabled = YES;
    [panel addSubview:appsBox];
    self.editorAppsBox = appsBox;

    UIButton *back = [UIButton buttonWithType:UIButtonTypeCustom];
    back.frame = CGRectMake(12.0, 6.0, 96.0, 36.0);
    back.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    back.layer.cornerRadius = 18.0;
    back.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    back.contentEdgeInsets = UIEdgeInsetsMake(0.0, 10.0, 0.0, 0.0);
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [back setTitle:@"‹ 返回" forState:UIControlStateNormal];
    [back setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [back addTarget:self action:@selector(onEditorBackTapped:) forControlEvents:UIControlEventTouchUpInside];
    [appsBox addSubview:back];
    self.editorBackButton = back;

    UIButton *tabAdded = [UIButton buttonWithType:UIButtonTypeCustom];
    tabAdded.layer.cornerRadius = 16.0;
    tabAdded.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [tabAdded addTarget:self action:@selector(onEditorTabChanged:) forControlEvents:UIControlEventTouchUpInside];
    [appsBox addSubview:tabAdded];
    self.editorTabAddedButton = tabAdded;

    UIButton *tabAll = [UIButton buttonWithType:UIButtonTypeCustom];
    tabAll.layer.cornerRadius = 16.0;
    tabAll.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [tabAll addTarget:self action:@selector(onEditorTabChanged:) forControlEvents:UIControlEventTouchUpInside];
    [appsBox addSubview:tabAll];
    self.editorTabAllButton = tabAll;
    self.editorTabAdded = YES;

    UILabel *countLabel = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 48.0, width - 36.0, 18.0)];
    countLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    countLabel.font = [UIFont systemFontOfSize:11.5];
    [appsBox addSubview:countLabel];
    self.editorCountLabel = countLabel;

    // 圆盘实时预览容器（已添加 tab 顶部；排序/增删时即时刷新 = 圆盘真实排布）
    UIView *previewBox = [[UIView alloc] initWithFrame:CGRectZero];
    previewBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    previewBox.layer.cornerRadius = 16.0;
    previewBox.userInteractionEnabled = NO;
    [appsBox addSubview:previewBox];
    self.editorPreviewBox = previewBox;

    // 【0.3.26】bundleID → 显示名（枚举时已取好，排序条 rebuild 时只查表，不再碰 SB 私有数据）
    NSMutableDictionary<NSString *, NSString *> *nameTable = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, NSString *> *app in apps) {
        if (app[@"id"].length > 0 && app[@"name"].length > 0) {
            nameTable[app[@"id"]] = app[@"name"];
        }
    }
    self.editorAppNames = nameTable;

    // 【0.3.26 → 0.6.11 用户指令】「已添加」排序：**平铺网格**（自动换行，一屏看全所有已选
    //   App，不再横向滑动找）+ 长按拖拽排序（二维最近邻换位）。
    //   快速点按格子 = 移出圆盘（长按仍是拖拽，互不干扰）。
    UIScrollView *orderScroll = [[UIScrollView alloc]
        initWithFrame:CGRectMake(0.0, 0.0, width, 300.0)];
    orderScroll.backgroundColor = [UIColor clearColor];
    orderScroll.opaque = NO;
    orderScroll.showsHorizontalScrollIndicator = NO;
    orderScroll.showsVerticalScrollIndicator = NO;
    orderScroll.alwaysBounceVertical = NO;
    orderScroll.delaysContentTouches = NO;
    UILongPressGestureRecognizer *drag = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onEditorOrderDrag:)];
    drag.minimumPressDuration = 0.25;
    drag.allowableMovement = CGFLOAT_MAX;
    [orderScroll addGestureRecognizer:drag];
    UITapGestureRecognizer *stripTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onEditorOrderStripTap:)];
    [orderScroll addGestureRecognizer:stripTap];
    [appsBox addSubview:orderScroll];
    self.editorOrderScroll = orderScroll;
    [self rebuildEditorOrderStrip];   // 首次按 editorSelection 的顺序铺好（含真图标/首字母占位）

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 400.0)];
    scroll.backgroundColor = [UIColor clearColor];
    scroll.opaque = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.tag = MF_RING_EDITOR_SCROLL;
    [appsBox addSubview:scroll];
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

    // 【0.6.10】未添加 tab = 只列未加入的 App（分类）；首帧统一布局（一级菜单 / 二级页 / 网格 / 预览）
    [self relayoutEditorGridAnimated:NO];
    [self layoutEditorMenuAnimated:NO];
    [self layoutEditorAppsAnimated:NO];
    [self rebuildEditorRingPreview];
    [self refreshEditorCount];
    MFLog(@"[ring] 0.7.5 编辑器已打开（二级菜单版）：%lu 个 App，已选 %lu 个",
          (unsigned long)apps.count, (unsigned long)selection.count);

    // 真图标延后分批抓（先"首字母"占位，避免一次性拉几百张图标卡住 SpringBoard）
    if (MFRingBool(@"mfRingFetchIcons", YES) && !gMFRingDegraded) {
        self.editorIconGeneration += 1;
        NSUInteger generation = self.editorIconGeneration;
        // 【0.3.26】排序条先填（最多 24 个，缓存命中即瞬时可见），再铺 200 个网格
        if (self.editorOrderCells.count > 0) {
            [self fillEditorIcons:[self.editorOrderCells copy] fromIndex:0 generation:generation];
        }
        [self fillEditorIcons:[self.editorCells copy] fromIndex:0 generation:generation];
    } else {
        MFLog(@"[ring] 编辑器跳过图标抓取（mfRingFetchIcons=false 或降级模式）");
    }
}

#pragma mark - 【0.3.22】触发条自调（编辑器顶部滑杆）

/// 三根滑杆：触发条**长度** / 沿边的**位置** / 呼出**灵敏度**（向屏内外扩的余量）。
/// 拖动即写 NSUserDefaults(com.mlgm.pulloverx) 并立刻重算触发带 + 刷新高亮预览 → 所见即所得；
/// 点「完成」不用额外保存（值在拖动时已落盘，respring 后仍生效）。
/// 标签用中文（用户不看英文）；滑杆 tag：1=长度 2=位置 3=灵敏度。
- (void)buildTriggerSettingsInPanel:(UIView *)panel top:(CGFloat)top {
    CGRect bounds = self.hostBounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = self.hostWindow.bounds;
    }
    CGFloat width = CGRectGetWidth(panel.bounds);
    if (width <= 0.0) {
        width = CGRectGetWidth(bounds);
    }
    NSString *edge = MFRingEdge();
    BOOL verticalEdge = !([edge isEqualToString:@"top"] || [edge isEqualToString:@"bottom"]);
    CGFloat along = verticalEdge ? CGRectGetHeight(bounds) : CGRectGetWidth(bounds);
    if (along <= 0.0) {
        along = verticalEdge ? 932.0 : 430.0;
    }

    CGFloat rawLength = MFRingNumber(@"mfTriggerLength", 0.0);
    CGFloat currentLength = rawLength > 0.0 ? MAX(80.0, rawLength) : MAX(80.0, along * 0.30);
    currentLength = MIN(currentLength, along);
    CGFloat centerRatio = MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.98);
    CGFloat margin = MIN(MAX(MFRingNumber(@"mfTriggerTouchMargin", 60.0), 0.0), 90.0);

    // 触发条高亮预览（在 App 之上、面板之下；只做显示，不接触摸）
    // 【0.3.23】用户 log32："触发条没有紧贴右边屏幕边缘"。原来预览是 0.16 白 + 6pt 圆角 + 1pt 边框，
    //   压在 0.87 黑的面板上几乎看不清，圆角也让人以为"条和屏边之间有缝"⇒ 改成：
    //   填充加亮、**圆角 0**、边框 2pt，并且**向外多铺 3pt**（越界部分被屏幕自然裁掉）——
    //   视觉上就明确是"被屏幕边缘切掉的一块"，一眼能看出它贴死在边缘。
    UIView *preview = [[UIView alloc] initWithFrame:CGRectZero];
    preview.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    preview.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    preview.layer.borderWidth = 2.0;
    preview.layer.cornerRadius = 0.0;
    preview.userInteractionEnabled = NO;
    [panel insertSubview:preview atIndex:0];
    self.triggerPreviewView = preview;

    self.triggerValueLabels = [NSMutableArray array];
    NSArray<NSString *> *titles = @[ @"触发条长度", @"上下位置", @"呼出灵敏度" ];
    NSArray<NSNumber *> *mins = @[ @(60.0), @(0.05), @(0.0) ];
    NSArray<NSNumber *> *maxs = @[ @(MAX(160.0, along * 0.55)), @(0.98), @(90.0) ];
    NSArray<NSNumber *> *values = @[ @(currentLength), @(centerRatio), @(margin) ];
    for (NSUInteger index = 0; index < titles.count; index++) {
        CGFloat rowY = top + (CGFloat)index * 32.0;
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(18.0, rowY, 76.0, 30.0)];
        name.text = titles[index];
        name.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        name.font = [UIFont systemFontOfSize:12.0];
        [panel addSubview:name];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(96.0, rowY + 3.0,
                                                                     MAX(80.0, width - 96.0 - 92.0), 24.0)];
        slider.minimumValue = mins[index].floatValue;
        slider.maximumValue = maxs[index].floatValue;
        slider.value = values[index].floatValue;
        slider.tag = (NSInteger)index + 1;
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        [slider addTarget:self action:@selector(onTriggerSliderChanged:)
         forControlEvents:UIControlEventValueChanged];
        [panel addSubview:slider];

        UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(width - 84.0, rowY, 66.0, 30.0)];
        value.textAlignment = NSTextAlignmentRight;
        value.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
        value.font = [UIFont systemFontOfSize:11.0];
        [panel addSubview:value];
        [self.triggerValueLabels addObject:value];
    }
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(18.0, top + 3.0 * 32.0 - 2.0, width - 36.0, 16.0)];
    hint.text = @"白色高亮 = 屏幕边缘的呼出触发条；调整立即生效并保存（不用 respring）";
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    hint.font = [UIFont systemFontOfSize:10.5];
    [panel addSubview:hint];

    [self refreshTriggerGeometryAfterPrefsChange];   // 同时刷新预览位置 + 数值标签
}

- (void)onTriggerSliderChanged:(UISlider *)slider {
    switch (slider.tag) {
        case 1:
            MFRingSetNumber(@"mfTriggerLength", slider.value);
            break;
        case 2:
            MFRingSetNumber(@"mfTriggerCenterRatio", slider.value);
            break;
        case 3:
            MFRingSetNumber(@"mfTriggerTouchMargin", slider.value);
            break;
        default:
            break;
    }
    [self refreshTriggerGeometryAfterPrefsChange];
}

/// 按当前配置重算触发带，并把高亮预览摆到新位置（宿主尺寸没变也要走 —— 这里不用缓存比较）。
- (void)refreshTriggerGeometryAfterPrefsChange {
    UIWindow *window = self.hostWindow;
    if (window == nil) {
        return;
    }
    CGRect bounds = window.bounds;
    if (CGRectIsEmpty(bounds)) {
        return;
    }
    self.hostBounds = bounds;
    self.triggerFrame = [self triggerFrameForBounds:bounds];
    if (self.stripView != nil) {
        self.stripView.frame = bounds;
    }
    if (self.triggerPreviewView != nil) {
        // 【0.3.23】预览向外多铺 3pt：越界部分被屏幕裁掉 → 视觉上"贴死在边缘、没有缝"
        CGRect previewRect = self.triggerFrame;
        NSString *edge = MFRingEdge();
        if ([edge isEqualToString:@"right"]) {
            previewRect.size.width += 3.0;
        } else if ([edge isEqualToString:@"left"]) {
            previewRect.origin.x -= 3.0;
            previewRect.size.width += 3.0;
        } else if ([edge isEqualToString:@"top"]) {
            previewRect.origin.y -= 3.0;
            previewRect.size.height += 3.0;
        } else {
            previewRect.size.height += 3.0;
        }
        self.triggerPreviewView.frame =
            [self.triggerPreviewView.superview convertRect:previewRect fromView:window];
    }
    [self syncTriggerValueLabels];
    MFLog(@"[ring] 触发条已更新：%@（长度 %.0fpt / 位置比例 %.2f / 灵敏度外扩 %.0fpt / 外侧边距屏边 %.1fpt）",
          NSStringFromCGRect(self.triggerFrame),
          CGRectGetHeight(self.triggerFrame) > 0 ? CGRectGetHeight(self.triggerFrame) : CGRectGetWidth(self.triggerFrame),
          MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.98),
          MAX(0.0, MFRingNumber(@"mfTriggerTouchMargin", 60.0)),
          [self triggerOuterEdgeGapForBounds:bounds]);
}

- (void)syncTriggerValueLabels {
    if (self.triggerValueLabels.count < 3) {
        return;
    }
    CGRect band = self.triggerFrame;
    CGFloat length = CGRectGetHeight(band) > 0 && CGRectGetWidth(band) <= 64.0
        ? CGRectGetHeight(band) : CGRectGetWidth(band);
    self.triggerValueLabels[0].text = [NSString stringWithFormat:@"%.0f pt", length];
    self.triggerValueLabels[1].text = [NSString stringWithFormat:@"%.0f%%",
        MIN(MAX(MFRingNumber(@"mfTriggerCenterRatio", 0.78), 0.05), 0.98) * 100.0];
    self.triggerValueLabels[2].text = [NSString stringWithFormat:@"%.0f pt",
        MAX(0.0, MFRingNumber(@"mfTriggerTouchMargin", 60.0))];
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
    // 【0.3.26】加入 = 追加到圆盘顺序末尾；移出 = 从顺序里删掉 ⇒ 排序条跟着重建
    // 【0.6.10】排序条重建末尾会连带刷新圆盘实时预览；未添加 tab 网格即时重排
    [self rebuildEditorOrderStrip];
    [self relayoutEditorGridAnimated:YES];
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

#pragma mark - 【0.3.26 用户 log35】「已添加」排序条（自定义圆盘内应用位置）

/// 按 `editorSelection`（= 圆盘真实顺序）**重建**排序网格：序号 + 图标 + 名称。
/// 顺带说明：圆盘上图标的位置就是这个顺序（`ringApps` 数组顺序），点「完成」即写盘生效。
/// ⚠️ 只做"加/减成员"后的重建；单纯换位置走 layoutEditorOrderCellsAnimated:（保留格子身份，
///    能看见"哪个 App 挪到哪儿"）。【0.6.8】◀ ▶ 已删，换位走拖拽 moveEditorOrderCellFromIndex:toIndex:。
/// 【0.6.11 用户指令】排序条改**平铺网格**（自动换行）：所有已选 App 一屏看全，不再横向滑动找 App。
- (void)rebuildEditorOrderStrip {
    UIScrollView *strip = self.editorOrderScroll;
    if (strip == nil) {
        return;
    }
    NSArray<NSString *> *ordered = (self.editorSelection != nil) ? self.editorSelection.array : @[];
    for (UIView *view in [strip.subviews copy]) {
        [view removeFromSuperview];
    }
    self.editorOrderCells = [NSMutableArray array];

    const CGFloat cellW = MF_RING_ORDER_CELL_W;
    const CGFloat cellH = MF_RING_ORDER_CELL_H;
    const CGFloat gap = MF_RING_ORDER_CELL_GAP;
    const CGFloat inset = MF_RING_ORDER_INSET;
    const CGFloat iconSize = 48.0;
    NSUInteger columns = [self mfEditorOrderColumnsForWidth:CGRectGetWidth(strip.bounds)];

    for (NSUInteger index = 0; index < ordered.count; index++) {
        NSString *bundleId = ordered[index];
        // 显示名用「枚举时一次性取好的表」（见 editorAppNames）—— 排序条每次增删/移动都会重建，
        // 不能在这里查 LSApplicationProxy（那是 SB 私有数据，必须留在 openEditor 的 guard 闸门内）。
        NSString *name = self.editorAppNames[bundleId];
        if (name.length == 0) {
            name = [bundleId lastPathComponent];
        }
        NSUInteger column = index % columns;
        NSUInteger row = index / columns;
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(inset + (CGFloat)column * (cellW + gap),
                                                                inset + (CGFloat)row * (cellH + gap),
                                                                cellW, cellH)];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        cell.layer.cornerRadius = 12.0;
        objc_setAssociatedObject(cell, &kMFRingBundleIdKey, bundleId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UILabel *order = [[UILabel alloc] initWithFrame:CGRectMake(6.0, 3.0, 22.0, 14.0)];
        order.tag = MF_RING_EDITOR_ORDER_INDEX;
        order.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        order.font = [UIFont boldSystemFontOfSize:11.0];
        [cell addSubview:order];

        // 图标视图与网格用同一个 tag ⇒ 复用 fillEditorIcons: 的贴图（含首字母占位）逻辑
        UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake((cellW - iconSize) / 2.0,
                                                                             4.0, iconSize, iconSize)];
        iconView.tag = MF_RING_EDITOR_ICON;
        iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        iconView.layer.cornerRadius = 12.0;
        iconView.layer.masksToBounds = YES;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        [cell addSubview:iconView];

        UILabel *placeholder = [[UILabel alloc] initWithFrame:iconView.bounds];
        placeholder.tag = MF_RING_EDITOR_LABEL;
        placeholder.text = (name.length > 0) ? [name substringToIndex:1] : @"?";
        placeholder.textAlignment = NSTextAlignmentCenter;
        placeholder.textColor = [UIColor whiteColor];
        placeholder.font = [UIFont boldSystemFontOfSize:20.0];
        [iconView addSubview:placeholder];

        UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(1.0, 4.0 + iconSize + 2.0,
                                                                      cellW - 2.0, 26.0)];
        nameLabel.text = name;
        nameLabel.textAlignment = NSTextAlignmentCenter;
        nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        nameLabel.font = [UIFont systemFontOfSize:9.5];
        nameLabel.numberOfLines = 2;
        [cell addSubview:nameLabel];

        // 【0.6.8 用户指令】◀ ▶ 逐格按钮已删——排序改长按拖拽（跟手换位，一步到位）。
        [strip addSubview:cell];
        [self.editorOrderCells addObject:cell];
        [self applyEditorOrderCellDecorations:cell index:index total:ordered.count];
    }

    // 【0.6.11】平铺网格：按当前宽度算行数，contentSize 纵向撑开（宽度方向不滚）
    NSUInteger rows = (ordered.count + columns - 1) / columns;
    strip.contentSize = CGSizeMake(MAX(CGRectGetWidth(strip.bounds),
                                       inset * 2.0 + (CGFloat)columns * (cellW + gap)),
                                   MAX(CGRectGetHeight(strip.bounds),
                                       (CGFloat)MAX(rows, 1) * (cellH + gap) + inset * 2.0));
    // 【0.6.8】提示并入计数行（排序条标题已随简约化移除，editorOrderTitle 不再创建）。

    // 图标：命中缓存是瞬时的；没命中先显示首字母，由 fillEditorIcons: 就近补齐
    if (self.editorPanel != nil && !gMFRingDegraded && MFRingBool(@"mfRingFetchIcons", YES)
        && self.editorOrderCells.count > 0) {
        [self fillEditorIcons:[self.editorOrderCells copy]
                    fromIndex:0
                   generation:self.editorIconGeneration];
    }
    MFLog(@"[ring] 排序网格已重建：%lu 个（%lu 列 × %lu 行平铺，长按拖动调整）",
          (unsigned long)ordered.count, (unsigned long)columns, (unsigned long)rows);
    // 【0.6.10】实时预览跟随成员变化（排序拖拽的换位走 moveEditorOrderCellFromIndex 单独刷新）
    [self rebuildEditorRingPreview];
    // 【0.6.11】成员变化 → 网格行数变化 → 预览/网格高度重排（layoutEditorAppsAnimated 只做布局不回环）
    [self layoutEditorAppsAnimated:NO];
}

/// 【0.6.11】排序网格每行列数：宽度 ÷ (格子宽+间距)，夹在 3~6（430pt 宽 = 5 列）。
- (NSUInteger)mfEditorOrderColumnsForWidth:(CGFloat)width {
    if (width <= 0.0) {
        width = CGRectGetWidth(self.editorPanel.bounds);
    }
    if (width <= 0.0) {
        width = 430.0;
    }
    NSUInteger columns = (NSUInteger)floor((width - MF_RING_ORDER_INSET * 2.0 + MF_RING_ORDER_CELL_GAP)
                                           / (MF_RING_ORDER_CELL_W + MF_RING_ORDER_CELL_GAP));
    return MAX((NSUInteger)3, MIN(columns, (NSUInteger)6));
}

/// 按数组顺序摆好每个格子（平铺网格 frame + 序号装饰）。
/// 换位置时只调它、不重建视图 ⇒ 格子带着自己的图标/名称一起滑动，看得清"哪个 App 挪到哪去"。
- (void)layoutEditorOrderCellsAnimated:(BOOL)animated {
    NSArray<UIView *> *cells = [self.editorOrderCells copy];
    UIScrollView *strip = self.editorOrderScroll;
    NSUInteger columns = [self mfEditorOrderColumnsForWidth:CGRectGetWidth(strip.bounds)];
    if (columns == 0) {
        columns = 1;
    }
    void (^layout)(void) = ^{
        const CGFloat stepX = MF_RING_ORDER_CELL_W + MF_RING_ORDER_CELL_GAP;
        const CGFloat stepY = MF_RING_ORDER_CELL_H + MF_RING_ORDER_CELL_GAP;
        NSUInteger total = cells.count;
        for (NSUInteger index = 0; index < total; index++) {
            UIView *cell = cells[index];
            if (cell == self.editorOrderDraggingCell) {
                // 【0.6.8】拖拽中的格子位置由手势跟手控制，layout 只刷新序号装饰
                [self applyEditorOrderCellDecorations:cell index:index total:total];
                continue;
            }
            CGRect frame = cell.frame;
            frame.origin.x = MF_RING_ORDER_INSET + (CGFloat)(index % columns) * stepX;
            frame.origin.y = MF_RING_ORDER_INSET + (CGFloat)(index / columns) * stepY;
            // 【0.6.17 用户 log57-①】帧没变就不写：UIView.frame 赋值即触发一次布局，
            //   拖拽中每次换位都全排 18 格 = 60Hz 下最实在的开销；未动的格子直接跳过。
            if (!CGRectEqualToRect(cell.frame, frame)) {
                cell.frame = frame;
            }
            [self applyEditorOrderCellDecorations:cell index:index total:total];
        }
        // 【0.6.11】contentSize 纵向撑开（平铺全览，宽度方向不滚）
        NSUInteger rows = (total + columns - 1) / columns;
        CGSize size = CGSizeMake(MAX(CGRectGetWidth(strip.bounds),
                                     MF_RING_ORDER_INSET * 2.0
                                     + (CGFloat)columns * stepX),
                                 MAX(CGRectGetHeight(strip.bounds),
                                     (CGFloat)MAX(rows, 1) * stepY + MF_RING_ORDER_INSET * 2.0));
        if (!CGSizeEqualToSize(strip.contentSize, size)) {
            strip.contentSize = size;
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:layout
                         completion:nil];
    } else {
        // 【0.6.17 用户 log57-①】非动画路径显式关掉 CALayer 隐式动画：
        //   拖拽期间若还有上一次落位 spring 的图层补间在跑，position 会被再补间一次 ⇒ 闪。
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layout();
        [CATransaction commit];
    }
}

/// 序号徽章（【0.6.8】◀▶ 可用状态已随拖拽排序移除，装饰只剩序号）。
- (void)applyEditorOrderCellDecorations:(UIView *)cell index:(NSUInteger)index total:(NSUInteger)total {
    if (cell == nil) {
        return;
    }
    (void)total;
    UILabel *order = (UILabel *)[cell viewWithTag:MF_RING_EDITOR_ORDER_INDEX];
    if (order != nil) {
        // 【0.6.17 用户 log57-①】文本没变不写：UILabel.text 赋值会触发布局+重画，
        //   拖拽中每帧给十几个格子重设文本是掉帧大户（旧法换位 97 次 ⇒ 文本写 1700+ 次）。
        NSUInteger shown = (NSUInteger)order.text.integerValue;
        if (order.text.length == 0 || shown != index + 1) {
            order.text = [NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)];
        }
    }
}

#pragma mark - 【0.6.8 用户指令】排序条长按拖拽（简约/快捷/效率：一步到位，替代 ◀ ▶ 逐格点）

/// 长按拖拽排序（【0.6.11】平铺网格版）：Began 提起 → Changed 跟手（x/y 双向）+ 最近格换位
/// → Ended 弹簧落位。数据同步 = editorSelection（remove + insert，即圆盘真实顺序）；
/// 视图 = cells 数组同步插入 + layoutEditorOrderCellsAnimated 让位
/// （铁律：交换/移动引用 + 只重排 frame，绝不整段重建）。平铺全览后不再需要边缘自动滚。
- (void)onEditorOrderDrag:(UILongPressGestureRecognizer *)gesture {
    UIScrollView *strip = self.editorOrderScroll;
    if (strip == nil || self.editorOrderCells.count == 0) {
        return;
    }
    CGPoint touchInStrip = [gesture locationInView:strip];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        // 定位按下点所在格子（内容坐标比对，x/y 双向）
        CGPoint contentPoint = CGPointMake(touchInStrip.x + strip.contentOffset.x,
                                           touchInStrip.y + strip.contentOffset.y);
        NSUInteger hit = NSNotFound;
        for (NSUInteger index = 0; index < self.editorOrderCells.count; index++) {
            UIView *cell = self.editorOrderCells[index];
            if (contentPoint.x >= CGRectGetMinX(cell.frame) && contentPoint.x <= CGRectGetMaxX(cell.frame) &&
                contentPoint.y >= CGRectGetMinY(cell.frame) && contentPoint.y <= CGRectGetMaxY(cell.frame)) {
                hit = index;
                break;
            }
        }
        if (hit == NSNotFound) {
            return;   // 按在空隙上：忽略（不进入拖拽）
        }
        UIView *cell = self.editorOrderCells[hit];
        self.editorOrderDraggingCell = cell;
        self.editorOrderDragIndex = hit;
        self.editorOrderDragSwapCount = 0;   // 【0.6.16】本场拖拽换位计数（诊断用）
        self.editorOrderDragGrabOffset = contentPoint.x - CGRectGetMidX(cell.frame);
        self.editorOrderDragGrabOffsetY = contentPoint.y - CGRectGetMidY(cell.frame);
        strip.scrollEnabled = NO;   // 拖拽期间禁滚动（网格平时全览不滚，防误滚）
        [strip addSubview:cell];    // 提到最上层（盖住让位的邻居）
        cell.transform = CGAffineTransformMakeScale(1.12, 1.12);
        cell.alpha = 0.95;
        cell.layer.shadowColor = [UIColor blackColor].CGColor;
        cell.layer.shadowOpacity = 0.55;
        cell.layer.shadowRadius = 10.0;
        cell.layer.shadowOffset = CGSizeMake(0.0, 3.0);
        [self mfRingHapticLight];
        MFLog(@"[ring] 拖拽排序开始：%@（第 %lu 位）",
              objc_getAssociatedObject(cell, &kMFRingBundleIdKey) ?: @"?", (unsigned long)(hit + 1));
        return;
    }

    UIView *dragCell = self.editorOrderDraggingCell;
    if (dragCell == nil) {
        return;
    }
    NSUInteger dragIndex = self.editorOrderDragIndex;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        // 跟手：center = 触点内容坐标 - 提起偏移（x/y 双向，平铺网格）
        CGPoint contentPoint = CGPointMake(touchInStrip.x + strip.contentOffset.x,
                                           touchInStrip.y + strip.contentOffset.y);
        CGPoint center = dragCell.center;
        center.x = contentPoint.x - self.editorOrderDragGrabOffset;
        center.y = contentPoint.y - self.editorOrderDragGrabOffsetY;
        dragCell.center = center;

        // 【0.6.17 用户 log57-① 重点修复·附近图标狂闪 / 卡顿掉帧】目标格位判定换算法
        //   旧法「离拖拽格中心最近的那个邻居格子」是**自杀式循环依赖**：邻居的 center 会随
        //   换位一起改变，换位之后刚被挤开的那一格反而又成了"最近邻" ⇒ 每帧来回换位。
        //   log57 实测 1.5 秒换位 97 次（≈每帧 1~2 次），视觉上就是附近图标疯狂闪烁、掉帧。
        //   新法：用**静态网格几何**（只跟格子宽高/间距有关，不随换位变化）反算拖拽格中心
        //   落在哪个槽位，反馈环被斩断 ⇒ 手指不动就绝不换位；再给目标格留一圈死区
        //   （必须真正压进目标格矩形内部才换位）⇒ 停在两格缝隙上也只抖不换。
        NSUInteger columns = [self mfEditorOrderColumnsForWidth:CGRectGetWidth(strip.bounds)];
        if (columns == 0) {
            columns = 1;
        }
        const CGFloat swapStepX = MF_RING_ORDER_CELL_W + MF_RING_ORDER_CELL_GAP;
        const CGFloat swapStepY = MF_RING_ORDER_CELL_H + MF_RING_ORDER_CELL_GAP;
        NSUInteger swapCount = self.editorOrderCells.count;
        NSInteger slotCol = (NSInteger)floor((center.x - MF_RING_ORDER_INSET) / swapStepX);
        NSInteger slotRow = (NSInteger)floor((center.y - MF_RING_ORDER_INSET) / swapStepY);
        slotCol = MAX((NSInteger)0, MIN(slotCol, (NSInteger)columns - 1));
        slotRow = MAX((NSInteger)0, slotRow);
        NSInteger slotIndex = slotRow * (NSInteger)columns + slotCol;
        BOOL beyondEnd = (slotIndex >= (NSInteger)swapCount);
        NSUInteger target = beyondEnd ? (swapCount - 1) : (NSUInteger)slotIndex;
        if (target != dragIndex) {
            BOOL commit = beyondEnd;   // 拖到网格以外的末尾：直接判给最后一格
            if (!commit) {
                CGRect targetRect = CGRectMake(MF_RING_ORDER_INSET
                                                   + (CGFloat)(target % columns) * swapStepX,
                                               MF_RING_ORDER_INSET
                                                   + (CGFloat)(target / columns) * swapStepY,
                                               MF_RING_ORDER_CELL_W, MF_RING_ORDER_CELL_H);
                // 死区：目标矩形内缩 ⇒ 格子之间的缝隙 + 两侧余量都不触发换位
                commit = CGRectContainsPoint(CGRectInset(targetRect,
                                                         MF_RING_ORDER_SWAP_DEAD_ZONE,
                                                         MF_RING_ORDER_SWAP_DEAD_ZONE),
                                             center);
            }
            if (commit) {
                [self moveEditorOrderCellFromIndex:dragIndex toIndex:target];
            }
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        strip.scrollEnabled = YES;
        self.editorOrderDraggingCell = nil;
        // 【0.6.16】松手后把实时预览补一次（拖拽期间为保帧率停掉了逐步重建）
        [self rebuildEditorRingPreview];
        NSUInteger finalIndex = dragIndex;
        UIView * __weak weakCell = dragCell;
        CGRect homeFrame = dragCell.frame;
        homeFrame.origin.x = MF_RING_ORDER_INSET
            + (CGFloat)(finalIndex % (NSUInteger)[self mfEditorOrderColumnsForWidth:CGRectGetWidth(strip.bounds)])
            * (MF_RING_ORDER_CELL_W + MF_RING_ORDER_CELL_GAP);
        homeFrame.origin.y = MF_RING_ORDER_INSET
            + (CGFloat)(finalIndex / (NSUInteger)[self mfEditorOrderColumnsForWidth:CGRectGetWidth(strip.bounds)])
            * (MF_RING_ORDER_CELL_H + MF_RING_ORDER_CELL_GAP);
        dragCell.frame = homeFrame;   // model 值先落位（动画从这个 home 弹回）
        dragCell.transform = CGAffineTransformMakeScale(1.12, 1.12);
        [UIView animateWithDuration:0.42
                              delay:0.0
             usingSpringWithDamping:0.55
              initialSpringVelocity:0.3
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:^{
            weakCell.transform = CGAffineTransformIdentity;
            weakCell.alpha = 1.0;
            weakCell.layer.shadowOpacity = 0.0;
        } completion:nil];
        [self mfRingHapticLight];
        NSString *bid = objc_getAssociatedObject(dragCell, &kMFRingBundleIdKey) ?: @"?";
        MFLog(@"[ring] 拖拽排序完成：%@ → 第 %lu 位（共 %lu 个，本场换位 %lu 次，点完成写盘生效）",
              bid, (unsigned long)(finalIndex + 1), (unsigned long)self.editorOrderCells.count,
              (unsigned long)self.editorOrderDragSwapCount);
    }
}

/// 换位：editorSelection 与 cells 数组同步 remove + insert，再让位动画重排（不重建视图）。
- (void)moveEditorOrderCellFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    NSMutableOrderedSet<NSString *> *selection = self.editorSelection;
    NSMutableArray<UIView *> *cells = self.editorOrderCells;
    if (selection == nil || cells == nil ||
        fromIndex >= cells.count || toIndex >= cells.count || fromIndex == toIndex) {
        return;
    }
    NSString *bundleId = selection.array[fromIndex];
    [selection removeObject:bundleId];
    [selection insertObject:bundleId atIndex:toIndex];
    UIView *cell = cells[fromIndex];
    [cells removeObjectAtIndex:fromIndex];
    [cells insertObject:cell atIndex:toIndex];
    self.editorOrderDragIndex = toIndex;
    self.editorOrderDragSwapCount += 1;
    // 【0.6.16 用户 log56-① 重点修复·卡顿掉帧】
    //   ① 拖拽期间**不做让位补间**：0.18s 的动画在连续换位时会被反复打断重启
    //      （BeginFromCurrentState），观感就是"格子在爬、落点不准"；拖拽中的格子本来就
    //      盖在邻居上面，直接落位反而最跟手。松手（Ended）才做一次收尾。
    //   ② 实时预览**不再每一步重建**：一次重建 = 拆掉十来个图标视图再整套重画，
    //      在 60Hz 的拖动里就是实打实的掉帧源 —— 攒到松手/成员变化时重建一次。
    [self layoutEditorOrderCellsAnimated:(self.editorOrderDraggingCell == nil)];
}

- (void)mfRingHapticLight {
    @try {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - 【0.6.10 用户指令】二级菜单 + 圆盘实时预览

/// 一级菜单行工厂：左标题 + 灰副标题 + 右侧 ›，浅底圆角（保持菜单简洁不拥挤）。
- (UIButton *)makeEditorMenuRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    row.layer.cornerRadius = 14.0;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.titleEdgeInsets = UIEdgeInsetsMake(-14.0, 16.0, 0.0, 0.0);
    [row setTitle:title forState:UIControlStateNormal];
    [row setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    row.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16.0, 36.0, 240.0, 18.0)];
    sub.text = subtitle;
    sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    sub.font = [UIFont systemFontOfSize:12.0];
    sub.userInteractionEnabled = NO;
    [row addSubview:sub];

    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 26.0, 64.0)];
    chevron.tag = MF_RING_EDITOR_ROW_CHEVRON;
    chevron.text = @"›";
    chevron.textColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    chevron.font = [UIFont boldSystemFontOfSize:20.0];
    chevron.textAlignment = NSTextAlignmentCenter;
    chevron.userInteractionEnabled = NO;
    [row addSubview:chevron];
    return row;
}

#pragma mark - 【0.7.5】二级页「点通知进悬浮窗」

/// 二级页构建：总开关 / 适用范围（全部应用 · 仅选中的应用）/ 应用名单（勾选）。
/// 名单数据源 = 编辑器已经枚举好的 `self.editorApps`（**不再二次枚举**，避免再碰 SB 私有数据）；
/// 系统动作伪 bundleID（mfsys.*）不会有系统通知，直接排除。
- (void)buildEditorNotifyPageInPanel:(UIView *)panel width:(CGFloat)width height:(CGFloat)height {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0.0, 92.0, width, height - 92.0)];
    box.hidden = YES;
    box.userInteractionEnabled = YES;
    [panel addSubview:box];
    self.editorNotifyBox = box;

    UIButton *back = [UIButton buttonWithType:UIButtonTypeCustom];
    back.frame = CGRectMake(12.0, 6.0, 96.0, 36.0);
    back.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    back.layer.cornerRadius = 18.0;
    back.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    back.contentEdgeInsets = UIEdgeInsetsMake(0.0, 10.0, 0.0, 0.0);
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [back setTitle:@"‹ 返回" forState:UIControlStateNormal];
    [back setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [back addTarget:self action:@selector(onEditorBackTapped:) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:back];
    self.editorNotifyBackButton = back;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"点通知进悬浮窗";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15.0];
    title.textAlignment = NSTextAlignmentRight;
    [box addSubview:title];
    self.editorNotifyTitleLabel = title;

    UIView *switchBox = [[UIView alloc] initWithFrame:CGRectZero];
    switchBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    switchBox.layer.cornerRadius = 14.0;
    switchBox.userInteractionEnabled = YES;
    [box addSubview:switchBox];
    self.editorNotifySwitchBox = switchBox;

    UILabel *switchLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    switchLabel.text = @"点通知进悬浮窗";
    switchLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    switchLabel.font = [UIFont systemFontOfSize:13.5];
    [switchBox addSubview:switchLabel];
    self.editorNotifySwitchLabel = switchLabel;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = MFRingBool(@"mfNotificationClickFloat", YES);
    toggle.onTintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    [toggle addTarget:self action:@selector(onEditorNotifySwitchChanged:)
     forControlEvents:UIControlEventValueChanged];
    [switchBox addSubview:toggle];
    self.editorNotifySwitch = toggle;

    UILabel *scopeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    scopeLabel.text = @"适用范围";
    scopeLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    scopeLabel.font = [UIFont systemFontOfSize:11.5];
    [box addSubview:scopeLabel];
    self.editorNotifyScopeLabel = scopeLabel;

    UIButton *allButton = [UIButton buttonWithType:UIButtonTypeCustom];
    allButton.layer.cornerRadius = 16.0;
    allButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [allButton setTitle:@"全部应用" forState:UIControlStateNormal];
    [allButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [allButton addTarget:self action:@selector(onEditorNotifyScopeTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:allButton];
    self.editorNotifyAllButton = allButton;

    UIButton *pickButton = [UIButton buttonWithType:UIButtonTypeCustom];
    pickButton.layer.cornerRadius = 16.0;
    pickButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [pickButton setTitle:@"仅选中的应用" forState:UIControlStateNormal];
    [pickButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [pickButton addTarget:self action:@selector(onEditorNotifyScopeTapped:)
         forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:pickButton];
    self.editorNotifyPickButton = pickButton;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    hint.font = [UIFont systemFontOfSize:11.0];
    hint.numberOfLines = 2;
    [box addSubview:hint];
    self.editorNotifyHintLabel = hint;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;
    [box addSubview:scroll];
    self.editorNotifyScroll = scroll;

    NSMutableOrderedSet<NSString *> *selected = [NSMutableOrderedSet orderedSet];
    id stored = [MFRingDefaults() objectForKey:@"mfNotificationClickFloatApps"];
    if ([stored isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)stored) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [selected addObject:item];
            }
        }
    }
    self.editorNotifySelected = selected;

    NSMutableArray<UIButton *> *rows = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *app in self.editorApps) {
        NSString *bundleId = app[@"id"];
        if (bundleId.length == 0 || [bundleId hasPrefix:@"mfsys."]) {
            continue;
        }
        NSString *name = (app[@"name"].length > 0) ? app[@"name"] : bundleId;
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        row.layer.cornerRadius = 12.0;
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.contentEdgeInsets = UIEdgeInsetsMake(0.0, 14.0, 0.0, 46.0);
        row.accessibilityIdentifier = bundleId;
        [row setTitle:name forState:UIControlStateNormal];
        [row setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92] forState:UIControlStateNormal];
        row.titleLabel.font = [UIFont systemFontOfSize:13.5];
        row.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addTarget:self action:@selector(onEditorNotifyAppTapped:)
      forControlEvents:UIControlEventTouchUpInside];

        UILabel *mark = [[UILabel alloc] initWithFrame:CGRectZero];
        mark.tag = MF_RING_NOTIFY_MARK;
        mark.text = @"";
        mark.textAlignment = NSTextAlignmentCenter;
        mark.textColor = [UIColor whiteColor];
        mark.font = [UIFont boldSystemFontOfSize:13.0];
        mark.layer.cornerRadius = 11.0;
        mark.layer.borderWidth = 1.5;
        mark.userInteractionEnabled = NO;
        [row addSubview:mark];

        [scroll addSubview:row];
        [rows addObject:row];
    }
    self.editorNotifyRows = rows;
    MFLog(@"[ring] 点通知进悬浮窗：名单可选项 %lu 个，已勾选 %lu 个",
          (unsigned long)rows.count, (unsigned long)self.editorNotifySelected.count);
}

- (void)layoutEditorNotifyPage {
    UIView *box = self.editorNotifyBox;
    if (box == nil) {
        return;
    }
    CGFloat w = CGRectGetWidth(box.bounds);
    CGFloat h = CGRectGetHeight(box.bounds);
    if (w <= 0.0 || h <= 0.0) {
        return;
    }
    self.editorNotifyBackButton.frame = CGRectMake(12.0, 6.0, 96.0, 36.0);
    self.editorNotifyTitleLabel.frame = CGRectMake(120.0, 6.0, MAX(60.0, w - 132.0), 36.0);

    self.editorNotifySwitchBox.frame = CGRectMake(12.0, 52.0, w - 24.0, 52.0);
    self.editorNotifySwitchLabel.frame = CGRectMake(14.0, 0.0, w - 116.0, 52.0);
    self.editorNotifySwitch.frame = CGRectMake(w - 24.0 - 14.0 - 51.0, 10.5, 51.0, 31.0);

    self.editorNotifyScopeLabel.frame = CGRectMake(18.0, 112.0, w - 36.0, 18.0);
    CGFloat segmentW = (w - 24.0 - 8.0) / 2.0;
    self.editorNotifyAllButton.frame = CGRectMake(12.0, 134.0, segmentW, 36.0);
    self.editorNotifyPickButton.frame = CGRectMake(12.0 + segmentW + 8.0, 134.0, segmentW, 36.0);

    self.editorNotifyHintLabel.frame = CGRectMake(18.0, 178.0, w - 36.0, 32.0);

    CGFloat listTop = 216.0;
    self.editorNotifyScroll.frame = CGRectMake(0.0, listTop, w, MAX(120.0, h - listTop));
    CGFloat rowW = w - 24.0;
    CGFloat y = 0.0;
    for (UIButton *row in self.editorNotifyRows) {
        row.frame = CGRectMake(12.0, y, rowW, MF_RING_NOTIFY_ROW_H);
        UILabel *mark = (UILabel *)[row viewWithTag:MF_RING_NOTIFY_MARK];
        mark.frame = CGRectMake(rowW - 34.0, (MF_RING_NOTIFY_ROW_H - 22.0) / 2.0, 22.0, 22.0);
        y += MF_RING_NOTIFY_ROW_H + MF_RING_NOTIFY_ROW_GAP;
    }
    self.editorNotifyScroll.contentSize = CGSizeMake(w, MAX(0.0, y));
}

/// 刷新整页状态：段控高亮、提示文案、名单行勾选圈与可点状态。
- (void)refreshEditorNotifyVisuals {
    BOOL on = MFRingBool(@"mfNotificationClickFloat", YES);
    NSInteger scope = (NSInteger)MFRingNumber(@"mfNotificationClickFloatScope", 0.0);
    BOOL pickMode = (scope == 1);
    UIColor *active = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    UIColor *idle = [UIColor colorWithWhite:1.0 alpha:0.12];

    self.editorNotifySwitch.on = on;
    self.editorNotifyAllButton.backgroundColor = pickMode ? idle : active;
    self.editorNotifyPickButton.backgroundColor = pickMode ? active : idle;
    self.editorNotifyAllButton.alpha = on ? 1.0 : 0.4;
    self.editorNotifyPickButton.alpha = on ? 1.0 : 0.4;

    NSUInteger selectedCount = self.editorNotifySelected.count;
    if (!on) {
        self.editorNotifyHintLabel.text = @"已关闭：点通知仍按系统原生方式全屏打开。";
    } else if (!pickMode) {
        self.editorNotifyHintLabel.text = @"全部应用：任何 App 的通知点开都进悬浮窗。";
    } else if (selectedCount == 0) {
        self.editorNotifyHintLabel.text = @"名单为空 ⇒ 不做限制（等同全部应用）。下面勾选要进悬浮窗的 App。";
    } else {
        self.editorNotifyHintLabel.text =
            [NSString stringWithFormat:@"仅这 %lu 个应用的通知进悬浮窗，其余照原生全屏。",
             (unsigned long)selectedCount];
    }

    BOOL editable = (on && pickMode);
    for (UIButton *row in self.editorNotifyRows) {
        NSString *bundleId = row.accessibilityIdentifier;
        BOOL picked = (bundleId.length > 0) && [self.editorNotifySelected containsObject:bundleId];
        UILabel *mark = (UILabel *)[row viewWithTag:MF_RING_NOTIFY_MARK];
        mark.text = picked ? @"✓" : @"";
        mark.backgroundColor = picked ? active : [UIColor clearColor];
        mark.layer.borderColor = (picked ? active : [UIColor colorWithWhite:1.0 alpha:0.28]).CGColor;
        row.alpha = editable ? 1.0 : 0.45;
        row.userInteractionEnabled = editable;
    }
}

- (void)onEditorNotifySwitchChanged:(UISwitch *)switchView {
    [MFRingDefaults() setObject:@(switchView.on) forKey:@"mfNotificationClickFloat"];
    [MFRingDefaults() synchronize];
    [self refreshEditorNotifyVisuals];
    MFLog(@"[ring] 点通知进悬浮窗 -> %@（下一次点通知就生效）", switchView.on ? @"开" : @"关");
}

- (void)onEditorNotifyScopeTapped:(UIButton *)sender {
    if (self.editorNotifySwitch == nil || !self.editorNotifySwitch.on) {
        return;
    }
    NSInteger scope = (sender == self.editorNotifyPickButton) ? 1 : 0;
    [MFRingDefaults() setObject:@(scope) forKey:@"mfNotificationClickFloatScope"];
    [MFRingDefaults() synchronize];
    [self refreshEditorNotifyVisuals];
    MFLog(@"[ring] 点通知进悬浮窗：适用范围 -> %@（已勾选 %lu 个，下一次点通知就生效）",
          (scope == 1) ? @"仅选中的应用" : @"全部应用",
          (unsigned long)self.editorNotifySelected.count);
}

- (void)onEditorNotifyAppTapped:(UIButton *)sender {
    NSString *bundleId = sender.accessibilityIdentifier;
    if (bundleId.length == 0) {
        return;
    }
    BOOL nowSelected = ![self.editorNotifySelected containsObject:bundleId];
    if (nowSelected) {
        [self.editorNotifySelected addObject:bundleId];
    } else {
        [self.editorNotifySelected removeObject:bundleId];
    }
    [MFRingDefaults() setObject:[self.editorNotifySelected.array copy]
                         forKey:@"mfNotificationClickFloatApps"];
    [MFRingDefaults() synchronize];
    [self refreshEditorNotifyVisuals];
    MFLog(@"[ring] 通知名单：%@ %@（共 %lu 个）",
          nowSelected ? @"+" : @"-",
          bundleId,
          (unsigned long)self.editorNotifySelected.count);
}

/// 一级菜单统一布局：四行 + 两个可展开区（触发条 / 其他选项），展开的行下方内容整体下移。
- (void)layoutEditorMenuAnimated:(BOOL)animated {
    UIView *box = self.editorMenuBox;
    if (box == nil) {
        return;
    }
    CGFloat w = CGRectGetWidth(box.bounds);
    if (w <= 0.0) {
        return;
    }
    void (^layout)(void) = ^{
        CGFloat y = 10.0;
        CGFloat rowW = w - 24.0;
        self.editorRowApps.frame = CGRectMake(12.0, y, rowW, 64.0);
        [(UILabel *)[self.editorRowApps viewWithTag:MF_RING_EDITOR_ROW_CHEVRON]
            setFrame:CGRectMake(rowW - 40.0, 0.0, 26.0, 64.0)];
        y += 72.0;
        self.editorRowTrigger.frame = CGRectMake(12.0, y, rowW, 64.0);
        [(UILabel *)[self.editorRowTrigger viewWithTag:MF_RING_EDITOR_ROW_CHEVRON]
            setFrame:CGRectMake(rowW - 40.0, 0.0, 26.0, 64.0)];
        y += 72.0;
        if (self.editorSettingsExpanded && self.triggerSettingsBox != nil) {
            self.triggerSettingsBox.frame = CGRectMake(12.0, y, rowW, CGRectGetHeight(self.triggerSettingsBox.frame));
            y += CGRectGetHeight(self.triggerSettingsBox.frame) + 10.0;
        }
        self.editorRowOther.frame = CGRectMake(12.0, y, rowW, 64.0);
        [(UILabel *)[self.editorRowOther viewWithTag:MF_RING_EDITOR_ROW_CHEVRON]
            setFrame:CGRectMake(rowW - 40.0, 0.0, 26.0, 64.0)];
        y += 72.0;
        if (self.editorOtherExpanded && self.otherSettingsBox != nil) {
            self.otherSettingsBox.frame = CGRectMake(12.0, y, rowW, CGRectGetHeight(self.otherSettingsBox.frame));
            y += CGRectGetHeight(self.otherSettingsBox.frame) + 10.0;
        }
        // 【0.7.5】第 4 行：点通知进悬浮窗（独立一级行，点进二级页）
        self.editorRowNotify.frame = CGRectMake(12.0, y, rowW, 64.0);
        [(UILabel *)[self.editorRowNotify viewWithTag:MF_RING_EDITOR_ROW_CHEVRON]
            setFrame:CGRectMake(rowW - 40.0, 0.0, 26.0, 64.0)];
        y += 72.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.26
                              delay:0.0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:layout
                         completion:nil];
    } else {
        layout();
    }
}

/// 二级页统一布局：返回/分段/计数行固定；已添加 = 预览 + 排序条；未添加 = 网格。
- (void)layoutEditorAppsAnimated:(BOOL)animated {
    UIView *box = self.editorAppsBox;
    if (box == nil) {
        return;
    }
    CGFloat w = CGRectGetWidth(box.bounds);
    CGFloat h = CGRectGetHeight(box.bounds);
    if (w <= 0.0 || h <= 0.0) {
        return;
    }
    void (^layout)(void) = ^{
        self.editorBackButton.frame = CGRectMake(12.0, 6.0, 96.0, 36.0);
        CGFloat tabW = 108.0;
        self.editorTabAddedButton.frame = CGRectMake(w - tabW * 2.0 - 26.0, 8.0, tabW, 32.0);
        self.editorTabAllButton.frame = CGRectMake(w - tabW - 14.0, 8.0, tabW, 32.0);
        self.editorCountLabel.frame = CGRectMake(18.0, 48.0, w - 36.0, 18.0);
        CGFloat y = 72.0;
        BOOL added = self.editorTabAdded;
        self.editorPreviewBox.hidden = !added;
        self.editorOrderScroll.hidden = !added;
        self.editorScroll.hidden = added;
        if (added) {
            // 【0.6.11 用户指令】平铺全览优先：先按已选数量算网格内容高，
            //   剩余空间给圆盘预览（夹 150~300pt）；极端多行时网格内部纵向滚。
            CGFloat avail = h - y;
            NSUInteger columns = [self mfEditorOrderColumnsForWidth:w];
            NSUInteger count = self.editorOrderCells.count;
            NSUInteger rows = (count > 0) ? (count + columns - 1) / columns : 1;
            CGFloat gridContentH = (CGFloat)rows * (MF_RING_ORDER_CELL_H + MF_RING_ORDER_CELL_GAP)
                + MF_RING_ORDER_INSET * 2.0;
            CGFloat previewH = MIN(MAX(avail - gridContentH - 24.0, 150.0), 300.0);
            self.editorPreviewBox.frame = CGRectMake(10.0, y, w - 20.0, previewH);
            y = CGRectGetMaxY(self.editorPreviewBox.frame) + 8.0;
            CGFloat gridH = MAX(160.0, h - y);
            self.editorOrderScroll.frame = CGRectMake(0.0, y, w, gridH);
            self.editorOrderScroll.scrollEnabled = (gridContentH > gridH + 1.0);
        } else {
            self.editorScroll.frame = CGRectMake(0.0, y, w, MAX(120.0, h - y));
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.26
                              delay:0.0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:layout
                         completion:nil];
    } else {
        layout();
    }
    [self refreshEditorTabVisual];
    // 【0.6.11】网格 contentSize 依赖自身高度 → 布局后重算一次（cells 只重排 frame，无重建）
    [self layoutEditorOrderCellsAnimated:NO];
}

/// 一级 ↔ 二级 通用切换（page = nil ⇒ 回一级菜单；淡入淡出 + 轻位移）。
/// 二级页现在有两个：`editorAppsBox`（应用管理）与 `editorNotifyBox`（点通知进悬浮窗）；
/// 两个容器都常驻，只用 hidden + 透明度切换 —— 切页不重建任何内容，回退不丢勾选。
- (void)showEditorPage:(UIView *)page animated:(BOOL)animated {
    UIView *menu = self.editorMenuBox;
    if (menu == nil) {
        return;
    }
    UIView *target = (page != nil) ? page : menu;
    if (self.editorVisiblePage == target) {
        return;
    }
    self.editorVisiblePage = (page != nil) ? page : nil;
    self.editorLevel2Visible = (page != nil);

    NSMutableArray<UIView *> *pages = [NSMutableArray arrayWithObject:menu];
    if (self.editorAppsBox != nil) {
        [pages addObject:self.editorAppsBox];
    }
    if (self.editorNotifyBox != nil) {
        [pages addObject:self.editorNotifyBox];
    }
    // hidden 切换本身没有过渡 ⇒ 先「上膛」再折 alpha。
    // ★ 本来是隐藏的页必须**当场置 alpha 0**：否则它会从 1.0 淡出，切页瞬间闪一下上一页的内容。
    NSMutableSet<UIView *> *wasVisible = [NSMutableSet set];
    for (UIView *view in pages) {
        if (view.hidden == NO && view.alpha > 0.01) {
            [wasVisible addObject:view];
        }
    }
    for (UIView *view in pages) {
        view.hidden = NO;
        if (view != target && ![wasVisible containsObject:view]) {
            view.alpha = 0.0;
            view.transform = CGAffineTransformMakeTranslation((page != nil) ? -24.0 : 0.0, 0.0);
        }
    }
    if (page == self.editorAppsBox) {
        self.editorTabAdded = YES;   // 每次进二级页都落在「已添加」（排序是高频操作）
        [self layoutEditorAppsAnimated:NO];
        [self relayoutEditorGridAnimated:NO];
        [self rebuildEditorRingPreview];
    } else if (page == self.editorNotifyBox) {
        [self layoutEditorNotifyPage];
        [self refreshEditorNotifyVisuals];
    }

    CGFloat slide = (page != nil) ? -24.0 : 0.0;
    target.alpha = 0.0;
    target.transform = CGAffineTransformMakeTranslation(slide, 0.0);
    void (^changes)(void) = ^{
        for (UIView *view in pages) {
            BOOL isTarget = (view == target);
            view.alpha = isTarget ? 1.0 : 0.0;
            view.transform = isTarget ? CGAffineTransformIdentity
                                      : CGAffineTransformMakeTranslation(slide, 0.0);
        }
    };
    void (^finish)(BOOL) = ^(BOOL finished) {
        (void)finished;
        for (UIView *view in pages) {
            BOOL isTarget = (view == target);
            view.hidden = !isTarget;
            if (!isTarget) {
                view.alpha = 1.0;   // 复位：下次进来从 1.0 起淡出
                view.transform = CGAffineTransformIdentity;
            }
        }
        target.alpha = 1.0;
        target.transform = CGAffineTransformIdentity;
    };
    if (!animated) {
        changes();
        finish(YES);
    } else {
        [UIView animateWithDuration:0.24
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:changes
                         completion:finish];
    }
    MFLog(@"[ring] 编辑器切到%@", (page != nil) ? @"二级页" : @"一级菜单");
}

/// 【0.6.10】兼容旧调用点：进/出「应用管理」页
- (void)showEditorLevel2:(BOOL)level2 {
    [self showEditorPage:(level2 ? self.editorAppsBox : nil) animated:YES];
}

- (void)onEditorRowAppsTapped:(UIButton *)sender {
    (void)sender;
    [self showEditorPage:self.editorAppsBox animated:YES];
}

- (void)onEditorRowNotifyTapped:(UIButton *)sender {
    (void)sender;
    if (self.editorNotifyBox == nil) {
        return;
    }
    [self showEditorPage:self.editorNotifyBox animated:YES];
}

- (void)onEditorBackTapped:(UIButton *)sender {
    (void)sender;
    [self showEditorPage:nil animated:YES];
}

- (void)onEditorTabChanged:(UIButton *)sender {
    BOOL added = (sender == self.editorTabAddedButton);
    if (self.editorTabAdded == added) {
        return;
    }
    self.editorTabAdded = added;
    [self layoutEditorAppsAnimated:YES];
    if (!added) {
        [self relayoutEditorGridAnimated:NO];
    }
    MFLog(@"[ring] 应用管理切到 %@", added ? @"已添加" : @"未添加");
}

- (void)refreshEditorTabVisual {
    BOOL added = self.editorTabAdded;
    UIColor *active = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    UIColor *idle = [UIColor colorWithWhite:1.0 alpha:0.12];
    self.editorTabAddedButton.backgroundColor = added ? active : idle;
    self.editorTabAllButton.backgroundColor = added ? idle : active;
}

/// 「其他选项」行：展开/收起（开关 + 圆盘大小滑杆）。
- (void)onEditorOtherToggle:(UIButton *)sender {
    BOOL expand = !self.editorOtherExpanded;
    self.editorOtherExpanded = expand;
    self.otherSettingsBox.hidden = NO;
    sender.backgroundColor = [UIColor colorWithWhite:1.0 alpha:expand ? 0.16 : 0.06];
    [self layoutEditorMenuAnimated:YES];
    [UIView animateWithDuration:0.26
                          delay:0.0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self.otherSettingsBox.alpha = expand ? 1.0 : 0.0;
    } completion:^(__unused BOOL finished) {
        if (!expand) {
            self.otherSettingsBox.hidden = YES;
        }
    }];
    MFLog(@"[ring] 其他选项：%@", expand ? @"展开" : @"收起");
}

/// 其他选项开关：tag 1 = 双指贴边呼出（重启 SpringBoard 生效）；tag 2 = 抓取真实图标（下次打开生效）。
/// 【0.7.5】「点通知进悬浮窗」已独立成一级行（自己的二级页），不再走这里。
- (void)onEditorOtherSwitchChanged:(UISwitch *)switchView {
    NSArray<NSString *> *keys = @[ @"mfRingTwoFingerSummon", @"mfRingFetchIcons" ];
    NSArray<NSString *> *effects = @[ @"重启 SpringBoard 后生效",
                                      @"下次打开编辑器/呼出生效" ];
    NSInteger index = switchView.tag - 1;
    if (index < 0 || index >= (NSInteger)keys.count) {
        return;
    }
    NSString *key = keys[(NSUInteger)index];
    [MFRingDefaults() setObject:@(switchView.on) forKey:key];
    [MFRingDefaults() synchronize];
    MFLog(@"[ring] 其他选项：%@ -> %@（%@）",
          key,
          switchView.on ? @"开" : @"关",
          effects[(NSUInteger)index]);
}

/// 圆盘大小滑杆（mfRingRadius）：下次呼出即生效（呼出时按配置半径重算几何）。
- (void)onEditorRadiusSliderChanged:(UISlider *)slider {
    MFRingSetNumber(@"mfRingRadius", slider.value);
    self.editorRadiusValueLabel.text = [NSString stringWithFormat:@"%.0f pt", slider.value];
    MFLog(@"[ring] 圆盘大小 -> %.0f pt（下次呼出生效）", slider.value);
}

/// 【0.6.10】已添加 tab：快速点按排序条格子 = 移出圆盘（长按仍是拖拽排序，互不干扰）。
- (void)onEditorOrderStripTap:(UITapGestureRecognizer *)tap {
    if (self.editorOrderDraggingCell != nil) {
        return;   // 拖拽中不响应点按
    }
    UIScrollView *strip = self.editorOrderScroll;
    if (strip == nil || self.editorOrderCells.count == 0) {
        return;
    }
    CGPoint touch = [tap locationInView:strip];
    CGPoint contentPoint = CGPointMake(touch.x + strip.contentOffset.x, touch.y + strip.contentOffset.y);
    UIView *hit = nil;
    for (UIView *cell in self.editorOrderCells) {
        if (contentPoint.x >= CGRectGetMinX(cell.frame) && contentPoint.x <= CGRectGetMaxX(cell.frame) &&
            contentPoint.y >= CGRectGetMinY(cell.frame) && contentPoint.y <= CGRectGetMaxY(cell.frame)) {
            hit = cell;
            break;
        }
    }
    if (hit == nil) {
        return;
    }
    NSString *bundleId = objc_getAssociatedObject(hit, &kMFRingBundleIdKey);
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        return;
    }
    NSMutableOrderedSet<NSString *> *selection = self.editorSelection;
    if (selection == nil || ![selection containsObject:bundleId]) {
        return;
    }
    [selection removeObject:bundleId];
    [self mfRingHapticLight];
    MFLog(@"[ring] 点按排序条移出 %@（剩 %lu）", bundleId, (unsigned long)selection.count);
    [self rebuildEditorOrderStrip];   // 末尾会连带刷新预览
    [self relayoutEditorGridAnimated:YES];
    [self refreshEditorCount];
}

/// 【0.6.10 → 0.6.11】未添加 tab 网格重排：只显示未加入的条目，
/// 且**分区展示**（用户指令：区分 ACR 快捷方式和桌面 APP）——ACR 组在上、桌面应用组在下，
/// 各带区块标题（组空则标题不显示）。加入/移出后即时重排 + 动画。
- (void)relayoutEditorGridAnimated:(BOOL)animated {
    UIScrollView *scroll = self.editorScroll;
    if (scroll == nil || self.editorCells == nil) {
        return;
    }
    CGFloat w = CGRectGetWidth(scroll.bounds);
    if (w <= 0.0) {
        w = CGRectGetWidth(self.editorPanel.bounds);
    }
    if (w <= 0.0) {
        return;
    }
    NSMutableSet<NSString *> *selected = [NSMutableSet setWithArray:self.editorSelection.array];
    NSMutableArray<UIView *> *visibleActions = [NSMutableArray array];   // 未加入的 ACR
    NSMutableArray<UIView *> *visibleApps = [NSMutableArray array];      // 未加入的桌面应用
    for (UIView *cell in self.editorCells) {
        NSString *bundleId = objc_getAssociatedObject(cell, &kMFRingBundleIdKey);
        BOOL isSelected = [selected containsObject:bundleId];
        cell.hidden = isSelected;   // 未添加 tab 只列未加入的
        if (!isSelected) {
            if (MFSystemActionIsActionId(bundleId)) {
                [visibleActions addObject:cell];
            } else {
                [visibleApps addObject:cell];
            }
        }
    }
    const NSUInteger columns = 4;
    const CGFloat sideInset = 8.0;
    const CGFloat cellW = floor((w - sideInset * 2.0) / (CGFloat)columns);
    const CGFloat cellH = 100.0;
    const CGFloat headerH = 30.0;
    // 区块标题（懒创建，挂在 scroll 上，随内容排版）
    UILabel *actionHeader = (UILabel *)[scroll viewWithTag:991021];
    UILabel *appHeader = (UILabel *)[scroll viewWithTag:991022];
    if (actionHeader == nil) {
        actionHeader = [[UILabel alloc] initWithFrame:CGRectZero];
        actionHeader.tag = 991021;
        actionHeader.text = @"ACR 快捷方式";
        actionHeader.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        actionHeader.font = [UIFont boldSystemFontOfSize:12.0];
        [scroll addSubview:actionHeader];
    }
    if (appHeader == nil) {
        appHeader = [[UILabel alloc] initWithFrame:CGRectZero];
        appHeader.tag = 991022;
        appHeader.text = @"桌面应用";
        appHeader.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        appHeader.font = [UIFont boldSystemFontOfSize:12.0];
        [scroll addSubview:appHeader];
    }
    actionHeader.hidden = (visibleActions.count == 0);
    appHeader.hidden = (visibleApps.count == 0);
    void (^layout)(void) = ^{
        __block CGFloat y = 6.0;
        if (visibleActions.count > 0) {
            actionHeader.frame = CGRectMake(sideInset + 4.0, y, w - sideInset * 2.0 - 8.0, headerH);
            y += headerH;
        }
        void (^placeGroup)(NSArray<UIView *> *cells) = ^(NSArray<UIView *> *cells) {
            NSUInteger column = 0;
            for (UIView *cell in cells) {
                cell.frame = CGRectMake(sideInset + column * cellW, y, cellW, cellH);
                column++;
                if (column >= columns) {
                    column = 0;
                    y += cellH;
                }
            }
            if (column > 0) {
                y += cellH;   // 收尾的半行
            }
        };
        placeGroup(visibleActions);
        if (visibleApps.count > 0) {
            y += 4.0;
            appHeader.frame = CGRectMake(sideInset + 4.0, y, w - sideInset * 2.0 - 8.0, headerH);
            y += headerH;
        }
        placeGroup(visibleApps);
        scroll.contentSize = CGSizeMake(w, y + 24.0);
    };
    if (animated) {
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:layout
                         completion:nil];
    } else {
        layout();
    }
}

/// 【0.6.10】圆盘实时预览：按「呼出布局同一套算法」把当前已选顺序画成小圆盘。
/// 排序拖拽 / 加减成员后即时刷新 —— 所见即圆盘真实排布；拖拽中的 App 蓝框高亮。
- (void)rebuildEditorRingPreview {
    UIView *box = self.editorPreviewBox;
    if (box == nil) {
        return;
    }
    for (UIView *view in [box.subviews copy]) {
        [view removeFromSuperview];
    }
    CGRect bounds = box.bounds;
    CGFloat w = CGRectGetWidth(bounds);
    CGFloat h = CGRectGetHeight(bounds);
    if (w <= 0.0 || h <= 0.0) {
        return;
    }
    NSArray<NSString *> *ordered = self.editorSelection.array;
    if (ordered.count == 0) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16.0, 0.0, w - 32.0, h)];
        hint.text = @"圆盘还没有应用\n去「未添加」里点图标加入";
        hint.textAlignment = NSTextAlignmentCenter;
        hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        hint.font = [UIFont systemFontOfSize:14.0];
        hint.numberOfLines = 0;
        [box addSubview:hint];
        return;
    }
    CGRect hostBounds = self.hostBounds;
    if (CGRectIsEmpty(hostBounds) && self.hostWindow != nil) {
        hostBounds = self.hostWindow.bounds;
    }
    if (CGRectIsEmpty(hostBounds)) {
        return;
    }
    MFRingGeometry geo = MFRingComputeGeometry(hostBounds, ordered.count);
    MFRingSlotPos slots[MF_RING_EDITOR_MAX_APPS];
    NSUInteger placed = MFRingComputeRingSlots(hostBounds, ordered.count, 0.0, slots, MF_RING_EDITOR_MAX_APPS);
    CGFloat factor = MIN(w, h) / (2.0 * geo.extent) * 0.96;
    CGPoint center = CGPointMake(w / 2.0, h / 2.0);

    CGFloat dialR = geo.dialRadius * factor;
    UIView *dial = [[UIView alloc] initWithFrame:CGRectMake(center.x - dialR, center.y - dialR,
                                                            dialR * 2.0, dialR * 2.0)];
    dial.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.85];
    dial.layer.cornerRadius = dialR;
    [box addSubview:dial];

    NSString *draggingId = objc_getAssociatedObject(self.editorOrderDraggingCell, &kMFRingBundleIdKey);
    CGFloat iconSize = geo.iconSize * factor;
    for (NSUInteger index = 0; index < placed && index < ordered.count; index++) {
        NSString *bundleId = ordered[index];
        CGFloat angle = slots[index].angleDegrees * M_PI / 180.0;
        CGFloat radius = slots[index].radius * factor;
        UIImageView *iconView = [[UIImageView alloc]
            initWithFrame:CGRectMake(center.x + radius * cos(angle) - iconSize / 2.0,
                                     center.y + radius * sin(angle) - iconSize / 2.0,
                                     iconSize, iconSize)];
        UIImage *image = MFRingIconForBundleId(bundleId);
        iconView.image = image;
        iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        iconView.layer.cornerRadius = iconSize / 2.0;
        iconView.layer.masksToBounds = YES;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        if (draggingId != nil && [draggingId isEqualToString:bundleId]) {
            iconView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0].CGColor;
            iconView.layer.borderWidth = 2.0;
        } else {
            iconView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
            iconView.layer.borderWidth = 1.0;
        }
        if (image == nil) {
            UILabel *placeholder = [[UILabel alloc] initWithFrame:iconView.bounds];
            placeholder.text = (bundleId.length > 0)
                ? [[bundleId lastPathComponent] substringToIndex:1].uppercaseString : @"?";
            placeholder.textAlignment = NSTextAlignmentCenter;
            placeholder.textColor = [UIColor whiteColor];
            placeholder.font = [UIFont boldSystemFontOfSize:iconSize * 0.4];
            [iconView addSubview:placeholder];
        }
        [box addSubview:iconView];
    }
}

/// 「触发条」行：展开/收起设置区（含高亮预览），行高亮跟随。
- (void)onEditorSettingsToggle:(UIButton *)sender {
    BOOL expand = !self.editorSettingsExpanded;
    self.editorSettingsExpanded = expand;
    self.triggerSettingsBox.hidden = NO;   // 展开动画需要先可见（收起在动画完成块里藏）
    sender.backgroundColor = [UIColor colorWithWhite:1.0 alpha:expand ? 0.16 : 0.06];
    if (expand) {
        self.triggerSettingsBox.alpha = 0.0;
        [self refreshTriggerGeometryAfterPrefsChange];   // 展开时刷新预览位置/数值
    }
    [self layoutEditorMenuAnimated:YES];
    [UIView animateWithDuration:0.26
                          delay:0.0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self.triggerSettingsBox.alpha = expand ? 1.0 : 0.0;
    } completion:^(__unused BOOL finished) {
        if (!expand) {
            self.triggerSettingsBox.hidden = YES;
        }
    }];
    MFLog(@"[ring] 编辑器设置区：%@", expand ? @"展开（触发条自调）" : @"收起");
}

- (void)refreshEditorCount {
    UILabel *label = self.editorCountLabel;
    NSUInteger selectedCount = self.editorSelection.count;
    NSUInteger total = self.editorApps.count;
    if (self.editorTabAddedButton != nil) {
        [self.editorTabAddedButton setTitle:[NSString stringWithFormat:@"已添加 %lu",
                                             (unsigned long)selectedCount]
                                   forState:UIControlStateNormal];
        [self.editorTabAddedButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    if (self.editorTabAllButton != nil) {
        [self.editorTabAllButton setTitle:[NSString stringWithFormat:@"未添加 %lu",
                                           (unsigned long)(total > selectedCount ? total - selectedCount : 0)]
                                 forState:UIControlStateNormal];
        [self.editorTabAllButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    if (label == nil) {
        return;
    }
    label.text = [NSString stringWithFormat:
                  @"已选 %lu / %lu（上限 %lu）· 已添加页点图标移出 · 未添加页点图标加入",
                  (unsigned long)selectedCount, (unsigned long)total, (unsigned long)MFRingMaxIcons()];
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
    self.editorOrderTitle = nil;      // 【0.3.26】排序条随面板一起收
    self.editorOrderScroll = nil;
    self.editorOrderCells = nil;
    self.editorAppNames = nil;
    self.editorApps = nil;            // 【0.6.10】二级页数据源随面板一起收
    self.editorMenuBox = nil;
    self.editorAppsBox = nil;
    self.editorLevel2Visible = NO;
    self.editorTabAdded = YES;
    self.editorPreviewBox = nil;
    self.otherSettingsBox = nil;
    self.editorOtherExpanded = NO;
    self.editorRowApps = nil;
    self.editorRowTrigger = nil;
    self.editorRowOther = nil;
    self.editorRowNotify = nil;
    self.editorNotifyBox = nil;
    self.editorVisiblePage = nil;
    self.editorNotifyBackButton = nil;
    self.editorNotifyTitleLabel = nil;
    self.editorNotifySwitchBox = nil;
    self.editorNotifySwitchLabel = nil;
    self.editorNotifySwitch = nil;
    self.editorNotifyScopeLabel = nil;
    self.editorNotifyAllButton = nil;
    self.editorNotifyPickButton = nil;
    self.editorNotifyHintLabel = nil;
    self.editorNotifyScroll = nil;
    self.editorNotifyRows = nil;
    self.editorNotifySelected = nil;
    self.editorBackButton = nil;
    self.editorTabAddedButton = nil;
    self.editorTabAllButton = nil;
    self.editorRadiusValueLabel = nil;
    self.triggerPreviewView = nil;    // 【0.3.22】触发条预览随面板一起收
    self.triggerValueLabels = nil;
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
    // 【0.3.25 用户 log34】圆盘**未固定**（还在长大 / 手指还没停留满 2s）时一律不产生选中：
    //   此时手指只是在从边缘往里拉、把圆盘拉大，擦过某个图标不该算"选中"，
    //   松手也不该开 App（用户原话："在圆盘没有固定时，所有圆盘内的图标都应该处于无法选中状态"）。
    if (!self.ringLatched) {
        [self applySelectionToButton:nil];
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
    // 【0.6.7 用户 log51】滑选 Q 弹强化（在 0.3.0 的 Stheno 弹簧基础上加大幅度与层次）：
    //   ① 底座按钮 1.38 倍过冲弹簧（damping 0.42 = 明显 Q 弹回晃）；
    //   ② 内部图标再叠一层更快更弹的放大（1.18 倍）——图标比底座弹得更高，层次感；
    //   ③ 选中亮起白色光晕（shadow），滑走时弹簧收回。手指划过即触发（BeginFromCurrentState
    //      保证快速连续划过时动画从当前态衔接不跳变）。
    // 【0.7.2·P1】★ 删掉三行 shadow* 动画 —— 圆盘图标 button 是 `masksToBounds = YES`
    //   （见 buildRingInContainer，圆角靠裁切实现），**外阴影一律被裁掉** ⇒ 这三行从来就没画出过
    //   任何光晕，只是每次悬停都让 CA 去算一遍 shadowOpacity/shadowRadius 的插值。
    //   现在"点亮"改成 borderWidth 1.0 → 2.5 的加粗描边（不吃离屏渲染，观感更硬朗）。
    //   节奏也统一：0.42/0.30 → 0.38/0.28，切换图标时不再"慢半拍"。
    [UIView animateWithDuration:0.38
                          delay:0.0
         usingSpringWithDamping:(selected ? 0.46 : 0.6)
          initialSpringVelocity:(selected ? 0.72 : 0.0)
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        button.transform = selected ? CGAffineTransformMakeScale(1.38, 1.38) : CGAffineTransformIdentity;
        button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:selected ? 0.45 : 0.14];
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:selected ? 0.95 : 0.35].CGColor;
        button.layer.borderWidth = selected ? 2.5 : 1.0;
    } completion:nil];
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:(selected ? 0.44 : 0.6)
          initialSpringVelocity:(selected ? 0.85 : 0.0)
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        button.imageView.transform =
            selected ? CGAffineTransformMakeScale(1.18, 1.18) : CGAffineTransformIdentity;
    } completion:nil];
}

#pragma mark 图标交互

- (void)onIconTapped:(UIButton *)button {
    // 【0.3.25 用户 log34】圆盘未固定时点图标不算（防误触：手指从边缘往里滑时可能擦过图标）
    if (!self.ringLatched) {
        MFLog(@"[ring] 圆盘未固定 → 忽略图标点击（防误触）");
        return;
    }
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
    // 【0.3.25】同理：未固定时不许"长按移出图标"（防误触）
    if (!self.ringLatched) {
        MFLog(@"[ring] 圆盘未固定 → 忽略长按移出（防误触）");
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

    // 【0.4.2】原地重建：重建时把**当前圆盘所在位置**当作"触发点"起点（showAtPoint: 会从那儿
    //   冒出来），随后立刻补满到屏幕中下中心并固定（不走"停留 1s"—— 用户是主动长按移出）。
    CGPoint center = self.ringRoot ? self.ringRoot.center
                                   : [self mfRingParkCenterForBounds:self.hostBounds];
    [self hide];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 临时 block 用 self（本类 == 单例，不会造成循环引用；ARC 铁律同款写法）
        [self showAtPoint:center];
        // 立刻收尾到 100% 并固定（latchToParkCenterAnimated: 内部会按满尺寸再夹一次圆心）
        if (self.ringRoot != nil) {
            self.ringRoot.transform = CGAffineTransformIdentity;
        }
        [self latchToParkCenterAnimated:NO];
    });
}

#pragma mark 打开浮窗

- (void)openFloatWithBundleId:(NSString *)bundleId {
    // 【0.4.12 用户 log38】系统动作（mfsys.screenshot / mfsys.translate）：
    //   所有"打开"入口（点图标 / 悬停松手 / 贴边松手）最终都汇聚到本方法，所以只在这里
    //   拦一次就全覆盖了。动作交给 MFSystemActions 执行 —— **不 pin App、不开浮窗**；
    //   延后 0.35s 是因为调用方都已经先 `hide` 了（收起动画 0.22s），不能把圆盘截进图里。
    if (MFSystemActionIsActionId(bundleId)) {
        MFLog(@"[ring] 系统动作 %@ → 交给系统动作模块执行（圆盘收起后 0.35s 生效）", bundleId);
        MFSystemActionPerform(bundleId, 0.35);
        return;
    }
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
        // 【0.6.13 用户指令·复刻视频动画层】把当前选中图标的屏幕矩形交给控制器：
        //   打开主窗时做"图标从选中位置 zoom 展开成主窗"的动画（与贴片变形同款机制）。
        @try {
            UIButton *selected = self.selectedButton;
            if (selected != nil && selected.window != nil) {
                CGRect iconScreenRect = [selected convertRect:selected.bounds toView:selected.window];
                SEL originSelector = NSSelectorFromString(@"mfSetRingOpenOriginRectFromValue:");
                if ([controller respondsToSelector:originSelector]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(controller, originSelector,
                                                          [NSValue valueWithCGRect:iconScreenRect]);
                }
            }
        } @catch (__unused NSException *exception) {
            // 起点记录失败只影响动画形态，不影响打开本身
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
///
/// 【0.3.22 血泪 log31】0.3.21 用 `CGRectInset(band, -60, -60)` —— **两条轴都外扩**：
/// 触发条只占右缘 y=587..867，但沿边方向也被撑到 527..927，于是"屏幕右侧中段（y≈530~590）
/// 也能呼出圆盘"，用户左滑返回时极易误触（log31：`系统手势呼出（触点 367,710）` 与
/// `距最近屏边 10pt 带内=是` 都在这一带）。
/// 现在只外扩**垂直于边**的那一条轴，沿边方向严格等于触发条本身：
/// 触发条多长/在哪，就只在那个范围能呼出（长度/位置可在编辑器里用滑杆自调）。
BOOL MFRingPointNearTriggerEdge(CGPoint point) {
    @try {
        MFRingPicker *picker = [MFRingPicker shared];
        CGRect band = picker.triggerFrame;
        if (CGRectIsEmpty(band)) {
            return NO;
        }
        NSString *edge = MFRingEdge();
        CGFloat margin = MAX(0.0, MFRingNumber(@"mfTriggerTouchMargin", 60.0));
        CGRect gate = band;
        if ([edge isEqualToString:@"left"] || [edge isEqualToString:@"right"]) {
            gate = CGRectInset(band, -margin, 0.0);   // 只向屏内扩，纵向不扩
        } else {
            gate = CGRectInset(band, 0.0, -margin);   // 上/下边：只向屏内扩，横向不扩
        }
        return CGRectContainsPoint(gate, point);
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

/// hook 回调入口②：在触点处呼出圆盘。
/// 【0.4.2】呼出后圆盘从**触发条位置**出现，跟手指位移到屏幕中下中心，手指停住 1.0s 自动固定。
void MFRingSummonFromSystemGestureAtPoint(CGPoint point) {
    @try {
        MFRingPicker *picker = [MFRingPicker shared];
        if (picker.hostWindow == nil) {
            return;
        }
        MFLog(@"[ring] >>> 系统手势呼出（触点 %.0f,%.0f）", point.x, point.y);
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

// 【0.6.9】双指贴边呼出的识别器（triggr 1.5 同款思路）：
//   单指贴边呼出会被 App 内的返回手势（系统交互返回 / 左滑返回类插件 hook 过仲裁的
//   全屏 pan）抢走触摸 —— 双指起步时所有单指识别器按 UIKit 规则强制 Failed，
//   而双指版 min=max=2 谁也抢不走。双指版 type = 基号+1，
//   仍在 MFRingIsEdgeGestureType() 的放行范围内（零新增 hook）。
@interface MFRingEdgeRecognizer : UIScreenEdgePanGestureRecognizer
@property (nonatomic, assign) NSUInteger mfFingers;   // 期望手指数（1=单指 / 2=双指）
@end

@implementation MFRingEdgeRecognizer
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.mfFingers == 0) {
        self.mfFingers = 1;
    }
    // 手指超编（单指版来了第三根 / 双指版来了第三根）→ 圆盘未展开时主动让位：
    //   单指版被双指压住就 Failed，把触摸让给双指版；展开（跟手选中）阶段多指搭手
    //   不打断 —— 跟手触摸流绝不能中途饿死（0.2.11 教训）。
    if (event.allTouches.count > self.mfFingers) {
        if (![MFRingPicker shared].expanded) {
            self.state = UIGestureRecognizerStateFailed;
        }
        return;
    }
}
@end

// 自定义 type 的放行判定（PullOverX.mm 的 hook 会引用这个范围）
BOOL MFRingIsEdgeGestureType(unsigned long long type) {
    return type >= MFRingEdgeGestureType && type < MFRingEdgeGestureType + 4ULL;
}

// 动作目标：识别器只做识别，动作全部走这里（@try 全包，绝不能把异常抛回系统手势路由）
@interface MFRingEdgePanTarget : NSObject
@end
@implementation MFRingEdgePanTarget
/// 边缘手势的完整驱动（0.2.8）：呼出前的"滑出阈值"判定 + 呼出后的
/// **跟随 → 停留固定 → 悬停选中 → 松手打开/收起**（与 onStripPan: 同一套逻辑）。
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
                [picker moveRingToPoint:location];   // 【0.4.2】累计滑动距离 ⇒ 跟手位移 + 长大
                // 【0.4.2】固定靠"抵达中下中心"或"停留 1.0s 自动固定"（计时器在 moveRingToPoint: 里重置）
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
    static BOOL installedSingle = NO;
    static BOOL installedDouble = NO;
    if (installedSingle && installedDouble) {
        return;
    }
    @try {
        if (!MFRingBool(@"mfRingGestureSummon", YES)) {
            return;   // 用户关了系统手势呼出 → 不注册
        }
        Class managerClass = objc_getClass("SBSystemGestureManager");
        if (managerClass == nil) {
            MFLog(@"[ring] 0.3.19 边缘手势：SBSystemGestureManager 不存在 -> 放弃（iOS 版本差异）");
            return;
        }
        if (![managerClass respondsToSelector:@selector(mainDisplayManager)]) {
            MFLog(@"[ring] 0.3.19 边缘手势：+mainDisplayManager 不存在 -> 放弃");
            return;
        }
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(mainDisplayManager));
        if (manager == nil) {
            MFLog(@"[ring] 0.3.19 边缘手势：管理器还没就绪 -> 稍后重试");
            return;
        }
        SEL addSelector = @selector(addGestureRecognizer:withType:);
        if (![manager respondsToSelector:addSelector]) {
            MFLog(@"[ring] 0.3.19 边缘手势：addGestureRecognizer:withType: 不存在 -> 放弃");
            return;
        }
        Class panClass = objc_getClass("UIScreenEdgePanGestureRecognizer");
        SEL privateInit = @selector(initWithTarget:action:type:options:);
        if (panClass == nil || ![panClass instancesRespondToSelector:privateInit]) {
            MFLog(@"[ring] 0.3.19 边缘手势：私有 init 不存在 -> 放弃");
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
        // 【0.6.9】起手区 20 → 28/40：App 自己的返回手势只认屏缘约 20pt，加深起手区
        //   不侵占它；带内贴边起手更容易被我们收到（对 leftPan/左滑返回类插件是增益）。
        if (!installedSingle) {
            MFRingEdgeRecognizer *recognizer =
                [[MFRingEdgeRecognizer alloc] initWithTarget:edgeTarget
                                                      action:@selector(mfEdgeSlid:)
                                                        type:(long long)2
                                                     options:(unsigned long long)0];
            recognizer.edges = edge;
            recognizer.mfFingers = 1;
            recognizer.minimumNumberOfTouches = 1;
            recognizer.maximumNumberOfTouches = 1;
            if ([recognizer respondsToSelector:@selector(_setEdgeRegionSize:)]) {
                [recognizer _setEdgeRegionSize:28.0];   // 单指起手区贴边 28pt（0.2.x 为 20）
            }
            // 【0.2.11】cancelsTouchesInView 必须为 YES（UIGestureRecognizer 默认值）：
            //   0.2.8 设 NO 的代价（log16 实证）= 系统把触摸同时喂给前台 App —— 用户拖着
            //   圆盘、App 页面跟着滚，我们的识别器事件流被饿死 ⇒ 全屏悬停稀疏、松手无选中。
            //   YES = 识别器 Began 即独占触摸：App 不滚、事件流完整（triggr 默认同款）。
            //   delaysTouchesBegan 保持 NO：桌面长按编辑器入口靠静止按下（Possible 不拦截）。
            recognizer.cancelsTouchesInView = YES;
            recognizer.delaysTouchesBegan = NO;
            recognizer.delaysTouchesEnded = NO;
            ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(manager, addSelector,
                                                                      recognizer, MFRingEdgeGestureType);
            installedSingle = YES;
        }
        // 【0.6.9】双指贴边呼出：单指被 App 内返回手势（含左滑返回类插件）抢走时的
        //   确定性兜底 —— 双指起步时单指识别器全部 Failed，双指版无可争议。
        if (!installedDouble && MFRingBool(@"mfRingTwoFingerSummon", YES)) {
            MFRingEdgeRecognizer *recognizer =
                [[MFRingEdgeRecognizer alloc] initWithTarget:edgeTarget
                                                      action:@selector(mfEdgeSlid:)
                                                        type:(long long)2
                                                     options:(unsigned long long)0];
            recognizer.edges = edge;
            recognizer.mfFingers = 2;
            recognizer.minimumNumberOfTouches = 2;
            recognizer.maximumNumberOfTouches = 2;
            if ([recognizer respondsToSelector:@selector(_setEdgeRegionSize:)]) {
                [recognizer _setEdgeRegionSize:40.0];   // 双指是明确意图，起手区更宽
            }
            recognizer.cancelsTouchesInView = YES;
            recognizer.delaysTouchesBegan = NO;
            recognizer.delaysTouchesEnded = NO;
            ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(manager, addSelector,
                                                                      recognizer, MFRingEdgeGestureType + 1ULL);
            installedDouble = YES;
        }
        MFLog(@"[ring] 0.7.5 边缘手势已注册：单指=%d 双指=%d edge=%@（全屏 App 内贴边滑出呼出；左滑返回插件可用双指呼出）",
              installedSingle, installedDouble, edgeName);
    } @catch (NSException *installException) {
        MFLog(@"[ring] !! 0.2.7 边缘手势注册异常：%@ -> 不影响圆盘本体", installException);
    }
}
