// MultiFloatProbe v0.5.0 — SpringBoard 运行期探针（安全闸门版）
//
// 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
// ============ v0.4.0 真机结果（必须先读） ============
// v0.4.0 安装后 15 秒触发安全模式。心跳证实：SpringBoard 连续崩了 3 次
// （pid 15919 / 15943 / 15964），三次的轨迹**逐字节相同**（各 3311 行），
// 最后一次心跳都是 stage=live:handleMap —— 即崩点 100% 确定在
// 「段 G 活体探测 · 7.2 scene → sceneHandle 反查」里，且从未跑完到 7.3。
// 段 E（第三方浮窗类）与段 F（结构 dump）本轮**全部完成**，数据已拿到。
//
// 7.2 相对 7.1（已验证安全）只多了三件事：
//    1) [sm existingSceneHandleForScene:sc]
//    2) [h application] / [h persistenceIdentifier]
//    3) [sc uiPresentationManager]      <-- 最大嫌疑
// 其中 3) 最可疑：段 F 的结构 dump 证明 ```uiPresentationManager``` 根本不是 FBScene 自己的方法，
// 而是**定义在 NSObject 上的一个 category 方法**（全镜像 3197 个类都"响应"它）。
// 也就是说它不是纯取值，极可能**惰性创建/注册 UIScenePresentationManager**，
// 而我们在**后台队列**上调用了它 —— 这正是 SpringBoard 常见的 "必须在主线程" 断言死法。
//
// ============ v0.5.0 的应对 ============
// 1. 【默认全安全】自动段只保留 v0.3.0 / v0.4.0 已连续两轮验证过没问题的：
//    env / 类清单 / selector 归属（白名单 + 镜像）/ 第三方类 / 结构 dump。
// 2. 【新增第 7 段：关键 selector 全镜像归属搜索】纯静态（只读 method list，不 realize、
//    不创建对象），直接回答："uiPresentationManager / setResizesHostedContext: /
//    presentationView / sceneIfExists / existingSceneHandleForPersistenceIdentifier: …
//    这些 selector 到底是哪个类定义的、在哪个镜像里、签名是什么"。
// 3. 【活体段改为闸门控制 + 主线程执行 + 逐调用落盘 + 自解除】
//    - 闸门文件  /var/mobile/MFProbe-live-gate.txt  内容 = 级别 1..4；不存在 => 完全不跑。
//    - 尝试标记  /var/mobile/MFProbe-live-attempt.txt  记录"已尝试过的级别"。
//      进程启动时若 标记级别 == 闸门级别 => 本轮直接跳过活体段（说明上一次就是崩在这）。
//      => 最多崩一次，永远不会再出现"崩→重启→再崩→安全模式"的循环。
//    - 活体段一律 dispatch 到**主线程**执行（这正是 v0.4.0 的最大失误）。
//    - 每次危险调用前后各写一条心跳 + 立即 append 到 -live.log，崩了也能精确定位到调用。
//    - 级别按风险递增：1/2 = 已验证安全的枚举；3 = handle 反查；4 = uiPresentationManager。
//    => 崩在 4 也照样拿到 1~3 的数据；想再采一次就在 Filza 里删掉 attempt 文件。
// 4. 【hook 段也加闸门】/var/mobile/MFProbe-hooks-gate.txt 存在才装（默认不装）。
// 5. 【summary 的假 COMPLETE 修掉】以前第 4 段后就写 ==== COMPLETE ====，会误判为跑完。
//
// 安全约束：自动段不创建任何对象、不改任何状态、不发送任何"会改状态"的消息。
// ==========================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdio.h>
#import <stdarg.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>

static NSString *const kOutDir  = @"/var/mobile";
static NSString *const kSummary = @"MultiFloatProbe-summary.log";
static NSString *const kMethods = @"MultiFloatProbe-methods.log";
static NSString *const kThird   = @"MultiFloatProbe-thirdparty.log";
static NSString *const kOwners  = @"MultiFloatProbe-owners.log";

#define MF_PROBE_VERSION "0.5.0"

#define MF_HEARTBEAT  "/var/mobile/MultiFloatProbe-heartbeat.log"
#define MF_HOOKLOG    "/var/mobile/MultiFloatProbe-hooks.log"
#define MF_BOOTLOG    "/var/mobile/MultiFloatProbe-boot.log"
#define MF_LIVELOG    "/var/mobile/MultiFloatProbe-live.log"

// ---- 安全闸门（全部手动创建，缺省一律"最保守"）----
#define MF_GATE_LIVE   "/var/mobile/MFProbe-live-gate.txt"     // 内容 1..4；不存在 => 活体段不跑
#define MF_GATE_HOOKS  "/var/mobile/MFProbe-hooks-gate.txt"    // 存在 => 装 hook（内容忽略）
#define MF_ATTEMPT     "/var/mobile/MFProbe-live-attempt.txt"  // 记录已尝试级别，防崩溃循环
// 自动段的自解除标记：崩过一次后下一次启动直接跳过，成功一次后自动删除。
// => 任何一段都不可能形成 "崩→重启→再崩" 的连锁，安全模式从结构上被排除。
#define MF_AUTORUN_ATTEMPT "/var/mobile/MFProbe-autorun-attempt.txt"
#define MF_OWNERS_ATTEMPT  "/var/mobile/MFProbe-owners-attempt.txt"
#define MF_OWNERSLOG       "/var/mobile/MultiFloatProbe-owners-progress.log"
#define MF_STATELOG        "/var/mobile/MultiFloatProbe-state.log"

#pragma mark - 心跳 / 追加写（纯 POSIX，不依赖 ObjC 运行时）

static void MFBeatf(const char *fmt, ...) {
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "t=%ld pid=%d ", (long)time(NULL), (int)getpid());
    if (n < 0) n = 0;
    if (n < (int)sizeof(buf) - 1) {
        va_list ap;
        va_start(ap, fmt);
        int m = vsnprintf(buf + n, sizeof(buf) - (size_t)n, fmt, ap);
        va_end(ap);
        if (m > 0) n += m;
    }
    if (n <= 0) return;
    if (n > (int)sizeof(buf) - 1) n = (int)sizeof(buf) - 1;
    buf[n++] = '\n';
    int fd = open(MF_HEARTBEAT, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, buf, (size_t)n);
    (void)w;
    close(fd);
}

static void MFBeat(const char *stage) { MFBeatf("stage=%s", stage); }

static void MFAppendTo(const char *path, NSString *text) {
    if (!text) return;
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!d || d.length == 0) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, d.bytes, d.length);
    (void)w;
    close(fd);
}

#pragma mark - 基础工具

static NSString *MFSysctl(const char *key) {
    size_t size = 0;
    if (sysctlbyname(key, NULL, &size, NULL, 0) != 0 || size == 0) return @"?";
    char *buf = (char *)malloc(size + 1);
    if (!buf) return @"?";
    NSString *value = @"?";
    if (sysctlbyname(key, buf, &size, NULL, 0) == 0) {
        buf[size] = '\0';
        value = [NSString stringWithUTF8String:buf] ?: @"?";
    }
    free(buf);
    return value;
}

static NSString *MFSafeClass(Class c) {
    if (c == Nil) return @"?";
    const char *n = class_getName(c);
    if (!n) return @"?";
    return [NSString stringWithUTF8String:n] ?: @"?";
}

// 只用 object_getClassName —— 不发送任何消息，绝对不会因为对象状态而崩
static NSString *MFClassOf(id obj) {
    if (!obj) return @"nil";
    const char *n = object_getClassName(obj);
    return n ? [NSString stringWithUTF8String:n] : @"?";
}

static BOOL MFOwnsSelector(Class cls, SEL sel) {
    if (cls == Nil) return NO;
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NO;
    BOOL found = NO;
    for (unsigned i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static Class MFDefiningClass(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        if (MFOwnsSelector(c, sel)) return c;
    }
    return Nil;
}

static NSString *MFHierarchy(Class cls) {
    NSMutableArray *parts = [NSMutableArray array];
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        NSString *n = MFSafeClass(c);
        if (n) [parts addObject:n];
        else break;
    }
    return [parts componentsJoinedByString:@" : "];
}

