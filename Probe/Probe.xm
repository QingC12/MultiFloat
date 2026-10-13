// MultiFloatProbe v0.2.0 — SpringBoard 运行期探针
//
// 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
// 目的：在本机 iOS 版本上取得"真值"，补齐 analysis/missing-reverse-data.md 的 [VERIFY] 项：
//   1. 13 个已知 selector 在本机由哪个类真正实现（owner 映射）+ 真实 type encoding
//   2. 候选类的方法清单与 ivar 布局
//   3. 本机存在哪些 Scene / Split / Floating 相关类
//   4. 越狱实况（jbroot 真实路径、ellekit/substrate 加载项、本探针自身安装路径）
//
// v0.1.0 → v0.2.0 变更（针对"安装后进安全模式"的加固）：
//   - %ctor 第一件事就是用纯 POSIX open/write 写"心跳"，任何阶段崩溃都留下面包屑
//   - 采样拆成 4 段，每段结束立即落盘 → 崩溃时已产出的数据不丢
//   - 用 class_getInstanceMethod 替代 instancesRespondToSelector:（少一次消息派发）
//   - 日志目录改到 /var/mobile（Filza 直接可见，不受 roothide 路径重定向影响）
//
// 安全约束：纯读取 + 写文件；不 hook、不改任何对象状态；每段 @try/@catch；
// 后台队列执行，不阻塞 SpringBoard 主线程；不在 %ctor 里做任何重活。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>

static NSString *const kOutDir  = @"/var/mobile";
static NSString *const kSummary = @"MultiFloatProbe-summary.log";
static NSString *const kMethods = @"MultiFloatProbe-methods.log";

#define MF_HEARTBEAT "/var/mobile/MultiFloatProbe-heartbeat.log"

#pragma mark - 心跳（纯 POSIX，不依赖 ObjC 运行时/自动释放池，任何阶段都不会抛异常）

static void MFBeat(const char *stage) {
    int fd = open(MF_HEARTBEAT, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "t=%ld pid=%d stage=%s\n",
                     (long)time(NULL), getpid(), stage);
    if (n > 0) { ssize_t w = write(fd, buf, (size_t)n); (void)w; }
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
        NSString *n = NSStringFromClass(c);
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

static int MFGetClassList(Class **outClasses) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { *outClasses = NULL; return 0; }
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) { *outClasses = NULL; return 0; }
    count = objc_getClassList(classes, count);
    *outClasses = classes;
    return count;
}

