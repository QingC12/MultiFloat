//
//  MFInternal.h — MultiFloat 内部共享接口
//
//  目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
//  设计约束（来自真机多轮验证，勿推翻）：
//   1. 绝不依赖固定路径 dlopen ellekit/substrate；本版根本不装 hook，零后端依赖。
//   2. 一切落盘用 POSIX write，崩溃前最后一行必须已写进文件。
//   3. 默认惰性：没有 /var/mobile/MultiFloat.plist 或 enabled=false 时不做任何事。
//   4. 崩溃自解除：动真格之前先写标记文件，下一进程见到标记就跳过。
//   5. 【0.4.0 新增】承载链路每一步都写 `>>> 步名` / `<<< 步名 ok`。
//      崩溃后，最后一个没有配对的 `>>>` 就是崩点 —— 下一轮启动自动写成归因文件。
//   6. 【0.4.0 新增 · 血泪教训】绝不用"用户手打的字符串"当开关。
//      0.3.0 真机事故：用户在 Filza 里把 mode 写成 shell，iOS 键盘自动更正成 she'll，
//      于是 `isEqualToString:@"shell"` 判定失败 → 走进了 host 分支 → 每次启动自动承载 → 崩循环。
//      现在所有行为开关一律用 **布尔/整数**；字符串只做展示。
//   7. 【0.5.0 新增 · 又一个事故】两个布尔开关名字太像也会出事。
//      0.4.0 真机：用户只把 hostEnabled 改成 true，漏了 enabled 总显示开关，
//      于是 tweak 完全惰性、浮窗根本不出。修法：默认 enabled=true（装上就显示外壳），
//      并在启动时自动修复 "enabled=false 且 hostEnabled=true" 这种自相矛盾。
//   8. 【0.7.0 新增 · 只认公开可验证的实现】别再自己猜私有 API 的用法。
//      0.6.0 用 `[[UIScenePresentationManager alloc] _initWithScene:scene]` 自造 presenter 管理器
//      → 链路全通、不崩、但不渲染（presenter 进不了 hosting 状态，露出黑底）。
//      唯一被公开源码验证过的写法（khanhduytran0/FrontBoardAppLauncher，LiveContainer 多任务同款）是
//          FBScene *scene = ...;                       // 要么用已存在的，要么自己 createSceneWithDefinition:
//          presenter = [scene.uiPresentationManager createPresenterWithIdentifier:sceneID];
//          [presenter modifyPresentationContext:^(ctx){ ctx.appearanceStyle = 2; }];
//          [presenter activate];
//          [view addSubview:presenter.presentationView];
//      **manager 必须来自 scene 自己**，不能自己 alloc。
//   9. 【0.8.0 新增 · 第三次安全模式的教训：我们已经有的东西，必须先看再建】
//      归档(7) 真机：route 4 在**同一个 SpringBoard 进程**里对**同一个 scene identity**
//      调了第二次 `createSceneWithDefinition:` ⇒ FBSceneManager 断言 ⇒ SpringBoard 挂 ⇒ 安全模式
//      （崩溃归因 `crashedStep=P4-scene`，MF-host-step-prev.txt 恰好停在 `>>> P4-scene`）。
//      同一轮里另一个同源问题：同一个 presenter identifier 被 create 第二次 ⇒
//      抛 "already in use" ⇒ 旧代码静默退回已知纯黑的宿主 VC ⇒ "重试一次画面就黑了"。
//      ⇒ 规则：凡是要"新建"一个运行时对象（scene / presenter / manager），
//        先问三个问题：① 我手里是不是已经有一个？② 系统里是不是已经有一个同 key 的？
//        ③ 要销毁它需要什么参数（**绝不能喂 nil** —— 0.3.0 的崩点就是这么来的）。
//      另外记录一条几何结论（省得再走弯路）：
//        `_UIScenePresentationView` 的自然尺寸 = `scene.settings.frame`。
//        想让浮窗里的画面比例正确，就得让 **scene.frame == 浮窗内容区尺寸**；
//        只设 `resizesHostedContext=YES` 是不够的（那只是让 App 跟着重新布局）。
//  10. 【0.9.0 新增 · "设置一次"和"一直保持"是两件事】
//      归档(8) 真机：浮窗终于全程正常 —— 内容对、缩放时比例也对、不崩。
//      但用户一从桌面切到"设置"，浮窗里的 Safari 就变黑。
//      日志（同一个 pid，同一轮承载）：
//        P6      : foreground=1 contentState=2 layerManager.layers=2 hostedLayers=2  ← 好的
//        P6+20s  : foreground=0 contentState=0 layerManager.layers=0 hostedLayers=0  ← 黑的
//      ⇒ P0（把 scene settings 拉成 foreground=YES）是**一次性**动作，
//        而 SpringBoard 会在"前台 App 换人"时重算目标 App 的 scene settings 并写回 NO
//        （很可能同时打开 idleModeEnabled、加上 deactivationReasons），
//        App 的 layerManager 随之丢光图层，presenter 手里只剩一个"没有图层可承载"的视图 ⇒ 黑。
//      ⇒ 规则：凡是"必须持续成立"的运行时状态（这里是 scene 可渲染），
//        就不能只在进入时设一次；要么上守护定时器反复拉回，要么 hook 住改它的那一方。
//        本项目坚持不装 hook，所以用守护定时器（keepAlive，默认 1 秒一次）。
//        并且守护必须**在日志里留下它拉回的证据**（状态签名变化才记一行），否则下一轮又只能猜。
//
//  11. 【0.9.1 新增 · 第四次踩同一个坑：先确认属性存在，再拿它下结论】
//      归档(9) 真机：0.9.0 上线后黑屏没了，但切 App 时会闪一下（约一个守护周期）。
//      排查时最大的坑不是"闪"，而是"fg=0 从头到尾一次都没变过"——
//      我们连着两轮把它解释成"被 SpringBoard 改回来了 / 设了没用"，
//      真相是 `UIMutableApplicationSceneSettings` 上**根本没有 foreground / setForeground:**
//      （响应真实存在的是 deactivationReasons / idleModeEnabled / frame / level 那几个）。
//      因为 MFBoolProp / MFMvBool 这些 helper 全都带 respondsToSelector 守卫，
//      **不存在的 selector 会被静默跳过**：设了个寂寞、读了个寂寞，而且判定还因此恒为真。
//      ⇒ 规则：任何被用作**判定依据**的属性，必须连"存在性"一起取出来并写进日志
//        （MFBoolPropEx / MFIntPropEx / MFULLPropEx 就是为了这个），
//        并且在能力报告里打一张 responds 矩阵。
//      另一条量化经验：**守护周期 ≈ 用户看到的闪烁时长**。
//        掉出检测最快只能等到下一个周期，所以周期就是黑窗的长度量级。
//        0.9.1 把 keepAliveMs 从 1000 降到 200。
//      还有一条：判断"黑不黑"的分水岭是 `layerManager.layers` / `hostedLayers` 是否为 0
//        与 `contentState` 是否 != 2，**不是** presenter 的 isHosting（它全程等于 1）。
//
//  12. 【0.10.0 新增 · 第五次踩同一个坑的升级版：**先怀疑自己的判据，再怀疑系统**】
//      归档(10) 真机：0.9.1 之后"切 App 不再黑屏，但会闪一下"；
//      **用户把 keepAliveMs 调到 100 / 50 后，闪烁反而更快。**
//      这一句就是整轮的钥匙：如果那帧黑是 SpringBoard 造成的，调小周期只会让黑窗更短，
//      绝不会让它更频繁；频率跟着我们的周期走 ⇒ 是我们自己在制造它。日志逐条比对完全吻合：
//        · deact=32/33/8/1 出现 20+ 次，其中**绝大多数与 layers=2 hosted=2 同时成立**（画面是好的）
//        · cs=0 出现 11 次，其中 8 次 layers/hosted 完好（cs 只是 settings 提交途中的瞬时值）
//        · layers=0（真黑）只出现 4 次 —— **4 次全部在我们写完 settings 之后 0~2 秒内**
//      ⇒ `updateSettingsWithBlock:`（尤其 setDisplayConfiguration:）会让 SpringBoard 重算整份
//        settings、让 App 的 scene 重新提交：contentState 2→0→1→2、图层重建一遍 = "闪一下"。
//        0.9.1 的判据 `deact!=0` 在真机上几乎一直成立 ⇒ 每拍写一次 ⇒ 闪的频率 = 1 / keepAliveMs。
//      ⇒ 规则一：**判据只能建立在"直接表征症状"的物理量上。**
//        黑屏的直接表征是 `layers<=0` / `hosted<=0`（那块表面上没有图层）；
//        deact / contentState / idle 都是"间接指标"，拿它们当判据会大量误报。
//      ⇒ 规则二：**写操作本身有副作用，而且常常比问题更大。**
//        每次写 settings 都是一次重排；所以必须分档（最小写 / 升级写）、限流、有宽限期、
//        有"连续 N 拍救不回来就放弃"的刹车 —— 否则修 bug 的手段就是新 bug 的来源。
//      ⇒ 规则三：**帧循环（守护/轮询）的周期，会成为用户感知的故障频率。**
//        任何"周期性动作"上线前都要问一句：如果这个动作本身有副作用，调快它会怎样？
//
//  附：0.9.x 关于判据的两条旧结论**已被归档(10) 推翻**，不要再引用：
//        · "`contentState != 2` 算掉出" —— cs=0 有 8/11 次 layers/hosted 完好，画面是好的；
//        · "`deactivationReasons != 0` 算掉出" —— 它只是 SpringBoard 的常规标记，不是黑屏。
//      另外两条作为纯事实保留（不是判据）：
//        · `UIMutableApplicationSceneSettings` 上**没有** foreground / setForeground:；
//        · `setDisplayConfiguration:` 会把 settings.frame 打回整屏（写入后必须重设 frame）。
//      还有：`processState`、`taskState`、`visibility` 都是 32 位 int ——
//        用 64 位 NSInteger 去接会读到未初始化高位（0.9.1 打出了 ps=10751930112）。
//        读这类属性一律用 MFIntProp32 那种"把返回类型写成 int"的封装。
//
//  13. 【0.11.0 新增 · 第六次踩同一个坑：**减少副作用，不等于删掉必要条件**】
//      归档(11) 真机：0.10.0 装上去之后"悬浮窗**大概率黑屏**"，比 0.9.1 还差。
//      0.10.0 的判据是对的（只有 layers<=0 才算黑，这一条保留），但它顺手做了两件错事：
//
//      ⇒ 错误一：把**救命的那一笔**当成"重排元凶"给省掉了。
//        0.10.0 从拉回动作里删掉 `setLevel:1` + `setDisplayConfiguration:`，只用
//        "最小写"（idle + deact + frame）。归档(11) 的实测结果是这一笔**一次都拉不回来**：
//        `layers=0` 连续 220+ 拍、其间写了约 11 次，全灭。
//        而 0.9.1 之所以能一把拉回来，差别恰恰就是这两项 —— 它们才是让 render server
//        重新给这个 scene 建图层的开关。
//        ⇒ 规则：**同一个动作，健康时是副作用，故障时可能是唯一解。**
//          所以要**按状态分档**（健康：只读不写；真黑：全量写），而不是一刀砍掉；
//          砍任何一步之前先问：去掉它之后，"故障态"还救得回来吗？
//
//      ⇒ 错误二：把刹车做成了"放弃"。
//        0.10.0 的 `keepAliveGiveUpAfter=30` ⇒ 真黑 6 秒后**永久停止重试**。
//        真黑是"必须救"的状态，对它踩刹车 = 主动选择永久黑屏（归档(11) 日志一路刷到"第 220 拍"）。
//        ⇒ 规则：**刹车只该降低频率，不该取消动作。** 用退避（间隔翻倍、有上限）代替放弃。
//
//      ⇒ 附带发现的第三件事：**黑有两种，别只认一种。**
//        归档(11) 的 Filza 轮：scene 自己完全健康（contentState=2 layers=2），
//        但 `presenter.isHosting=0`、`hostContainer=nil`、presentationView 被改成整屏 430x932。
//        这是**承载侧**掉了 —— 写 scene settings 完全打不中，只会白送一次全量重排。
//        ⇒ 规则：动手前先分类。`layers>0` 而 `hosted<=0` ⇒ 只修承载；
//          `layers<=0` ⇒ 才去写 settings。混在一起治，就会一边治不好、一边制造新闪。
//
//      另一条工程结论（少一次写就少一次重排）：**挂载路径上的写要合并。**
//      归档(11) 的挂载序列是 P0 写一次（不含 frame，因为那时还没登记目标尺寸）
//      → 紧接着 MFSyncSceneGeometry 再写一次补 frame ⇒ 两次全量重算。
//      现在 P0 之前就登记目标尺寸（frame 进同一个 block 的最后一项），并加了一层
//      "刚写过同一个 frame"的备忘挡住重复写。
//
//      还有一条日志纪律：**别把关键证据锁在 verbose 门控后面。**
//      0.10.0 把"已写 settings"挂在"第 1 拍 / 每 10 拍"上，于是约 2/3 的写入在日志里
//      根本不存在，只剩一句"限流"——这一轮只能靠碰运气留下的那一次来定性。
//      ⇒ 规则：**能改变系统状态的动作，必须留下可数的痕迹**（哪怕日志会变长）。
//
//  14. 【0.12.0 新增 · 第七次：**分清"可逆的征兆"与"不可逆的终态"**】
//      归档(12) 真机：0.10.0 / 0.11.0 在"返回桌面"时**立刻黑屏**，而 0.9.1 不会（只是闪）。
//      三个版本共享同一套承载链路，差别只有一个 —— **在哪个状态上动手**。
//
//      ⇒ 事实一：`layers<=0` 是**终态，不可逆**。
//         Safari 轮里 layers 从 2 掉到 0 之后，我们连着写了 **81 次**全量写
//         （含 setLevel + setDisplayConfiguration + frame），layers 读数一次都没离开 0。
//         我们改的是 settings（"诉求"），改不了 App 进程已经撤走的图层。
//
//      ⇒ 事实二：`deact!=0` / `cs!=2` 是**征兆，可逆**，而且领先终态约 **1 秒**。
//         归档(12) 两轮都清晰复现：先 deact=32（此刻 cs=2 layers=2 hosted=2，画面还是好的），
//         约 1 秒之后才 cs=0 layers=0。
//         0.9.1 把这一秒当成"要动手"，所以它不掉图层；
//         0.10.0 把它降级成"软警告，永不动手"，所以它必然黑。
//
//      ⇒ 规则：**看见一个坏状态时，先问一句"它还能自己变好吗"。**
//        能 → 那才是你该出手的地方，而且要在它之前出手；
//        不能 → 别在那儿花力气，去前面那个可逆状态上做预防。
//        0.11.0 的修复正好打反了方向：它把"不可逆那一侧"的写入加重了（改成全量写），
//        所以对症状毫无改善 —— 这也是"修了但没效果"的典型形态。
//
//      ⇒ 与之配套的一条代价纪律：**预防要便宜，补救可以贵。**
//        同一个"写 settings"动作，健康时是副作用（会重排 = 闪），故障时是唯一解。
//        所以不能"一刀砍掉"，而要**按状态分档**：
//          预防档 = 只写纯状态量（idleModeEnabled / deactivationReasons），不碰几何 ⇒ 理论上零可见代价；
//          真黑档 = 全量写（改几何也无所谓，反正已经黑了）。
//        0.10.0 的错误是"要么全写、要么不写"；0.12.0 的答案是三档。
//
//      ⇒ 附属推论：**可逆窗口的长度就是你轮询周期的上限。**
//        窗口约 1 秒 ⇒ 预防写的限流必须远小于 1 秒（默认 250 ms = 4 次机会）。
//        0.9.1 用 200 ms 周期也抓得住它，但代价是每拍都写全量（每秒闪 5 次）。
//
//  15. 【0.13.0 新增 · 第八次：**你以为"这个接口不存在"，很可能只是你问错了对象**】
//      归档(13) 真机：0.12.0 装上去之后"切换应用时悬浮窗依旧黑屏"。这是连续第三轮
//      "判据方向对了、病根没碰到"的形态 —— 0.12.0 的预防档**确实发出了**，
//      但 App 还是死了。而这一轮的能力报告第一次把**进程**层面的状态摆了出来：
//        `目标 App processState = taskState: **Suspended**; visibility: Background`
//      进程被挂起了。一个被挂起的进程不可能出图 —— 所以"81 次全量写、layers 恒为 0"
//      根本不是"settings 写不进去"，而是**没有进程在画**。
//
//      ⇒ 事实一：把 0.9.1 与 0.10.0+ 的**有效写操作**逐项对齐，只剩一项差别：
//        0.9.1 因为 `forceAll=YES` 每拍都发 `setForeground:YES`；0.10.0 起默认不发。
//        而这一项之所以被去掉，仅仅是因为 0.9.x 里写了一句注释：
//          "foreground / setForeground: 在本机不存在（responds 守卫静默跳过）"。
//
//      ⇒ 事实二：那句话是错的，错在**问错了对象**。
//        它只问了 `FBScene` 的 `respondsToSelector:`（=NO），从来没问 settings。
//        本轮的存在性矩阵问 settings，得到的是
//          `foreground (getter) = -`、**`setForeground: (setter) = YES`**
//        —— 一个"只写"的前台开关。**getter 不存在，不蕴含 setter 不存在。**
//
//      ⇒ 规则：**断言"这个 API 不存在"之前，先确认你问的是不是真正会被调用的那个对象。**
//        具体的三条纪律：
//          ① 同一个属性要在**所有相关对象**上分别问（这里至少有 FBScene 与 settings 两个）；
//          ② 我们真正写入的对象是 `updateSettingsWithBlock:` 的 **block 参数**
//             （`UIMutableApplicationSceneSettings`），探针必须打在它身上 ——
//             打在 `scene.settings`（不可变对象）上会得到一串假的 `-`；
//          ③ "有没有这个 selector"与"它管不管用"是两件事，**用完必须回读验证**
//             （见下一条）。
//
//      ⇒ 配套的一条纪律（也是这轮唯一新增的运行时开销）：**写完要回读，连败要停手。**
//        `setForeground:YES` 写完立刻 KVC 回读 `FBScene.foreground`，
//        连续 3 次读完仍然是 0 ⇒ 判定它是空转并**停止再写**。
//        没有这一步，一个"存在但无效"的 setter 会把我们变成
//        "每拍写一次 = 每拍闪一次"—— 也就是 0.9.1 的老毛病，而且是在**白闪**。
//
//      ⇒ 最后一条，也是最反直觉的：**"删掉一个空转项"比"多发一个冗余项"危险得多。**
//        冗余项最多浪费一点性能；被判成"空转"而删掉的那一项，可能是唯一的救命开关。
//        删之前请先**把它的效果量出来**（0.13.0 的做法：加到预防档 + 回读验证，
//        用 keepAlivePreventForeground 单开单关做 A/B）。
#ifndef MF_INTERNAL_H
#define MF_INTERNAL_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>
#include <sys/stat.h>

