// MultiFloatProbe v0.4.0 — SpringBoard 运行期探针（蓝图补采版）
//
// 目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
// ============ v0.3.0 → v0.4.0 变更 ============
// v0.3.0 真机结果：全程跑完、无崩溃、未进安全模式（心跳末尾 run:done，summary 有 COMPLETE）。
// 崩因（全类 realize）已验证消除，因此本轮可以安全地扩展采集面。
//
// 本轮新增 4 段（都是"补蓝图盲区"）：
//   E. 第三方浮窗类定位       —— 全镜像 objc_copyClassNamesForImage（不 realize），
//                               查 SSFloatingManager / SSFloatingWindow / SSFloatingRootViewController
//                               到底由哪个 dylib 提供，并列出所有非系统镜像里的浮窗类。
//   F. 呈现链路结构 dump      —— _UIScenePresenter / UIScenePresentationManager / SBDeviceApplicationSceneEntity
//                               等"场景→呈现"关键类的完整 ivar + 方法 + type encoding。
//   G. 活体只读探测           —— 枚举当前活着的 FBScene，读它们的 uiPresentationManager，
//                               并按 bundleID 找 QQ 的 scene / scene handle。只读，不创建任何对象。
//   H. open 入口纯日志 hook   —— 通过 dlsym(RTLD_DEFAULT) 运行期解析 MSHookMessageEx，
//                               给 SBMainWorkspace / FBSceneManager / UIScenePresentationManager
//                               的关键方法装 passthrough hook，只记录不改变行为。
//                               （记忆约束：不能依赖固定路径 dlopen ellekit/substrate）
//
// 安全约束：不创建 scene / 不创建 presenter / 不改任何对象状态；后台队列执行，不阻塞主线程。
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
static NSString *const kLive    = @"MultiFloatProbe-live.log";

#define MF_HEARTBEAT  "/var/mobile/MultiFloatProbe-heartbeat.log"
#define MF_HOOKLOG    "/var/mobile/MultiFloatProbe-hooks.log"

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
    [s appendString:@"==== MultiFloatProbe v0.4.0 · 环境实况 ====\n"];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"进程     : %@ (pid %d)\n", [[NSProcessInfo processInfo] processName], (int)getpid()];
    [s appendFormat:@"bundle   : %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [s appendFormat:@"iOS      : %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [s appendFormat:@"osversion: %@\n", MFSysctl("kern.osversion")];
    [s appendFormat:@"设备     : %@ / %@\n", MFSysctl("hw.machine"), MFSysctl("hw.model")];
    [s appendFormat:@"探针版本 : 0.4.0 (roothide / arm64e)\n"];

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
    [m appendString:@"==== MultiFloatProbe v0.4.0 · 呈现链路结构 ====\n"];
    NSArray *keywords = MFMethodKeywords();
    NSArray *full = MFDetailClasses();

    NSMutableArray *list = [NSMutableArray array];
    [list addObjectsFromArray:full];
    // 追加：SSFloating* 三类（若存在则完整 dump）
    for (NSString *t in @[@"SSFloatingManager", @"SSFloatingWindow", @"SSFloatingRootViewController"]) {
        [list addObject:t];
    }

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
    [m appendString:@"\n==== COMPLETE ====\n"];
    return m;
}

#pragma mark - 段 7（新）：活体只读探测

static NSMutableString *gLive = nil;

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