static void MFWrite(const NSString *filename, const NSString *content) {
    @try {
        NSString *path = [kOutDir stringByAppendingPathComponent:(NSString *)filename];
        [(NSString *)content writeToFile:path atomically:YES
                                encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {
        MFBeat("write:exception");
    }
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

static NSArray *MFProbeClasses(void) {
    return @[
        @"SBMainWorkspace", @"SBWorkspace", @"SBSceneManager", @"SBMainDisplaySceneManager",
        @"SBSceneManagerCoordinator", @"SBApplicationController", @"SBApplication",
        @"SBApplicationSceneHandle", @"SBSceneHandle", @"SBWindowScene",
        @"FBSceneManager", @"FBScene", @"FBSceneHandle", @"FBSceneWorkspace",
        @"SBTransientOverlayPresenter", @"SBUIController", @"SBSwitcherController",
        @"SBMainSwitcherControllerCoordinator", @"SBFloatingDockController",
    ];
}

static NSArray *MFDumpAllClasses(void) {
    return @[
        @"SBMainWorkspace", @"SBSceneManager", @"SBSceneManagerCoordinator",
        @"SBApplicationSceneHandle", @"FBSceneManager", @"FBScene",
    ];
}

static NSArray *MFMethodKeywords(void) {
    return @[@"open", @"scene", @"split", @"float", @"window", @"mini", @"fullscreen",
             @"gesture", @"pan", @"press", @"reuse", @"destroy", @"present", @"transition",
             @"activate", @"layout", @"frame", @"resize", @"drag", @"close"];
}

#pragma mark - 分段构造

// 第 1 段：环境实况（最快最安全，先落盘）
static NSString *MFSectionEnv(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"==== MultiFloatProbe v0.2.0 · 环境实况 ====\n"];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"进程     : %@ (pid %d)\n", [[NSProcessInfo processInfo] processName], getpid()];
    [s appendFormat:@"bundle   : %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [s appendFormat:@"iOS      : %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [s appendFormat:@"osversion: %@\n", MFSysctl("kern.osversion")];
    [s appendFormat:@"设备     : %@ / %@\n", MFSysctl("hw.machine"), MFSysctl("hw.model")];
    [s appendFormat:@"探针版本 : 0.2.0 (roothide / arm64e)\n"];

    // 关键镜像路径：roothide 下 jbroot 为随机路径，本探针自身路径即真实安装位置
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

// 第 2 段：类清单
static NSString *MFSectionClassInventory(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"\n==== 类清单：名称含 Scene / Split / Floating / Workspace ====\n"];
    Class *classes = NULL;
    int count = MFGetClassList(&classes);
    if (!classes || count <= 0) {
        [s appendString:@"(class list 不可用)\n"];
        return s;
    }
    NSMutableArray *hit = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
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
    [s appendFormat:@"运行期类总数已扫描；匹配 %lu 个：\n", (unsigned long)sorted.count];
    for (NSString *n in sorted) [s appendFormat:@"  %@\n", n];
    return s;
}

// 第 3 段：13 个 selector 的真实归属（全类扫描，用 class_getInstanceMethod 定位定义类）
static NSString *MFSectionSelectors(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"\n==== 13 个已知 selector 的真实归属（全类扫描）====\n"];
    Class *classes = NULL;
    int count = MFGetClassList(&classes);
    if (!classes || count <= 0) {
        [s appendString:@"(class list 不可用)\n"];
        return s;
    }
    for (NSString *selStr in MFSelectors()) {
        SEL sel = NSSelectorFromString(selStr);
        NSMutableDictionary *defs = [NSMutableDictionary dictionary];
        NSUInteger responders = 0;
        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            if (c == Nil) continue;
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            responders++;
            Class d = MFDefiningClass(c, sel);
            if (d == Nil) continue;
            NSString *dn = NSStringFromClass(d);
            if (!dn || defs[dn]) continue;
            Method dm = class_getInstanceMethod(d, sel);
            const char *enc = dm ? method_getTypeEncoding(dm) : NULL;
            defs[dn] = enc ? [NSString stringWithUTF8String:enc] : @"?";
        }
        [s appendFormat:@"\n%@\n", selStr];
        if (responders == 0) {
            [s appendString:@"  归属: (本机无任何类响应此 selector)\n"];
            continue;
        }
        NSArray *keys = [[defs allKeys] sortedArrayUsingSelector:@selector(compare:)];
        [s appendFormat:@"  响应类 %lu 个；定义类 %lu 个：\n",
         (unsigned long)responders, (unsigned long)keys.count];
        for (NSString *dn in keys) {
            [s appendFormat:@"    %@  encoding=%@\n", dn, defs[dn]];
        }
    }
    free(classes);
    return s;
}

// 第 4 段：候选类方法/ivar 明细（独立文件）
static NSString *MFBuildMethodsReport(void) {
    NSMutableString *m = [NSMutableString string];
    [m appendString:@"==== MultiFloatProbe v0.2.0 · 方法/ivar 明细 ====\n"];
    NSArray *keywords = MFMethodKeywords();
    NSArray *fullDump = MFDumpAllClasses();
    for (NSString *clsName in MFProbeClasses()) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (cls == Nil) {
            [m appendFormat:@"\n### %@ —— 不存在\n", clsName];
            continue;
        }
        BOOL all = [fullDump containsObject:clsName];
        [m appendFormat:@"\n### %@  (%@)\n", clsName, all ? @"完整方法列表" : @"按关键词过滤"];
        [m appendFormat:@"继承链: %@\n", MFHierarchy(cls)];
        [m appendFormat:@"ivar:\n  %@\n", MFIvars(cls, YES)];
        [m appendFormat:@"方法:\n%@\n", MFMethods(cls, keywords, all, 600)];
    }
    [m appendString:@"\n==== COMPLETE ====\n"];
    return m;
}

#pragma mark - 主流程（分段落盘）

static void MFProbeRun(void) {
    @autoreleasepool {
        MFBeat("run:enter");
        NSMutableString *s = [NSMutableString string];

        @try {
            MFBeat("sec:env");
            [s appendString:MFSectionEnv()];
            MFWrite(kSummary, s);

            MFBeat("sec:classes");
            [s appendString:MFSectionClassInventory()];
            MFWrite(kSummary, s);

            MFBeat("sec:selectors");
            [s appendString:MFSectionSelectors()];
            [s appendString:@"\n==== COMPLETE ====\n"];
            MFWrite(kSummary, s);

            MFBeat("sec:methods");
            MFWrite(kMethods, MFBuildMethodsReport());

            MFBeat("run:done");
        } @catch (NSException *e) {
            MFBeat("run:exception");
            [s appendFormat:@"\n!! EXCEPTION %@ — %@\n", e.name, e.reason];
            MFWrite(kSummary, s);
        }
    }
}

%ctor {
    MFBeat("ctor:enter");
    // 等 SpringBoard 完全启动、类注册齐全后再采样（后台队列，不阻塞主线程）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        MFProbeRun();
    });
    MFBeat("ctor:exit");
}