static NSString *MFIvars(Class cls, BOOL withOffset) {
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    if (!ivars || count == 0) {
        if (ivars) free(ivars);
        return @"(无 ivar)";
    }
    NSMutableArray *items = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (withOffset) {
            [items addObject:[NSString stringWithFormat:@"%s @%ld (%s)",
                              name ? name : "?",
                              (long)ivar_getOffset(ivars[i]),
                              type ? type : "?"]];
        } else if (name) {
            NSString *n = [NSString stringWithUTF8String:name];
            if (n) [items addObject:n];
        }
    }
    free(ivars);
    return [items componentsJoinedByString:withOffset ? @", " : @" "];
}

static NSString *MFMethods(Class cls, NSArray *keywords, BOOL dumpAll, NSUInteger cap) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods || count == 0) {
        if (methods) free(methods);
        return @"  (无自有方法)";
    }
    NSMutableArray *lines = [NSMutableArray array];
    NSUInteger matched = 0;
    for (unsigned i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i])) ?: @"?";
        if (!dumpAll) {
            NSString *lower = [name lowercaseString];
            BOOL hit = NO;
            for (NSString *kw in keywords) {
                if ([lower rangeOfString:kw].location != NSNotFound) { hit = YES; break; }
            }
            if (!hit) continue;
        }
        const char *enc = method_getTypeEncoding(methods[i]);
        [lines addObject:[NSString stringWithFormat:@"    - [%@] %s", name, enc ? enc : "?"]];
        matched++;
        if (matched >= cap) {
            [lines addObject:[NSString stringWithFormat:@"    ... 已截断（共 %u 个自有方法）", count]];
            break;
        }
    }
    free(methods);
    if (lines.count == 0) {
        return [NSString stringWithFormat:@"  (无匹配方法；该类共 %u 个自有方法)", count];
    }
    NSString *head = [NSString stringWithFormat:@"  (自有方法总数 %u，列出 %lu)", count, (unsigned long)lines.count];
    return [NSString stringWithFormat:@"%@\n%@", head, [lines componentsJoinedByString:@"\n"]];
}

static void MFWrite(const NSString *filename, const NSString *content) {
    NSString *path = [kOutDir stringByAppendingPathComponent:(NSString *)filename];
    NSError *err = nil;
    BOOL ok = [(NSString *)content writeToFile:path atomically:YES
                                      encoding:NSUTF8StringEncoding error:&err];
    if (!ok) MFBeatf("writefail:%s", filename.UTF8String);
}

// 只发送 respondsToSelector: 与目标 selector，任何异常都被吞掉
static id MFObjProp(id obj, SEL sel) {
    if (!obj) return nil;
    if (![obj respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *MFStrProp(id obj, SEL sel) {
    id v = MFObjProp(obj, sel);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

static id MFClassSharedInstance(Class cls) {
    if (cls == Nil) return nil;
    SEL candidates[] = { @selector(sharedInstance), @selector(sharedInstanceIfExists),
                         @selector(sharedManager), @selector(defaultManager),
                         @selector(sharedApplication) };
    for (int i = 0; i < 5; i++) {
        SEL s = candidates[i];
        if ([cls respondsToSelector:s]) {
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)((id)cls, s);
                if (v) return v;
            } @catch (NSException *e) { }
        }
    }
    return nil;
}

// 探测矩阵：对一批 selector 输出「响应/不响应」，用于确认实现路径存在
static NSString *MFResponseMatrix(id obj, NSArray<NSString *> *sels) {
    NSMutableString *s = [NSMutableString string];
    if (!obj) return @"  (对象为 nil)\n";
    for (NSString *selStr in sels) {
        SEL sel = NSSelectorFromString(selStr);
        BOOL ok = NO;
        @try { ok = [obj respondsToSelector:sel]; } @catch (NSException *e) { ok = NO; }
        [s appendFormat:@"  %@ %@\n", ok ? @"YES" : @"NO ", selStr];
    }
    return s;
}

#pragma mark - 候选类集合（全部不触发 realize）

static NSArray<NSString *> *MFWhitelistClasses(void) {
    return @[
        @"SBMainWorkspace", @"SBWorkspace", @"SBMainWorkspaceTransaction",
        @"SBMainWorkspaceTransitionRequest",
        @"SBSceneManager", @"SBMainDisplaySceneManager", @"SBSceneManagerCoordinator",
        @"SBSecureMainDisplaySceneManager", @"SBNonInteractiveDisplaySceneManager",
        @"SBSystemShellExternalDisplaySceneManager",
        @"SBApplicationController", @"SBApplication",
        @"SBSceneHandle", @"SBApplicationSceneHandle", @"SBDeviceApplicationSceneHandle",
        @"SBApplicationSceneEntity", @"SBDeviceApplicationSceneEntity",
        @"SBWindowScene", @"SBWindowSceneManager",
        @"SBUIController", @"SBSwitcherController",
        @"SBMainSwitcherControllerCoordinator",
        @"SBFloatingDockController", @"SBFloatingDockRootViewController",
        @"SBTransientOverlayScenePresenter", @"SBTransientOverlayPresenter",
        @"SBSceneDisconnectionManager", @"SBSceneDataStore", @"SBSceneIdentityProvider",
        @"SBLayoutStateSceneIdentityProvider", @"SBSceneLayoutStateProvider",
        @"FBSceneManager", @"FBScene", @"FBSceneWorkspace", @"FBSceneLayerManager",
        @"FBSceneHandle", @"FBSceneClientHandle", @"FBSceneRemnant",
        @"FBSScene", @"FBSWorkspace", @"FBSWorkspaceScenesClient", @"FBWorkspace",
        @"FBSceneTransitionContext", @"FBSWorkspaceSceneRequestOptions",
        @"BKSSceneHostRegistration", @"BKSWorkspace",
        @"UIWindowScene", @"UIScene", @"UIApplicationSceneDeactivationManager",
        @"UIScenePresentationManager",
  // ---- v0.4.0 新增白名单 ----
        @"_UIScenePresenter", @"_UIScenePresentationView", @"_UISceneHostingController",
        @"SBApplicationSceneViewController", @"SBApplicationSceneView",
        @"SBDeviceApplicationSceneViewController",
        @"SBMedusaDecoratedDeviceApplicationSceneViewController",
        @"SBFluidSwitcherGestureManager", @"SBAppLayout", @"SBDisplayItem",
        @"SBPIPControllerCoordinator", @"SBPIPInteractionController",
        @"UIApplicationSceneDeactivationAssertion", @"UIWindow",
  ];
}

// 结构 dump 时输出"完整方法列表"的类
static NSArray<NSString *> *MFDetailClasses(void) {
    return @[
        @"_UIScenePresenter", @"UIScenePresentationManager",
        @"SBApplication", @"SBApplicationController",
        @"SBSceneHandle", @"SBApplicationSceneHandle", @"SBDeviceApplicationSceneHandle",
        @"SBApplicationSceneEntity", @"SBDeviceApplicationSceneEntity",
        @"SBMainDisplaySceneManager", @"SBSceneManager", @"SBSceneManagerCoordinator",
        @"SBWindowScene", @"SBWindowSceneManager",
        @"SBApplicationSceneViewController", @"SBApplicationSceneView",
        @"SBDeviceApplicationSceneViewController",
        @"SBFluidSwitcherGestureManager", @"SBAppLayout", @"SBDisplayItem",
        @"FBSceneManager", @"FBScene", @"UIWindowScene", @"UIWindow",
        @"SBPIPControllerCoordinator", @"SBPIPInteractionController",
        // ---- v0.5.0 新增：补上"呈现上下文 / 宿主 / scene 定义"这几块拼图 ----
        // 7.2 崩溃的 uiPresentationManager 到底把对象注册到哪儿，答案在这些类里
        @"UIScenePresentationContext", @"UISceneMutablePresentationContext",
        @"_UIScenePresentationView", @"_UIScenePresenterOwner", @"_UISceneHostingView",
        @"UISceneHostingViewController", @"UIApplicationSceneSettings",
        @"FBSceneWorkspace", @"FBSMutableSceneDefinition", @"FBSMutableSceneParameters",
        @"FBSMutableSceneSettings", @"FBSMutableSceneClientSettings",
        @"FBSMutableSceneIdentityToken", @"FBSceneIdentityToken", @"FBSSceneDefinition",
        @"SBMainWorkspace", @"SBMainWorkspaceTransaction", @"SBMainWorkspaceTransitionRequest",
        @"SBWorkspaceTransaction", @"SBWorkspaceEntity", @"SBWorkspaceApplicationSceneTransitionContext",
        @"SBFluidSwitcherViewController", @"SBHomeScreenViewController",
        @"SBDisplayIdentifier", @"SBSceneSnapshotReferenceFrame",
        // ---- 设备上真实存在的第三方浮窗类（v0.4.0 已确认来自 ScreenshotShell.dylib）----
        // 注意：段 E 已证明它是"截图浮动图片"，不是活体 App 浮窗；
        //       这里 dump 它是为了抄它的取窗口/拖动窗口的写法，不再指望它给分屏链路。
        @"SSFloatingManager", @"SSFloatingWindow", @"SSFloatingRootViewController",
        @"ADPanelWindow", @"KayokoCompactLandscapeOverlayWindow", @"SSHistoryOverlayWindow",
    ];
}

// 取指定镜像内定义的类名（objc_copyClassNamesForImage 不 realize 任何类）
static NSArray<NSString *> *MFClassNamesInImages(NSArray<NSString *> *imageBaseNames) {
    NSMutableArray *out = [NSMutableArray array];
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p) continue;
        if (![imageBaseNames containsObject:[p lastPathComponent]]) continue;

        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(path, &count);
        if (!names) continue;
        for (unsigned int j = 0; j < count; j++) {
            if (!names[j]) continue;
            NSString *n = [NSString stringWithUTF8String:names[j]];
            if (n && ![out containsObject:n]) [out addObject:n];
        }
        free((void *)names);
    }
    return out;
}

