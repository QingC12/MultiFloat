//
//  POCameraCompatibility.m
//  PullOverMF —— 【0.4.0】相机守护进程侧兼容（本 fork 拆包重写）
//
//  ── 问题（用户 log35 之后反馈）───────────────────────────────────────────────
//  PullOver 把 App 的**画面**搬进 SpringBoard 的浮窗里显示，但这个 App 自身仍处于
//  后台（BKS 应用状态 = background）。相机服务（cameracaptured）据此拒绝为它出帧
//  ⇒ 微信"扫一扫"、QQ 拍照等一律黑屏/失败。
//  上游的解法就是往相机守护进程注入、放宽"该 client 是否有前台相机权"的判定；
//  但上游把这份代码编进了**主 dylib** —— 而主 dylib 里有
//  `_OBJC_CLASS_$_UIApplication` / `_UIApplicationLaunchOptionsSourceApplicationKey` /
//  `_kCACornerCurveContinuous` 等**加载期即绑定**（non-lazy）的 UIKit / QuartzCore 符号。
//  相机守护进程不加载这两个框架，把主 dylib 注进去会在 dyld 绑定阶段直接
//  "Symbol not found" 崩掉相机服务 —— 比不修还糟。
//
//  ── 本 fork 的解法（拆包）────────────────────────────────────────────────────
//  把相机兼容**单独编成极小 dylib**（POCaptureCompat.dylib），
//  只依赖 libSystem / libobjc / Foundation / CoreFoundation，**零 UIKit、零 QuartzCore**，
//  且 plist 只注入 cameracaptured（Filter → Executables）。
//  主 dylib（PullOverMF.dylib）依旧**只注入 SpringBoard**，一行 hook 都没多加。
//
//  ── 与上游的差异（逐条）─────────────────────────────────────────────────────
//   1. 进程判定改**纯 C** `getprogname()`（原来用 NSProcessInfo/NSBundle；dylib 在守护
//      进程极早期加载时 Foundation 可能尚未就绪 —— 铁律 1）。
//   2. 自带日志 POCamLog()（纯 C、双路径兜底），不再依赖 MFDebugLog（主 dylib 的符号）。
//   3. hook 机制改 `method_setImplementation` + **Method 指针去重**。上游用
//      MSHookMessageEx 的**全局单变量**存原实现，一旦同一 selector 落在多个类上，
//      原实现会互相覆盖 ⇒ 无限递归 / 全崩。
//   4. 目标类**不再硬编码**：扫描类名含 FigCapture / CaptureClient / SessionMonitor /
//      ApplicationStateMonitor 的类，凡实现 hasBackgroundCameraAccess /
//      _resolveApplicationState 的都挂上（iOS 大类名变动自己兜住）。
//   5. `_resolveApplicationState` **去掉 iOS 14/15 版本门**（上游在 iOS 17 直接跳过，
//      于是"应用状态改判"这条腿根本没有）。
//   6. 客户端应用标识改**多候选属性名**（applicationID 等在 iOS 17 可能改名）。
//   7. 新增**诊断清单日志**：把扫到的类与"应用状态/前台"相关 selector 全打出来 ——
//      万一这版还不够，凭这份清单下一轮就能精确补 hook，不必再猜。
//

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <pthread.h>

#import "POCameraGrantState.h"

#pragma mark - 日志（纯 C，双路径兜底）

// 相机守护进程以 root 运行且带沙箱，/var/mobile 未必可写 ⇒ 退到 /tmp；
// 两个都失败就静默放弃（不影响功能，只是看不到诊断）。
#define POCamLogPathPrimary  "/var/mobile/PullOverMF.log"
#define POCamLogPathFallback "/tmp/PullOverMF-cam.log"

static pthread_mutex_t POCamLogLock = PTHREAD_MUTEX_INITIALIZER;
static FILE *POCamLogFile = NULL;
static BOOL POCamLogResolved = NO;

