#import "POExternalActivationCoordinator.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ContextHostManager.h"
#import "POApplicationHelper.h"
#import "POXWindow.h"

typedef void (^POExternalOpenCompletion)(NSError *error);

static id POExternalReadObject(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *POExternalBundleIdentifier(id object) {
    id value = POExternalReadObject(object, NSSelectorFromString(@"bundleIdentifier"));
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *POExternalBundleIdentifierOrString(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        return object;
    }
    return POExternalBundleIdentifier(object);
}

static NSString *POExternalStringConstant(const char *symbolName) {
    if (!symbolName) {
        return nil;
    }
    void *address = dlsym(RTLD_DEFAULT, symbolName);
    if (!address) {
        return nil;
    }
    NSString * __unsafe_unretained *symbol = (NSString * __unsafe_unretained *)address;
    return [*symbol isKindOfClass:[NSString class]] ? *symbol : nil;
}

static NSString *POExternalActivateSuspendedOptionKey(void) {
    static NSString *key;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        key = POExternalStringConstant("FBSOpenApplicationOptionKeyActivateSuspended");
    });
    return key;
}

static NSString *POExternalPayloadOptionsKey(void) {
    static NSString *key;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        key = POExternalStringConstant("FBSOpenApplicationOptionKeyPayloadOptions");
    });
    return key;
}

static id POExternalOpenOptions(id request) {
    return POExternalReadObject(request, NSSelectorFromString(@"options"));
}

static NSDictionary *POExternalOpenOptionsDictionary(id request) {
    id options = POExternalOpenOptions(request);
    id dictionary = [options isKindOfClass:[NSDictionary class]]
        ? options
        : POExternalReadObject(options, NSSelectorFromString(@"dictionary"));
    return [dictionary isKindOfClass:[NSDictionary class]] ? dictionary : nil;
}

static NSURL *POExternalOpenURL(id request) {
    id options = POExternalOpenOptions(request);
    id value = POExternalReadObject(options, NSSelectorFromString(@"url"));
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    NSDictionary *dictionary = [options isKindOfClass:[NSDictionary class]]
        ? options
        : POExternalReadObject(options, NSSelectorFromString(@"dictionary"));
    value = [dictionary isKindOfClass:[NSDictionary class]] ? dictionary[@"__PayloadURL"] : nil;
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    return [value isKindOfClass:[NSString class]] ? [NSURL URLWithString:value] : nil;
}

static NSDictionary *POExternalOptionsDictionary(id options) {
    if ([options isKindOfClass:[NSDictionary class]]) {
        return options;
    }
    id dictionary = POExternalReadObject(options, NSSelectorFromString(@"dictionary"));
    return [dictionary isKindOfClass:[NSDictionary class]] ? dictionary : nil;
}