static NSArray<NSString *> *MFImageClassesFiltered(void) {
    NSArray *imgs = @[
        @"SpringBoard", @"SpringBoardUI", @"SpringBoardFoundation",
        @"SpringBoardHome", @"SpringBoardUIServices",
        @"BoardServices", @"FrontBoard", @"FrontBoardServices", @"BackBoardServices",
    ];
    NSArray *all = MFClassNamesInImages(imgs);
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *n in all) {
        if ([n hasPrefix:@"SB"] || [n hasPrefix:@"FB"] ||
            [n hasPrefix:@"BK"] || [n hasPrefix:@"BB"] ||
            [n hasPrefix:@"UIWindowScene"] || [n hasPrefix:@"UIScene"]) {
            [kept addObject:n];
        }
    }
    return kept;
}

#pragma mark - 探测目标

static NSArray *MFSelectors(void) {
    return @[
        // 入口
        @"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:",
        @"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
        @"_handleUntrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
        @"_openURLCore:display:animating:activationSettings:origin:withResult:",
        @"openInSplit:",
        // scene 创建 / 销毁 / 复用
        @"createSceneWithDefinition:initialParameters:",
        @"createSceneWithDefinition:",
        @"_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:",
        @"destroyScene:withTransitionContext:",
        @"sceneWithIdentifier:", @"enumerateScenesWithBlock:", @"scenesPassingTest:",
        @"sceneHandle:reuseExistingScene:",
        // scene handle 反查
        @"existingSceneHandleForScene:", @"existingSceneHandleForSceneIdentity:",
        @"existingSceneHandleForPersistenceIdentifier:",
        @"fetchOrCreateApplicationSceneHandleForRequest:",
        @"newSceneViewController",
        @"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:",
        @"allScenes", @"boundScenes", @"runningApplicationScenes:",
        @"externalApplicationSceneHandles", @"externalForegroundApplicationSceneHandles",
        // 呈现链路 ★
        @"uiPresentationManager", @"presentationManager",
        @"createPresenterWithIdentifier:priority:", @"createPresenterWithIdentifier:",
        @"createPresenterForLayerTarget:identifier:priority:",
        @"setResizesHostedContext:", @"setSceneResizesHostedContext:",
        @"setScenePresenterRenderIdentifierForSnapshotting:",
        @"presentationView", @"scene", @"sceneHandle",
        // entity 构造
        @"initWithApplicationForMainDisplay:generatingNewPrimarySceneIfRequired:",
        @"initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:",
        @"initWithApplication:sceneHandleProvider:displayIdentity:",
        // 应用解析
        @"applicationWithBundleIdentifier:", @"applicationProxyForIdentifier:",
        @"launchApplicationWithIdentifier:suspended:", @"applicationDidFinishLaunching:",
        // 布局 / 手势
        @"frameForFloatingAppLayoutInInterfaceOrientation:floatingConfiguration:",
        @"_currentFloatingAppLayout", @"addAppLayoutForDisplayItem:completion:",
        @"handlePanGesture:", @"handleLongPressGesture:",
        @"minimizeCurrentFloatingWindow", @"fullscreenCurrentFloatingWindow",
        @"closeCurrentFloatingWindow",
        // 窗口场景
        @"sceneManager", @"sceneManagerForDisplayIdentity:", @"sceneManagerForPersistenceIdentifier:",
        @"activeDisplayWindowScene", @"connectedWindowScenes",
    ];
}

static NSArray *MFMethodKeywords(void) {
    return @[@"open", @"scene", @"split", @"float", @"window", @"mini", @"fullscreen",
             @"gesture", @"pan", @"press", @"reuse", @"destroy", @"present", @"transition",
             @"activate", @"layout", @"frame", @"resize", @"drag", @"close", @"hosted",
             @"layer", @"root", @"handle", @"application", @"snapshot"];
}

#pragma mark - 段 1：环境实况

static NSString *MFSectionEnv(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"==== MultiFloatProbe v%s · 环境实况 ====\n", MF_PROBE_VERSION];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"进程     : %@ (pid %d)\n", [[NSProcessInfo processInfo] processName], (int)getpid()];
    [s appendFormat:@"bundle   : %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [s appendFormat:@"iOS      : %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [s appendFormat:@"osversion: %@\n", MFSysctl("kern.osversion")];
    [s appendFormat:@"设备     : %@ / %@\n", MFSysctl("hw.machine"), MFSysctl("hw.model")];
    [s appendFormat:@"探针版本 : %s (roothide / arm64e)\n", MF_PROBE_VERSION];

    [s appendString:@"\n-- 关键已加载镜像 --\n"];
    uint32_t imgCount = _dyld_image_count();
    NSUInteger hits = 0;
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *p = [NSString stringWithUTF8String:nm];
        if (!p) continue;
        NSString *low = [p lowercaseString];
        if ([low rangeOfString:@"multifloat"].location != NSNotFound ||
            [low rangeOfString:@"ellekit"].location != NSNotFound ||
            [low rangeOfString:@"substrate"].location != NSNotFound ||
            [low rangeOfString:@"roothide"].location != NSNotFound ||
            [low rangeOfString:@"inject"].location != NSNotFound) {
            [s appendFormat:@"  %@\n", p];
            hits++;
        }
    }
    if (hits == 0) [s appendString:@"  (无匹配)\n"];

    [s appendString:@"\n-- 路径存在性 --\n"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        @"/var/jb",
        @"/Library/MobileSubstrate/DynamicLibraries",
        @"/usr/lib/libellekit.dylib",
        @"/usr/lib/libsubstrate.dylib",
        @"/var/mobile/MultiFloatProbe-heartbeat.log",
    ];
    for (NSString *p in paths) {
        [s appendFormat:@"  %@  ->  %@\n", p, [fm fileExistsAtPath:p] ? @"存在" : @"不存在"];
    }

    // hook 后端可用性（决定 H 段能否装 hook）
    void *h = dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!h) h = dlsym(RTLD_DEFAULT, "_MSHookMessageEx");
    [s appendFormat:@"\n-- hook 后端 --\n  dlsym(RTLD_DEFAULT,\"MSHookMessageEx\") = %s\n", h ? "可用" : "不可用"];
    void *orig = dlsym(RTLD_DEFAULT, "MSHookFunction");
    [s appendFormat:@"  dlsym(RTLD_DEFAULT,\"MSHookFunction\")  = %s\n", orig ? "可用" : "不可用"];
    return s;
}

#pragma mark - 段 2：类清单