// ---- 版本 ----
NSString *MFVersionString(void);

// ---- 日志 ----
void MFLogLine(NSString *line);
void MFLogRawC(const char *utf8);

// ---- 配置 ----
NSDictionary *MFLoadConfig(void);
void MFWriteDefaultConfigIfNeeded(void);
/// 老版本写下的 plist 缺 0.4.0 的新键时，原地补齐（避免用户手打键名被键盘自动更正坑到）
void MFUpgradeConfigIfNeeded(NSDictionary *cfg);

/// 【0.5.0 新增】修复自相矛盾的配置：enabled=false 但 hostEnabled=true
/// => 说明用户改开关时漏了总开关，这里把 enabled 补成 true 并回写磁盘。
/// 返回可能被修正过的配置，**调用方必须用返回值继续判断**（无需修正时原样返回）。
NSDictionary *MFRepairConfigContradiction(NSDictionary *cfg);

/// 配置读取一律走这三个，缺键/类型不符时返回 fallback（绝不返回垃圾值）
BOOL        MFConfigBool(NSDictionary *cfg, NSString *key, BOOL fallback);
NSInteger   MFConfigInt(NSDictionary *cfg, NSString *key, NSInteger fallback);
NSString   *MFConfigString(NSDictionary *cfg, NSString *key);

