//
//  MFCore.xm — 日志 / 配置 / 崩溃自解除闸门 / 承载步骤追踪 / 安全消息发送
//
//  本文件不做任何 UI、不装任何 hook，只提供可被安全调用的基础设施。
//  所有函数在参数异常时必须"返回而不是崩"，因为调用方在 SpringBoard 主进程里。
//
#import "MFInternal.h"

#pragma mark - ---------- 版本 ----------

NSString *MFVersionString(void) {
    return @"0.19.0";
}

#pragma mark - ---------- 底层落盘 ----------

/// 一次性 open→write→close，保证崩溃前该行已经在盘上（不做缓冲）
static void MFRawAppend(const char *path, const char *utf8, size_t len) {
    if (path == NULL || utf8 == NULL || len == 0) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t written = write(fd, utf8, len);
    (void)written;
    close(fd);
}

static void MFWriteBothPaths(const char *utf8) {
    if (utf8 == NULL) return;
    // /var/mobile/Media/... 在"文件"App 与 Filza 里都好找；/var/mobile 是用户既定目录
    mkdir("/var/mobile/Media/MultiFloat", 0755);
    size_t len = strlen(utf8);
    MFRawAppend("/var/mobile/MultiFloat.log", utf8, len);
    MFRawAppend("/var/mobile/Media/MultiFloat/MultiFloat.log", utf8, len);
}

void MFLogRawC(const char *utf8) {
    MFWriteBothPaths(utf8);
}

void MFLogLine(NSString *line) {
    if (line == nil) return;
    NSString *full = [NSString stringWithFormat:@"t=%ld pid=%d ver=%@ %@\n",
                      (long)time(NULL), (int)getpid(), MFVersionString(), line];
    const char *utf8 = full.UTF8String;
    if (utf8 == NULL) return;
    MFWriteBothPaths(utf8);
    NSLog(@"[MultiFloat] %@", line);
}

#pragma mark - ---------- 配置 ----------

static NSArray *MFConfigCandidatePaths(void) {
    return @[ @"/var/mobile/MultiFloat.plist", @"/var/mobile/Media/MultiFloat.plist" ];
}

BOOL MFConfigBool(NSDictionary *cfg, NSString *key, BOOL fallback) {
    if (cfg == nil || key == nil) return fallback;
    id v = cfg[key];
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return fallback;
}

NSInteger MFConfigInt(NSDictionary *cfg, NSString *key, NSInteger fallback) {
    if (cfg == nil || key == nil) return fallback;
    id v = cfg[key];
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return fallback;
}