static NSString *MFSectionClassInventory(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"\n==== 类清单：名称含 Scene / Split / Floating / Workspace ====\n"];
    int total = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)(total > 0 ? total : 1));
    if (!classes) { [s appendString:@"(class list 不可用)\n"]; return s; }
    int count = objc_getClassList(classes, total);
    NSMutableArray *hit = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        const char *nm = class_getName(classes[i]);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (!name) continue;
        if ([name rangeOfString:@"Scene"].location != NSNotFound ||
            [name rangeOfString:@"Split"].location != NSNotFound ||
            [name rangeOfString:@"Floating"].location != NSNotFound ||
            [name rangeOfString:@"Workspace"].location != NSNotFound) {
            [hit addObject:name];
        }
    }
    free(classes);
    NSArray *sorted = [hit sortedArrayUsingSelector:@selector(compare:)];
    [s appendFormat:@"运行期类总数 %d；匹配 %lu 个：\n", count, (unsigned long)sorted.count];
    for (NSString *n in sorted) [s appendFormat:@"  %@\n", n];
    return s;
}

#pragma mark - 段 3：selector 归属

static NSString *MFSectionSelectors(NSArray<NSString *> *classNames, NSString *label) {
    NSMutableString *s = [NSMutableString string];
    NSArray *sels = MFSelectors();
    [s appendFormat:@"\n==== selector 归属（限定：%@，候选类 %lu）====\n",
     label, (unsigned long)classNames.count];

    NSMutableDictionary<NSString *, NSMutableDictionary *> *bySel = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *respCount = [NSMutableDictionary dictionary];
    for (NSString *selStr in sels) {
        bySel[selStr] = [NSMutableDictionary dictionary];
        respCount[selStr] = @0;
    }

    NSUInteger visited = 0;
    for (NSString *cn in classNames) {
        Class c = objc_getClass(cn.UTF8String);
        if (c == Nil) continue;
        MFBeatf("cls:%s", cn.UTF8String);   // 崩溃时最后一行即崩溃类
        visited++;
        for (NSString *selStr in sels) {
            SEL sel = NSSelectorFromString(selStr);
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            respCount[selStr] = @(respCount[selStr].unsignedIntegerValue + 1);
            Class d = MFDefiningClass(c, sel);
            if (d == Nil) continue;
            NSString *dn = MFSafeClass(d);
            if (!dn || bySel[selStr][dn]) continue;
            Method dm = class_getInstanceMethod(d, sel);
            const char *enc = dm ? method_getTypeEncoding(dm) : NULL;
            bySel[selStr][dn] = enc ? [NSString stringWithUTF8String:enc] : @"?";
        }
    }

    [s appendFormat:@"实际遍历 %lu 个类\n", (unsigned long)visited];
    for (NSString *selStr in sels) {
        NSMutableDictionary *defs = bySel[selStr];
        NSUInteger r = respCount[selStr].unsignedIntegerValue;
        [s appendFormat:@"\n%@\n", selStr];
        if (r == 0) {
            [s appendString:@"  归属: (限定集合内无类响应此 selector)\n"];
            continue;
        }
        NSArray *keys = [[defs allKeys] sortedArrayUsingSelector:@selector(compare:)];
        [s appendFormat:@"  响应类 %lu；定义类 %lu：\n", (unsigned long)r, (unsigned long)keys.count];
        for (NSString *dn in keys) [s appendFormat:@"    %@  encoding=%@\n", dn, defs[dn]];
    }
    return s;
}

#pragma mark - 段 5（新）：第三方浮窗类定位

// 判断一个镜像是否属于"非系统"（第三方 tweak / App）
static BOOL MFIsThirdPartyImage(NSString *path) {
    if (!path) return NO;
    if ([path hasPrefix:@"/System/Library/"]) return NO;
    if ([path hasPrefix:@"/System/"]) return NO;
    if ([path hasPrefix:@"/usr/lib/"]) return NO;
    if ([path hasPrefix:@"/Developer/"]) return NO;
    if ([path hasPrefix:@"/AppleInternal/"]) return NO;
    return YES;
}

static NSString *MFSectionThirdParty(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"==== 第三方（非系统镜像）类定位 ====\n"];

    NSArray *targets = @[@"SSFloatingManager", @"SSFloatingWindow", @"SSFloatingRootViewController"];
    NSMutableDictionary<NSString *, NSString *> *loc = [NSMutableDictionary dictionary];
    for (NSString *t in targets) loc[t] = @"(未找到)";

    NSArray *patterns = @[@"floating", @"floatwindow", @"floatview", @"multiwindow",
                          @"multitask", @"splitview", @"splitwindow", @"taskwindow",
                          @"overlaywindow", @"pipwindow", @"panelwindow"];

    uint32_t imgCount = _dyld_image_count();
    [s appendFormat:@"已加载镜像总数 %u\n", imgCount];
    NSUInteger thirdPartyImages = 0, interesting = 0;

    for (uint32_t i = 0; i < imgCount; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *path = [NSString stringWithUTF8String:p];
        if (!MFIsThirdPartyImage(path)) continue;
        thirdPartyImages++;

        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(p, &count);
        if (!names || count == 0) { if (names) free((void *)names); continue; }

        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int j = 0; j < count; j++) {
            if (!names[j]) continue;
            NSString *n = [NSString stringWithUTF8String:names[j]];
            if (!n) continue;
            if ([targets containsObject:n]) loc[n] = path;
            NSString *low = [n lowercaseString];
            for (NSString *pat in patterns) {
                if ([low rangeOfString:pat].location != NSNotFound) {
                    [hits addObject:n];
                    break;
                }
            }
        }
        free((void *)names);

        if (hits.count) {
            interesting++;
            [s appendFormat:@"\n  ● %@  (%lu 个疑似浮窗类)\n", path, (unsigned long)hits.count];
            NSArray *sorted = [hits sortedArrayUsingSelector:@selector(compare:)];
            for (NSString *n in sorted) [s appendFormat:@"      %@\n", n];
        }
    }

    [s appendString:@"\n==== 目标类归属镜像 ====\n"];
    for (NSString *t in targets) [s appendFormat:@"  %-32s -> %@\n", t.UTF8String, loc[t]];
    [s appendFormat:@"\n非系统镜像数 %lu；其中含浮窗类命中的 %lu 个\n",
     (unsigned long)thirdPartyImages, (unsigned long)interesting];
    return s;
}

#pragma mark - 段 6（新）：呈现链路结构 dump

static NSString *MFBuildStructureReport(void) {
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"==== MultiFloatProbe v%s · 呈现链路结构 ====\n", MF_PROBE_VERSION];
    NSArray *keywords = MFMethodKeywords();
    NSArray *full = MFDetailClasses();

    NSMutableArray *list = [NSMutableArray array];
    for (NSString *t in full) if (![list containsObject:t]) [list addObject:t];

    for (NSString *clsName in list) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (cls == Nil) {
            [m appendFormat:@"\n### %@ —— 不存在\n", clsName];
            continue;
        }
        MFBeatf("scls:%s", clsName.UTF8String);
        BOOL all = YES;   // 本轮全部输出完整方法列表
        [m appendFormat:@"\n### %@  (%@)\n", clsName, all ? @"完整方法列表" : @"按关键词过滤"];
        [m appendFormat:@"继承链: %@\n", MFHierarchy(cls)];
        [m appendFormat:@"ivar:\n  %@\n", MFIvars(cls, YES)];
        [m appendFormat:@"类方法:\n%@\n", MFMethods(object_getClass(cls), keywords, all, 200)];
        [m appendFormat:@"实例方法:\n%@\n", MFMethods(cls, keywords, all, 900)];
    }
    [m appendString:@"\n==== 段 F 结束 ====\n"];
    return m;
}

#pragma mark - 段 9（新）：关键 selector 全镜像归属搜索（纯静态）

// 这些 selector 是"浮窗分屏"唯一必须打通的接口。v0.4.0 的实例/归属查询只覆盖了
// 白名单 64 类 + SpringBoard 镜像里的 SB/FB/BK 类，恰好漏掉了 "uiPresentationManager
// 到底谁定义" 这种 NSObject-category 情况 —— 这里做全镜像无遗漏搜索。
static NSArray<NSString *> *MFOwnerTargets(void) {
    return @[
        @"uiPresentationManager",
        @"presentationManager",
        @"presentationView",
        @"_initWithScene:",
        @"createPresenterWithIdentifier:",
        @"createPresenterWithIdentifier:priority:",
        @"createPresenterForLayerTarget:identifier:priority:",
        @"modifyPresentationContext:",
        @"modifyDefaultPresentationContext:",
        @"setResizesHostedContext:",
        @"resizesHostedContext",
        @"sceneResizesHostedContext",
        @"setSceneResizesHostedContext:",
        @"sceneIfExists",
        @"existingSceneHandleForScene:",
        @"existingSceneHandleForPersistenceIdentifier:",
        @"existingSceneHandleForSceneIdentity:",
        @"applicationWithBundleIdentifier:",
        @"_createSceneForApplication:withOptions:completion:",
        @"windowScene",
        @"_uiPresentationManager",
        @"_setResizesHostedContext:",
        @"_setWindowLevel:",
    ];
}

