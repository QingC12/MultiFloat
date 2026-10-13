// MultiFloatProbe v0.3.0 — SpringBoard 运行期探针（崩溃规避版）
//
// 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
// ============ v0.2.0 → v0.3.0 变更（基于实测崩溃修复）============
// v0.2.0 实测结果：段1（环境）、段2（类清单，1342 项）均成功落盘，
// 但段3（全类 selector 扫描）无任何输出，随后 SpringBoard 崩溃进安全模式。
//
// 定位：段3 对全部 ~5000 个类逐个调用 class_getInstanceMethod()，该 API 会
//       realize 目标类（分配 class_rw_t、解析方法列表）。SpringBoard 里存在
//       大量被 roothide patch 过的私有类与第三方插件注入类，其中某一个在
//       realize 时踩到无效内存 → SpringBoard 挂掉 → 安全模式。
//
// 修复（三条同时上）：
//   1. 【收敛扫描面】不再全类扫描。候选类 = 显式白名单 + (SpringBoard 系镜像内
//      且类名以 SB/FB/BK/BB 开头的类)，用 objc_copyClassNamesForImage 取得，
//      该 API 不触发 realize。
//   2. 【崩溃可定位】每个候选类处理前写一条心跳 `cls:<类名>`，一旦仍崩，
//      心跳最后一行即崩溃类名。
//   3. 【分段落盘】白名单段与镜像段分别独立扫描、独立写盘：镜像段即使崩，
//      白名单段的结果也已安全落盘。
//
// 安全约束：纯读取；不 hook、不改任何对象状态；后台队列执行，不阻塞主线程。
// ==========================================================================

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
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

#define MF_HEARTBEAT "/var/mobile/MultiFloatProbe-heartbeat.log"

#pragma mark - 心跳（纯 POSIX，不依赖 ObjC 运行时/自动释放池）

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

#pragma mark - 候选类集合构造（全部不触发 realize）

// 显式白名单：已知 / 高度疑似承载 scene、workspace、floating 逻辑的类
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

// 镜像内类再按前缀收敛，只保留系统私有框架命名风格的核心类
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
        @"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:",
        @"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
        @"_handleUntrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
        @"_openURLCore:display:animating:activationSettings:origin:withResult:",
        @"openInSplit:",
        @"sceneHandle:reuseExistingScene:",
        @"createSceneWithDefinition:initialParameters:",
        @"destroyScene:withTransitionContext:",
        @"handlePanGesture:",
        @"handleLongPressGesture:",
        @"minimizeCurrentFloatingWindow",
        @"fullscreenCurrentFloatingWindow",
        @"closeCurrentFloatingWindow",
    ];
}

static NSArray *MFMethodKeywords(void) {
    return @[@"open", @"scene", @"split", @"float", @"window", @"mini", @"fullscreen",
             @"gesture", @"pan", @"press", @"reuse", @"destroy", @"present", @"transition",
             @"activate", @"layout", @"frame", @"resize", @"drag", @"close"];
}

#pragma mark - 分段构造

// 段 1：环境实况（最快最安全）
static NSString *MFSectionEnv(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"==== MultiFloatProbe v0.3.0 · 环境实况 ====\n"];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"进程     : %@ (pid %d)\n", [[NSProcessInfo processInfo] processName], (int)getpid()];
    [s appendFormat:@"bundle   : %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [s appendFormat:@"iOS      : %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [s appendFormat:@"osversion: %@\n", MFSysctl("kern.osversion")];
    [s appendFormat:@"设备     : %@ / %@\n", MFSysctl("hw.machine"), MFSysctl("hw.model")];
    [s appendFormat:@"探针版本 : 0.3.0 (roothide / arm64e)\n"];

    [s appendString:@"\n-- 关键已加载镜像（含本探针自身安装路径）--\n"];
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
            [low rangeOfString:@"vroot"].location != NSNotFound ||
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
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/usr/lib/libellekit.dylib",
        @"/var/jb/usr/lib/libellekit.dylib",
        @"/usr/lib/libsubstrate.dylib",
        @"/var/jb/usr/lib/libsubstrate.dylib",
        @"/var/mobile/MultiFloatProbe-heartbeat.log",
    ];
    for (NSString *p in paths) {
        [s appendFormat:@"  %@  ->  %@\n", p,
         [fm fileExistsAtPath:p] ? @"存在" : @"不存在"];
    }
    return s;
}