NSString *MFConfigString(NSDictionary *cfg, NSString *key) {
    if (cfg == nil || key == nil) return nil;
    id v = cfg[key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

NSDictionary *MFLoadConfig(void) {
    for (NSString *path in MFConfigCandidatePaths()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            MFLog(@"[cfg] loaded %@ keys=%lu", path, (unsigned long)dict.count);
            return dict;
        }
        MFLog(@"[cfg] %@ 解析失败，跳过", path);
    }
    return nil;
}

//  0.9.0 的默认配置（相对 0.8.0 新增三项，全部围绕归档(8) 的"切到别的 App 就黑屏"）：
//    enabled        = true  —— 总显示开关（装上就显示外壳）
//    hostEnabled    = true  ——【0.17.0 默认改 YES】真承载开关（用户要求，省去每次手动开；
//    hostRoute      = 3     —— 承载路线（3=接管已存在 scene，实测唯一"出画面且不崩"的路）
//    forceForeground= true  —— 承载前把目标 scene 设成"前台可渲染"（P0 步）
//    resizesHosted  = true  —— 让被承载的 scene 按浮窗尺寸渲染（App 跟着重新布局）
//    hostSceneFrame = true  —— 把 scene.frame 也设成浮窗内容区尺寸。
//                              presentationView 的自然尺寸就等于 scene.frame，不设的话
//                              整屏 scene(430x932, 宽高比 0.461) 塞进内容区(267x336.6, 0.793)
//                              必然拉伸变形 —— 这就是归档(7)「route 3 出画面但比例不对」的根因。
//    allowRouteB    = false —— presenter 失败时是否退回 SBDeviceApplicationSceneViewController。
//                              它是已被两次真机验证的**纯黑**宿主，挂着只会把失败伪装成成功。
//    keepAlive      = true  ——承载成功后开守护定时器，盯着目标 scene 的"图层还在不在"。
//    keepAliveMs    = 200   ——守护周期（毫秒），夹在 50..5000。
//                              【0.11.0 澄清】它只决定"发现真黑要多久"和"重试有多密"：
//                              归档(10) 里"闪的频率 = 1/keepAliveMs"是因为那时**健康时也每拍写**
//                              （判据太宽），现在只有真的一个图层都没有时才写，所以调小它
//                              不会让闪更频繁。反过来，真黑时调小它是**好事**（救得更快）。
//    keepAliveSoft  = false ——【0.11.0 澄清】它**只是日志开关，永不动手**。
//                              **默认 false，这是 0.10.0 修掉闪屏的关键一档。** 归档(10) 日志里
//                              deact=32/33 出现 20+ 次而其中绝大多数 layers/hosted 完好（画面是好的），
//                              0.9.1 拿它当判据 → 每拍都写 settings → 每写一次就闪一次。
//                              打开它只是为了把 deact/idle 的波动记进日志观察，**不会写任何 settings**。
//    keepAliveForeground = true ——【0.13.0 改 false -> true，本轮最关键的一处】
//                              **0.10.0 起它默认 NO 是一个错误，而且是三轮回归的总根源。**
//                              当年那句注释（"本机 settings 上根本没有 setForeground:"）
//                              是**问错了对象**得出的：它只问了 `FBScene` 的
//                              respondsToSelector（=NO），而归档(13) 的存在性矩阵问 settings 时
//                              得到的是 `foreground (getter) = -`、**`setForeground: (setter) = YES`**
//                              —— 它是个"只写"的前台开关。
//                              0.9.1 因为 `forceAll=YES` 而每拍都发这一项，所以它不掉图层；
//                              0.10.0/0.11.0/0.12.0 从不发 ⇒ App 被挂起
//                              （归档(13) 报告：`taskState: Suspended; visibility: Background`）
//                              ⇒ 图层永久消失，写什么都救不回来。
//                              设成 false 可以复现 0.10.0~0.12.0 的黑屏，仅用于对照实验。
//    keepAliveIdle  = true  ——真黑时是否清 idleModeEnabled=NO。
//    keepAliveDeact = true  ——真黑时是否清 deactivationReasons=0。
//    keepAliveHardWrite = true ——【0.11.0 新增】真黑时是否走**全量写**
//                              （idle + deact + setLevel:1 + setDisplayConfiguration: + frame）。
//                              **必须默认 true。** 归档(11) 证明：0.10.0 的"最小写"（只有
//                              idle + deact + frame）一次都拉不回来 —— layers=0 连续 220+ 拍、
//                              其间写了十几次全灭。0.9.1 能拉回来，差别就是这两项。
//                              设成 false 等于复现 0.10.0 的黑屏，仅用于对照实验。
//    keepAliveLevel = false ——【0.11.0 起**废弃**：代码不再读取它】保留键只为兼容旧配置。
//                              真黑一律全量写（见 keepAliveHardWrite），不再有"升级写"这一档。
//    keepAliveEscalateAfter = 5    ——【0.11.0 起**废弃**：代码不再读取它】同上。
//    keepAliveMinWriteMs    = 300  ——两次写 settings 的最小间隔（限流）。
//    keepAliveGraceMs       = 600  ——【0.11.0 改 1500 -> 600】挂载宽限期：
//                                     presenter 建 hosting 是异步的，刚挂上时"没有图层"很正常，
//                                     这段时间只观察不写。真黑本来就该尽快救，600 ms 足够盖住
//                                     "P0 的写 + presenter 挂载"这一个异步窗口。
//    keepAliveBackoffAfter  = 50   ——【0.11.0 新增】连续多少拍没救回来之后开始**退避**
//                                     （写入间隔按 20 拍一档翻倍，上限 keepAliveBackoffMaxMs）。
//    keepAliveBackoffMaxMs  = 2000 ——【0.11.0 新增】退避的写入间隔上限。
//    keepAliveGiveUpAfter   = 0    ——【0.11.0 改 30 -> 0】**0 = 永不放弃**。
//                                     0.10.0 设成 30，结果真黑 6 秒后我们就再也不写了
//                                     （归档(11)：日志一路刷到"第 220 拍"，画面始终没回来）。
//                                     真黑是"必须救"的状态，放弃 = 永久黑屏。
//                                     设成 >0 可以复现 0.10.0 的行为，仅用于对照实验。
//    keepAliveFrameSync     = true ——是否在守护里纠正 scene.frame
//                                     （只在真的漂了时写，且每秒最多查一次）。
//  —— 以下 5 个键是【0.12.0 新增 / 本轮的重点】——
//    keepAlivePrevent       = true ——【0.12.0 核心开关】是否启用**预防档**：
//                                     当"图层还在、但 scene 已被去激活 / 进 idle / 掉出 ready"时，
//                                     **主动**把 deactivationReasons/idleModeEnabled 写回去。
//                                     归档(12) 证明这是唯一有效的时机：
//                                       Filza 轮——挂载时带着 deact=33，1 秒后 layers 2 -> 0，再也回不来；
//                                       Safari 轮——按 Home 后 deact 变 32，约 1 秒后 layers 2 -> 0，
//                                                  随后**连着 81 次全量写全部无效**。
//                                     而 0.9.1 把这一档算作"要动手"，所以它不掉图层
//                                     （用户原话："v0.9.1 版本好像是正常的……切换应用时悬浮窗不会黑屏"）。
//                                     设成 false 就等于退回 0.10.0/0.11.0 的行为（会黑），仅用于对照。
//    keepAlivePreventMs     = 250  ——预防写的最小间隔（限流）。必须远小于"约 1 秒"的掉图层死线。
//                                     0.9.1 是"每拍都写"（200 ms ⇒ 每秒 5 次），那是它闪屏的代价；
//                                     0.12.0 只在真的写进去有意义时才写，默认 250 ms 够用。
//    keepAlivePreventHard   = false ——预防写要不要额外走"0.9.1 的完整版"
//                                     （再叠加 setDisplayConfiguration: + setFrame:）。
//                                     **默认 false 是关键**：预防档刻意**不碰任何几何**，
//                                     因为归档(10) 测到那一帧黑正是 `setDisplayConfiguration:`
//                                     把 frame 打回整屏 + 随后的 `setFrame:` 造成的。
//                                     万一"差量写"仍按不住，再打开它做 A/B（会闪，但最猛）。
//  —— 以下 6 个键是【0.13.0 新增 / 本轮的重点】——
//    keepAlivePreventForeground = true ——【0.13.0 核心】预防档要不要发 `setForeground:YES`。
//                                     **它就是 0.9.1 与 0.10.0+ 之间唯一有效的差别**（见上）。
//                                     实现上不是"每拍都发"：先在 FBScene 上读 `foreground`，
//                                     只有读出来是 0 才写；写完还会读回验证，
//                                     连续 3 次写完仍是 0 就判定"本机这个 setter 是空转"并停止再写
//                                     （避免每拍写一次 = 每拍闪一次，那是 0.9.1 的老毛病）。
//    keepAlivePreventIdle       = true ——预防档是否把 idleModeEnabled 清零（差量写）。 
//    keepAlivePreventDeact      = true ——预防档是否把 deactivationReasons 清零（差量写）。
//    keepAlivePreventLevel      = true ——预防档是否补 `setLevel:1`（差量写：只在 level != 1 时发）。
//    keepAlivePreventBackoffAfter  = 40   ——连续多少拍还在预防档之后开始退避（间隔翻倍）。
//    keepAlivePreventBackoffMaxMs  = 2000 ——预防退避的间隔上限。
//                                    真黑档是"永不放弃、只降频"，预防档同理：
//                                    一直按不住说明系统就是要它后台，那就少写几次，别把 CPU 和电量烧掉。
//    keepAliveViewFrameMs   = 500  ——承载视图尺寸纠正的节流间隔。
//                                     0.11.0 是"差 0.5 点就掰"，在 50 ms 周期下每秒掰 20 次，
//                                     等于跟 presenter 自己的布局对拉（归档(12) 日志被刷了 7 万字节）。
//    keepAliveViewFrameTol  = 0.08 ——承载视图尺寸的容差（比例）。偏差小于它就不管
//                                     （那是正常布局抖动）；偏差 >25% 时无视节流立刻掰回来。
//    hostStep       = 6     —— 承载链路最多走到第几步（1..6，测试用；默认走满）
//    mode           = "shell" —— 纯展示用，**不再参与任何判断**
//
//  为什么 0.7.0 把 hostRoute 默认从 2 改成 3：
//    0.6.0 真机（归档(5)）：presenter 链 P1..P5 全通、拿到真正的 _UIScenePresentationView、
//    20 秒存活、不崩 —— 但内容区**纯黑**。对照公开可用的实现
//    （khanhduytran0/FrontBoardAppLauncher，LiveContainer 多任务同款源码）后发现，
//    它拿 presenter 的**唯一**写法是
//        [scene.uiPresentationManager createPresenterWithIdentifier:...]
//    而我们 0.6.0 用的是自己 alloc 出来的 `_initWithScene:` manager ——
//    那个 manager 没有挂在 scene 自己的 presenter owner 体系里，
//    于是 presenter 永远进不了 "hosting" 状态（呈现上下文里
//    backgroundColorWhileNotHosting 就是那层黑底）。
//    Route 3 就是"改用 scene 自己的 manager"。Route 2 保留下来做 A/B 对照。
void MFWriteDefaultConfigIfNeeded(void) {
    NSString *path = @"/var/mobile/MultiFloat.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSDictionary *def = @{
        @"enabled"         : @YES,                     // 总显示开关：装上就显示外壳
        @"mode"            : @"shell",                 // 仅展示
        @"hostEnabled"     : @YES,                      // 真承载：【0.17.0 默认改 YES】用户明确要求
                                                        // （每天都要手动开一次太麻烦；危险动作
                                                        // 仍需用户点应用名显式触发，不违反铁律 4）
        @"hostRoute"       : @3,                       // 3=接管已存在 scene（默认）/ 4=自建 scene（危险）/ 2 / 1
        @"forceForeground" : @YES,                     // P0：把 scene 设成前台可渲染
        @"resizesHosted"   : @YES,                     // 让 scene 按浮窗尺寸渲染（App 跟着重新布局）
        @"hostSceneFrame"  : @YES,                     // 【0.8.0 默认改成 YES】把 scene.frame 设成浮窗内容区尺寸
                                                       //   —— 这是"画面比例正确"的必要条件：presentationView
                                                       //   的自然尺寸就等于 scene.frame，两者宽高比必须一致
        @"allowRouteB"     : @NO,                      // presenter 失败时是否退回那个已知纯黑的宿主 VC
        @"keepAlive"       : @YES,                     // 【0.9.0 新增】承载成功后守护 scene（切 App 不再黑屏）
        @"keepAliveMs"     : @200,                     // 【0.9.1 改】守护周期（毫秒）1000 -> 200：
                                                       //   闪屏时长 ≈ 一个守护周期（归档(9) 实测），砍到 1/5
        @"keepAliveForeground" : @YES,                 // 【0.13.0 改 NO -> YES】**本轮最关键的一处**。
                                                       //   0.10.0~0.12.0 一直默认 NO，依据是一句
                                                       //   问错对象的注释（只问了 FBScene，而
                                                       //   setForeground: 其实在 settings 上存在）。
                                                       //   结果 App 被挂起、图层永久消失。
                                                       //   false = 复现 0.10.0~0.12.0 的黑屏，仅用于对照。
        @"keepAliveIdle"   : @YES,                     // 真掉出时清 idleModeEnabled
        @"keepAliveDeact"  : @YES,                     // 真掉出时清 deactivationReasons=0
        @"keepAliveLevel"  : @NO,                      // 【0.11.0 起废弃】代码不再读取；保留键只为兼容旧配置
        @"keepAliveSoft"   : @NO,                      // 【0.11.0 澄清】**只是日志开关，永不动手**。
                                                       //   默认 NO 是 0.10.0 修掉闪屏的关键：归档(10) 里
                                                       //   deact 波动 20+ 次而画面大多是好的，一动手就闪。
        @"keepAliveHardWrite"     : @YES,              // 【0.11.0 新增】真黑时全量写（idle+deact+level+dc+frame）。
                                                       //   归档(11) 证明 0.10.0 的"最小写"一次都拉不回来。
                                                       //   false = 复现 0.10.0 的黑屏，仅用于对照实验。
        @"keepAliveMinWriteMs"    : @300,              // 【0.10.0 新增】两次写 settings 的最小间隔
        @"keepAliveGraceMs"       : @600,              // 【0.11.0 改 1500 -> 600】挂载宽限期（只观察不写）
        @"keepAliveEscalateAfter" : @5,                // 【0.11.0 起废弃】代码不再读取
        @"keepAliveGiveUpAfter"   : @0,                // 【0.11.0 改 30 -> 0】**0 = 永不放弃**。
                                                       //   真黑是"必须救"的状态，放弃 = 永久黑屏。
        @"keepAliveBackoffAfter"  : @50,               // 【0.11.0 新增】连续多少拍没救回来开始退避
        @"keepAliveBackoffMaxMs"  : @2000,             // 【0.11.0 新增】退避后的写入间隔上限
        @"keepAliveFrameSync"     : @YES,              // 【0.10.0 新增】是否纠正漂掉的 scene.frame
        @"keepAlivePrevent"       : @YES,              // 【0.12.0 核心】**预防档**：图层还在但正在被
                                                       //   去激活时，主动把 idle+deact 写回去。
                                                       //   归档(12)：这是唯一有效的时机 —— 图层
                                                       //   掉光之后就不可逆了（81 次全量写全灭）。
        @"keepAlivePreventMs"     : @250,              // 【0.12.0 新增】预防写的限流间隔
        @"keepAlivePreventHard"   : @NO,               // 【0.12.0 新增 / 0.14.0 语义再收窄】走"0.9.1 的完整版"：
                                                       //   再叠加 displayConfiguration + frame（会闪但最猛）。
                                                       //   默认 NO：预防档**不碰任何几何**，因为归档(10)
                                                       //   测到那一帧黑就是 displayConfiguration + frame 造成的。
                                                       //   0.14.0：hard 不再参与「要不要写」的差量判断
                                                       //   （归档(14) 里用户开了 hard ⇒ hard 恒为真 ⇒
                                                       //   每拍都「有差量」⇒ 每拍写一次 = 每拍闪一次）。
        // ---- 【0.13.0 新增】预防档的"差量写"开关（只发真的不一样的那几项）----
        @"keepAlivePreventForeground" : @NO,           //   【0.17.0 默认改 NO】预防档不再发 setForeground:YES。
                                                       //   实证（归档(15)(16)(17) 三轮）：本机 fg 读不到 ⇒
                                                       //   fg 保活 = 每个预防回合必写一帧（每次
                                                       //   updateSettingsWithBlock = 一次重提交 = 一帧闪），
                                                       //   而真黑次数一轮没降（92→93）⇒ 零收益纯成本。
                                                       //   救命的 fg 在**真黑档 L1**（keepAliveForeground=YES），
                                                       //   与本键无关 —— 黑屏修复原理不受影响。
                                                       //   读得到 fg 的机器想要预防保活可改回 YES。
        @"keepAlivePreventIdle"       : @YES,          //   清 idleModeEnabled（差量）
        @"keepAlivePreventDeact"      : @YES,          //   清 deactivationReasons（差量）
        @"keepAlivePreventLevel"      : @YES,          //   补 setLevel:1（只在 level != 1 时发）
        @"keepAlivePreventBackoffAfter" : @40,         //   连续多少拍还在预防档之后开始退避
        @"keepAlivePreventBackoffMaxMs" : @2000,       //   预防退避的间隔上限（永不放弃，只降频）
        @"keepAlivePreventCooldownMs"  : @2000,        // 【0.16.0 新增】预防写冷却：同一"去激活回合"
                                                       //   第 1 发之后的写至少隔这么久。归档(16)：
                                                       //   每发 updateSettingsWithBlock = 一次 scene
                                                       //   重提交 = 一帧可见的内容闪；追加发并不
                                                       //   阻止掉层（掉了由真黑档 L1 兜底）。
                                                       //   0 = 关冷却（回到 0.15.0 的连发，A/B 用）。
        // ---- 【0.14.0 新增】消闪三件套 ----
        @"keepAliveDeactFuse"     : @5,                //   deact 写的熔断阈值：写完读回发现没变过
                                                       //   就连续计败，达到 N 次后**永不回写 deact**
                                                       //   （0 = 关熔断，用于 A/B 复现 0.13.0 的持续闪）。
                                                       //   归档(14)：deact 常态就是 32，每拍写回 0
                                                       //   等于每拍付一次 scene 重提交、换零收益。
        @"keepAliveTieredRestore" : @YES,              //   真黑恢复**分级**：L1 只写状态量（不碰几何）
                                                       //   → L2 +frame → L3 +displayConfiguration。
                                                       //   归档(14)：真黑 1 拍就恢复，多半 L1 就够；
                                                       //   关掉 = 回到 0.13.0 恒为 L3（含 DC，必闪）。
        // ---- 【0.15.0 新增】消闪（视觉侧）----
        @"keepAliveSnapshot"      : @YES,              //   垫底快照：内容区最底层垫一张"最后一帧"截图
                                                       //   （健康时限流 2 s 刷新）。配合"未承载背景色=透明
                                                       //   + 剥黑底"，切换 App 掉图层的那 200~400ms 里
                                                       //   露出的是定格画面而不是黑 —— 体感从"闪黑"
                                                       //   变成"画面停一拍"。归档(15)：48 次真黑里 45 次
                                                       //   前一拍 deact 还是 0，**没有前兆**，轮询永远
                                                       //   追不上，只能在视觉侧兜住。
        @"keepAliveSnapshotMask"  : @YES,              // 【0.18.0 新增】快照**置顶遮盖**：掉层被发现的
                                                       //   第 1 拍把快照提到内容区最上层，盖住
                                                       //   presentationView 的一切可见异常（黑/白/
                                                       //   半渲染），恢复后等 2 拍归位垫底。
                                                       //   归档(19)：每次切出/切回必掉层、垫底盖不住
                                                       //   上层的闪烁 —— 只有置顶才能遮。
                                                       //   0 = 退回 0.15.0 的纯垫底。
        @"keepAliveViewFrameMs"   : @500,              // 【0.12.0 新增】承载视图尺寸纠正的节流
        @"keepAliveViewFrameTol"  : @0.08,             // 【0.12.0 新增】承载视图尺寸容差（比例）
        @"hostStep"        : @6,                       // 承载最多走到第几步
        @"cfgVersion"      : @19,                      // 配置结构版本（升级迁移用）
        @"targetBundleID"  : @"com.apple.mobilesafari",
        @"showDelay"       : @12,
        @"windowLevel"     : @1010,
    };
    BOOL ok = [def writeToFile:path atomically:YES];
    MFLog(@"[cfg] 写出默认配置 %@ ok=%d（enabled=true / hostEnabled=true / hostRoute=3 / hostSceneFrame=true / "
          @"keepAlive=true@200ms / 预防档=差量写（fg 保活默认关）/ keepAliveForeground=true / "
          @"deact 熔断=5 / 真黑分级恢复=带生效确认窗 / 预防冷却=2000ms）",
          path, (int)ok);
}