static NSURL *POExternalURLFromOptions(id options) {
    id value = POExternalReadObject(options, NSSelectorFromString(@"url"));
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    value = dictionary[@"__PayloadURL"];
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static NSString *POExternalPayloadSourceBundleIdentifierFromOptions(id options) {
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    NSString *payloadOptionsKey = POExternalPayloadOptionsKey();
    if (payloadOptionsKey.length == 0) {
        return nil;
    }
    id payloadOptions = dictionary[payloadOptionsKey];
    if (![payloadOptions isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    id sourceBundleId = payloadOptions[UIApplicationLaunchOptionsSourceApplicationKey];
    return [sourceBundleId isKindOfClass:[NSString class]] ? sourceBundleId : nil;
}

static NSString *POExternalPayloadSourceBundleIdentifier(id request) {
    return POExternalPayloadSourceBundleIdentifierFromOptions(POExternalOpenOptions(request));
}

static NSString *POExternalOriginBundleIdentifier(id origin) {
    NSString *bundleId = POExternalBundleIdentifierOrString(origin);
    if (bundleId.length > 0) {
        return bundleId;
    }
    for (NSString *selectorName in @[ @"clientProcess", @"process", @"originatingProcess", @"sourceProcess" ]) {
        id nested = POExternalReadObject(origin, NSSelectorFromString(selectorName));
        bundleId = POExternalBundleIdentifier(nested);
        if (bundleId.length > 0) {
            return bundleId;
        }
    }
    return nil;
}

static NSString *POExternalTargetBundleIdentifierFromRequest(id request) {
    for (NSString *selectorName in @[
        @"bundleIdentifier",
        @"targetBundleIdentifier",
        @"applicationBundleIdentifier",
        @"applicationIdentifier"
    ]) {
        NSString *bundleId = POExternalBundleIdentifierOrString(
            POExternalReadObject(request, NSSelectorFromString(selectorName)));
        if (bundleId.length > 0) {
            return bundleId;
        }
    }

    for (NSString *selectorName in @[@"application", @"targetApplication"]) {
        NSString *bundleId = POExternalBundleIdentifierOrString(
            POExternalReadObject(request, NSSelectorFromString(selectorName)));
        if (bundleId.length > 0) {
            return bundleId;
        }
    }
    return nil;
}

static BOOL POExternalIsUserApplicationBundleIdentifier(NSString *bundleId) {
    return bundleId.length > 0 &&
        [POApplicationHelper isUserFacingApplicationBundleId:bundleId];
}

static NSString *POExternalAttributedUserSourceBundleIdentifier(NSString *directSourceBundleId,
                                                                 NSString *payloadSourceBundleId,
                                                                 NSURL *openURL,
                                                                 BOOL documentOpenRequest) {
    if (POExternalIsUserApplicationBundleIdentifier(directSourceBundleId)) {
        return directSourceBundleId;
    }
    if (POExternalIsUserApplicationBundleIdentifier(payloadSourceBundleId)) {
        return payloadSourceBundleId;
    }
    if (documentOpenRequest && openURL.isFileURL && directSourceBundleId.length > 0 &&
        !POExternalIsUserApplicationBundleIdentifier(directSourceBundleId)) {
        NSString *frontMostBundleId = [POApplicationHelper frontMostBundleId];
        if (POExternalIsUserApplicationBundleIdentifier(frontMostBundleId)) {
            return frontMostBundleId;
        }
    }
    return nil;
}

static BOOL POExternalIsValidURL(NSURL *openURL) {
    return openURL != nil && openURL.scheme.length > 0 && openURL.absoluteString.length > 0;
}

static BOOL POExternalPullOverIsStableClosed(void) {
    POXWindow *window = (POXWindow *)[POXWindow sharedWindow];
    PullOverViewController *controller = window.controller;
    return controller != nil && !controller.isPanelActive && !controller.isPanelTransitioning;
}

static id POExternalOptionsByAddingActivateSuspended(id options) {
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    NSString *activateSuspendedKey = POExternalActivateSuspendedOptionKey();
    if (!dictionary || activateSuspendedKey.length == 0) {
        return nil;
    }
    NSMutableDictionary *mutableDictionary = [dictionary mutableCopy];
    mutableDictionary[activateSuspendedKey] = @YES;

    SEL setDictionarySelector = NSSelectorFromString(@"setDictionary:");
    if (options && ![options isKindOfClass:[NSDictionary class]] &&
        [options respondsToSelector:setDictionarySelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(options, setDictionarySelector, mutableDictionary);
        return options;
    }
    if ([options isKindOfClass:[NSDictionary class]]) {
        return [mutableDictionary copy];
    }
    return nil;
}

static BOOL POExternalCanPrepareSuspendedOpenRequest(id request) {
    id options = POExternalOpenOptions(request);
    NSDictionary *dictionary = POExternalOpenOptionsDictionary(request);
    NSString *activateSuspendedKey = POExternalActivateSuspendedOptionKey();
    SEL setDictionarySelector = NSSelectorFromString(@"setDictionary:");
    return dictionary != nil && activateSuspendedKey.length > 0 &&
        [options respondsToSelector:setDictionarySelector];
}

static BOOL POExternalPrepareSuspendedOpenRequest(id request) {
    if (!POExternalCanPrepareSuspendedOpenRequest(request)) {
        return NO;
    }
    id options = POExternalOpenOptions(request);
    NSDictionary *dictionary = POExternalOpenOptionsDictionary(request);
    NSMutableDictionary *mutableDictionary = [dictionary mutableCopy];
    mutableDictionary[POExternalActivateSuspendedOptionKey()] = @YES;
    ((void (*)(id, SEL, id))objc_msgSend)(options, NSSelectorFromString(@"setDictionary:"), mutableDictionary);
    return YES;
}

static NSString *POExternalTargetBundleIdentifier(id transitionRequest,
                                                  NSString *hostedBundleId,
                                                  NSString *sourceBundleId) {
    id entities = POExternalReadObject(transitionRequest,
                                       NSSelectorFromString(@"toApplicationSceneEntities"));
    if (![entities respondsToSelector:@selector(objectEnumerator)]) {
        return nil;
    }

    NSString *fallbackTarget = nil;
    NSEnumerator *enumerator = [entities objectEnumerator];
    for (id entity in enumerator) {
        id application = POExternalReadObject(entity, NSSelectorFromString(@"application"));
        NSString *bundleId = POExternalBundleIdentifier(application);
        if (bundleId.length == 0) {
            continue;
        }
        if (![bundleId isEqualToString:sourceBundleId] &&
            [bundleId isEqualToString:hostedBundleId]) {
            return bundleId;
        }
        if (![bundleId isEqualToString:sourceBundleId] && fallbackTarget.length == 0) {
            fallbackTarget = bundleId;
        }
    }
    return fallbackTarget;
}

static BOOL POExternalTransitionContainsBundleIdentifier(id transitionRequest,
                                                          NSString *bundleId) {
    if (bundleId.length == 0) {
        return NO;
    }
    id entities = POExternalReadObject(transitionRequest,
                                       NSSelectorFromString(@"toApplicationSceneEntities"));
    if (![entities respondsToSelector:@selector(objectEnumerator)]) {
        return NO;
    }
    for (id entity in [entities objectEnumerator]) {
        id application = POExternalReadObject(entity, NSSelectorFromString(@"application"));
        if ([POExternalBundleIdentifier(application) isEqualToString:bundleId]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - 【0.7.4·P2】点通知 → 悬浮窗

/// 读通知功能的偏好：**CFPreferences 直读**。
/// 圆盘编辑器用的是另一个 NSUserDefaults 实例（同 suite），同进程的
/// `+[POApplicationHelper settingsDefaults]` 缓存可能还是旧值 ⇒ 直读才保证
/// 「编辑器里改完，下一次点通知就生效」。
static id POExternalNotificationPref(NSString *key) {
    if (key.length == 0) {
        return nil;
    }
    id value = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                               CFSTR("com.mlgm.pulloverx"));
    if (value == nil) {
        value = [[POApplicationHelper settingsDefaults] objectForKey:key];
    }
    return value;
}

/// 总开关：mfNotificationClickFloat（圆盘编辑器一级行「点通知进悬浮窗」）。默认 **开**。
static BOOL POExternalNotificationClickFloatEnabled(void) {
    id value = POExternalNotificationPref(@"mfNotificationClickFloat");
    if (value == nil) {
        return YES;
    }
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
}

/// 适用范围的判定：mfNotificationClickFloatScope = 0 全部应用（默认）/ 1 仅选中的应用。
/// 「仅选」但名单为空 ⇒ 不过滤（否则用户刚切过去、还没勾任何 App 时会以为功能坏了）。
static BOOL POExternalNotificationTargetAllowed(NSString *targetBundleId,
                                                NSString * __autoreleasing *outReason) {
    id scopeValue = POExternalNotificationPref(@"mfNotificationClickFloatScope");
    NSInteger scope = [scopeValue respondsToSelector:@selector(integerValue)] ? [scopeValue integerValue] : 0;
    if (scope != 1) {
        if (outReason) {
            *outReason = @"范围=全部应用";
        }
        return YES;
    }
    id listValue = POExternalNotificationPref(@"mfNotificationClickFloatApps");
    NSArray *list = [listValue isKindOfClass:[NSArray class]] ? (NSArray *)listValue : nil;
    if (list.count == 0) {
        if (outReason) {
            *outReason = @"范围=仅选，名单为空 ⇒ 不过滤";
        }
        return YES;
    }
    for (id item in list) {
        NSString *bundleId = nil;
        if ([item isKindOfClass:[NSString class]]) {
            bundleId = (NSString *)item;
        } else if ([item respondsToSelector:@selector(stringValue)]) {
            bundleId = [item stringValue];
        }
        if (bundleId.length > 0 && [bundleId isEqualToString:targetBundleId]) {
            if (outReason) {
                *outReason = [NSString stringWithFormat:@"范围=仅选(%lu 个)，命中名单",
                              (unsigned long)list.count];
            }
            return YES;
        }
    }
    if (outReason) {
        *outReason = [NSString stringWithFormat:@"范围=仅选(%lu 个)，不在名单内",
                      (unsigned long)list.count];
    }
    return NO;
}

/// 诊断日志预算：这条路径「每次 App 启动都会过一遍」，日志又是无缓冲写盘，
/// 所以一次会话最多 120 条，超了静默（不影响功能）。
static NSInteger POExternalNotificationLogBudget = 120;

static void POExternalNotificationLog(NSString *format, ...) {
    if (POExternalNotificationLogBudget <= 0) {
        return;
    }
    POExternalNotificationLogBudget -= 1;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    MFLog(@"[notify] %@", message);
}

/// 「target 都没认出来」的请求单独给 20 条预算：通知请求的字段结构与普通启动
/// 可能不同，万一认不出 target，这 20 条就是下一版定因的唯一线索。
static NSInteger POExternalUnknownTargetLogBudget = 20;

static BOOL POExternalUnknownTargetLog(NSString *format, ...) {
    if (POExternalUnknownTargetLogBudget <= 0) {
        return NO;
    }
    POExternalUnknownTargetLogBudget -= 1;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    MFLog(@"[notify] %@", message);
    return YES;
}

/// 调用栈探测：通知点击最终也是一次 OpenApplication 请求，和「点桌面图标」在
/// 请求参数上几乎没有区别 —— 唯一稳定的信号是**调用栈里有没有通知中心/横幅的类**。
/// 只在「URL 为空 + target 是用户 App」时才调用（= 用户启动 App 的次数），开销可忽略。
static BOOL POExternalCallStackLooksLikeNotification(NSString * __autoreleasing *outFrame) {
    NSArray<NSString *> *symbols = [NSThread callStackSymbols];
    if (symbols.count == 0) {
        return NO;
    }
    static NSArray<NSString *> *needles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        needles = @[
            @"NCNotification",
            @"NotificationCenter",
            @"SBNotification",
            @"BannerDestination",
            @"BulletinBoard",
            @"NCBulletin"
        ];
    });
    NSUInteger limit = MIN(symbols.count, (NSUInteger)24);
    for (NSUInteger index = 0; index < limit; index++) {
        NSString *frame = symbols[index];
        if (![frame isKindOfClass:[NSString class]] || frame.length == 0) {
            continue;
        }
        for (NSString *needle in needles) {
            if ([frame rangeOfString:needle].location != NSNotFound) {
                if (outFrame) {
                    *outFrame = frame;
                }
                return YES;
            }
        }
    }
    return NO;
}

/// 同一次点击可能同时经过 handleOpenApplicationRequest 与
/// handleTrustedOpenApplicationRequest 两条入口 —— 1.5 秒内同 target 只接管一次。
static CFTimeInterval POExternalLastNotificationRouteAt = 0;
static NSString *POExternalLastNotificationRouteTarget = nil;

static BOOL POExternalNotificationRouteDuplicate(NSString *targetBundleId) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (POExternalLastNotificationRouteTarget != nil &&
        [POExternalLastNotificationRouteTarget isEqualToString:targetBundleId] &&
        (now - POExternalLastNotificationRouteAt) < 1.5) {
        return YES;
    }
    POExternalLastNotificationRouteTarget = [targetBundleId copy];
    POExternalLastNotificationRouteAt = now;
    return NO;
}

/// 判定一次 OpenApplication 请求是不是「用户点了通知」。
/// 返回 NO 一律原样放行 —— **识别不出来 = 以前的行为**（安全的失败模式）。
static BOOL POExternalIsNotificationLaunch(id options,
                                           NSURL *openURL,
                                           NSDictionary * __autoreleasing *outDictionary,
                                           NSString * __autoreleasing *outStackFrame,
                                           NSString * __autoreleasing *outLaunchOrigin) {
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    if (outDictionary) {
        *outDictionary = dictionary;
    }

    NSString *launchOrigin = nil;
    NSString *launchOriginKey = POExternalStringConstant("FBSOpenApplicationOptionKeyLaunchOrigin");
    if (launchOriginKey.length > 0) {
        id value = dictionary[launchOriginKey];
        if ([value isKindOfClass:[NSString class]]) {
            launchOrigin = value;
        } else if ([value respondsToSelector:@selector(stringValue)]) {
            launchOrigin = [value stringValue];
        }
    }
    if (outLaunchOrigin) {
        *outLaunchOrigin = launchOrigin;
    }

    // 带 URL 的请求交给原有 URL 路由（那里已有成熟的跨 App 跳转语义）
    if (POExternalIsValidURL(openURL)) {
        return NO;
    }
    // 系统自己写明了来源 ⇒ 直接信它。
    // ★ log66 实测：点通知的 launchOrigin 不是含 "notification" 的字符串，而是
    //   `BulletinDestinationCoverSheet`（锁屏/通知中心）/ `BulletinDestinationBanner`（横幅）。
    //   只查 "notification" ⇒ 永远判「非通知」，功能永远不生效 —— 这是 0.7.4 没跑起来的唯一原因。
    //   反过来，点桌面图标时 launchOrigin 为 **空**（log66 实证），所以这张关键词表不会误伤。
    if (launchOrigin.length > 0) {
        static NSArray<NSString *> *originNeedles;
        static dispatch_once_t originOnceToken;
        dispatch_once(&originOnceToken, ^{
            originNeedles = @[ @"notification", @"bulletin", @"banner" ];
        });
        for (NSString *needle in originNeedles) {
            if ([launchOrigin rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
        return NO;
    }
    // 没写来源，只能靠调用栈（取栈有开销，所以放在最后）
    NSString *frame = nil;
    BOOL stackHit = POExternalCallStackLooksLikeNotification(&frame);
    if (outStackFrame) {
        *outStackFrame = frame;
    }
    return stackHit;
}

/// 把 options 里我们关心的键压成一行（诊断用）
static NSString *POExternalOptionsSummary(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]] || dictionary.count == 0) {
        return @"(空)";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id key in dictionary) {
        NSString *name = [key isKindOfClass:[NSString class]] ? key : [key description];
        id value = dictionary[key];
        NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
        if (text.length > 60) {
            text = [[text substringToIndex:60] stringByAppendingString:@"…"];
        }
        [parts addObject:[NSString stringWithFormat:@"%@=%@", name, text]];
        if (parts.count >= 8) {
            break;
        }
    }
    return [parts componentsJoinedByString:@", "];
}

// ─────────────────────────────────────────────────────────────────────────────
// 【0.7.7】点通知进浮窗后，把那条通知标记为已读（= 让它从通知中心/锁屏消失）
//
// 依据（全部实测，不是猜）：
//  ① log67 行 120 实证：options 的 `__Actions` 里带 `UINotificationResponseAction`
//     ⇒ 它是「通知被点击」的响应动作，持有公开类型 UNNotificationResponse。
//  ② analysis/deb_packages/.../TrollOpenJB.dylib 字符串表实证：系统里存在
//     类 `NCNotificationDispatcher` / `SBNCNotificationDispatcher`，
//     方法 `notificationDispatcher` 与 `withdrawNotificationRequest:`。
//
// 所以链路 = action.notificationResponse.notification.request.identifier（公开 API，零风险）
//          → NCNotificationDispatcher 按 UUID 精确 withdraw（私有 API，全程 respondsToSelector 守门）
// 任何一步拿不到 ⇒ 什么都不做（= 以前的行为）。**绝不按「清空该 App 全部通知」兜底**，
// 那会顺手删掉用户还没看的重要通知。
// ─────────────────────────────────────────────────────────────────────────────

/// 从 openApplication 的 options 里取出「这次点的是哪一条通知」的 UUID。
static NSString *POExternalNotificationIdentifierFromOptions(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id actions = dictionary[@"__Actions"];
    if (![actions isKindOfClass:[NSArray class]]) {
        actions = [actions respondsToSelector:@selector(allObjects)] ? [actions allObjects] : nil;
    }
    if (![actions isKindOfClass:[NSArray class]]) {
        return nil;
    }

    SEL responseSelector = NSSelectorFromString(@"notificationResponse");
    for (id action in actions) {
        // 用「有没有 notificationResponse」识别，不按类名猜 ——
        // UINotificationResponseAction / UISNotificationResponseAction 两个名字都出现过。
        id response = POExternalReadObject(action, responseSelector);
        if (!response) {
            continue;
        }
        id notification = POExternalReadObject(response, NSSelectorFromString(@"notification"));
        id request = POExternalReadObject(notification, NSSelectorFromString(@"request"));
        id identifier = POExternalReadObject(request, NSSelectorFromString(@"identifier"));
        if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) {
            return identifier;
        }
    }
    return nil;
}

/// 清除动作的日志预算（40 条/会话）：这条路径只在点通知时走，正常不会刷屏。
static NSInteger POExternalNotificationDismissLogBudget = 40;

static void POExternalNotificationDismissLog(NSString *format, ...) {
    if (POExternalNotificationDismissLogBudget <= 0) {
        return;
    }
    POExternalNotificationDismissLogBudget -= 1;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    MFLog(@"[notify] %@", message);
}

/// 取真正的 NCNotificationDispatcher：
///   UIApplication(SpringBoard 实例) -notificationDispatcher → SBNCNotificationDispatcher
///   SBNCNotificationDispatcher -notificationDispatcher      → NCNotificationDispatcher
/// 有的系统版本第一层就返回可用的 dispatcher，所以取不到第二层时回退第一层。
static id POExternalNotificationDispatcher(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (!application) {
        return nil;
    }
    id first = POExternalReadObject(application, NSSelectorFromString(@"notificationDispatcher"));
    if (!first) {
        return nil;
    }
    id second = POExternalReadObject(first, NSSelectorFromString(@"notificationDispatcher"));
    return second ?: first;
}

/// 每会话只 dump 一次：把 dispatcher 上和「清除/取列表」有关的方法名打出来。
/// 只列举、不调用 —— 这是下一版在 API 名变化时唯一的依据。
static void POExternalDumpNotificationDispatcherSelectors(id dispatcher) {
    if (!dispatcher) {
        return;
    }
    Class cls = object_getClass(dispatcher);
    if (!cls) {
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (name.length == 0) {
            continue;
        }
        if ([name rangeOfString:@"ithdraw"].location != NSNotFound ||
            [name rangeOfString:@"ismiss"].location != NSNotFound ||
            [name rangeOfString:@"lear"].location != NSNotFound ||
            [name rangeOfString:@"emove"].location != NSNotFound ||
            [name rangeOfString:@"Requests"].location != NSNotFound) {
            [hits addObject:name];
        }
    }
    if (methods) {
        free(methods);
    }
    POExternalNotificationDismissLog(@"清除通知：%@ 相关方法 [%@]",
                                     NSStringFromClass(cls),
                                     [hits componentsJoinedByString:@", "]);
}

/// 按 UUID 清掉一条已投递的通知。**拿不到就什么都不做**。
static void POExternalDismissDeliveredNotification(NSString *bundleId, NSString *identifier) {
    @try {
        id dispatcher = POExternalNotificationDispatcher();
        if (!dispatcher) {
            POExternalNotificationDismissLog(@"清除通知：拿不到 notificationDispatcher（放弃，不影响开窗）");
            return;
        }
        static BOOL dumped = NO;
        if (!dumped) {
            dumped = YES;
            POExternalDumpNotificationDispatcherSelectors(dispatcher);
        }

        // ① 取该 App 名下的通知请求（section identifier 通常就是 bundleId）
        NSArray *requests = nil;
        BOOL sectionScoped = NO;
        SEL bySection = NSSelectorFromString(@"notificationRequestsForSectionIdentifier:");
        if (bundleId.length > 0 && [dispatcher respondsToSelector:bySection]) {
            id value = ((id (*)(id, SEL, id))objc_msgSend)(dispatcher, bySection, bundleId);
            if ([value isKindOfClass:[NSArray class]]) {
                requests = value;
                sectionScoped = YES;
            }
        }
        if (![requests isKindOfClass:[NSArray class]]) {
            id value = POExternalReadObject(dispatcher, NSSelectorFromString(@"allNotificationRequests"));
            if ([value isKindOfClass:[NSArray class]]) {
                requests = value;
            }
        }
        if (![requests isKindOfClass:[NSArray class]]) {
            POExternalNotificationDismissLog(@"清除通知：拿不到通知请求列表（该版本无对应 API）");
            return;
        }

        // ② 按 UUID 精确挑出被点的那一条
        id target = nil;
        NSMutableArray<NSString *> *uuids = [NSMutableArray array];
        for (id request in requests) {
            NSString *uuid = POExternalReadObject(request, NSSelectorFromString(@"uuid"));
            if (![uuid isKindOfClass:[NSString class]] || uuid.length == 0) {
                uuid = POExternalReadObject(request, NSSelectorFromString(@"notificationIdentifier"));
            }
            BOOL uuidIsText = [uuid isKindOfClass:[NSString class]] && uuid.length > 0;
            if (uuidIsText && uuids.count < 6) {
                [uuids addObject:uuid];
            }
            if (identifier.length > 0 && uuidIsText && [uuid isEqualToString:identifier]) {
                target = request;
                break;
            }
        }
        // 兜底：UUID 没取到，但该 App 名下只剩一条 ⇒ 就是刚点的那条。
        // ★ 只在 sectionScoped 成立时用：allNotificationRequests 是**全系统**列表，
        //   在那里「只剩一条」可能是别的 App 的通知，删了就是误伤。
        if (!target && sectionScoped && identifier.length == 0 && requests.count == 1) {
            target = requests.firstObject;
        }
        if (!target) {
            POExternalNotificationDismissLog(@"清除通知：未命中（UUID=%@，列表 %lu 条 [%@]）",
                                             identifier.length > 0 ? identifier : @"(无)",
                                             (unsigned long)requests.count,
                                             [uuids componentsJoinedByString:@", "]);
            return;
        }

        SEL withdraw = NSSelectorFromString(@"withdrawNotificationRequest:");
        if (![dispatcher respondsToSelector:withdraw]) {
            POExternalNotificationDismissLog(@"清除通知：dispatcher 无 withdrawNotificationRequest:（放弃）");
            return;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(dispatcher, withdraw, target);
        POExternalNotificationDismissLog(@"清除通知：已清除 %@ 的 1 条（UUID=%@）",
                                         bundleId,
                                         identifier.length > 0 ? identifier : @"(按唯一一条兜底)");
    } @catch (NSException *exception) {
        POExternalNotificationDismissLog(@"清除通知异常：%@", exception.reason);
    }
}

/// 延后 0.45s 再清：此刻 SpringBoard 正跑 OpenApplication 事务，
/// 立刻去动通知中心有撞内部断言的历史（0.6.20 控制中心那一课）。
/// 等浮窗起来再清，用户看到的是「浮窗出现 → 通知随即消失」。
static void POExternalScheduleDismissDeliveredNotification(NSString *bundleId, NSString *identifier) {
    if (bundleId.length == 0) {
        return;
    }
    NSString *targetBundleId = [bundleId copy];
    NSString *targetIdentifier = [identifier copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        POExternalDismissDeliveredNotification(targetBundleId, targetIdentifier);
    });
}

@interface POExternalActivationCoordinator ()
@property (nonatomic, assign) NSUInteger routeRequestGeneration;
@property (nonatomic, assign) NSUInteger nativeRouteGeneration;
@property (nonatomic, assign) BOOL nativeRouteInFlight;
@property (nonatomic, copy) NSString *pendingNativeTargetBundleId;

- (BOOL)beginNativeRouteForTargetBundleId:(NSString *)targetBundleId
                           sourceBundleId:(NSString *)sourceBundleId;
- (BOOL)isNativeRouteGenerationCurrent:(NSUInteger)generation;
- (void)finishNativeRouteForGeneration:(NSUInteger)generation;
- (void)restoreNativeTargetBundleId:(NSString *)targetBundleId
                         generation:(NSUInteger)generation;
- (void)completeNativeRouteForGeneration:(NSUInteger)generation
                          targetBundleId:(NSString *)targetBundleId
                                   error:(NSError *)error;
- (id)routeNotificationLaunchIfNeeded:(id)request completion:(id)completion;
- (id)routeNotificationLaunchForTrustedApplication:(id)application
                                           options:(id)options
                                            origin:(id)origin
                                            result:(id)result
                                      routedResult:(id __autoreleasing *)routedResult;
- (id)notificationRoutedCompletionForTarget:(NSString *)targetBundleId
                          prepareSuspended:(BOOL (^)(void))prepareSuspended
                     notificationIdentifier:(NSString *)notificationIdentifier
                                 completion:(id)completion;
@end

@implementation POExternalActivationCoordinator

+ (instancetype)sharedInstance {
    static POExternalActivationCoordinator *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [POExternalActivationCoordinator new];
        MFLog(@"[notify] 0.7.4 P2 已启用：点通知 → 悬浮窗"
              "（开关 mfNotificationClickFloat 默认开；0.7.7 起入口 = 圆盘编辑器一级行「点通知进悬浮窗」，"
              "二级页里可选「全部应用」或「仅选中的应用」）"
              "｜识别 = launchOrigin 含 notification/bulletin/banner，或调用栈命中 NCNotification/SBNotification/Banner");
        MFLog(@"[notify] 0.7.7 已启用：点通知进浮窗后自动清除该条通知（标已读）"
              "｜UUID 取自 options.__Actions 的 notificationResponse.request.identifier"
              "｜清除 = NCNotificationDispatcher -withdrawNotificationRequest:（拿不到就不动，绝不误删）");
    });
    return sharedInstance;
}