// 全镜像 "类名 -> 镜像文件名" 映射。只用 objc_copyClassNamesForImage（不 realize）。
static NSDictionary<NSString *, NSString *> *MFClassImageMap(void) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p) continue;
        unsigned int cnt = 0;
        const char **names = objc_copyClassNamesForImage(path, &cnt);
        if (!names) continue;
        NSString *base = [p lastPathComponent];
        for (unsigned int j = 0; j < cnt; j++) {
            if (!names[j]) continue;
            NSString *cn = [NSString stringWithUTF8String:names[j]];
            if (cn && map[cn] == nil && base) map[cn] = base;
        }
        free((void *)names);
    }
    return map;
}

static NSString *MFOwnerSearchReport(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"==== MultiFloatProbe v%s · 关键 selector 全镜像归属搜索 ====\n", MF_PROBE_VERSION];
    [s appendString:@"方法：遍历全部已注册类的 class_copyMethodList；不 realize、不创建对象、不发消息。\n"];
    [s appendString:@"(只看 \"自有方法\"，继承命中不在此列出——那正是 v0.4.0 归属查询的盲区)\n\n"];

    NSArray<NSString *> *targets = MFOwnerTargets();
    NSUInteger n = targets.count;
    SEL *sels = (SEL *)calloc(n ? n : 1, sizeof(SEL));
    if (!sels) return @"(calloc 失败)\n";
    for (NSUInteger i = 0; i < n; i++) sels[i] = NSSelectorFromString(targets[i]);

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *owners = [NSMutableDictionary dictionary];
    for (NSString *t in targets) owners[t] = [NSMutableArray array];

    MFBeat("owners:imagemap");
    NSDictionary<NSString *, NSString *> *imgMap = MFClassImageMap();
    MFBeat("owners:imagemap:ok");

    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) { free(sels); return @"(objc_getClassList 返回 0)\n"; }
    Class *classes = (Class *)calloc((size_t)numClasses, sizeof(Class));
    if (!classes) { free(sels); return @"(类数组分配失败)\n"; }
    numClasses = objc_getClassList(classes, numClasses);
    [s appendFormat:@"已注册类 %d 个；类名→镜像映射 %lu 条；目标 selector %lu 个\n",
     numClasses, (unsigned long)imgMap.count, (unsigned long)n];

    MFBeat("owners:scan:begin");
    MFAppendTo(MF_OWNERSLOG, [NSString stringWithFormat:@"[owners] scan begin, classes=%d targets=%lu\n",
                              numClasses, (unsigned long)n]);
    for (int i = 0; i < numClasses; i++) {
        Class c = classes[i];
        if (!c) continue;
        if ((i % 500) == 0) {
            MFBeatf("owners:scan:%d", i);
            // 进度落盘：万一崩了，最后一行就是崩点附近的类序号
            MFAppendTo(MF_OWNERSLOG, [NSString stringWithFormat:@"[owners] i=%d/%d name=%s\n",
                                      i, numClasses, class_getName(c) ?: "?"]);
        }
        unsigned mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        if (!ms) continue;
        for (unsigned k = 0; k < mc; k++) {
            SEL sel = method_getName(ms[k]);
            if (!sel) continue;
            for (NSUInteger t = 0; t < n; t++) {
                if (sel != sels[t]) continue;
                const char *cn = class_getName(c);
                NSString *owner = cn ? [NSString stringWithUTF8String:cn] : @"?";
                if (!owner) owner = @"?";
                const char *e = method_getTypeEncoding(ms[k]);
                NSString *enc = e ? [NSString stringWithUTF8String:e] : @"?";
                if (!enc) enc = @"?";
                [owners[targets[t]] addObject:[NSString stringWithFormat:
                    @"      %@  enc=%@  img=%@\n", owner, enc, imgMap[owner] ?: @"?"]];
                break;
            }
        }
        free(ms);
    }
    free(classes);
    free(sels);
    MFBeat("owners:scan:end");

    for (NSString *t in targets) {
        NSArray<NSString *> *list = owners[t];
        [s appendFormat:@"\n%@\n  定义类 %lu 个:\n", t, (unsigned long)list.count];
        if (list.count == 0) {
            [s appendString:@"      (无类定义此 selector)\n"];
            continue;
        }
        NSUInteger cap = list.count > 40 ? 40 : list.count;
        for (NSUInteger i = 0; i < cap; i++) [s appendString:list[i]];
        if (list.count > cap) [s appendFormat:@"      ...（共 %lu 个，已截断）\n", (unsigned long)list.count];
    }
    [s appendString:@"\n==== 段 9 结束 ====\n"];
    return s;
}

#pragma mark - 段 7（新）：活体只读探测（闸门 + 分级 + 主线程 + 逐调用落盘）

// 取容器元素个数（显式类型化 objc_msgSend，避免 id 返回值被当成指针）
static NSUInteger MFCountOf(id container) {
    if (!container) return 0;
    if (![container respondsToSelector:@selector(count)]) return 0;
    @try {
        return ((NSUInteger (*)(id, SEL))objc_msgSend)(container, @selector(count));
    } @catch (NSException *e) {
        return 0;
    }
}

// 取容器第 i 个元素
static id MFObjectAt(id container, NSUInteger i) {
    if (!container) return nil;
    id arr = MFObjProp(container, @selector(allObjects));
    if (![arr respondsToSelector:@selector(objectAtIndex:)]) return nil;
    @try {
        return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(arr, @selector(objectAtIndex:), i);
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - 安全闸门（v0.5.0）

static int MFReadIntFile(const char *path, int dflt) {
    FILE *f = fopen(path, "r");
    if (!f) return dflt;
    int v = dflt;
    if (fscanf(f, "%d", &v) != 1) v = dflt;
    fclose(f);
    return v;
}

static void MFWriteIntFile(const char *path, int v) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%d\n", v);
    fflush(f);
    fclose(f);
}

static BOOL MFFileExists(const char *path) {
    return access(path, F_OK) == 0;
}

// 活体段专用日志：每条都立刻落盘（不再攒到函数返回，崩了也不丢前面已采到的数据）
static void MFLiveLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (line) MFAppendTo(MF_LIVELOG, line);
}

static void MFLiveStepStart(const char *tag) {
    MFBeatf("live:%s", tag);
    MFLiveLine(@">>> %s\n", tag);
}

static void MFLiveStepDone(const char *tag) {
    MFLiveLine(@"<<< %s ok\n", tag);
    MFBeatf("live:%s:ok", tag);
}

// ---------------- L1：枚举活着的 windowScene / sceneManager（v0.4.0 的 7.1 前半，已验证安全）----
static void MFLiveLevel1(void) {
    Class uiAppCls = objc_getClass("UIApplication");
    id uiApp = MFClassSharedInstance(uiAppCls);
    if (!uiApp) uiApp = MFObjProp((id)uiAppCls, @selector(sharedApplication));
    MFLiveLine(@"UIApplication = %@\n", MFClassOf(uiApp));

    MFLiveStepStart("l1.connectedScenes");
    id conn = MFObjProp(uiApp, @selector(connectedScenes));
    NSUInteger wsCount = MFCountOf(conn);
    MFLiveLine(@"connectedScenes = %@ count=%lu\n", MFClassOf(conn), (unsigned long)wsCount);
    MFLiveStepDone("l1.connectedScenes");

    for (NSUInteger i = 0; i < wsCount && i < 8; i++) {
        MFLiveStepStart("l1.windowScene");
        id ws = MFObjectAt(conn, i);
        if (ws) {
            MFLiveLine(@"  [windowScene %lu] %@\n", (unsigned long)i, MFClassOf(ws));
            id sm = MFObjProp(ws, @selector(sceneManager));
            MFLiveLine(@"      sceneManager = %@\n", MFClassOf(sm));
            id all = MFObjProp(sm, @selector(allScenes));
            MFLiveLine(@"      allScenes = %@ count=%lu\n",
                       MFClassOf(all), (unsigned long)MFCountOf(all));
        }
        MFLiveStepDone("l1.windowScene");
    }
}

