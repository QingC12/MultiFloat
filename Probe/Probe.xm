// MultiFloatProbe — SpringBoard 运行期探针（只读，不 Hook 任何方法）
//
// 目的：在本机 iOS 版本上取得"真值"，补齐 analysis/missing-reverse-data.md 中
// 的 [VERIFY] 项：
//   1. 13 个已知 selector 在本机由哪个类真正实现（owner 映射）
//   2. 这些方法的真实 type encoding（返回类型 / 参数类型 / ABI）
//   3. 候选类的方法清单与 ivar 布局
//   4. 本机存在哪些 Scene / Split / Floating 相关类
//   5. 越狱环境与钩子后端（ellekit / substrate）实况
//
// 安全约束：纯读取 + 写文件；不 hook、不改任何对象状态；全程 @try/@catch；
// 在后台队列执行，不阻塞 SpringBoard 主线程。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <unistd.h>

static NSString *const kLogDir   = @"/var/mobile/Library/Logs";
static NSString *const kMediaDir = @"/var/mobile/Media/MultiFloatProbe";
static NSString *const kSummary  = @"MultiFloatProbe-summary.log";
static NSString *const kMethods  = @"MultiFloatProbe-methods.log";

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
        [parts addObject:NSStringFromClass(c)];
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
            [items addObject:[NSString stringWithUTF8String:name] ?: @"?"];
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

static NSArray *MFAllClassNames(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return @[];
    count = objc_getClassList(classes, count);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (name) [names addObject:name];
    }
    free(classes);
    return names;
}

static NSArray *MFLoadedImagesMatching(NSArray *needles) {
    NSMutableArray *hits = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (!path) continue;
        NSString *lower = [path lowercaseString];
        for (NSString *needle in needles) {
            if ([lower rangeOfString:needle].location != NSNotFound) {
                [hits addObject:path];
                break;
            }
        }
    }
    return hits;
}

static void MFWriteBoth(NSString *content, NSString *filename) {
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kLogDir withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:[kLogDir stringByAppendingPathComponent:filename] atomically:YES];
    [fm createDirectoryAtPath:kMediaDir withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:[kMediaDir stringByAppendingPathComponent:filename] atomically:YES];
}

#pragma mark - 探针主体