- (id)prepareOpenApplicationRequestIfNeeded:(id)request completion:(id)completion {
    if (!NSThread.isMainThread || !request || ![POApplicationHelper isEnabled]) {
        return completion;
    }


    // ── 【0.7.4·P2】点通知 → 悬浮窗 ──
    //   必须放在「URL 必须有效」这条判断**之前**：通知点击几乎不带 URL
    //   （只有带 deep link 的通知才有），原逻辑会在这里直接放行原生。
    id notificationCompletion = [self routeNotificationLaunchIfNeeded:request
                                                              completion:completion];
    if (notificationCompletion) {
        return notificationCompletion;
    }

    NSURL *openURL = POExternalOpenURL(request);
    if (!POExternalIsValidURL(openURL)) {
        return completion;
    }
    NSDictionary *openOptions = POExternalOpenOptionsDictionary(request);
    BOOL documentOpenRequest = [openOptions[@"__DocumentOpen4LS"] boolValue];
    NSString *targetBundleId = POExternalTargetBundleIdentifierFromRequest(request);
    if (!POExternalIsUserApplicationBundleIdentifier(targetBundleId)) {
        return completion;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    POXWindow *pullOverWindow = (POXWindow *)[POXWindow sharedWindow];
    id clientProcess = POExternalReadObject(request, NSSelectorFromString(@"clientProcess"));
    NSString *directSourceBundleId = POExternalBundleIdentifierOrString(clientProcess);
    NSString *payloadSourceBundleId = POExternalPayloadSourceBundleIdentifier(request);

    BOOL hostedRouteAvailable = manager.isForegroundLeaseActive &&
        hostedBundleId.length > 0 && pullOverWindow.controller.isPanelActive;
    if (hostedRouteAvailable) {
        BOOL directHostedSource = [directSourceBundleId isEqualToString:hostedBundleId];
        BOOL payloadHostedSource = [payloadSourceBundleId isEqualToString:hostedBundleId];
        BOOL directSourceIsUserApplication = POExternalIsUserApplicationBundleIdentifier(directSourceBundleId);
        BOOL directSourceIsBroker = directSourceBundleId.length > 0 && !directSourceIsUserApplication;
        BOOL payloadSourceIsBroker = payloadSourceBundleId.length > 0 &&
            !POExternalIsUserApplicationBundleIdentifier(payloadSourceBundleId);
        BOOL payloadHostedBroker = !directHostedSource && payloadHostedSource &&
            !directSourceIsUserApplication;
        BOOL payloadAttributableToHostedFlow = payloadSourceBundleId.length == 0 ||
            payloadHostedSource || payloadSourceIsBroker;
        BOOL brokeredDocumentFromPullOver = !directHostedSource && !payloadHostedBroker &&
            documentOpenRequest && openURL.isFileURL && directSourceIsBroker &&
            payloadAttributableToHostedFlow;

        if (directHostedSource || payloadHostedBroker || brokeredDocumentFromPullOver) {
            NSString *sourceBundleId = hostedBundleId;
            if ([targetBundleId isEqualToString:sourceBundleId]) {
                return completion;
            }

            SEL trustedSelector = NSSelectorFromString(@"isTrusted");
            SEL setTrustedSelector = NSSelectorFromString(@"setTrusted:");
            if (![request respondsToSelector:setTrustedSelector] ||
                ![request respondsToSelector:trustedSelector] ||
                !POExternalCanPrepareSuspendedOpenRequest(request)) {
                return completion;
            }

            BOOL isTrusted = ((BOOL (*)(id, SEL))objc_msgSend)(request, trustedSelector);
            if (!isTrusted && !directHostedSource) {
                return completion;
            }

            if (!POExternalPrepareSuspendedOpenRequest(request)) {
                return completion;
            }
            if (!isTrusted) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(request, setTrustedSelector, YES);
            }

            NSUInteger hostGeneration = manager.activeLeaseGeneration;
            NSUInteger routeGeneration = ++self.routeRequestGeneration;
            POExternalOpenCompletion originalCompletion = completion;
            POExternalOpenCompletion routedCompletion = ^(NSError *error) {
                if (originalCompletion) {
                    originalCompletion(error);
                }
                if (error) {
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    ContextHostManager *currentManager = [ContextHostManager sharedInstance];
                    NSString *currentHostedBundleId = [ContextHostManager activeHostedBundleId];
                    if (routeGeneration != self.routeRequestGeneration ||
                        !currentManager.isForegroundLeaseActive ||
                        currentManager.activeLeaseGeneration != hostGeneration ||
                        ![currentHostedBundleId isEqualToString:sourceBundleId]) {
                        return;
                    }

                    POXWindow *currentWindow = (POXWindow *)[POXWindow sharedWindow];
                    [currentWindow.controller routeExternalApplicationInsidePullOver:targetBundleId];
                });
            };
            return [routedCompletion copy];
        }
    }

    NSString *nativeSourceBundleId = POExternalAttributedUserSourceBundleIdentifier(
        directSourceBundleId, payloadSourceBundleId, openURL, documentOpenRequest);
    SEL trustedSelector = NSSelectorFromString(@"isTrusted");
    if (![POApplicationHelper isExternalURLRoutingTargetBundleId:targetBundleId] ||
        nativeSourceBundleId.length == 0 ||
        [targetBundleId isEqualToString:nativeSourceBundleId] ||
        !POExternalPullOverIsStableClosed() ||
        ![request respondsToSelector:trustedSelector] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(request, trustedSelector) ||
        !POExternalCanPrepareSuspendedOpenRequest(request)) {
        return completion;
    }

    if (![self beginNativeRouteForTargetBundleId:targetBundleId
                                  sourceBundleId:nativeSourceBundleId]) {
        return completion;
    }
    if (!POExternalPrepareSuspendedOpenRequest(request)) {
        [self finishNativeRouteForGeneration:self.nativeRouteGeneration];
        return completion;
    }

    NSUInteger nativeGeneration = self.nativeRouteGeneration;
    POExternalOpenCompletion originalCompletion = completion;
    POExternalOpenCompletion routedCompletion = ^(NSError *error) {
        if (originalCompletion) {
            originalCompletion(error);
        }
        [self completeNativeRouteForGeneration:nativeGeneration
                                targetBundleId:targetBundleId
                                         error:error];
    };
    return [routedCompletion copy];
}