// 段 2：类清单（已验证安全：只用 objc_getClassList + class_getName）
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

// 段 3：selector 归属（限定候选类；逐类心跳；可被单独落盘）
static NSString *MFSectionSelectors(NSArray<NSString *> *classNames, NSString *label) {
    NSMutableString *s = [NSMutableString string];
    NSArray *sels = MFSelectors();
    [s appendFormat:@"\n==== 已知 selector 归属（限定：%@，候选类 %lu）====\n",
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
        MFBeatf("cls:%s", cn.UTF8String);   // ← 崩溃时最后一行即崩溃类
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

// 段 4：白名单类的方法 / ivar 明细（独立文件）
static NSString *MFBuildMethodsReport(void) {
    NSMutableString *m = [NSMutableString string];
    [m appendString:@"==== MultiFloatProbe v0.3.0 · 方法/ivar 明细 ====\n"];
    NSArray *keywords = MFMethodKeywords();
    NSArray *fullDump = @[
        @"SBMainWorkspace", @"SBSceneManager", @"SBSceneManagerCoordinator",
        @"SBApplicationSceneHandle", @"FBSceneManager", @"FBScene",
    ];
    for (NSString *clsName in MFWhitelistClasses()) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (cls == Nil) {
            [m appendFormat:@"\n### %@ —— 不存在\n", clsName];
            continue;
        }
        MFBeatf("mcls:%s", clsName.UTF8String);
        BOOL all = [fullDump containsObject:clsName];
        [m appendFormat:@"\n### %@  (%@)\n", clsName, all ? @"完整方法列表" : @"按关键词过滤"];
        [m appendFormat:@"继承链: %@\n", MFHierarchy(cls)];
        [m appendFormat:@"ivar:\n  %@\n", MFIvars(cls, YES)];
        [m appendFormat:@"方法:\n%@\n", MFMethods(cls, keywords, all, 600)];
    }
    [m appendString:@"\n==== COMPLETE ====\n"];
    return m;
}

#pragma mark - 主流程（分段落盘：每段独立写盘，段间崩溃不丢已有数据）

static void MFProbeRun(void) {
    @autoreleasepool {
        MFBeat("run:enter");
        NSMutableString *s = [NSMutableString string];

        MFBeat("sec:env");
        [s appendString:MFSectionEnv()];
        MFWrite(kSummary, s);
        MFBeat("ok:env");

        MFBeat("sec:classes");
        [s appendString:MFSectionClassInventory()];
        MFWrite(kSummary, s);
        MFBeat("ok:classes");

        // --- 3.1 白名单类（低风险，先落盘）---
        MFBeat("sec:sel:whitelist");
        [s appendString:MFSectionSelectors(MFWhitelistClasses(), @"显式白名单")];
        MFWrite(kSummary, s);
        MFBeat("ok:sel:whitelist");

        // --- 3.2 SpringBoard 系镜像内 SB/FB/BK 前缀类（较高风险，独立落盘）---
        MFBeat("sec:sel:image");
        NSArray *imgClasses = MFImageClassesFiltered();
        [s appendFormat:@"\n(镜像候选类 %lu 个)\n", (unsigned long)imgClasses.count];
        [s appendString:MFSectionSelectors(imgClasses, @"SpringBoard/BoardServices 镜像内 SB/FB/BK 类")];
        [s appendString:@"\n==== COMPLETE ====\n"];
        MFWrite(kSummary, s);
        MFBeat("ok:sel:image");

        // --- 4 方法明细 ---
        MFBeat("sec:methods");
        MFWrite(kMethods, MFBuildMethodsReport());

        MFBeat("run:done");
    }
}

%ctor {
    MFBeat("ctor:enter");
    // SpringBoard 完全启动、类注册齐全后再采样（后台队列，不阻塞主线程）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        MFProbeRun();
    });
    MFBeat("ctor:exit");
}