static NSString *MFSectionLive(void) {
    gLive = [NSMutableString string];
    [gLive appendString:@"==== 活体只读探测（不创建任何对象）====\n"];
    [gLive appendFormat:@"时间: %@\n\n", [NSDate date]];

    // --- 7.1 UIApplication.connectedScenes → 每个 window scene 的 SBSceneManager ---
    MFBeat("live:uiapp");
    Class uiAppCls = objc_getClass("UIApplication");
    id uiApp = MFClassSharedInstance(uiAppCls);
    if (!uiApp) uiApp = MFObjProp((id)uiAppCls, @selector(sharedApplication));
    [gLive appendFormat:@"UIApplication.sharedApplication = %@\n", MFClassOf(uiApp)];

    id conn = MFObjProp(uiApp, @selector(connectedScenes));
    [gLive appendFormat:@"connectedScenes = %@ (count=%lu)\n",
     MFClassOf(conn), [conn respondsToSelector:@selector(count)] ? (unsigned long)[conn count] : 0UL];
    if ([conn respondsToSelector:@selector(allObjects)]) {
        id arr = MFObjProp(conn, @selector(allObjects));
        if ([arr respondsToSelector:@selector(count)]) {
            NSUInteger n = (NSUInteger)[arr count];
            for (NSUInteger i = 0; i < n && i < 12; i++) {
                id ws = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(arr, @selector(objectAtIndex:), i);
                [gLive appendFormat:@"\n  [windowScene %lu] %@\n", (unsigned long)i, MFClassOf(ws)];
                id sm = MFObjProp(ws, @selector(sceneManager));
                [gLive appendFormat:@"      sceneManager = %@\n", MFClassOf(sm)];
                id all = MFObjProp(sm, @selector(allScenes));
                [gLive appendFormat:@"      allScenes = %@\n", MFClassOf(all)];
                if ([all respondsToSelector:@selector(allObjects)]) {
                    id sarr = MFObjProp(all, @selector(allObjects));
                    NSUInteger sn = [sarr respondsToSelector:@selector(count)] ? (NSUInteger)[sarr count] : 0;
                    [gLive appendFormat:@"      allScenes count = %lu\n", (unsigned long)sn];
                    for (NSUInteger k = 0; k < sn && k < 60; k++) {
                        id sc = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(sarr, @selector(objectAtIndex:), k);
                        NSString *sid = MFStrProp(sc, @selector(identifier));
                        [gLive appendFormat:@"        - %@ id=%@\n", MFClassOf(sc), sid ?: @"?"];
                    }
                }
            }
        }
    }

    // --- 7.2 逐个 windowScene 做 scene→handle 反查（同上一段的场景对象复用不了，单独再来一次）---
    MFBeat("live:handleMap");
    [gLive appendString:@"\n---- scene → sceneHandle 反查 ----\n"];
    if ([conn respondsToSelector:@selector(allObjects)]) {
        id arr = MFObjProp(conn, @selector(allObjects));
        NSUInteger n = [arr respondsToSelector:@selector(count)] ? (NSUInteger)[arr count] : 0;
        for (NSUInteger i = 0; i < n && i < 12; i++) {
            id ws = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(arr, @selector(objectAtIndex:), i);
            id sm = MFObjProp(ws, @selector(sceneManager));
            if (!sm || ![sm respondsToSelector:@selector(allScenes)]) continue;
            id all = MFObjProp(sm, @selector(allScenes));
            id sarr = MFObjProp(all, @selector(allObjects));
            NSUInteger sn = [sarr respondsToSelector:@selector(count)] ? (NSUInteger)[sarr count] : 0;
            for (NSUInteger k = 0; k < sn && k < 60; k++) {
                id sc = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(sarr, @selector(objectAtIndex:), k);
                NSString *sid = MFStrProp(sc, @selector(identifier));
                id h = nil;
                if ([sm respondsToSelector:@selector(existingSceneHandleForScene:)]) {
                    @try {
                        h = ((id (*)(id, SEL, id))objc_msgSend)(sm, @selector(existingSceneHandleForScene:), sc);
                    } @catch (NSException *e) { h = nil; }
                }
                [gLive appendFormat:@"  scene id=%@ -> handle=%@\n", sid ?: @"?", MFClassOf(h)];
                if (h) {
                    id app = MFObjProp(h, @selector(application));
                    NSString *bid = MFStrProp(app, @selector(bundleIdentifier));
                    [gLive appendFormat:@"      handle.application=%@ bid=%@ persistence=%@\n",
                     MFClassOf(app), bid ?: @"?", MFStrProp(h, @selector(persistenceIdentifier)) ?: @"?"];
                }
                // scene 的呈现管理器探测（只读）
                NSString *pmLine = nil;
                for (NSString *pmSel in @[@"uiPresentationManager", @"presentationManager"]) {
                    SEL sl = NSSelectorFromString(pmSel);
                    if (![sc respondsToSelector:sl]) continue;
                    id pm = MFObjProp(sc, sl);
                    pmLine = [NSString stringWithFormat:@"      %@ = %@  createPresenterWithIdentifier:priority:=%@  createPresenterForLayerTarget:identifier:priority:=%@\n",
                              pmSel, MFClassOf(pm),
                              [pm respondsToSelector:@selector(createPresenterWithIdentifier:priority:)] ? @"YES" : @"NO",
                              [pm respondsToSelector:@selector(createPresenterForLayerTarget:identifier:priority:)] ? @"YES" : @"NO"];
                    [gLive appendString:pmLine];
                }
            }
        }
    }

    // --- 7.3 QQ 应用对象 + 关键 selector 响应矩阵 ---
    MFBeat("live:qq");
    [gLive appendString:@"\n---- 目标应用（com.tencent.mqq）解析 ----\n"];
    Class acc = objc_getClass("SBApplicationController");
    id ctl = MFClassSharedInstance(acc);
    [gLive appendFormat:@"SBApplicationController = %@  sharedInstance=%@\n", MFSafeClass(acc), MFClassOf(ctl)];
    [gLive appendFormat:@"  controller 响应矩阵:\n%@", MFResponseMatrix(ctl, @[
        @"applicationWithBundleIdentifier:", @"applications", @"allApplications",
        @"applicationWithBundleIdentifier:createIfNecessary:", @"applicationWithBundleIdentifier:ifExists:"])];

    id qq = nil;
    if (ctl && [ctl respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
        @try {
            qq = ((id (*)(id, SEL, id))objc_msgSend)(ctl, @selector(applicationWithBundleIdentifier:), @"com.tencent.mqq");
        } @catch (NSException *e) { qq = nil; }
    }
    [gLive appendFormat:@"QQ SBApplication = %@  bundleIdentifier=%@\n",
     MFClassOf(qq), MFStrProp(qq, @selector(bundleIdentifier)) ?: @"?"];
    [gLive appendFormat:@"  SBApplication 响应矩阵:\n%@", MFResponseMatrix(qq, @[
        @"bundleIdentifier", @"mainSceneHandle", @"sceneHandleForMainScene",
        @"supportsMultiWindowLayoutsForSwitcherWindowManagementStyle:displayIdentity:",
        @"supportsSplitView", @"supportsChamoisSceneResizing",
        @"applicationInfo", @"processState"])];

    // entity 构造路径的存在性（只查 respondsToSelector，不真的构造）
    Class entCls = objc_getClass("SBDeviceApplicationSceneEntity");
    [gLive appendFormat:@"\nSBDeviceApplicationSceneEntity = %@\n", MFSafeClass(entCls)];
    [gLive appendFormat:@"  实例响应矩阵（对 alloc 出来的实体实例不构造，只查类方法/实例方法存在性）:\n"];
    for (NSString *selStr in @[
        @"initWithApplicationForMainDisplay:generatingNewPrimarySceneIfRequired:",
        @"initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:",
        @"initWithApplication:sceneHandleProvider:displayIdentity:",
        @"sceneHandle"]) {
        SEL sl = NSSelectorFromString(selStr);
        BOOL has = entCls && (class_getInstanceMethod(entCls, sl) != NULL);
        [gLive appendFormat:@"  %@ %@\n", has ? @"YES" : @"NO ", selStr];
    }

    [gLive appendString:@"\n==== LIVE COMPLETE ====\n"];
    return gLive;
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
    MFAppendTo(MF_HOOKLOG, [NSString stringWithFormat:@"\n==== MultiFloatProbe v0.4.0 hook 安装 t=%ld pid=%d ====\n",
                            (long)time(NULL), (int)getpid()]);

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

        // H 段先装 hook —— 这样探针期间的 open 请求都能被抓到
        MFInstallHooks();

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
        [s appendString:@"\n==== COMPLETE ====\n"];
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

        // --- G 活体只读探测（风险最高，放最后）---
        MFBeat("sec:live");
        MFWrite(kLive, MFSectionLive());
        MFBeat("ok:live");

        MFBeat("run:done");
    }
}

%ctor {
    MFBeat("ctor:enter");
    // SpringBoard 完全启动、类注册齐全后再采样（后台队列，不阻塞主线程）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        MFProbeRun();
    });
    MFBeat("ctor:exit");
}