- (id)prepareTrustedWorkspaceOpenApplication:(id)application
                                     options:(id)options
                                      origin:(id)origin
                                      result:(id)result
                                routedResult:(id __autoreleasing *)routedResult {
    if (routedResult) {
        *routedResult = result;
    }
    if (!NSThread.isMainThread || !application || !options || ![POApplicationHelper isEnabled]) {
        return options;
    }


    NSString *targetBundleId = [application isKindOfClass:[NSString class]]
        ? application
        : POExternalBundleIdentifier(application);
    // ── 【0.7.4·P2】点通知 → 悬浮窗（trusted 入口）──
    id notificationResult = result;
    id notificationOptions = [self routeNotificationLaunchForTrustedApplication:application
                                                                        options:options
                                                                         origin:origin
                                                                         result:result
                                                                   routedResult:&notificationResult];
    if (notificationOptions) {
        if (routedResult) {
            *routedResult = notificationResult;
        }
        return notificationOptions;
    }

    NSURL *openURL = POExternalURLFromOptions(options);
    if (!POExternalIsUserApplicationBundleIdentifier(targetBundleId) ||
        !POExternalIsValidURL(openURL)) {
        return options;
    }

    NSDictionary *openOptions = POExternalOptionsDictionary(options);
    BOOL documentOpenRequest = [openOptions[@"__DocumentOpen4LS"] boolValue];
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    POXWindow *pullOverWindow = (POXWindow *)[POXWindow sharedWindow];
    NSString *originBundleId = POExternalOriginBundleIdentifier(origin);
    NSString *payloadSourceBundleId = POExternalPayloadSourceBundleIdentifierFromOptions(options);

    BOOL hostedRouteAvailable = manager.isForegroundLeaseActive &&
        hostedBundleId.length > 0 && pullOverWindow.controller.isPanelActive;
    if (hostedRouteAvailable && ![targetBundleId isEqualToString:hostedBundleId] &&
        documentOpenRequest && openURL.isFileURL) {
        BOOL originIsUserApplication = POExternalIsUserApplicationBundleIdentifier(originBundleId);
        BOOL originIsBroker = originBundleId.length > 0 && !originIsUserApplication;
        BOOL payloadHostedSource = [payloadSourceBundleId isEqualToString:hostedBundleId];
        BOOL payloadSourceIsBroker = payloadSourceBundleId.length > 0 &&
            !POExternalIsUserApplicationBundleIdentifier(payloadSourceBundleId);
        BOOL payloadAttributableToHostedFlow = payloadSourceBundleId.length == 0 ||
            payloadHostedSource || payloadSourceIsBroker;

        if (!((!originIsBroker && !payloadSourceIsBroker) ||
              originIsUserApplication || !payloadAttributableToHostedFlow)) {
            id preparedOptions = POExternalOptionsByAddingActivateSuspended(options);
            if (!preparedOptions) {
                return options;
            }

            NSUInteger hostGeneration = manager.activeLeaseGeneration;
            NSUInteger routeGeneration = ++self.routeRequestGeneration;
            NSString *sourceBundleId = [hostedBundleId copy];
            POExternalOpenCompletion originalResult = result;
            POExternalOpenCompletion wrappedResult = ^(NSError *error) {
                if (originalResult) {
                    originalResult(error);
                }
                if (error) {
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    ContextHostManager *currentManager = [ContextHostManager sharedInstance];
                    NSString *currentHostedBundleId = [ContextHostManager activeHostedBundleId];
                    if (routeGeneration != self.routeRequestGeneration ||
                        !currentManager.isForegroundLeaseActive ||
                        currentManager.activeLeaseGeneration != hostGeneration ||
                        ![currentHostedBundleId isEqualToString:sourceBundleId]) {
                        return;
                    }
                    POXWindow *currentWindow = (POXWindow *)[POXWindow sharedWindow];
                    [currentWindow.controller routeExternalApplicationInsidePullOver:targetBundleId];
                });
            };
            if (routedResult) {
                *routedResult = [wrappedResult copy];
            }

            return preparedOptions;
        }
    }

    NSString *nativeSourceBundleId = POExternalAttributedUserSourceBundleIdentifier(
        originBundleId, payloadSourceBundleId, openURL, documentOpenRequest);
    if (![POApplicationHelper isExternalURLRoutingTargetBundleId:targetBundleId] ||
        nativeSourceBundleId.length == 0 ||
        [targetBundleId isEqualToString:nativeSourceBundleId] ||
        !POExternalPullOverIsStableClosed()) {
        return options;
    }

    if (![self beginNativeRouteForTargetBundleId:targetBundleId
                                  sourceBundleId:nativeSourceBundleId]) {
        return options;
    }

    id preparedOptions = POExternalOptionsByAddingActivateSuspended(options);
    if (!preparedOptions) {
        [self finishNativeRouteForGeneration:self.nativeRouteGeneration];
        return options;
    }

    NSUInteger nativeGeneration = self.nativeRouteGeneration;
    POExternalOpenCompletion originalResult = result;
    POExternalOpenCompletion wrappedResult = ^(NSError *error) {
        if (originalResult) {
            originalResult(error);
        }
        [self completeNativeRouteForGeneration:nativeGeneration
                                targetBundleId:targetBundleId
                                         error:error];
    };
    if (routedResult) {
        *routedResult = [wrappedResult copy];
    }

    return preparedOptions;
}