static void POCamLogEnsureOpen(void) {
    if (POCamLogResolved) {
        return;
    }
    POCamLogResolved = YES;   // 只探一次，避免反复撞沙箱
    POCamLogFile = fopen(POCamLogPathPrimary, "a");
    if (POCamLogFile == NULL) {
        POCamLogFile = fopen(POCamLogPathFallback, "a");
    }
    if (POCamLogFile != NULL) {
        setvbuf(POCamLogFile, NULL, _IONBF, 0);
    }
}

static void POCamLog(const char *format, ...) {
    if (format == NULL) {
        return;
    }
    char body[1024];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(body, sizeof(body), format, arguments);
    va_end(arguments);

    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
        now.tv_sec = time(NULL);
        now.tv_nsec = 0;
    }
    struct tm parts;
    time_t seconds = now.tv_sec;
    localtime_r(&seconds, &parts);
    char stamp[64];
    strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &parts);
    size_t used = strlen(stamp);
    if (used + 6 < sizeof(stamp)) {
        snprintf(stamp + used, sizeof(stamp) - used, ".%03ld", (long)(now.tv_nsec / 1000000));
    }

    pthread_mutex_lock(&POCamLogLock);
    POCamLogEnsureOpen();
    if (POCamLogFile != NULL) {
        fprintf(POCamLogFile, "%s [cam] %s\n", stamp, body);
    }
    pthread_mutex_unlock(&POCamLogLock);
}

#pragma mark - 目标进程判定

/// 【0.4.0】纯 C 判定（铁律 1）：不在相机守护进程里就立刻返回，什么都不做。
static BOOL POIsTargetCameraDaemon(void) {
    const char *name = getprogname();
    if (name == NULL) {
        return NO;
    }
    if (strcmp(name, "cameracaptured") == 0) {
        return YES;
    }
    if (strcmp(name, "mediaserverd") == 0) {   // iOS 14/15 的相机服务
        return YES;
    }
    return NO;
}

#pragma mark - 客户端标识与授权匹配

/// 【0.4.0】客户端应用标识**多候选**：iOS 大版本之间私有属性名改过（applicationID 等），
/// 逐个探测，命中任意一个即可。
static SEL POCameraClientIdentifierSelectors[8];
static size_t POCameraClientIdentifierSelectorCount = 0;

static void POCameraPrepareClientIdentifierSelectors(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *names[] = {
            "applicationID",
            "applicationIdentifier",
            "clientApplicationIdentifier",
            "applicationBundleIdentifier",
            "clientBundleIdentifier",
            "bundleIdentifier",
        };
        for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
            SEL selector = sel_registerName(names[index]);
            if (selector != NULL && POCameraClientIdentifierSelectorCount < 8) {
                POCameraClientIdentifierSelectors[POCameraClientIdentifierSelectorCount++] = selector;
            }
        }
    });
}

static NSString *POCameraClientApplicationIdentifier(id object) {
    if (object == nil) {
        return nil;
    }
    POCameraPrepareClientIdentifierSelectors();
    for (size_t index = 0; index < POCameraClientIdentifierSelectorCount; index++) {
        SEL selector = POCameraClientIdentifierSelectors[index];
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        } @catch (NSException *exception) {
            value = nil;
        }
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return (NSString *)value;
        }
    }
    return nil;
}

/// 授权命中时限频打一行日志（同一个 App 每 2 秒最多一条，免得刷满日志）。
/// 用文件级 static（与上游 POCameraGrantState.h 同一形式，ARC 下已验证可用），
/// 不用函数内 static 的 ObjC 指针，避免所有权歧义。
static NSString *POCamLastGrantLoggedClient;
static CFAbsoluteTime POCamLastGrantLoggedTime = 0;

static void POCamLogGrantOnce(NSString *client) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (POCamLastGrantLoggedClient != nil &&
        [POCamLastGrantLoggedClient isEqualToString:client] &&
        now - POCamLastGrantLoggedTime < 2.0) {
        return;
    }
    POCamLastGrantLoggedClient = [client copy];
    POCamLastGrantLoggedTime = now;
    POCamLog("浮窗 App 的前台相机授权已生效：%s", client.UTF8String);
}