// ---- 崩溃自解除闸门 ----
BOOL MFAttemptExists(void);
void MFAttemptWrite(const char *why);
void MFAttemptClear(void);

// ---- 承载步骤追踪（崩溃归因）----
/// 每个危险调用【之前】写一行 `>>> tag t=… pid=…`
void MFStepMark(NSString *tag);
/// 该调用【返回之后】写一行 `<<< tag ok`
void MFStepOk(NSString *tag);
/// 启动时调用：分析上一轮的步骤日志，若最后一个 `>>>` 没有配对 => 那就是崩点。
/// 有结论时写 /var/mobile/MF-crash-attribution.txt 并把步骤日志轮转留档。
/// 返回崩点步名（nil = 上一轮没有崩在步骤里）。
NSString *MFStepRotateAndAnalyze(void);
/// 开一轮新的承载：清空步骤日志
void MFStepReset(void);

// ---- 运行期消息发送（全部带 respondsToSelector 守卫）----
id MFMsg(id obj, SEL sel);
id MFMsg1(id obj, SEL sel, id a);
NSString *MFStr(id obj, SEL sel);
BOOL MFBoolProp(id obj, SEL sel);
NSInteger MFIntProp(id obj, SEL sel);

/// 把 NSArray / NSSet / NSDictionary / 任何有 allObjects / objectEnumerator 的容器统一成 NSArray
NSArray *MFIterate(id collection);
/// 取类的单例（依次尝试 sharedInstance / sharedInstanceIfExists）
id MFClassSharedInstance(NSString *name);
/// 这个 selector 在类的实例方法表里存在吗
BOOL MFClassHasInstanceMethod(NSString *className, NSString *selName);

// ---- 对外入口 ----
void MFFloatBootstrap(void);
/// 把"上一轮崩在哪一步"告诉浮窗层，让浮窗启动后能在状态栏里显示它
void MFFloatSetBootCrashStep(NSString *step);

/// 格式化日志宏（Clang 的 , ##__VA_ARGS__ 在无参时自动吃掉逗号）
#define MFLog(fmt, ...) MFLogLine([NSString stringWithFormat:(fmt), ##__VA_ARGS__])
/// 无参日志（不带 % 占位符时用，避免零变参宏参的边界告警）
#define MFLogS(text)    MFLogLine(text)

#endif /* MF_INTERNAL_H */