- (BOOL)beginNativeRouteForTargetBundleId:(NSString *)targetBundleId
                           sourceBundleId:(NSString *)sourceBundleId {
    if (!NSThread.isMainThread || self.nativeRouteInFlight ||
        targetBundleId.length == 0 || sourceBundleId.length == 0) {
        return NO;
    }

    self.nativeRouteGeneration += 1;
    NSUInteger generation = self.nativeRouteGeneration;
    self.nativeRouteInFlight = YES;
    self.pendingNativeTargetBundleId = [targetBundleId copy];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![self isNativeRouteGenerationCurrent:generation]) {
            return;
        }
        [self restoreNativeTargetBundleId:targetBundleId
                               generation:generation];
    });
    return YES;
}

- (BOOL)isNativeRouteGenerationCurrent:(NSUInteger)generation {
    return self.nativeRouteInFlight && self.nativeRouteGeneration == generation;
}

- (void)finishNativeRouteForGeneration:(NSUInteger)generation {
    if (!self.nativeRouteInFlight || self.nativeRouteGeneration != generation) {
        return;
    }
    self.nativeRouteInFlight = NO;
    self.pendingNativeTargetBundleId = nil;
    self.nativeRouteGeneration += 1;
}

- (void)restoreNativeTargetBundleId:(NSString *)targetBundleId
                         generation:(NSUInteger)generation {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreNativeTargetBundleId:targetBundleId
                                   generation:generation];
        });
        return;
    }
    if (![self isNativeRouteGenerationCurrent:generation]) {
        return;
    }

    POXWindow *pullOverWindow = (POXWindow *)[POXWindow sharedWindow];
    [pullOverWindow.controller prepareForNativeApplicationTakeover:targetBundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:targetBundleId suspended:NO];
    [self finishNativeRouteForGeneration:generation];
}