static NSArray *MFProbeSelectors(void) {
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

static NSString *MFBuildSummary(void) {
    NSMutableString *s = [NSMutableString string];

    NSDateFormatter *fmt = [NSDateFormatter new];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *now = [fmt stringFromDate:[NSDate date]];

    [s appendString:@"==== MultiFloatProbe summary ====\n"];
    [s appendFormat:@"时间        : %@\n", now];
    [s appendFormat:@"进程        : %@ (pid %d)\n", [[NSProcessInfo processInfo] processName], getpid()];
    [s appendFormat:@"bundle      : %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [s appendFormat:@"iOS         : %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [s appendFormat:@"iOS build   : %@\n", MFSysctl("kern.osversion")];
    [s appendFormat:@"设备        : %@ / %@\n", MFSysctl("hw.machine"), MFSysctl("hw.model")];

    NSFileManager *fm = [NSFileManager defaultManager];
    [s appendFormat:@"rootless    : /var/jb %@\n", [fm fileExistsAtPath:@"/var/jb"] ? @"存在" : @"不存在"];
    NSArray *backendPaths = @[
        @"/var/jb/usr/lib/libellekit.dylib", @"/usr/lib/libellekit.dylib",
        @"/var/jb/usr/lib/libsubstrate.dylib", @"/usr/lib/libsubstrate.dylib",
        @"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        @"/usr/lib/libhooker.dylib", @"/var/jb/usr/lib/libhooker.dylib",
    ];
    for (NSString *p in backendPaths) {
        if ([fm fileExistsAtPath:p]) [s appendFormat:@"后端文件    : %@ (存在)\n", p];
    }
    [s appendFormat:@"MultiFloat  : %@\n",
        [fm fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/MultiFloat.dylib"]
            ? @"dylib 已安装" : @"dylib 未找到"];
    [s appendString:@"已加载镜像(ellekit/substrate/inject/multifloat):\n"];
    NSArray *images = MFLoadedImagesMatching(@[@"ellekit", @"substrate", @"inject", @"multifloat"]);
    if (images.count == 0) {
        [s appendString:@"  (无匹配)\n"];
    } else {
        for (NSString *img in images) [s appendFormat:@"  %@\n", img];
    }

    NSArray *allClasses = MFAllClassNames();
    [s appendFormat:@"\n运行期类总数: %lu\n", (unsigned long)allClasses.count];

    [s appendString:@"\n==== 1) 已知 selector 的真实归属（全类扫描）====\n"];
    NSUInteger scanned = 0;
    for (NSString *selString in MFProbeSelectors()) {
        SEL sel = NSSelectorFromString(selString);
        NSMutableArray *responders = [NSMutableArray array];
        for (NSString *clsName in allClasses) {
            Class cls = objc_getClass(clsName.UTF8String);
            if (cls == Nil) continue;
            if ([cls instancesRespondToSelector:sel]) [responders addObject:clsName];
        }
        scanned++;
        [s appendFormat:@"\n%@\n", selString];
        if (responders.count == 0) {
            [s appendString:@"  归属: (本机无任何类响应此 selector)\n"];
            continue;
        }
        [s appendFormat:@"  响应类 %lu 个\n", (unsigned long)responders.count];
        NSUInteger shown = MIN(responders.count, (NSUInteger)10);
        for (NSUInteger i = 0; i < shown; i++) {
            NSString *clsName = responders[i];
            Class cls = objc_getClass(clsName.UTF8String);
            Class def = MFDefiningClass(cls, sel);
            Method m = class_getInstanceMethod(cls, sel);
            const char *enc = m ? method_getTypeEncoding(m) : NULL;
            BOOL direct = (def == cls);
            [s appendFormat:@"    %@%@  <- 定义于 %@  encoding=%s\n",
             clsName,
             direct ? @" [直接实现]" : @"",
             def ? NSStringFromClass(def) : @"?",
             enc ? enc : "?"];
        }
        if (responders.count > shown) {
            [s appendFormat:@"    ... 其余 %lu 个类省略\n", (unsigned long)(responders.count - shown)];
        }
    }
    [s appendFormat:@"\n(共扫描 selector %lu 个)\n", (unsigned long)scanned];

    [s appendString:@"\n==== 2) 候选类存在性与概况 ====\n"];
    for (NSString *clsName in MFProbeClasses()) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (cls == Nil) {
            [s appendFormat:@"\n%@ : 不存在\n", clsName];
            continue;
        }
        unsigned mcount = 0;
        Method *ms = class_copyMethodList(cls, &mcount);
        if (ms) free(ms);
        unsigned icount = 0;
        Ivar *iv = class_copyIvarList(cls, &icount);
        if (iv) free(iv);
        [s appendFormat:@"\n%@\n  继承链: %@\n  自有方法 %u / 自有 ivar %u\n  ivar: %@\n",
         clsName, MFHierarchy(cls), mcount, icount, MFIvars(cls, NO)];
    }

    [s appendString:@"\n==== PROBE COMPLETE ====\n"];
    return s;
}

static NSString *MFBuildMethods(void) {
    NSMutableString *m = [NSMutableString string];
    [m appendString:@"==== MultiFloatProbe 方法/ivar 明细 ====\n"];

    [m appendString:@"\n-- A. 候选类方法明细 --\n"];
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

    [m appendString:@"\n-- B. 全类清单：名称含 Scene / Split / Floating --\n"];
    NSArray *allClasses = MFAllClassNames();
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *name in allClasses) {
        if ([name rangeOfString:@"Scene"].location != NSNotFound ||
            [name rangeOfString:@"Split"].location != NSNotFound ||
            [name rangeOfString:@"Floating"].location != NSNotFound) {
            [hits addObject:name];
        }
    }
    NSArray *related = [hits sortedArrayUsingSelector:@selector(compare:)];
    [m appendFormat:@"共 %lu 个:\n", (unsigned long)related.count];
    for (NSString *name in related) [m appendFormat:@"  %@\n", name];

    [m appendString:@"\n==== PROBE COMPLETE ====\n"];
    return m;
}

static void MFProbeRun(void) {
    @autoreleasepool {
        NSDate *start = [NSDate date];
        @try {
            NSString *summary = MFBuildSummary();
            NSString *methods = MFBuildMethods();
            NSString *footer = [NSString stringWithFormat:
                @"\n耗时 %.2fs | summary %lu 字节 / methods %lu 字节\n输出: %@/%@\n",
                -[start timeIntervalSinceNow],
                (unsigned long)[summary lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                (unsigned long)[methods lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                kLogDir, kSummary];
            MFWriteBoth([summary stringByAppendingString:footer], kSummary);
            MFWriteBoth([methods stringByAppendingString:footer], kMethods);
            NSLog(@"[MultiFloatProbe] done in %.2fs", -[start timeIntervalSinceNow]);
        } @catch (NSException *e) {
            NSString *err = [NSString stringWithFormat:
                @"[MultiFloatProbe] EXCEPTION: %@ — %@\n%@\n",
                e.name, e.reason, [e callStackSymbols]];
            MFWriteBoth(err, @"MultiFloatProbe-error.log");
            NSLog(@"[MultiFloatProbe] exception: %@", e);
        }
    }
}

%ctor {
    // 等 SpringBoard 完成启动、运行时类注册齐全后再采样（后台队列，不阻塞主线程）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MFProbeRun();
    });
}