/// 0.3.0 的 plist 只有 5 个键，缺 hostEnabled/hostStep。
/// 与其让用户用 Filza 手打新键名（键盘自动更正随时会把键值改坏），
/// 不如我们把这几个键原地补上，用户只需要把 false 改成 true。
///
/// 【0.8.0】改成"按 cfgVersion 做一次迁移"，而不是"缺键就补"：
/// 因为 0.8.0 要动的不是"缺的键"，而是**用户已经设过的值**——
///   hostRoute     4 -> 3   （4 在 0.7.0 真机上把 SpringBoard 干挂了 → 安全模式）
///   hostSceneFrame false -> true（false 会让 route 3 的画面比例不对）
/// 用 cfgVersion 记一笔，这两种修正**只做一次**，之后用户想改回 4/false 不会被反复覆盖。
void MFUpgradeConfigIfNeeded(NSDictionary *cfg) {
    if (cfg == nil) return;

    NSInteger cur = MFConfigInt(cfg, @"cfgVersion", 0);
    BOOL missingKeys = (cfg[@"hostEnabled"] == nil || cfg[@"hostStep"] == nil ||
                        cfg[@"hostRoute"] == nil || cfg[@"forceForeground"] == nil ||
                        cfg[@"resizesHosted"] == nil || cfg[@"hostSceneFrame"] == nil ||
                        cfg[@"allowRouteB"] == nil ||
                        cfg[@"keepAlive"] == nil || cfg[@"keepAliveMs"] == nil ||
                        cfg[@"keepAliveIdle"] == nil || cfg[@"keepAliveForeground"] == nil ||
                        cfg[@"keepAliveDeact"] == nil || cfg[@"keepAliveLevel"] == nil ||
                        cfg[@"keepAliveSoft"] == nil || cfg[@"keepAliveMinWriteMs"] == nil ||
                        cfg[@"keepAliveGraceMs"] == nil || cfg[@"keepAliveEscalateAfter"] == nil ||
                        cfg[@"keepAliveGiveUpAfter"] == nil || cfg[@"keepAliveFrameSync"] == nil ||
                        cfg[@"keepAliveHardWrite"] == nil || cfg[@"keepAliveBackoffAfter"] == nil ||
                        cfg[@"keepAliveBackoffMaxMs"] == nil ||
                        cfg[@"keepAlivePrevent"] == nil || cfg[@"keepAlivePreventMs"] == nil ||
                        cfg[@"keepAlivePreventHard"] == nil ||
                        cfg[@"keepAliveViewFrameMs"] == nil || cfg[@"keepAliveViewFrameTol"] == nil ||
                        cfg[@"keepAlivePreventForeground"] == nil || cfg[@"keepAlivePreventIdle"] == nil ||
                        cfg[@"keepAlivePreventDeact"] == nil || cfg[@"keepAlivePreventLevel"] == nil ||
                        cfg[@"keepAlivePreventBackoffAfter"] == nil ||
                        cfg[@"keepAlivePreventBackoffMaxMs"] == nil ||
                        cfg[@"keepAliveDeactFuse"] == nil ||
                        cfg[@"keepAliveTieredRestore"] == nil ||
                        cfg[@"keepAliveSnapshot"] == nil ||
                        cfg[@"keepAliveSnapshotMask"] == nil ||
                        cfg[@"keepAlivePreventCooldownMs"] == nil);
    if (cur >= 19 && !missingKeys) return;

    for (NSString *path in MFConfigCandidatePaths()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![onDisk isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *up = [onDisk mutableCopy];
        if (up[@"hostEnabled"] == nil) up[@"hostEnabled"] = @NO;
        if (up[@"hostStep"]    == nil) up[@"hostStep"]    = @6;
        if (up[@"mode"]        == nil) up[@"mode"]        = @"shell";
        if (up[@"hostRoute"]   == nil) up[@"hostRoute"]   = @3;
        if (up[@"forceForeground"] == nil) up[@"forceForeground"] = @YES;
        if (up[@"resizesHosted"]   == nil) up[@"resizesHosted"]   = @YES;
        if (up[@"hostSceneFrame"]  == nil) up[@"hostSceneFrame"]  = @YES;
        if (up[@"allowRouteB"]     == nil) up[@"allowRouteB"]     = @NO;
        if (up[@"keepAlive"]       == nil) up[@"keepAlive"]       = @YES;
        if (up[@"keepAliveMs"]     == nil) up[@"keepAliveMs"]     = @200;   // 0.9.1 新默认
        if (up[@"keepAliveForeground"] == nil) up[@"keepAliveForeground"] = @YES; // 0.13.0 新默认
        if (up[@"keepAliveIdle"]   == nil) up[@"keepAliveIdle"]   = @YES;
        if (up[@"keepAliveDeact"]  == nil) up[@"keepAliveDeact"]  = @YES;
        if (up[@"keepAliveLevel"]  == nil) up[@"keepAliveLevel"]  = @NO;   // 0.10.0 新默认
        if (up[@"keepAliveSoft"]   == nil) up[@"keepAliveSoft"]   = @NO;   // 0.10.0 新默认（闪屏修复的关键）
        if (up[@"keepAliveHardWrite"]    == nil) up[@"keepAliveHardWrite"]    = @YES;  // 0.11.0 新默认
        if (up[@"keepAliveMinWriteMs"]    == nil) up[@"keepAliveMinWriteMs"]    = @300;
        if (up[@"keepAliveGraceMs"]       == nil) up[@"keepAliveGraceMs"]       = @600;   // 0.11.0 新默认
        if (up[@"keepAliveEscalateAfter"] == nil) up[@"keepAliveEscalateAfter"] = @5;
        if (up[@"keepAliveGiveUpAfter"]   == nil) up[@"keepAliveGiveUpAfter"]   = @0;     // 0.11.0 新默认（永不放弃）
        if (up[@"keepAliveBackoffAfter"]  == nil) up[@"keepAliveBackoffAfter"]  = @50;    // 0.11.0 新增
        if (up[@"keepAliveBackoffMaxMs"]  == nil) up[@"keepAliveBackoffMaxMs"]  = @2000;  // 0.11.0 新增
        if (up[@"keepAliveFrameSync"]     == nil) up[@"keepAliveFrameSync"]     = @YES;
        if (up[@"keepAlivePrevent"]       == nil) up[@"keepAlivePrevent"]       = @YES;  // 0.12.0 核心
        if (up[@"keepAlivePreventMs"]     == nil) up[@"keepAlivePreventMs"]     = @250;  // 0.12.0 新增
        if (up[@"keepAlivePreventHard"]   == nil) up[@"keepAlivePreventHard"]   = @NO;   // 0.12.0 新增
        if (up[@"keepAliveViewFrameMs"]   == nil) up[@"keepAliveViewFrameMs"]   = @500;  // 0.12.0 新增
        if (up[@"keepAliveViewFrameTol"]  == nil) up[@"keepAliveViewFrameTol"]  = @0.08; // 0.12.0 新增
        // ---- 0.13.0 预防档"差量写"的六个键 ----
        if (up[@"keepAlivePreventForeground"] == nil) up[@"keepAlivePreventForeground"] = @YES; // 0.13.0 核心
        if (up[@"keepAlivePreventIdle"]       == nil) up[@"keepAlivePreventIdle"]       = @YES;
        if (up[@"keepAlivePreventDeact"]      == nil) up[@"keepAlivePreventDeact"]      = @YES;
        if (up[@"keepAlivePreventLevel"]      == nil) up[@"keepAlivePreventLevel"]      = @YES;
        if (up[@"keepAlivePreventBackoffAfter"] == nil) up[@"keepAlivePreventBackoffAfter"] = @40;
        if (up[@"keepAlivePreventBackoffMaxMs"] == nil) up[@"keepAlivePreventBackoffMaxMs"] = @2000;
        // ---- 0.14.0 消闪三件套 ----
        if (up[@"keepAliveDeactFuse"]     == nil) up[@"keepAliveDeactFuse"]     = @5;   // 0.14.0 新增
        if (up[@"keepAliveTieredRestore"] == nil) up[@"keepAliveTieredRestore"] = @YES; // 0.14.0 新增
        // ---- 0.15.0 视觉消闪 ----
        if (up[@"keepAliveSnapshot"] == nil) up[@"keepAliveSnapshot"] = @YES;           // 0.15.0 新增
        if (up[@"keepAliveSnapshotMask"] == nil) up[@"keepAliveSnapshotMask"] = @YES;   // 0.18.0 新增
        if (up[@"keepAlivePreventCooldownMs"] == nil) up[@"keepAlivePreventCooldownMs"] = @2000; // 0.16.0 新增
        // 旧键 forceActivate 已废弃（真机实测它会让 SpringBoard 在 20 秒存活窗口内挂掉）。
        // 留着不删，代码里已经完全不读它。

        if (cur < 8) {
            id rv = up[@"hostRoute"];
            NSInteger route = [rv respondsToSelector:@selector(integerValue)] ? [rv integerValue] : 3;

            // 0.6.0 自动补的 hostRoute=2（自建 _initWithScene:）实测黑屏 -> 升 3
            if (route == 2) {
                up[@"hostRoute"] = @3;
                route = 3;
                MFLogS(@"[cfg] ★ 迁移：hostRoute 2 -> 3（2 实测黑屏）");
            }
            // 0.7.0 的 hostRoute=4（自建 scene）在真机上对**同一个 identity** 建了第二次，
            // FBSceneManager 断言 -> SpringBoard 崩 -> 安全模式。默认降回 3；
            // 想继续做 4 的对照实验，改回来即可（本次迁移只做一次）。
            if (route == 4) {
                up[@"hostRoute"] = @3;
                MFLogRawC("[cfg] ★ 迁移：hostRoute 4 -> 3\n"
                          "[cfg]   原因：4 会在同一 identity 上重复建 scene，实测把 SpringBoard 干挂（安全模式）\n"
                          "[cfg]   0.8.0 已给 4 加了“只建一次 + 复用”的保护；想继续拿它做对照实验，\n"
                          "[cfg]   把本文件里的 hostRoute 改回 4 即可（这条迁移不会再执行第二次）。\n");
            }
            // 0.7.0 的 hostSceneFrame=false 会让 route 3 的画面比例不对 -> 强制打开
            BOOL hsf = MFConfigBool(up, @"hostSceneFrame", NO);
            if (!hsf) {
                up[@"hostSceneFrame"] = @YES;
                MFLogS(@"[cfg] ★ 迁移：hostSceneFrame false -> true（不开的话画面比例会不对）");
            }
            up[@"cfgVersion"] = @8;
        }

        // ---- 0.8 -> 0.9：只**新增键**，不改任何已有取值 ----
        // 归档(8) 证明 route 3 和 route 4 都能出画面且都不崩，所以这次没有需要"纠正"的旧值；
        // 用户的 hostRoute / hostSceneFrame 原样保留（想做对照实验的继续用 4 也没问题）。
        if (cur < 9) {
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=9：新增 keepAlive / keepAliveMs / keepAliveForeground / keepAliveIdle（默认 true / 1000 / true / true）");
            MFLogS(@"[cfg]   这三项是归档(8)「切到别的 App 浮窗就变黑」的修复开关：承载成功后会守护 scene，");
            MFLogS(@"[cfg]   持续把 foreground / idleModeEnabled / deactivationReasons 拉回可渲染态。");
            up[@"cfgVersion"] = @9;
        }

        // ---- 0.9 -> 0.10：修正一项误导的默认值 + 新增两个分项开关 ----
        // 归档(9) 真机证据：
        //   ① 闪屏时长 ≈ 一个守护周期 => keepAliveMs=1000 就是"闪一下"的长度本身；
        //   ② 当年还顺手把 keepAliveForeground 关掉了，理由是"本机没有 setForeground:（空转）"。
        //      **那条理由后来被归档(13) 推翻了**（它只问了 FBScene，没问 settings），
        //      所以 0.13.0 起**不再**在这里关它（见下面 cur<14 那一段：反而要打开）。
        if (cur < 10) {
            // 只改"还停在旧默认值"的；用户自己调过的原样尊重。
            if (MFConfigInt(up, @"keepAliveMs", 1000) == 1000) {
                up[@"keepAliveMs"] = @200;
                MFLogS(@"[cfg] ★ 迁移：keepAliveMs 1000 -> 200（闪屏 ≈ 一个守护周期，直接砍到 1/5）");
            }
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=10：新增 keepAliveDeact / keepAliveLevel（默认 true / true）");
            MFLogS(@"[cfg]   ※ 0.13.0 说明：0.9->0.10 时曾把 keepAliveForeground 关成 false，理由是"
                  @"「本机没有 setForeground:」——那个判断是错的（问错了对象），现在它默认 true。");
            up[@"cfgVersion"] = @10;
        }

        // ---- 0.10 -> 0.11：把"越救越闪"的那两项关掉 ----
        // 归档(10) 真机证据（这条是整轮的决定性证据）：
        //   用户把 keepAliveMs 调成 100 / 50 后，**闪烁反而更快**。
        //   若黑是 SpringBoard 造成的，调小周期只会让黑窗更短，不会更频繁；
        //   频率跟着我们的周期走 ⇒ 是我们自己的写操作在造那一帧黑。逐条比对日志也印证：
        //     deact=32/33 出现 20+ 次、其中绝大多数 layers/hosted 完好；
        //     layers=0（真黑）只出现 4 次，且 4 次全在我们写完 settings 之后 0~2 秒内。
        if (cur < 11) {
            if (MFConfigBool(up, @"keepAliveLevel", YES)) {
                up[@"keepAliveLevel"] = @NO;
                MFLogS(@"[cfg] ★ 迁移：keepAliveLevel true -> false"
                      @"（升级写会让 SpringBoard 重算整份 settings，且把 frame 打回整屏；一写换两次重排）");
            }
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=11：新增 keepAliveSoft / keepAliveMinWriteMs / keepAliveGraceMs /"
                  @" keepAliveEscalateAfter / keepAliveGiveUpAfter / keepAliveFrameSync"
                  @"（默认 false / 300 / 1500 / 5 / 30 / true）");
            MFLogS(@"[cfg]   0.10.0 起守护只在「一个图层都没有」时才写 settings；deact/idle 只记日志。");
            up[@"cfgVersion"] = @11;
        }

        // ---- 0.11 -> 0.12：把 0.10.0 那个"救不回来还不许救"的错误配置纠正回来 ----
        // 归档(11) 真机证据：0.10.0 装上去之后"悬浮窗大概率黑屏"。
        //   ① 拉回动作被降级成"最小写"（丢掉 setLevel + setDisplayConfiguration）
        //      ⇒ layers=0 连续 220+ 拍、其间写了十几次，**一次都没拉回来**；
        //   ② keepAliveGiveUpAfter=30 ⇒ 6 秒后连试都不试了，永久黑屏；
        //   ③ 还有一种黑根本没被识别：scene 好好的（layers=2）但 presenter 掉了 hosting。
        // 所以这一版把默认值改回来：真黑全量写 / 永不放弃 / 宽限期 600 ms / 新增退避参数。
        // 只改"还停在 0.10.0 旧默认值"的项，用户自己调过的原样尊重。
        if (cur < 12) {
            if (MFConfigInt(up, @"keepAliveGiveUpAfter", 30) == 30) {
                up[@"keepAliveGiveUpAfter"] = @0;
                MFLogS(@"[cfg] ★ 迁移：keepAliveGiveUpAfter 30 -> 0（0 = 永不放弃）"
                      @"—— 归档(11) 里就是它让真黑 6 秒后再也不重试，变成永久黑屏");
            }
            if (MFConfigInt(up, @"keepAliveGraceMs", 1500) == 1500) {
                up[@"keepAliveGraceMs"] = @600;
                MFLogS(@"[cfg] ★ 迁移：keepAliveGraceMs 1500 -> 600（真黑本来就该尽快救）");
            }
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=12：新增 keepAliveHardWrite / keepAliveBackoffAfter /"
                  @" keepAliveBackoffMaxMs（默认 true / 50 / 2000）");
            MFLogS(@"[cfg]   ★ 真黑时现在一律**全量写**（含 setLevel + setDisplayConfiguration）——"
                  @"0.10.0 那种最小写（只有 idle + deact + frame）实测一次都拉不回来；"
                  @"要复现旧行为把 keepAliveHardWrite 设 false。");
            MFLogS(@"[cfg]   ★ 0.11.0 还区分了两种黑：scene 没图层（写 settings）vs presenter 掉 hosting（只修承载）。");
            up[@"cfgVersion"] = @12;
        }

        // ---- 0.12 -> 0.13：加回"预防档"（0.9.1 之所以不掉图层的那个机制）----
        // 归档(12) 真机证据（用户原话 + 日志双向印证）：
        //   "v0.10.0 和 v0.11.0 存在问题，v0.9.1 版本好像是正常的，
        //    虽然屏幕会闪一下，但是切换应用时悬浮窗不会黑屏。"
        //   日志：Filza 轮挂载时就带着 deact=33，1 秒后 layers 2 -> 0；
        //         Safari 轮按 Home 后 deact 变 32，约 1 秒后 layers 2 -> 0，
        //         此后连着 81 次"全量写"全部无效。
        //   ⇒ 图层一旦掉光就是不可逆的；唯一有效的时机是"deact!=0 而图层还在"的那一秒。
        //     0.9.1 把这一档算作"要动手"，所以它不掉图层；
        //     0.10.0/0.11.0 拿它当"软警告（不动手）"，所以必然黑。
        //   0.12.0 加回这一档，但只写 idle+deact（不碰几何），所以不该再有 0.9.1 的那一闪。
        if (cur < 13) {
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=13：新增 keepAlivePrevent / keepAlivePreventMs /"
                  @" keepAlivePreventHard / keepAliveViewFrameMs / keepAliveViewFrameTol"
                  @"（默认 true / 250 / false / 500 / 0.08）");
            MFLogS(@"[cfg]   ★ 0.12.0 新增「预防档」：图层还在但 scene 正在被去激活时，"
                  @"趁它没掉先把 idleModeEnabled / deactivationReasons 写回去。");
            MFLogS(@"[cfg]     归档(12) 证明图层掉光之后不可逆（81 次全量写全灭）=> 必须**提前**动手。");
            MFLogS(@"[cfg]     预防写刻意不写 level / displayConfiguration / frame —— 没有任何几何变化，"
                  @"所以不会产生 0.9.1 那种可见的一帧黑。");
            MFLogS(@"[cfg]     若仍然会黑（说明只清 deact 按不住），把 keepAlivePreventHard 设 true 做 A/B。");
            MFLogS(@"[cfg]     承载视图尺寸纠正也加了容差(8%)与节流(500 ms)：0.11.0 是每秒掰 20 次，"
                  @"等于在跟 presenter 自己的布局对拉。");
            up[@"cfgVersion"] = @13;
        }

        // ---- 0.13 -> 0.14：把 0.10.0 误删的那个开关**装回去** ----
        // 归档(13) 真机证据（用户原话："切换应用时悬浮窗依旧黑屏"，0.12.0）：
        //   · 日志：`deact 0->32`（画面还好）→ 我们的预防写发出去了 → 同一秒 `cs 2->0`
        //     → 下一拍 `layers 2->0`，之后再没回来；
        //   · 能力报告：`目标 App processState = taskState: Suspended; visibility: Background`
        //     —— **App 进程被挂起了**。被挂起的进程不可能出图，写多少 settings 都没用。
        //   把 0.9.1 与 0.10.0+ 的写操作对齐，只剩**一项**差别：
        //     0.9.1 因为 forceAll=YES，每拍都发 `setForeground:YES`；0.10.0 起默认 NO（从不发）。
        //   而那句"本机没有 setForeground:"的依据是**问错了对象**：
        //     只问了 FBScene 的 respondsToSelector（=NO），没问 settings ——
        //     归档(13) 的存在性矩阵明确给出 `setForeground: settings=YES`（只写型的前台开关）。
        if (cur < 14) {
            // 只改"还停在旧默认 NO"的；用户自己调过 true 的原样尊重。
            if (!MFConfigBool(up, @"keepAliveForeground", NO)) {
                up[@"keepAliveForeground"] = @YES;
                MFLogS(@"[cfg] ★ 迁移：keepAliveForeground false -> true"
                      @"（0.10.0 起它默认 NO 是三轮回归的总根源：scene 失去前台身份 -> App 被挂起 -> 图层永久消失）");
            }
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=14：预防档改成**差量写**，并新增"
                  @" keepAlivePreventForeground / keepAlivePreventIdle / keepAlivePreventDeact /"
                  @" keepAlivePreventLevel / keepAlivePreventBackoffAfter / keepAlivePreventBackoffMaxMs"
                  @"（默认 true / true / true / true / 40 / 2000）");
            MFLogS(@"[cfg]   ★ 0.13.0 的两条原则：① 预防档必须发 setForeground:YES（0.9.1 与 0.10.0+ 之间唯一有效的差别）；");
            MFLogS(@"[cfg]     ② 只写**差量** —— 先把当前值读出来，只有真的不一样才发；一项差量都没有就连 block 都不调（零写入 = 零重排 = 零闪）。");
            MFLogS(@"[cfg]   ★ 写完还会回读 FBScene.foreground 验证；连续 3 次无效就停手，避免「每拍写一次 = 每拍闪一次」。");
            up[@"cfgVersion"] = @14;
        }

        // ---- 0.14 -> 0.15：消闪（不黑了，但每拍还在闪）----
        // 归档(14) 真机证据（用户原话："这次没有黑屏，但是悬浮窗在切换应用时依旧会闪一下"）：
        //   · 黑屏判定通过：setForeground 回读从 0 -> 1，App 进程不再被挂起；
        //   · 但日志里「预防写[deact=1]」每拍出现（deact=32 共 32 次），fgS=n(0)；
        //   · 用户还开了逃生门 keepAlivePreventHard=true ⇒ hard 恒为真 ⇒
        //     「无差量」短路永远不成立 ⇒ 每拍一次 updateSettingsWithBlock: = 每拍闪一次。
        // 三处修正：
        //   ① deact 写加熔断（常态 32 写回 0 实测零收益，纯亏一次重排）；
        //   ② hard 不再参与差量判断（只影响写什么，不再制造"假差量"）；
        //   ③ 真黑恢复分级：L1 只写状态量 → L2 +frame → L3 +DC（归档(14) 真黑 1 拍即恢复，
        //      说明多数情况根本不需要动几何 —— DC 正是把 frame 打回整屏的那个）。
        if (cur < 15) {
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=15：消闪三件套 ——");
            MFLogS(@"[cfg]     ① 新增 keepAliveDeactFuse=5：deact 写完读回若从未生效，连败 5 次后熔断、不再回写");
            MFLogS(@"[cfg]        （归档(14)：deact 常态就是 32，每拍写回 0 = 每拍付一次重排换零收益）；");
            MFLogS(@"[cfg]     ② keepAlivePreventHard 不再参与「要不要写」的差量判断，只决定写什么");
            MFLogS(@"[cfg]        （它开着时恒为真，把差量短路顶掉了 = 每拍写 = 每拍闪）；");
            MFLogS(@"[cfg]     ③ 新增 keepAliveTieredRestore=YES：真黑恢复从最温和的 L1 试起，");
            MFLogS(@"[cfg]        L1=纯状态量 → L2=+frame → L3=+displayConfiguration（关掉 = 回 0.13.0 恒 L3）。");
            up[@"cfgVersion"] = @15;
        }

        // ---- 0.15 -> 0.16：消闪第二阶段（fg 保活 + 视觉侧兜底）----
        // 归档(15) 真机证据（用户原话："切走和切回都会闪一下"）：
        //   · 23 次真黑（切换掉图层）全部 1~2 拍（200~400ms）被 L1 拉回；
        //   · 45/48 次真黑前一拍 deact=0 —— **没有前兆**，预防档来不及介入；
        //   · 全场 fg=n(0)：本机 FBScene.foreground KVC 读不到 ⇒ 预防档的 fg
        //     差量检测从未生效 ⇒ setForeground:YES 一次都没发过（救场的全是
        //     真黑档 L1 的无条件 fg=1 —— 每次都晚 200~400ms）。
        // 三处改动：
        //   ① 预防档 fg 改**保活**：读不到 fg 的机器每拍发 setForeground:YES
        //      （纯状态量、不碰几何；回读"读不到"不计败 —— 否则会被误熔断）；
        //   ② P3b 把 context 的"未承载背景色"设透明（归档(15) dump：
        //      BGColorWhileHosting = 灰度0 α1 = 纯黑，这正是黑窗的颜色来源）；
        //   ③ 新增 keepAliveSnapshot：内容区垫"最后一帧"快照 —— 掉图层时
        //      露出定格画面而不是黑，体感从"闪黑"变"画面停一拍"。
        if (cur < 16) {
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=16：消闪第二阶段 ——");
            MFLogS(@"[cfg]     ① 预防档 setForeground:YES 从「差量项」改「保活项」"
                  @"（本机 fg 读不到 ⇒ 差量检测从未生效 ⇒ 一次都没发过）");
            MFLogS(@"[cfg]     ② presenter 上下文的「未承载背景色」黑 -> 透明"
                  @"（切换掉图层的黑窗 = presenter 在画这个色）");
            MFLogS(@"[cfg]     ③ 新增 keepAliveSnapshot=YES：内容区垫最后一帧快照，"
                  @"掉图层时露出定格画面；掉图层的 200~400ms 由 L1 拉回，视觉上几乎无感");
            up[@"cfgVersion"] = @17;
        }
        // ---- 0.17.0：fg 保活退场 + hostEnabled 默认开 ----
        // 实证（归档(15)(16)(17) 三轮）：fg 保活 = 每个预防回合必写一帧
        //（每次 updateSettingsWithBlock = 一次重提交 = 一帧"内容闪"），
        // 真黑次数一轮没降（92→93）⇒ 零收益纯成本。救命的 fg 在真黑档 L1，
        // 不受影响。一次性迁移：用户之后手动改回 YES 不会被反复覆盖。
        if (cur < 18) {
            id pv = up[@"keepAlivePreventForeground"];
            BOOL wasOn = [pv respondsToSelector:@selector(boolValue)] ? [pv boolValue] : NO;
            up[@"keepAlivePreventForeground"] = @NO;
            if (up[@"hostEnabled"] == nil) up[@"hostEnabled"] = @YES;   // 缺键补默认（0.17.0 起 YES）
            MFLog(@"[cfg] ★ 迁移到 cfgVersion=18：① 预防档 fg 保活关闭"
                  @"（三轮实证零收益、每回合白付一帧闪；真黑档 L1 的 fg 保留）"
                  @"② hostEnabled 默认 YES（用户要求；原值 was %@）",
                  wasOn ? @"YES" : @"NO");
            up[@"cfgVersion"] = @18;
        }
        // ---- 0.18.0：快照置顶遮盖 ----
        // 归档(19)：每次切出/切回系统必掉层（47 次真黑），垫底快照盖不住上层
        // presentationView 的可见异常。置顶遮盖 = 掉层期间显示最后一帧定格画面，
        // 恢复后等 2 拍归位。缺键补默认（YES），老配置升上来即可用。
        if (cur < 19) {
            MFLogS(@"[cfg] ★ 迁移到 cfgVersion=19：快照置顶遮盖（keepAliveSnapshotMask=YES）"
                  @"—— 掉层瞬间把最后一帧画面盖在最上层，恢复后归位；"
                  @"归档(19) 实证每次切换必掉层、垫底盖不住上层的闪烁");
            up[@"cfgVersion"] = @19;
        }

        BOOL ok = [up writeToFile:path atomically:YES];
        MFLog(@"[cfg] 配置已升级到 cfgVersion=%@ 于 %@ ok=%d（hostRoute=%@ / hostSceneFrame=%@ / keepAlive=%@ / keepAliveMs=%@ / keepAliveSoft=%@ / keepAliveHardWrite=%@ / keepAliveGiveUpAfter=%@ / 预防=%@@%@ms / 预防硬写=%@ / keepAliveForeground=%@ / 预防发前台=%@ / deact熔断=%@ / 分级恢复=%@ / 垫底快照=%@ / 预防冷却=%@ms）",
             up[@"cfgVersion"], path, (int)ok, up[@"hostRoute"], up[@"hostSceneFrame"],
             up[@"keepAlive"], up[@"keepAliveMs"], up[@"keepAliveSoft"],
             up[@"keepAliveHardWrite"], up[@"keepAliveGiveUpAfter"],
             up[@"keepAlivePrevent"], up[@"keepAlivePreventMs"], up[@"keepAlivePreventHard"],
             up[@"keepAliveForeground"], up[@"keepAlivePreventForeground"],
             up[@"keepAliveDeactFuse"], up[@"keepAliveTieredRestore"], up[@"keepAliveSnapshot"],
             up[@"keepAlivePreventCooldownMs"]);
        return;
    }
}