static BOOL POCameraGrantMatchesClient(id object) {
    NSString *granted = POCameraForegroundGrantBundleIdentifier();
    if (granted.length == 0) {
        return NO;
    }
    NSString *client = POCameraClientApplicationIdentifier(object);
    if (client.length == 0 || ![client isEqualToString:granted]) {
        return NO;
    }
    POCamLogGrantOnce(client);
    return YES;
}

#pragma mark - Hook 表（Method 指针去重，避免原实现互相覆盖）

#define POCamMaxHooks 256

typedef struct {
    Method method;
    IMP original;
} POCamHookEntry;

static POCamHookEntry POCamHooks[POCamMaxHooks];
static int POCamHookCount = 0;
static pthread_mutex_t POCamHookLock = PTHREAD_MUTEX_INITIALIZER;

/// 取"该对象的这个方法"在挂 hook 之前的原实现。
/// 用 **Method 指针**做匹配：class_getInstanceMethod 沿父类链返回的正是同一个 Method
/// （继承的方法不会被复制），所以子类实例也能命中父类那一项。
static IMP POCamOriginalImplementationForObject(id object, SEL selector) {
    if (object == nil || selector == NULL) {
        return NULL;
    }
    IMP original = NULL;
    pthread_mutex_lock(&POCamHookLock);
    Class current = object_getClass(object);
    while (current != Nil && original == NULL) {
        Method resolved = class_getInstanceMethod(current, selector);
        if (resolved != NULL) {
            for (int index = 0; index < POCamHookCount; index++) {
                if (POCamHooks[index].method == resolved) {
                    original = POCamHooks[index].original;
                    break;
                }
            }
        }
        current = class_getSuperclass(current);
    }
    pthread_mutex_unlock(&POCamHookLock);
    return original;
}

static IMP POCamReplacementForSelector(SEL selector);

/// 挂一个 hook：同一个 Method（含被多个类继承的）只挂一次。
static BOOL POCamInstallHook(Class targetClass, SEL selector) {
    if (targetClass == Nil || selector == NULL) {
        return NO;
    }
    Method method = class_getInstanceMethod(targetClass, selector);
    if (method == NULL) {
        return NO;
    }
    IMP replacement = POCamReplacementForSelector(selector);
    if (replacement == NULL) {
        return NO;
    }

    pthread_mutex_lock(&POCamHookLock);
    for (int index = 0; index < POCamHookCount; index++) {
        if (POCamHooks[index].method == method) {
            pthread_mutex_unlock(&POCamHookLock);
            return NO;   // 已挂过（含从父类继承来的同一个 Method）
        }
    }
    if (POCamHookCount >= POCamMaxHooks) {
        pthread_mutex_unlock(&POCamHookLock);
        return NO;
    }
    POCamHooks[POCamHookCount].method = method;
    POCamHooks[POCamHookCount].original = method_getImplementation(method);
    POCamHookCount++;
    pthread_mutex_unlock(&POCamHookLock);

    method_setImplementation(method, replacement);
    return YES;
}

#pragma mark - 被替换的实现

/// FigCapture*Client.hasBackgroundCameraAccess —— 授权命中就放行（= 允许后台相机）。
static BOOL POCamHasBackgroundCameraAccess(id self, SEL _cmd) {
    if (POCameraGrantMatchesClient(self)) {
        return YES;
    }
    IMP original = POCamOriginalImplementationForObject(self, _cmd);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;
}

#pragma mark - 旧版 mediaserverd 状态机（iOS 14/15 遗留路径，保留但不再被版本门挡住）

static BOOL POCameraLegacyMonitorFlag(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) {
        return NO;
    }
    uint8_t *address = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
    return *(BOOL *)address;
}

static unsigned int POCameraLegacyMonitorUnsignedInt(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) {
        return 0;
    }
    uint8_t *address = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
    return *(unsigned int *)address;
}