// ---------------- L2：逐个 scene 的 identifier（v0.4.0 的 7.1 后半，已验证安全）----
static void MFLiveLevel2(void) {
    id uiApp = MFClassSharedInstance(objc_getClass("UIApplication"));
    id conn = MFObjProp(uiApp, @selector(connectedScenes));
    NSUInteger wsCount = MFCountOf(conn);
    for (NSUInteger i = 0; i < wsCount && i < 8; i++) {
        MFLiveStepStart("l2.allScenes");
        id ws = MFObjectAt(conn, i);
        if (ws) {
            id sm = MFObjProp(ws, @selector(sceneManager));
            id all = MFObjProp(sm, @selector(allScenes));
            NSUInteger sn = MFCountOf(all);
            MFLiveLine(@"  windowScene %lu → allScenes %lu 个:\n", (unsigned long)i, (unsigned long)sn);
            for (NSUInteger k = 0; k < sn && k < 80; k++) {
                id sc = MFObjectAt(all, k);
                if (!sc) continue;
                MFLiveLine(@"      - %@  id=%@\n",
                           MFClassOf(sc), MFStrProp(sc, @selector(identifier)) ?: @"?");
            }
        }
        MFLiveStepDone("l2.allScenes");
    }
}

// ---------------- L3：handle 反查 + 按 bundleID 找应用（v0.4.0 崩点前半）----
static void MFLiveLevel3(void) {
    // 3.1 SBApplicationController → SBApplication
    MFLiveStepStart("l3.appController");
    Class acc = objc_getClass("SBApplicationController");
    id ctl = MFClassSharedInstance(acc);
    MFLiveLine(@"SBApplicationController = %@ sharedInstance=%@\n", MFSafeClass(acc), MFClassOf(ctl));
    if (ctl) {
        MFLiveLine(@"  响应矩阵:\n%@", MFResponseMatrix(ctl, @[
            @"applicationWithBundleIdentifier:", @"applications", @"allApplications",
            @"applicationWithBundleIdentifier:createIfNecessary:",
            @"applicationWithBundleIdentifier:ifExists:"]));
    }
    MFLiveStepDone("l3.appController");

    for (NSString *bid in @[@"com.apple.mobilesafari", @"com.apple.Preferences", @"com.tencent.mqq"]) {
        MFLiveStepStart("l3.app");
        id app = nil;
        if (ctl && [ctl respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
            @try {
                app = ((id (*)(id, SEL, id))objc_msgSend)(ctl,
                        @selector(applicationWithBundleIdentifier:), bid);
            } @catch (NSException *e) { app = nil; }
        }
        MFLiveLine(@"  %@ → SBApplication = %@\n", bid, MFClassOf(app));
        if (app) {
            MFLiveLine(@"      响应矩阵:\n%@", MFResponseMatrix(app, @[
                @"bundleIdentifier", @"mainSceneHandle", @"sceneHandleForMainScene",
                @"supportsSplitView", @"supportsChamoisSceneResizing",
                @"applicationInfo", @"processState"]));
        }
        MFLiveStepDone("l3.app");
    }

    // 3.2 SBSceneManagerCoordinator → 按 persistenceIdentifier 找 handle
    MFLiveStepStart("l3.coordinator");
    Class coCls = objc_getClass("SBSceneManagerCoordinator");
    id co = MFClassSharedInstance(coCls);
    MFLiveLine(@"SBSceneManagerCoordinator = %@ sharedInstance=%@\n", MFSafeClass(coCls), MFClassOf(co));
    for (NSString *bid in @[@"com.apple.mobilesafari", @"com.tencent.mqq"]) {
        if (co && [co respondsToSelector:@selector(existingSceneHandleForPersistenceIdentifier:)]) {
            id h = nil;
            @try {
                h = ((id (*)(id, SEL, id))objc_msgSend)(co,
                        @selector(existingSceneHandleForPersistenceIdentifier:), bid);
            } @catch (NSException *e) { h = nil; }
            id sc = MFObjProp(h, @selector(sceneIfExists));
            MFLiveLine(@"  %@ → handle=%@ sceneIfExists=%@ id=%@\n",
                       bid, MFClassOf(h), MFClassOf(sc),
                       MFStrProp(sc, @selector(identifier)) ?: @"?");
            if (h) {
                MFLiveLine(@"      handle 响应矩阵:\n%@", MFResponseMatrix(h, @[
                    @"scene", @"sceneIfExists", @"application", @"persistenceIdentifier",
                    @"sceneIdentifier", @"displayIdentity"]));
            }
        } else {
            MFLiveLine(@"  %@ → coordinator 不响应 existingSceneHandleForPersistenceIdentifier:\n", bid);
        }
    }
    MFLiveStepDone("l3.coordinator");

    // 3.3 逐 scene 反查 handle（v0.4.0 崩点）
    id uiApp = MFClassSharedInstance(objc_getClass("UIApplication"));
    id conn = MFObjProp(uiApp, @selector(connectedScenes));
    NSUInteger wsCount = MFCountOf(conn);
    for (NSUInteger i = 0; i < wsCount && i < 8; i++) {
        MFLiveStepStart("l3.handleMap");
        id ws = MFObjectAt(conn, i);
        if (ws) {
            id sm = MFObjProp(ws, @selector(sceneManager));
            if (sm && [sm respondsToSelector:@selector(allScenes)]) {
                id all = MFObjProp(sm, @selector(allScenes));
                NSUInteger sn = MFCountOf(all);
                for (NSUInteger k = 0; k < sn && k < 40; k++) {
                    id sc = MFObjectAt(all, k);
                    if (!sc) continue;
                    id h = nil;
                    if ([sm respondsToSelector:@selector(existingSceneHandleForScene:)]) {
                        @try {
                            h = ((id (*)(id, SEL, id))objc_msgSend)(sm,
                                    @selector(existingSceneHandleForScene:), sc);
                        } @catch (NSException *e) { h = nil; }
                    }
                    id app = MFObjProp(h, @selector(application));
                    MFLiveLine(@"      scene id=%@ → handle=%@ app=%@ bid=%@ persistence=%@\n",
                               MFStrProp(sc, @selector(identifier)) ?: @"?",
                               MFClassOf(h), MFClassOf(app),
                               MFStrProp(app, @selector(bundleIdentifier)) ?: @"?",
                               MFStrProp(h, @selector(persistenceIdentifier)) ?: @"?");
                }
            }
        }
        MFLiveStepDone("l3.handleMap");
    }
}

// ---------------- L4：uiPresentationManager（v0.4.0 最大嫌疑，放最后）----
static void MFLiveLevel4(void) {
    id uiApp = MFClassSharedInstance(objc_getClass("UIApplication"));
    id conn = MFObjProp(uiApp, @selector(connectedScenes));
    NSUInteger wsCount = MFCountOf(conn);
    for (NSUInteger i = 0; i < wsCount && i < 8; i++) {
        id ws = MFObjectAt(conn, i);
        if (!ws) continue;
        id sm = MFObjProp(ws, @selector(sceneManager));
        if (!sm || ![sm respondsToSelector:@selector(allScenes)]) continue;
        id all = MFObjProp(sm, @selector(allScenes));
        NSUInteger sn = MFCountOf(all);
        for (NSUInteger k = 0; k < sn && k < 40; k++) {
            id sc = MFObjectAt(all, k);
            if (!sc) continue;
            MFLiveStepStart("l4.respondsTo");
            MFLiveLine(@"      scene %@  responds[uiPresentationManager]=%@ responds[presentationManager]=%@\n",
                       MFClassOf(sc),
                       [sc respondsToSelector:@selector(uiPresentationManager)] ? @"YES" : @"NO",
                       [sc respondsToSelector:@selector(presentationManager)] ? @"YES" : @"NO");
            MFLiveStepDone("l4.respondsTo");

            // 只对"真的定义了 uiPresentationManager 的类"动手，避免盲发消息
            Class scCls = object_getClass(sc);
            BOOL owns = scCls ? MFOwnsSelector(scCls, @selector(uiPresentationManager)) : NO;
            MFLiveLine(@"      定义类 own=%@  (defcls=%@)\n",
                       owns ? @"YES" : @"NO",
                       MFSafeClass(MFDefiningClass(scCls, @selector(uiPresentationManager))));

            MFLiveStepStart("l4.getPM");
            id pm = MFObjProp(sc, @selector(uiPresentationManager));
            MFLiveLine(@"      uiPresentationManager = %@\n", MFClassOf(pm));
            MFLiveStepDone("l4.getPM");

            if (pm) {
                MFLiveStepStart("l4.pmMatrix");
                MFLiveLine(@"      pm 响应矩阵:\n%@", MFResponseMatrix(pm, @[
                    @"createPresenterWithIdentifier:", @"createPresenterWithIdentifier:priority:",
                    @"createPresenterForLayerTarget:identifier:priority:",
                    @"modifyDefaultPresentationContext:", @"scene", @"snapshotContext"]));
                MFLiveStepDone("l4.pmMatrix");
            }
        }
    }
}

// ---------------- 闸门驱动 ----------------
static void MFRunLiveLevel(int level) {
    MFLiveLine(@"\n==== 活体段开始 level=%d pid=%d main=%d ====\n",
               level, (int)getpid(), (int)[NSThread isMainThread]);
    if (level >= 1) { MFLiveLine(@"[LVL 1 BEGIN]\n"); MFLiveLevel1(); MFLiveLine(@"[LVL 1 OK]\n"); }
    if (level >= 2) { MFLiveLine(@"[LVL 2 BEGIN]\n"); MFLiveLevel2(); MFLiveLine(@"[LVL 2 OK]\n"); }
    if (level >= 3) { MFLiveLine(@"[LVL 3 BEGIN]\n"); MFLiveLevel3(); MFLiveLine(@"[LVL 3 OK]\n"); }
    if (level >= 4) { MFLiveLine(@"[LVL 4 BEGIN]\n"); MFLiveLevel4(); MFLiveLine(@"[LVL 4 OK]\n"); }
    MFLiveLine(@"==== 活体段结束 level=%d ====\n", level);
    MFBeat("live:all-done");
}

#pragma mark - 段 8（新）：open 入口纯日志 hook

typedef void (*MFMSHookMessageEx_t)(Class cls, SEL sel, IMP imp, IMP *old);

static MFMSHookMessageEx_t MFHookBackend(void) {
    static MFMSHookMessageEx_t fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        void *p = dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        if (!p) p = dlsym(RTLD_DEFAULT, "_MSHookMessageEx");
        fn = (MFMSHookMessageEx_t)p;
    }
    return fn;
}