/// 0.5.0 真机事故的修复：用户把 hostEnabled 改成 true，却漏了 enabled 这个总开关
/// （它俩名字太像），于是 tweak 完全惰性、连外壳都不显示，用户以为"改了开关没反应"。
/// 与其再被这样绊一次，启动时直接把这种自相矛盾的配置修好：
///     enabled=false 且 hostEnabled=true  =>  用户意图显然是"要用" => 把 enabled 补成 true。
/// 只补总显示开关，**绝不自动打开 hostEnabled**（真承载开关必须由用户显式打开）。
/// 返回可能被修正过的配置（调用方必须用返回值继续判断），无需修正时原样返回。
NSDictionary *MFRepairConfigContradiction(NSDictionary *cfg) {
    if (cfg == nil) return cfg;
    BOOL enabled  = MFConfigBool(cfg, @"enabled", NO);
    BOOL hostWanted = MFConfigBool(cfg, @"hostEnabled", NO);
    if (enabled || !hostWanted) return cfg;   // 不矛盾，什么都不做

    MFLogRawC("[cfg] !! 配置自相矛盾：enabled=false 但 hostEnabled=true\n"
              "[cfg]    （这就是“改了 hostEnabled 却没出现浮窗”的原因：enabled 是总开关，优先于一切）\n"
              "[cfg]    已自动把 enabled 补成 true；hostEnabled 保持你自己的选择不变。\n");

    NSMutableDictionary *fixed = [cfg mutableCopy];
    fixed[@"enabled"] = @YES;
    for (NSString *path in MFConfigCandidatePaths()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        BOOL ok = [fixed writeToFile:path atomically:YES];
        MFLog(@"[cfg] 回写修正后的配置 %@ ok=%d（enabled=true）", path, (int)ok);
        break;
    }
    return fixed;
}