static int POCameraLegacyMonitorClientType(id object) {
    SEL selector = @selector(clientType);
    if (object == nil || ![object respondsToSelector:selector]) {
        return 0;
    }
    return ((int (*)(id, SEL))objc_msgSend)(object, selector);
}

/// 借系统自己的映射函数把"BKS 应用状态"翻成"前台状态"（有就用，没有就算了）。
static BOOL POCameraForegroundApplicationState(id object, int *state) {
    Class monitorClass = object_getClass(object);
    SEL selector = NSSelectorFromString(@"_applicationStateForBKSApplicationState:clientType:");
    Method method = monitorClass ? class_getClassMethod(monitorClass, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4) {
        return NO;
    }
    int clientType = POCameraLegacyMonitorClientType(object);
    unsigned int bksApplicationState = POCameraLegacyMonitorUnsignedInt(object, "_bksApplicationState");
    int foregroundState = ((int (*)(id, SEL, unsigned int, int))objc_msgSend)(
        (id)monitorClass,
        selector,
        bksApplicationState,
        clientType);
    if (state) {
        *state = foregroundState;
    }
    return YES;
}

/// SessionMonitor._resolveApplicationState —— 授权命中就把"后台"改判成"前台"。
/// 【0.4.0】上游只在 iOS 14/15 挂这一条，iOS 16+ 直接跳过；现在**只要 selector 存在就挂**。
static int POCamResolveApplicationState(id self, SEL _cmd) {
    IMP original = POCamOriginalImplementationForObject(self, _cmd);
    int resolvedState = original != NULL ? ((int (*)(id, SEL))original)(self, _cmd) : 0;
    if (!POCameraGrantMatchesClient(self)) {
        return resolvedState;
    }
    if (POCameraLegacyMonitorFlag(self, "_invalid") ||
        POCameraLegacyMonitorFlag(self, "_deviceIsLocked")) {
        return resolvedState;
    }
    int foregroundState = 0;
    if (POCameraForegroundApplicationState(self, &foregroundState)) {
        return foregroundState;
    }
    return resolvedState;
}

static IMP POCamReplacementForSelector(SEL selector) {
    if (selector == NULL) {
        return NULL;
    }
    static SEL hasBackgroundSelector = NULL;
    static SEL resolveStateSelector = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hasBackgroundSelector = sel_registerName("hasBackgroundCameraAccess");
        resolveStateSelector = sel_registerName("_resolveApplicationState");
    });
    if (selector == hasBackgroundSelector) {
        return (IMP)POCamHasBackgroundCameraAccess;
    }
    if (selector == resolveStateSelector) {
        return (IMP)POCamResolveApplicationState;
    }
    return NULL;
}

#pragma mark - 扫描 + 安装

static int POCamReportedHookTotal = -1;
static int POCamReportedReportLength = -1;

static BOOL POCamClassNameIsCaptureRelated(const char *name) {
    if (name == NULL) {
        return NO;
    }
    return strstr(name, "FigCapture") != NULL ||
        strstr(name, "CaptureClient") != NULL ||
        strstr(name, "SessionMonitor") != NULL ||
        strstr(name, "ApplicationStateMonitor") != NULL;
}