static IMP mf_orig_openApp = NULL;
static IMP mf_orig_openTrusted = NULL;
static IMP mf_orig_openUntrusted = NULL;
static IMP mf_orig_createScenePub = NULL;
static IMP mf_orig_createScenePriv = NULL;
static IMP mf_orig_createPresenter1 = NULL;
static IMP mf_orig_createPresenter2 = NULL;

static void MFLogOpenCall(const char *tag, id request, id options, id origin, id result) {
    @autoreleasepool {
        NSMutableString *m = [NSMutableString string];
        [m appendFormat:@"t=%ld pid=%d [%s] req=%@",
         (long)time(NULL), (int)getpid(), tag, MFClassOf(request)];
        NSString *bid = MFStrProp(request, @selector(bundleIdentifier));
        NSString *sid = MFStrProp(request, @selector(sceneIdentifier));
        if (bid) [m appendFormat:@" bid=%@", bid];
        if (sid) [m appendFormat:@" scene=%@", sid];
        id keys = MFObjProp(options, @selector(allKeys));
        if ([keys isKindOfClass:[NSArray class]]) {
            NSMutableArray *ks = [NSMutableArray array];
            for (id k in (NSArray *)keys) if ([k isKindOfClass:[NSString class]]) [ks addObject:k];
            [m appendFormat:@" optKeys=[%@]", [ks componentsJoinedByString:@","]];
        }
        [m appendFormat:@" origin=%@ result=%@\n", MFClassOf(origin), MFClassOf(result)];
        MFAppendTo(MF_HOOKLOG, m);
    }
}

static void mf_openApp(id self, SEL _cmd, id request, id options, id activationSettings, id origin, id result) {
    MFLogOpenCall("open", request, options, origin, result);
    if (mf_orig_openApp) {
        ((void (*)(id, SEL, id, id, id, id, id))mf_orig_openApp)(self, _cmd, request, options, activationSettings, origin, result);
    }
}

static void mf_openTrusted(id self, SEL _cmd, id app, id options, id activationSettings, id origin, id result) {
    MFLogOpenCall("open-trusted", app, options, origin, result);
    if (mf_orig_openTrusted) {
        ((void (*)(id, SEL, id, id, id, id, id))mf_orig_openTrusted)(self, _cmd, app, options, activationSettings, origin, result);
    }
}

static void mf_openUntrusted(id self, SEL _cmd, id app, id options, id activationSettings, id origin, id result) {
    MFLogOpenCall("open-untrusted", app, options, origin, result);
    if (mf_orig_openUntrusted) {
        ((void (*)(id, SEL, id, id, id, id, id))mf_orig_openUntrusted)(self, _cmd, app, options, activationSettings, origin, result);
    }
}

static id mf_createScenePub(id self, SEL _cmd, id definition, id parameters) {
    @autoreleasepool {
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:
            @"t=%ld [createScene:/initialParameters:] def=%@ id=%@\n",
            (long)time(NULL), MFClassOf(definition),
            MFStrProp(definition, @selector(identifier)) ?: @"?"]);
    }
    if (mf_orig_createScenePub) {
        return ((id (*)(id, SEL, id, id))mf_orig_createScenePub)(self, _cmd, definition, parameters);
    }
    return nil;
}

static id mf_createScenePriv(id self, SEL _cmd, id definition, id settings, id clientSettings,
                             id ctx, id remnant, id provider, id completion) {
    @autoreleasepool {
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:
            @"t=%ld [createScene:_settings:...] def=%@ id=%@ settings=%@ ctx=%@ remnant=%@\n",
            (long)time(NULL), MFClassOf(definition),
            MFStrProp(definition, @selector(identifier)) ?: @"?",
            MFClassOf(settings), MFClassOf(ctx), MFClassOf(remnant)]);
    }
    if (mf_orig_createScenePriv) {
        return ((id (*)(id, SEL, id, id, id, id, id, id, id))mf_orig_createScenePriv)(
            self, _cmd, definition, settings, clientSettings, ctx, remnant, provider, completion);
    }
    return nil;
}

static id mf_createPresenter1(id self, SEL _cmd, id identifier) {
    MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"t=%ld [createPresenterWithIdentifier:] pm=%@ id=%@ -> ...\n",
        (long)time(NULL), MFClassOf(self), identifier]);
    id r = mf_orig_createPresenter1
        ? ((id (*)(id, SEL, id))mf_orig_createPresenter1)(self, _cmd, identifier) : nil;
    MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"t=%ld [createPresenterWithIdentifier:] -> %@\n",
        (long)time(NULL), MFClassOf(r)]);
    return r;
}

static id mf_createPresenter2(id self, SEL _cmd, id identifier, long priority) {
    MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"t=%ld [createPresenterWithIdentifier:priority:] pm=%@ id=%@ prio=%ld -> ...\n",
        (long)time(NULL), MFClassOf(self), identifier, priority]);
    id r = mf_orig_createPresenter2
        ? ((id (*)(id, SEL, id, long))mf_orig_createPresenter2)(self, _cmd, identifier, priority) : nil;
    MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"t=%ld [createPresenterWithIdentifier:priority:] -> %@\n",
        (long)time(NULL), MFClassOf(r)]);
    return r;
}

static void MFInstallOne(Class cls, SEL sel, IMP imp, IMP *old, const char *label) {
    MFMSHookMessageEx_t hook = MFHookBackend();
    if (!hook) {
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"SKIP %s : hook backend unavailable\n", label]);
        return;
    }
    if (cls == Nil) {
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"SKIP %s : class missing\n", label]);
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"SKIP %s : method missing\n", label]);
        return;
    }
    @try {
        hook(cls, sel, imp, old);
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"OK   %s (enc=%s)\n", label,
                                method_getTypeEncoding(m) ?: "?"]);
    } @catch (NSException *e) {
        MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"FAIL %s : %@\n", label, e.reason]);
    }
}