#pragma mark - ---------- 崩溃自解除闸门 ----------

static const char *const kMFAttemptPath = "/var/mobile/MF-float-attempt.txt";

BOOL MFAttemptExists(void) {
    return access(kMFAttemptPath, F_OK) == 0;
}

void MFAttemptWrite(const char *why) {
    int fd = open(kMFAttemptPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        MFLogRawC("[gate] !! 无法写出 attempt 标记（本轮没有崩溃保护）\n");
        return;
    }
    char buf[200];
    const char *w = (why != NULL) ? why : "?";
    int n = snprintf(buf, sizeof(buf), "why=%s t=%ld pid=%d\n", w, (long)time(NULL), (int)getpid());
    if (n > 0) {
        ssize_t written = write(fd, buf, (size_t)n);
        (void)written;
    }
    close(fd);
    MFLog(@"[gate] attempt 标记已写（%s）：下一次启动若它还在 => 本轮崩了 => 本轮不再承载", w);
}

void MFAttemptClear(void) {
    unlink(kMFAttemptPath);
}

#pragma mark - ---------- 承载步骤追踪（崩溃归因）----------

static const char *const kMFStepPath      = "/var/mobile/MF-host-step.txt";
static const char *const kMFStepPrevPath  = "/var/mobile/MF-host-step-prev.txt";
static const char *const kMFAttribPath    = "/var/mobile/MF-crash-attribution.txt";