/// 【0.4.0】不再硬编码两个类名：扫描全部已注册类，凡与相机采集相关的都尝试挂；
/// 同时把"应用状态/前台"相关 selector 打成清单（下一轮的精确补 hook 依据）。
static void POCamScanAndInstall(void) {
    unsigned int classCount = objc_getClassList(NULL, 0);
    if (classCount == 0) {
        return;
    }
    Class *classes = (Class *)calloc(classCount, sizeof(Class));
    if (classes == NULL) {
        return;
    }
    classCount = objc_getClassList(classes, (int)classCount);

    SEL hasBackgroundSelector = NSSelectorFromString(@"hasBackgroundCameraAccess");
    SEL resolveStateSelector = NSSelectorFromString(@"_resolveApplicationState");

    int scannedClasses = 0;
    int hookedBackground = 0;
    int hookedResolve = 0;
    char selectorReport[2048];
    selectorReport[0] = '\0';
    size_t reportLength = 0;

    for (unsigned int index = 0; index < classCount; index++) {
        Class candidate = classes[index];
        const char *className = class_getName(candidate);
        if (!POCamClassNameIsCaptureRelated(className)) {
            continue;
        }
        scannedClasses++;

        if (POCamInstallHook(candidate, hasBackgroundSelector)) {
            hookedBackground++;
        }
        if (POCamInstallHook(candidate, resolveStateSelector)) {
            hookedResolve++;
        }

        // 诊断清单：该类自身定义的、名字里带 前台/应用状态 的 getter/setter（参数数 ≤ 3）
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(candidate, &methodCount);
        if (methods == NULL) {
            continue;
        }
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            const char *selectorName = sel_getName(method_getName(methods[methodIndex]));
            if (selectorName == NULL) {
                continue;
            }
            BOOL interesting = strstr(selectorName, "Foreground") != NULL ||
                strstr(selectorName, "foreground") != NULL ||
                strstr(selectorName, "ApplicationState") != NULL ||
                strstr(selectorName, "applicationState") != NULL;
            if (!interesting || method_getNumberOfArguments(methods[methodIndex]) > 3) {
                continue;
            }
            int written = snprintf(selectorReport + reportLength,
                                   sizeof(selectorReport) - reportLength,
                                   "%s%s.%s",
                                   (reportLength > 0 ? " | " : ""),
                                   className,
                                   selectorName);
            if (written > 0 && reportLength + (size_t)written < sizeof(selectorReport)) {
                reportLength += (size_t)written;
            }
        }
        free(methods);
    }
    free(classes);

    int hookTotal = hookedBackground + hookedResolve;
    // 每次镜像加载都会跑一遍本函数；只在"hook 数或 selector 清单有变化"时打日志，免得刷屏。
    if (hookTotal == POCamReportedHookTotal && (int)reportLength == POCamReportedReportLength) {
        return;
    }
    POCamReportedHookTotal = hookTotal;
    POCamReportedReportLength = (int)reportLength;

    POCamLog("扫描：命中采集相关类 %d 个；本次新挂 hasBackgroundCameraAccess %d 个、_resolveApplicationState %d 个（累计 %d）",
             scannedClasses, hookedBackground, hookedResolve, hookTotal);
    if (reportLength > 0) {
        POCamLog("应用状态/前台相关 selector 清单：%s", selectorReport);
    } else {
        POCamLog("应用状态/前台相关 selector 清单：空（这些类还没加载进来，后续镜像加载时会再扫）");
    }
    if (hookTotal > 0) {
        POCamLog("相机守护进程兼容已就绪（浮窗里的 App 现在应可使用相机）");
    }
}

#pragma mark - 授权状态变化通知

static void POCameraGrantStateDidChange(CFNotificationCenterRef __unused center,
                                        void *__unused observer,
                                        CFStringRef __unused name,
                                        const void *__unused object,
                                        CFDictionaryRef __unused userInfo) {
    POCameraGrantStateInvalidateCaches();
}

static void POCameraRegisterStateObservers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, POCameraGrantStateDidChange,
                                        (__bridge CFStringRef)POCameraGrantStateChangedNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

#pragma mark - 引导

static void POCameraImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    POCamScanAndInstall();
}

static __attribute__((constructor)) void POCameraCompatibilityBootstrap(void) {
    if (!POIsTargetCameraDaemon()) {
        return;   // 非相机守护进程：立刻返回，什么都不碰（铁律 1）
    }

    POCamLog("=== PullOverMF 0.6.15 相机守护进程兼容已加载（进程 %s，pid %d）===",
             getprogname(), (int)getpid());

    POCameraRegisterStateObservers();
    // CMCapture.framework 的类可能在注入之后才注册 ⇒ 先立刻扫一次，再在每次镜像加载时重扫
    //（会命中新注册的类；重复扫描由 hook 表的 Method 去重兜住）。
    _dyld_register_func_for_add_image(POCameraImageDidLoad);
    POCameraImageDidLoad(NULL, 0);
}