- (void)completeNativeRouteForGeneration:(NSUInteger)generation
                          targetBundleId:(NSString *)targetBundleId
                                   error:(NSError *)error {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeNativeRouteForGeneration:generation
                                    targetBundleId:targetBundleId
                                             error:error];
        });
        return;
    }
    if (![self isNativeRouteGenerationCurrent:generation]) {
        return;
    }
    if (error) {
        [self finishNativeRouteForGeneration:generation];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isNativeRouteGenerationCurrent:generation]) {
            return;
        }
        POXWindow *pullOverWindow = (POXWindow *)[POXWindow sharedWindow];
        BOOL accepted = [pullOverWindow.controller
            openExternallyActivatedApplicationInPullOver:targetBundleId];
        if (accepted) {
            [self finishNativeRouteForGeneration:generation];
            return;
        }
        [self restoreNativeTargetBundleId:targetBundleId
                               generation:generation];
    });
}

- (void)prepareNativeTakeoverForTransitionRequestIfNeeded:(id)transitionRequest {
    if (!NSThread.isMainThread || !transitionRequest || ![POApplicationHelper isEnabled]) {
        return;
    }

    NSString *pendingTargetBundleId = self.pendingNativeTargetBundleId;
    if (self.nativeRouteInFlight &&
        POExternalTransitionContainsBundleIdentifier(transitionRequest, pendingTargetBundleId)) {
        return;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    if (!manager.isForegroundLeaseActive || hostedBundleId.length == 0) {
        return;
    }

    id originatingProcess = POExternalReadObject(transitionRequest,
                                                 NSSelectorFromString(@"originatingProcess"));
    NSString *sourceBundleId = POExternalBundleIdentifierOrString(originatingProcess);
    NSString *targetBundleId = POExternalTargetBundleIdentifier(transitionRequest,
                                                                hostedBundleId,
                                                                sourceBundleId);
    if (targetBundleId.length == 0 || [targetBundleId isEqualToString:sourceBundleId]) {
        return;
    }

    BOOL hostedIsTarget = [hostedBundleId isEqualToString:targetBundleId];
    BOOL hostedIsSource = [hostedBundleId isEqualToString:sourceBundleId];
    if (!hostedIsTarget || hostedIsSource) {
        return;
    }

    POXWindow *pullOverWindow = (POXWindow *)[POXWindow sharedWindow];
    [pullOverWindow.controller prepareForNativeApplicationTakeover:targetBundleId];
}

- (id)routeNotificationLaunchIfNeeded:(id)request completion:(id)completion {
    if (!NSThread.isMainThread || !request) {
        return nil;
    }

    NSString *targetBundleId = POExternalTargetBundleIdentifierFromRequest(request);
    BOOL targetIsUserApp = POExternalIsUserApplicationBundleIdentifier(targetBundleId);
    NSURL *openURL = POExternalOpenURL(request);
    if (!targetIsUserApp && !POExternalIsValidURL(openURL)) {
        // 连 target 都认不出：留 20 条线索（万一通知请求就是这种形状，下一版才有据可依）
        id unknownClient = POExternalReadObject(request, NSSelectorFromString(@"clientProcess"));
        POExternalUnknownTargetLog(@"openApplication(未识别 target)：target=%@ 来源=%@ options=%@",
                                   targetBundleId ?: @"(无)",
                                   POExternalBundleIdentifierOrString(unknownClient) ?: @"(无)",
                                   POExternalOptionsSummary(POExternalOpenOptionsDictionary(request)));
        return nil;
    }

    id clientProcess = POExternalReadObject(request, NSSelectorFromString(@"clientProcess"));
    NSString *originBundleId = POExternalBundleIdentifierOrString(clientProcess);
    NSDictionary *dictionary = nil;
    NSString *stackFrame = nil;
    NSString *launchOrigin = nil;
    BOOL notificationLaunch = POExternalIsNotificationLaunch(POExternalOpenOptions(request),
                                                             openURL,
                                                             &dictionary,
                                                             &stackFrame,
                                                             &launchOrigin);

    POExternalNotificationLog(@"openApplication：target=%@ 来源=%@ launchOrigin=%@ URL=%@ 判定=%@",
                              targetBundleId ?: @"(无)",
                              originBundleId ?: @"(无)",
                              launchOrigin ?: @"(无)",
                              openURL.absoluteString ?: @"(无)",
                              notificationLaunch ? @"通知" : @"非通知");
    if (notificationLaunch) {
        POExternalNotificationLog(@"  栈帧=%@", stackFrame ?: @"(未命中，靠 launchOrigin)");
        POExternalNotificationLog(@"  options=%@", POExternalOptionsSummary(dictionary));
        POExternalNotificationLog(@"  通知 UUID=%@（取不到就不清除，避免误删）",
                                  POExternalNotificationIdentifierFromOptions(dictionary) ?: @"(无)");
    }

    if (!notificationLaunch || !targetIsUserApp) {
        return nil;
    }
    if (!POExternalNotificationClickFloatEnabled()) {
        POExternalNotificationLog(@"[notify] 开关=关 ⇒ 放行原生打开 %@", targetBundleId);
        return nil;
    }
    NSString *scopeReason = nil;
    if (!POExternalNotificationTargetAllowed(targetBundleId, &scopeReason)) {
        POExternalNotificationLog(@"[notify] %@ ⇒ 放行原生打开 %@", scopeReason, targetBundleId);
        return nil;
    }
    if (POExternalNotificationRouteDuplicate(targetBundleId)) {
        return nil;
    }
    return [self notificationRoutedCompletionForTarget:targetBundleId
                                     prepareSuspended:^BOOL{
        return POExternalPrepareSuspendedOpenRequest(request);
    }
                               notificationIdentifier:POExternalNotificationIdentifierFromOptions(dictionary)
                                            completion:completion];
}

- (id)routeNotificationLaunchForTrustedApplication:(id)application
                                           options:(id)options
                                            origin:(id)origin
                                            result:(id)result
                                      routedResult:(id __autoreleasing *)routedResult {
    if (routedResult) {
        *routedResult = result;
    }
    if (!NSThread.isMainThread) {
        return nil;
    }

    NSString *targetBundleId = [application isKindOfClass:[NSString class]]
        ? application
        : POExternalBundleIdentifier(application);
    if (!POExternalIsUserApplicationBundleIdentifier(targetBundleId)) {
        return nil;
    }
    NSURL *openURL = POExternalURLFromOptions(options);
    if (POExternalIsValidURL(openURL)) {
        return nil;
    }

    NSString *originBundleId = POExternalOriginBundleIdentifier(origin);
    NSDictionary *dictionary = nil;
    NSString *stackFrame = nil;
    NSString *launchOrigin = nil;
    BOOL notificationLaunch = POExternalIsNotificationLaunch(options,
                                                             openURL,
                                                             &dictionary,
                                                             &stackFrame,
                                                             &launchOrigin);

    POExternalNotificationLog(@"[trusted] target=%@ 来源=%@ launchOrigin=%@ 判定=%@ 栈帧=%@",
                              targetBundleId ?: @"(无)",
                              originBundleId ?: @"(无)",
                              launchOrigin ?: @"(无)",
                              notificationLaunch ? @"通知" : @"非通知",
                              stackFrame ?: @"(未命中)");
    if (!notificationLaunch) {
        return nil;
    }
    if (!POExternalNotificationClickFloatEnabled()) {
        POExternalNotificationLog(@"[trusted] 开关=关 ⇒ 放行原生");
        return nil;
    }
    NSString *trustedScopeReason = nil;
    if (!POExternalNotificationTargetAllowed(targetBundleId, &trustedScopeReason)) {
        POExternalNotificationLog(@"[trusted] %@ ⇒ 放行原生", trustedScopeReason);
        return nil;
    }
    if (POExternalNotificationRouteDuplicate(targetBundleId)) {
        return nil;
    }

    // suspended 选项的写入交给下面的路由决策（只有真的接管才写）——
    // 给 options 加上 suspended 之后 App 就不上前台了，提前写会污染原生路径。
    __block id preparedOptions = nil;
    id routedResultValue = [self notificationRoutedCompletionForTarget:targetBundleId
                                                     prepareSuspended:^BOOL{
        preparedOptions = POExternalOptionsByAddingActivateSuspended(options);
        return preparedOptions != nil;
    }
                                               notificationIdentifier:POExternalNotificationIdentifierFromOptions(dictionary)
                                                           completion:result];
    if (!routedResultValue) {
        return nil;
    }
    if (routedResult) {
        *routedResult = routedResultValue;
    }
    return preparedOptions;
}

- (id)notificationRoutedCompletionForTarget:(NSString *)targetBundleId
                          prepareSuspended:(BOOL (^)(void))prepareSuspended
                     notificationIdentifier:(NSString *)notificationIdentifier
                                 completion:(id)completion {
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    POXWindow *pullOverWindow = (POXWindow *)[POXWindow sharedWindow];
    PullOverViewController *controller = pullOverWindow.controller;
    BOOL hostedRouteAvailable = manager.isForegroundLeaseActive &&
        hostedBundleId.length > 0 && controller.isPanelActive;

    // ── A. 浮窗正开着 → 换掉主窗里的 App（与「浮窗里点链接跳到别的 App」同一语义）
    if (hostedRouteAvailable) {
        if ([targetBundleId isEqualToString:hostedBundleId]) {
            POExternalNotificationLog(@"目标就是当前浮窗里的 App ⇒ 不接管（避免内容重载）");
            return nil;
        }
        if (!prepareSuspended()) {
            POExternalNotificationLog(@"suspended 选项不可写 ⇒ 放行原生");
            return nil;
        }
        // 【0.7.7】已确定接管 ⇒ 把被点的那条通知标已读（浮窗起来后 0.45s 生效）
        POExternalScheduleDismissDeliveredNotification(targetBundleId, notificationIdentifier);
        NSUInteger hostGeneration = manager.activeLeaseGeneration;
        NSUInteger routeGeneration = ++self.routeRequestGeneration;
        NSString *sourceBundleId = [hostedBundleId copy];
        POExternalOpenCompletion originalCompletion = completion;
        POExternalOpenCompletion routedCompletion = ^(NSError *error) {
            if (originalCompletion) {
                originalCompletion(error);
            }
            if (error) {
                POExternalNotificationLog(@"OpenApplication 失败（%@）⇒ 放弃接管", error.localizedDescription);
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                ContextHostManager *currentManager = [ContextHostManager sharedInstance];
                NSString *currentHostedBundleId = [ContextHostManager activeHostedBundleId];
                if (routeGeneration != self.routeRequestGeneration ||
                    !currentManager.isForegroundLeaseActive ||
                    currentManager.activeLeaseGeneration != hostGeneration ||
                    ![currentHostedBundleId isEqualToString:sourceBundleId]) {
                    return;
                }
                POXWindow *currentWindow = (POXWindow *)[POXWindow sharedWindow];
                POExternalNotificationLog(@"浮窗换内容 → %@", targetBundleId);
                [currentWindow.controller routeExternalApplicationInsidePullOver:targetBundleId];
            });
        };
        return [routedCompletion copy];
    }

    // ── B. 浮窗关着 → 先以 suspended 起 App（不上前台，屏幕不会闪一下全屏），
    //     OpenApplication 成功后由既有「外部激活」通道把浮窗打开并加载它。
    if (!POExternalPullOverIsStableClosed()) {
        POExternalNotificationLog(@"浮窗正在过渡/不空闲 ⇒ 放行原生");
        return nil;
    }
    // 先占住在途标记，再写 suspended 选项 —— 写失败就立刻回滚，绝不污染原生路径
    if (![self beginNativeRouteForTargetBundleId:targetBundleId sourceBundleId:@"notification"]) {
        POExternalNotificationLog(@"已有一路接管在途 ⇒ 放行原生");
        return nil;
    }
    if (!prepareSuspended()) {
        [self finishNativeRouteForGeneration:self.nativeRouteGeneration];
        POExternalNotificationLog(@"suspended 选项不可写 ⇒ 放行原生");
        return nil;
    }
    NSUInteger nativeGeneration = self.nativeRouteGeneration;
    POExternalOpenCompletion originalCompletion = completion;
    POExternalOpenCompletion routedCompletion = ^(NSError *error) {
        if (originalCompletion) {
            originalCompletion(error);
        }
        [self completeNativeRouteForGeneration:nativeGeneration
                                targetBundleId:targetBundleId
                                         error:error];
    };
    // 【0.7.7】已确定接管 ⇒ 把被点的那条通知标已读（浮窗起来后 0.45s 生效）
    POExternalScheduleDismissDeliveredNotification(targetBundleId, notificationIdentifier);
    POExternalNotificationLog(@"浮窗关着 ⇒ 起 App 后开浮窗加载 %@", targetBundleId);
    return [routedCompletion copy];
}

@end