static void MFStepWrite(const char *prefix, NSString *tag) {
    if (tag == nil) return;
    char buf[220];
    int n = snprintf(buf, sizeof(buf), "%s %s t=%ld pid=%d\n",
                     prefix, tag.UTF8String, (long)time(NULL), (int)getpid());
    if (n > 0) MFRawAppend(kMFStepPath, buf, (size_t)n);
}

void MFStepMark(NSString *tag) { MFStepWrite(">>>", tag); }
void MFStepOk(NSString *tag)   { MFStepWrite("<<<", tag); }

void MFStepReset(void) {
    unlink(kMFStepPath);
}

/// 把整个文件读进内存（步骤日志很短，上限 256KB 足够）
static NSMutableData *MFReadWholeFile(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return nil;
    NSMutableData *out = [NSMutableData data];
    char chunk[4096];
    ssize_t got = 0;
    size_t total = 0;
    while ((got = read(fd, chunk, sizeof(chunk))) > 0) {
        [out appendBytes:chunk length:(NSUInteger)got];
        total += (size_t)got;
        if (total > (256u * 1024u)) break;   // 保险丝
    }
    close(fd);
    return out;
}

NSString *MFStepRotateAndAnalyze(void) {
    if (access(kMFStepPath, F_OK) != 0) return nil;

    NSMutableData *data = MFReadWholeFile(kMFStepPath);
    NSString *crashed = nil;

    if (data.length > 0) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text == nil) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];

        // 0.6.0：改成**栈式**配对。因为 Route A2 的 P1..P5 是嵌在 S4 里面执行的，
        // 旧版"遇到配对就置 nil"的写法会在 P5 配对后把 S4 也一起忘掉；
        // 栈式则始终保留"还没闭合的最内层步骤"，崩点归因依然准确。
        NSMutableArray<NSString *> *stack = [NSMutableArray array];
        for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0) continue;
            // 形如 ">>> S4-hostvc t=… pid=…"
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
            if (parts.count < 2) continue;
            NSString *head = parts[0];
            NSString *tag  = parts[1];
            if ([head isEqualToString:@">>>"]) {
                [stack addObject:tag];
            } else if ([head isEqualToString:@"<<"]) {
                // 从栈顶往下找第一个同名项闭合（支持嵌套）
                for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
                    if ([stack[(NSUInteger)i] isEqualToString:tag]) {
                        [stack removeObjectAtIndex:(NSUInteger)i];
                        break;
                    }
                }
            }
        }
        crashed = stack.lastObject;
    }

    // 无论有没有结论，都把这一轮日志留档，然后开新的一轮
    if (crashed.length > 0) {
        NSString *why = [NSString stringWithFormat:
                         @"crashedStep=%@\n说明：上一轮承载走到 %@ 之后进程消失，"
                         @"也就是说崩点就在这一步（或其内部的异步副作用）。\n"
                         @"t=%ld\n",
                         crashed, crashed, (long)time(NULL)];
        [why writeToFile:@(kMFAttribPath) atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
        MFLog(@"[gate] ★ 崩溃归因：上一轮崩在步骤 %@（详见 /var/mobile/MF-crash-attribution.txt）", crashed);
    }

    // 留档 + 清空
    [[NSFileManager defaultManager] removeItemAtPath:@(kMFStepPrevPath) error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:@(kMFStepPath)
                                            toPath:@(kMFStepPrevPath)
                                             error:NULL];
    return crashed;
}