static void MFInstallHooks(void) {
    MFBeat("hooks:enter");
    MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"\n==== MultiFloatProbe v%s hook 安装 t=%ld pid=%d ====\n",
                            MF_PROBE_VERSION, (long)time(NULL), (int)getpid()]);

    Class ws = objc_getClass("SBMainWorkspace");
    if (ws != Nil) {
        MFBeat("hooks:ws");
        MFInstallOne(ws, NSSelectorFromString(@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:"),
                     (IMP)mf_openApp, &mf_orig_openApp, "SBMainWorkspace._handleOpenApplicationRequest:");
        MFInstallOne(ws, NSSelectorFromString(@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:"),
                     (IMP)mf_openTrusted, &mf_orig_openTrusted, "SBMainWorkspace._handleTrustedOpenRequest:");
        MFInstallOne(ws, NSSelectorFromString(@"_handleUntrustedOpenRequestForApplication:options:activationSettings:origin:withResult:"),
                     (IMP)mf_openUntrusted, &mf_orig_openUntrusted, "SBMainWorkspace._handleUntrustedOpenRequest:");
    }

    Class fbsm = objc_getClass("FBSceneManager");
    if (fbsm != Nil) {
        MFBeat("hooks:fbsm");
        MFInstallOne(fbsm, NSSelectorFromString(@"createSceneWithDefinition:initialParameters:"),
                     (IMP)mf_createScenePub, &mf_orig_createScenePub, "FBSceneManager.createSceneWithDefinition:initialParameters:");
        MFInstallOne(fbsm, NSSelectorFromString(@"_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:"),
                     (IMP)mf_createScenePriv, &mf_orig_createScenePriv, "FBSceneManager._createSceneWithDefinition:");
    }

    Class pm = objc_getClass("UIScenePresentationManager");
    if (pm != Nil) {
        MFBeat("hooks:pm");
        MFInstallOne(pm, NSSelectorFromString(@"createPresenterWithIdentifier:"),
                     (IMP)mf_createPresenter1, &mf_orig_createPresenter1, "UIScenePresentationManager.createPresenterWithIdentifier:");
        MFInstallOne(pm, NSSelectorFromString(@"createPresenterWithIdentifier:priority:"),
                     (IMP)mf_createPresenter2, &mf_orig_createPresenter2, "UIScenePresentationManager.createPresenterWithIdentifier:priority:");
    }

    MFAppendTo(MF_HOOKLOG, @"==== hook 安装结束 ====\n");
    MFBeat("hooks:done");
}

#pragma mark - 主流程（分段落盘：每段独立写盘，段间崩溃不丢已有数据）

static void MFProbeRun(void) {
    @autoreleasepool {
        MFBeat("run:enter");
        NSMutableString *s = [NSMutableString string];

        // H 段 hook 只在闸门文件存在时安装（默认不装：hook 会全局改变 SpringBoard 行为）
        if (MFFileExists(MF_GATE_HOOKS)) {
            MFInstallHooks();
        } else {
            MFBeat("hooks:disabled");
        }

        MFBeat("sec:env");
        [s appendString:MFSectionEnv()];
        MFWrite(kSummary, s);
        MFBeat("ok:env");

        MFBeat("sec:classes");
        [s appendString:MFSectionClassInventory()];
        MFWrite(kSummary, s);
        MFBeat("ok:classes");

        MFBeat("sec:sel:whitelist");
        [s appendString:MFSectionSelectors(MFWhitelistClasses(), @"显式白名单")];
        MFWrite(kSummary, s);
        MFBeat("ok:sel:whitelist");

        MFBeat("sec:sel:image");
        NSArray *imgClasses = MFImageClassesFiltered();
        [s appendFormat:@"\n(镜像候选类 %lu 个)\n", (unsigned long)imgClasses.count];
        [s appendString:MFSectionSelectors(imgClasses, @"SpringBoard/BoardServices 镜像内 SB/FB/BK 类")];
        // 注意：这里不是全文结束，后面还有第三方类 / 结构 dump / selector 归属搜索
        [s appendString:@"\n==== 段 1-4 结束（非全文结束，勿据此外推）====\n"];
        MFWrite(kSummary, s);
        MFBeat("ok:sel:image");

        // --- E 第三方浮窗类定位 ---
        MFBeat("sec:thirdparty");
        MFWrite(kThird, MFSectionThirdParty());
        MFBeat("ok:thirdparty");

        // --- F 呈现链路结构 ---
        MFBeat("sec:structures");
        MFWrite(kMethods, MFBuildStructureReport());
        MFBeat("ok:structures");

        // --- 段 9：关键 selector 全镜像归属搜索（纯静态，无需实例）---
        // 段 9 是唯一"要遍历全部已注册类"的新动作，单独给它一个崩溃自解除标记。
        MFBeat("sec:owners");
        if (MFFileExists(MF_OWNERS_ATTEMPT)) {
            MFBeat("owners:skipped-after-crash");
            MFAppendTo(MF_STATELOG,
                @"[skip] 上次运行已在段 9 中断，本进程跳过段 9。\n"
                @"       想重试：Filza 删掉 /var/mobile/MFProbe-owners-attempt.txt 后 Respring。\n");
        } else {
            MFWriteIntFile(MF_OWNERS_ATTEMPT, 1);
            MFWrite(kOwners, MFOwnerSearchReport());
            unlink(MF_OWNERS_ATTEMPT);   // 段 9 成功 => 解除
        }
        MFBeat("ok:owners");

        // 活体段刻意不在这里跑：由 %ctor 按闸门调度到主线程
        MFBeat("run:done");
        unlink(MF_AUTORUN_ATTEMPT);      // 整轮安全段成功 => 解除自动段的标记
    }
}

%ctor {
    MFBeat("ctor:enter");
    MFAppendTo(MF_BOOTLOG, [NSString stringWithFormat:@"t=%ld pid=%d boot\n",
                            (long)time(NULL), (int)getpid()]);

    // 第一轮：安全自动段（后台队列，v0.3.0/v0.4.0 连续两轮验证不崩）。
    // 自解除：崩过一次则下次启动直接跳过 —— 从结构上杜绝"崩→重启→再崩→安全模式"。
    if (MFFileExists(MF_AUTORUN_ATTEMPT)) {
        MFBeat("autorun:skipped-after-crash");
        MFAppendTo(MF_STATELOG,
            @"[skip] 上次启动在自动段崩过，本轮跳过自动段。\n"
            @"       想重试：Filza 删掉 /var/mobile/MFProbe-autorun-attempt.txt 后 Respring。\n");
    } else {
        MFWriteIntFile(MF_AUTORUN_ATTEMPT, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            MFProbeRun();
        });
    }

    // 第二轮：活体段。闸门缺省关闭；崩过一次就自动不再尝试，
    // 因此不会出现 v0.4.0 那种"崩→重启→再崩→安全模式"的连锁。
    int gate = MFReadIntFile(MF_GATE_LIVE, 0);
    if (gate <= 0) {
        MFBeat("live:disabled");
        MFAppendTo(MF_STATELOG,
                   @"[skip] 活体段未启用：/var/mobile/MFProbe-live-gate.txt 不存在或内容 <=0\n");
    } else {
        if (gate > 4) gate = 4;
        int attempted = MFReadIntFile(MF_ATTEMPT, -1);
        if (attempted == gate) {
            MFBeat("live:skipped-after-crash");
            MFAppendTo(MF_STATELOG, [NSString stringWithFormat:
                @"[skip] level=%d 上次已尝试过且本进程是新起的 —— 说明上次就是崩在活体段。\n"
                @"       想再采一次：Filza 里删掉 /var/mobile/MFProbe-live-attempt.txt 后 Respring。\n", gate]);
        } else {
            // 先落"已尝试"标记再执行：即使崩了，下次启动也会自动跳过
            MFWriteIntFile(MF_ATTEMPT, gate);
            MFBeat("live:scheduled");
            // ★ 主线程执行：v0.4.0 在后台队列上调 uiPresentationManager 是最大失误
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                MFRunLiveLevel(gate);
            });
            // 第二次采样（同级别）：留给用户手动打开目标 App 后抓它的 scene
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                MFLiveLine(@"\n==== 第二次活体采样（t+80s，应已手动打开过目标 App）====\n");
                MFRunLiveLevel(gate);
            });
        }
    }
    MFBeat("ctor:exit");
}