#pragma mark - ---------- 安全消息发送 ----------

id MFMsg(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return nil;
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

id MFMsg1(id obj, SEL sel, id a) {
    if (obj == nil || sel == NULL) return nil;
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, a);
}

NSString *MFStr(id obj, SEL sel) {
    id v = MFMsg(obj, sel);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

BOOL MFBoolProp(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return NO;
    if (![obj respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

NSInteger MFIntProp(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return 0;
    if (![obj respondsToSelector:sel]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

NSArray *MFIterate(id collection) {
    if (collection == nil) return @[];
    if ([collection isKindOfClass:[NSArray class]]) return (NSArray *)collection;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection allObjects];
    if ([collection isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)collection allValues];
    if ([collection respondsToSelector:@selector(allObjects)]) {
        id all = MFMsg(collection, @selector(allObjects));
        if ([all isKindOfClass:[NSArray class]]) return (NSArray *)all;
    }
    if ([collection respondsToSelector:@selector(objectEnumerator)]) {
        NSMutableArray *out = [NSMutableArray array];
        NSEnumerator *e = [collection objectEnumerator];
        for (id o in e) {
            if (o != nil) [out addObject:o];
        }
        return out;
    }
    return @[];
}

id MFClassSharedInstance(NSString *name) {
    if (name == nil) return nil;
    const char *cname = name.UTF8String;
    if (cname == NULL) return nil;
    Class cls = objc_getClass(cname);
    if (cls == Nil) return nil;
    for (NSString *selName in @[@"sharedInstance", @"sharedInstanceIfExists"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![cls respondsToSelector:sel]) continue;
        id inst = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
        if (inst != nil) return inst;
    }
    return nil;
}

BOOL MFClassHasInstanceMethod(NSString *className, NSString *selName) {
    if (className == nil || selName == nil) return NO;
    Class cls = objc_getClass(className.UTF8String);
    if (cls == Nil) return NO;
    return class_getInstanceMethod(cls, NSSelectorFromString(selName)) != NULL;
}
