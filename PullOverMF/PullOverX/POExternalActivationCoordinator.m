#import "POExternalActivationCoordinator.h"

#import <CoreFoundation/CoreFoundation.h>
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

/// 【0.7.9】路由异常闸：诊断/清理逻辑**永远不许**影响"打开"本身。
/// log69 病根：0.7.8 在打日志阶段就去取 UUID，那一步抛异常 ⇒ 整条 open 请求被丢掉，
/// SpringBoard 反复重试（30 次点击全是「判定=通知」然后没有下文），用户看到的就是"点了没反应、
/// 连全屏都不开"。异常必须在入口处被吃掉，然后**按原生路径放行**。
static NSInteger POExternalRouteFaultBudget = 40;

static void POExternalRouteFaultLog(NSException *exception) {
    if (POExternalRouteFaultBudget <= 0) {
        return;
    }
    POExternalRouteFaultBudget -= 1;
    MFLog(@"[notify] 路由异常已拦截：%@ — %@（本次放行原生打开，功能不受影响）",
          exception.name ?: @"?", exception.reason ?: @"?");
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
// 【0.7.8】点通知进浮窗后，把那条通知清掉（标已读：横幅收起 + 通知中心里消失）
//
// 0.7.7 为什么没生效（log68 实证，三次点通知两次一模一样）：
//  ① `通知 UUID=(无)`：旧实现只试 `action.notificationResponse.notification.request.identifier`
//     一条链。`UINotificationResponseAction` 是 BSAction 子类，内容放在 `-info` 里，
//     不一定暴露 `notificationResponse` ⇒ 一失败整条链放弃。
//  ② `SBNCNotificationDispatcher 相关方法 []`：dump 用 `class_copyMethodList`，
//     它**只列本类**方法；真正的方法在父类 `NCNotificationDispatcher` 上 ⇒ 空列表是假象。
//  ③ `拿不到通知请求列表`：旧实现只试了两个 selector 名字。
//
// 0.7.8 改法（所有私有 API 全部 respondsToSelector 守门；任何一步失败只打日志，
// 绝不影响开窗、绝不误删）：
//  ① UUID 四条路径：公开链 / `-info` 字典 / 对象图深挖 / 36 位 UUID 形态匹配。
//     ★ UUID 只用于「在列表里匹配」，匹配不上就不删 ⇒ 形态误命中也不会误删。
//  ② dump 沿父类链列举，关键字放宽，把真实方法名写进日志（下一版据此收口）。
//  ③ 清除：多候选 dispatcher × 多候选列表 selector × 多候选清除 selector；
//     全落空时在 dispatcher 对象图里直接找 `NCNotificationRequest` 实例兜底。
//  ④ 横幅：清成功后试 `SBBannerManager -dismissAllBanners`（必须无参才调用）。
// ─────────────────────────────────────────────────────────────────────────────

/// 清除动作的日志预算（90 条/会话）：这条路径只在点通知时走，正常不会刷屏。
static NSInteger POExternalNotificationDismissLogBudget = 90;

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


/// 一个通知请求对象的标识：NCNotificationRequest 上叫 uuid / notificationIdentifier，
/// 少数版本叫 identifier。三个都试，取第一个非空字符串。
static NSString *POExternalIdentifierOfNotificationRequest(id request) {
    if (!request) {
        return nil;
    }
    for (NSString *name in @[@"uuid", @"notificationIdentifier", @"identifier"]) {
        id value = POExternalReadObject(request, NSSelectorFromString(name));
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

// ── 对象图扫描：只在「selector 全试过都不行」时兜底用 ──
//   预算 + 截止时间双闸，避免在 SpringBoard 主线程上遍历大对象图卡住。
// ★ ARC 禁止 struct 里出现默认 __strong 的对象指针，这里必须显式 __unsafe_unretained；
//   集合的生命周期由下面这个全局强引用兜住（只在主线程串行使用，不重入）。
typedef struct {
    NSInteger budget;
    CFAbsoluteTime deadline;
    __unsafe_unretained NSMutableSet<NSValue *> *visited;
} POExternalGraphScanContext;

static NSMutableSet<NSValue *> *POExternalGraphScanRetainedVisited = nil;

static void POExternalGraphScanInit(POExternalGraphScanContext *context,
                                    NSInteger budget,
                                    NSTimeInterval milliseconds) {
    context->budget = budget;
    context->deadline = CFAbsoluteTimeGetCurrent() + milliseconds / 1000.0;
    POExternalGraphScanRetainedVisited = [NSMutableSet set];
    context->visited = POExternalGraphScanRetainedVisited;
}

static BOOL POExternalGraphScanExhausted(POExternalGraphScanContext *context) {
    if (context->budget <= 0) {
        return YES;
    }
    if (CFAbsoluteTimeGetCurrent() > context->deadline) {
        context->budget = 0;
        return YES;
    }
    return NO;
}


/// 在对象图里找「第一个类名含 NotificationRequest 的实例」。
/// 这是取 UUID 最准的一条：先定位到通知请求对象，再读它的 uuid 属性，
/// 比「随便抓一个 UUID 形态字符串」可靠得多。
static id POExternalGraphFindFirstNotificationRequest(id object,
                                                      NSInteger depth,
                                                      POExternalGraphScanContext *context) {
    if (!object || depth < 0 || POExternalGraphScanExhausted(context)) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] ||
        [object isKindOfClass:[NSNull class]] || [object isKindOfClass:[NSData class]]) {
        return nil;
    }

    Class cls = object_getClass(object);
    NSString *className = cls ? NSStringFromClass(cls) : @"";
    if ([className rangeOfString:@"NotificationRequest"].location != NSNotFound) {
        return object;
    }

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([context->visited containsObject:key]) {
        return nil;
    }
    [context->visited addObject:key];
    context->budget -= 1;

    if ([object isKindOfClass:[NSDictionary class]] || [object isKindOfClass:[NSArray class]] ||
        [object isKindOfClass:[NSSet class]]) {
        id children = [object isKindOfClass:[NSDictionary class]]
            ? [(NSDictionary *)object allValues]
            : object;
        for (id value in children) {
            id hit = POExternalGraphFindFirstNotificationRequest(value, depth - 1, context);
            if (hit) {
                return hit;
            }
        }
        return nil;
    }

    // ★ 安全闸：只在前几层深挖普通对象的 ivar。深层的 assign/unsafe_unretained 成员
    //   可能已经是野指针，object_getIvar 读它就是 EXC_BAD_ACCESS（会直接打死 SpringBoard）。
    //   通知请求对象一定还在容器里（section / registry 的数组、字典），所以浅层转换
    //   到容器之后就不再深挖普通对象，够用且安全。
    if (depth < 4) {
        return nil;
    }

    Class current = cls;
    NSInteger level = 0;
    while (current && current != [NSObject class] && level < 7) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *encoding = ivar_getTypeEncoding(ivars[index]);
            if (!encoding || encoding[0] != '@') {
                continue;
            }
            id value = nil;
            @try {
                value = object_getIvar(object, ivars[index]);
            } @catch (__unused NSException *exception) {
                value = nil;
            }
            if (!value) {
                continue;
            }
            id hit = POExternalGraphFindFirstNotificationRequest(value, depth - 1, context);
            if (hit) {
                if (ivars) {
                    free(ivars);
                }
                return hit;
            }
            if (POExternalGraphScanExhausted(context)) {
                break;
            }
        }
        if (ivars) {
            free(ivars);
        }
        current = class_getSuperclass(current);
        level += 1;
    }
    return nil;
}

/// 在对象图里找「uuid 等于给定值」的 NCNotificationRequest 实例（最后一层兜底）。
/// 类名用字符串判断，兼容 NCMutableNotificationRequest 这类子类。
static id POExternalGraphFindNotificationRequest(id object,
                                                 NSString *identifier,
                                                 NSInteger depth,
                                                 POExternalGraphScanContext *context) {
    if (!object || depth < 0 || identifier.length == 0 || POExternalGraphScanExhausted(context)) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] ||
        [object isKindOfClass:[NSNull class]] || [object isKindOfClass:[NSData class]]) {
        return nil;
    }
    if ([object isKindOfClass:[NSDictionary class]] || [object isKindOfClass:[NSArray class]] ||
        [object isKindOfClass:[NSSet class]]) {
        NSValue *collectionKey = [NSValue valueWithPointer:(__bridge const void *)object];
        if ([context->visited containsObject:collectionKey]) {
            return nil;
        }
        [context->visited addObject:collectionKey];
        context->budget -= 1;
        NSArray *children = nil;
        if ([object isKindOfClass:[NSDictionary class]]) {
            children = [(NSDictionary *)object allValues];
        } else {
            children = (NSArray *)object;
        }
        for (id value in children) {
            id hit = POExternalGraphFindNotificationRequest(value, identifier, depth - 1, context);
            if (hit) {
                return hit;
            }
        }
        return nil;
    }

    Class cls = object_getClass(object);
    NSString *className = cls ? NSStringFromClass(cls) : @"";
    if ([className rangeOfString:@"NotificationRequest"].location != NSNotFound) {
        NSString *candidate = POExternalIdentifierOfNotificationRequest(object);
        if ([candidate isEqualToString:identifier]) {
            return object;
        }
    }

    // ★ 安全闸：这一条遍历的是 dispatcher 的对象图（比 action 大得多），
    //   深层的 assign/unsafe_unretained 成员可能是野指针，读它就是 EXC_BAD_ACCESS。
    //   通知请求一定在 section 的容器里，所以浅层转到容器之后就不再深挖普通对象。
    if (depth < 3) {
        return nil;
    }

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([context->visited containsObject:key]) {
        return nil;
    }
    [context->visited addObject:key];
    context->budget -= 1;

    Class current = cls;
    NSInteger level = 0;
    while (current && current != [NSObject class] && level < 7) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *encoding = ivar_getTypeEncoding(ivars[index]);
            if (!encoding || encoding[0] != '@') {
                continue;
            }
            id value = nil;
            @try {
                value = object_getIvar(object, ivars[index]);
            } @catch (__unused NSException *exception) {
                value = nil;
            }
            if (!value) {
                continue;
            }
            id hit = POExternalGraphFindNotificationRequest(value, identifier, depth - 1, context);
            if (hit) {
                if (ivars) {
                    free(ivars);
                }
                return hit;
            }
            if (POExternalGraphScanExhausted(context)) {
                break;
            }
        }
        if (ivars) {
            free(ivars);
        }
        current = class_getSuperclass(current);
        level += 1;
    }
    return nil;
}

/// 【0.7.9】结构探测：只读**类名**，不碰对象内部。
/// 「取不到 UUID」时这一行就是下一版定因的唯一线索：
/// action 类名 + 它的 -info 类名（顺带 info 若是字典就把 key 列出来）。
/// ★ 全部走 respondsToSelector 守门，绝不用 KVC valueForKey:（未定义键必抛异常）。
static NSString *POExternalActionsSummary(NSDictionary *dictionary) {
    @try {
        id actions = dictionary[@"__Actions"];
        if (![actions isKindOfClass:[NSArray class]] && [actions respondsToSelector:@selector(allObjects)]) {
            actions = [actions allObjects];
        }
        if (![actions isKindOfClass:[NSArray class]] || [(NSArray *)actions count] == 0) {
            return @"(无 __Actions)";
        }
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id action in (NSArray *)actions) {
            Class actionClass = object_getClass(action);
            NSString *text = actionClass ? NSStringFromClass(actionClass) : @"?";
            id info = POExternalReadObject(action, NSSelectorFromString(@"info"));
            if (info) {
                Class infoClass = object_getClass(info);
                text = [text stringByAppendingFormat:@"(info=%@)", infoClass ? NSStringFromClass(infoClass) : @"?"];
                if ([info isKindOfClass:[NSDictionary class]]) {
                    NSArray *keys = [(NSDictionary *)info allKeys];
                    if (keys.count > 0) {
                        text = [text stringByAppendingFormat:@" keys=%@",
                                [keys componentsJoinedByString:@"|"]];
                    }
                }
            }
            [parts addObject:text];
            if (parts.count >= 3) {
                break;
            }
        }
        return parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"(空)";
    } @catch (NSException *exception) {
        return @"(读取抛异常)";
    }
}

/// 从 openApplication 的 options 里取出「这次点的是哪一条通知」的 UUID。
/// 四条路径依次试，任意一条命中即返回。
/// ★【0.7.9】第二个参数 allowGraphScan：
///   主链路上（点通知的那一刻）**必须传 NO** —— 对象图深挖是本函数里唯一可能真正耗时/踩野指针的部分，
///   它绝不允许出现在 open 事务里。只有 0.45s 后的清除阶段才允许传 YES。
static NSString *POExternalNotificationIdentifierFromOptions(NSDictionary *dictionary, BOOL allowGraphScan) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    @try {
    id actions = dictionary[@"__Actions"];
    if (![actions isKindOfClass:[NSArray class]] &&
        [actions respondsToSelector:@selector(allObjects)]) {
        actions = [actions allObjects];
    }
    NSArray *actionList = [actions isKindOfClass:[NSArray class]] ? actions : nil;

    // 路径 1：公开链 notificationResponse.notification.request.identifier
    for (id action in actionList) {
        id response = POExternalReadObject(action, NSSelectorFromString(@"notificationResponse"));
        if (!response) {
            continue;
        }
        id notification = POExternalReadObject(response, NSSelectorFromString(@"notification"));
        id request = POExternalReadObject(notification, NSSelectorFromString(@"request"));
        id identifier = POExternalReadObject(request, NSSelectorFromString(@"identifier"));
        if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) {
            return identifier;
        }
        NSString *direct = POExternalIdentifierOfNotificationRequest(
            POExternalReadObject(response, NSSelectorFromString(@"request")));
        if (direct.length > 0) {
            return direct;
        }
    }

    // 路径 1b【0.7.9】：action 上几个**无参、只读、不碰 KVC** 的候选 selector。
    //   取到的值只有在该 App 的通知列表里能匹配上才会真删 ⇒ 猜错也只是"匹配不上、不清"，不会误删。
    //   ★ 故意不含 `identifier`：BSAction 自己的 identifier 也是 36 位形态，抓错会堵死兜底。
    for (id action in actionList) {
        for (NSString *name in @[@"notificationRequestIdentifier", @"requestIdentifier",
                                 @"notificationIdentifier", @"notificationUUID", @"uuid"]) {
            id value = POExternalReadObject(action, NSSelectorFromString(name));
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] >= 8) {
                return value;
            }
        }
    }

    // 路径 2：BSAction 的 -info / -infoDictionary（UINotificationResponseAction 的真实承载处）
    for (id action in actionList) {
        for (NSString *name in @[@"info", @"infoDictionary"]) {
            id info = POExternalReadObject(action, NSSelectorFromString(name));
            if (!info) {
                continue;
            }
            for (NSString *key in @[@"UNNotificationResponse", @"notificationResponse",
                                    @"UNNotificationRequest", @"notificationRequest"]) {
                id value = nil;
                if ([info isKindOfClass:[NSDictionary class]]) {
                    value = ((NSDictionary *)info)[key];
                } else {
                    // ★★【0.7.9】这里原来还试了 `valueForKey:` —— 那是 0.7.8 点击彻底失效的元凶：
                    //   BSAction 的 -info 不是字典，而 NSObject 全都有 valueForKey:（KVC 类别），
                    //   respondsToSelector 必然通过 ⇒ 对未定义键必抛 NSUnknownKeyException。
                    //   异常从这条路由抛出去 ⇒ open 请求整条丢弃 ⇒ 反复重试 ⇒ "点了没反应、全屏也不开"。
                    //   只保留 objectForKey:（容器语义，取不到就是 nil，不抛）。
                    SEL readSelector = NSSelectorFromString(@"objectForKey:");
                    if ([info respondsToSelector:readSelector]) {
                        value = ((id (*)(id, SEL, id))objc_msgSend)(info, readSelector, key);
                    }
                }
                if (!value) {
                    continue;
                }
                id request = POExternalReadObject(value, NSSelectorFromString(@"request")) ?: value;
                id identifier = POExternalReadObject(request, NSSelectorFromString(@"identifier"));
                if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) {
                    return identifier;
                }
                NSString *direct = POExternalIdentifierOfNotificationRequest(request);
                if (direct.length > 0) {
                    return direct;
                }
            }
        }
    }

    // 路径 3：在 action 对象图里先找 NotificationRequest 实例，再读它的 uuid。
    // ★ 只做这一种深挖：目标对象就是「通知请求」本身，读到的 uuid 一定是通知的 uuid。
    //   不做「随便抓一个 UUID 形态字符串」那种兜底 —— 容易抓到 BSAction 自己的 identifier，
    //   匹配不上还把「唯一一条」的兜底逻辑堵死，得不偿失。
    if (allowGraphScan && actionList.count > 0) {
        POExternalGraphScanContext requestContext;
        POExternalGraphScanInit(&requestContext, 360, 12.0);
        for (id action in actionList) {
            id request = POExternalGraphFindFirstNotificationRequest(action, 6, &requestContext);
            NSString *identifier = POExternalIdentifierOfNotificationRequest(request);
            if (identifier.length > 0) {
                return identifier;
            }
            if (POExternalGraphScanExhausted(&requestContext)) {
                break;
            }
        }
    }

        return nil;
    } @catch (NSException *exception) {
        static NSInteger budget = 12;
        if (budget > 0) {
            budget -= 1;
            MFLog(@"[notify] 取 UUID 抛异常已拦截：%@ — %@（不影响开窗；本条只记前 12 次）",
                  exception.name ?: @"?", exception.reason ?: @"?");
        }
        return nil;
    }
}

/// 取所有可候选的 dispatcher：UIApplication → notificationDispatcher → 再一层，
/// 外加几个类单例。全部 respondsToSelector 守门，取不到就跳过。
static NSArray *POExternalNotificationDispatchers(void) {
    NSMutableArray *candidates = [NSMutableArray array];
    UIApplication *application = [UIApplication sharedApplication];
    if (application) {
        id first = POExternalReadObject(application, NSSelectorFromString(@"notificationDispatcher"));
        if (first) {
            [candidates addObject:first];
            id second = POExternalReadObject(first, NSSelectorFromString(@"notificationDispatcher"));
            if (second && second != first) {
                [candidates addObject:second];
            }
        }
    }
    for (NSString *className in @[@"SBNCNotificationDispatcher", @"NCNotificationDispatcher"]) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            continue;
        }
        for (NSString *selectorName in @[@"sharedInstance", @"sharedDispatcher"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![cls respondsToSelector:selector]) {
                continue;
            }
            id instance = nil;
            @try {
                instance = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
            } @catch (__unused NSException *exception) {
                instance = nil;
            }
            if (instance && ![candidates containsObject:instance]) {
                [candidates addObject:instance];
            }
        }
    }
    return candidates;
}

/// 每类只 dump 一次：沿**父类链**把这几个关键字的方法名全部打出来。
/// 0.7.7 用 class_copyMethodList 只看本类 ⇒ 打出空列表（log68 行 83），是假象。
static void POExternalDumpNotificationDispatcherSelectors(id dispatcher) {
    if (!dispatcher) {
        return;
    }
    static NSMutableSet<NSString *> *dumpedClasses = nil;
    if (!dumpedClasses) {
        dumpedClasses = [NSMutableSet set];
    }
    Class cls = object_getClass(dispatcher);
    if (!cls) {
        return;
    }
    NSString *className = NSStringFromClass(cls);
    if (!className || [dumpedClasses containsObject:className]) {
        return;
    }
    [dumpedClasses addObject:className];

    NSArray<NSString *> *keywords = @[@"ithdraw", @"ismiss", @"emove", @"lear",
                                      @"equest", @"ection", @"ounce", @"estination"];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    NSInteger total = 0;
    Class current = cls;
    NSInteger level = 0;
    while (current && current != [NSObject class] && level < 8) {
        [chain addObject:NSStringFromClass(current)];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        total += (NSInteger)count;
        for (unsigned int index = 0; index < count; index++) {
            NSString *name = NSStringFromSelector(method_getName(methods[index]));
            if (name.length == 0) {
                continue;
            }
            for (NSString *keyword in keywords) {
                if ([name rangeOfString:keyword].location != NSNotFound) {
                    if (hits.count < 40 && ![hits containsObject:name]) {
                        [hits addObject:name];
                    }
                    break;
                }
            }
        }
        if (methods) {
            free(methods);
        }
        current = class_getSuperclass(current);
        level += 1;
    }
    NSString *joined = [hits componentsJoinedByString:@", "];
    if (joined.length > 1100) {
        joined = [[joined substringToIndex:1100] stringByAppendingString:@"…"];
    }
    POExternalNotificationDismissLog(@"清除通知·API 地图：类=%@ 链=[%@] 本链方法 %ld 个｜相关方法 [%@]",
                                     className,
                                     [chain componentsJoinedByString:@" ← "],
                                     (long)total,
                                     joined.length > 0 ? joined : @"(空)");
}

/// 从一个 dispatcher 上收集该 App 名下的通知请求。返回 nil = 一个列表 selector 都没有。
/// 第二个出参 sectionScoped 表示「列表已按 bundleId 收窄」（决定能不能用「只剩一条」兜底）。
static NSArray *POExternalCollectNotificationRequests(id dispatcher,
                                                      NSString *bundleId,
                                                      BOOL *sectionScoped,
                                                      NSString **usedSelector) {
    NSMutableArray *collected = [NSMutableArray array];
    BOOL scoped = NO;
    NSString *used = nil;

    if (bundleId.length > 0) {
        SEL bySection = NSSelectorFromString(@"notificationRequestsForSectionIdentifier:");
        if ([dispatcher respondsToSelector:bySection]) {
            id value = nil;
            @try {
                value = ((id (*)(id, SEL, id))objc_msgSend)(dispatcher, bySection, bundleId);
            } @catch (__unused NSException *exception) {
                value = nil;
            }
            if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
                [collected addObjectsFromArray:value];
                scoped = YES;
                used = @"notificationRequestsForSectionIdentifier:";
            }
        }
    }

    for (NSString *name in @[@"allNotificationRequests", @"notificationRequests",
                             @"pendingNotificationRequests", @"deliveredNotificationRequests"]) {
        SEL selector = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:selector]) {
            continue;
        }
        id value = POExternalReadObject(dispatcher, selector);
        if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
            [collected addObjectsFromArray:value];
            if (!used) {
                used = name;
            }
        }
    }

    for (NSString *name in @[@"notificationSectionLists", @"sectionLists", @"sections",
                             @"notificationSections", @"structuredSectionLists"]) {
        SEL selector = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:selector]) {
            continue;
        }
        id value = POExternalReadObject(dispatcher, selector);
        if (![value isKindOfClass:[NSArray class]] && [value respondsToSelector:@selector(allObjects)]) {
            value = [value allObjects];
        }
        if (![value isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (id section in (NSArray *)value) {
            for (NSString *innerName in @[@"notificationRequests", @"allNotificationRequests"]) {
                SEL innerSelector = NSSelectorFromString(innerName);
                if (![section respondsToSelector:innerSelector]) {
                    continue;
                }
                id innerValue = POExternalReadObject(section, innerSelector);
                if ([innerValue isKindOfClass:[NSArray class]] && [(NSArray *)innerValue count] > 0) {
                    [collected addObjectsFromArray:innerValue];
                    if (!used) {
                        used = [NSString stringWithFormat:@"%@.%@", name, innerName];
                    }
                }
            }
        }
    }

    if (sectionScoped) {
        *sectionScoped = scoped;
    }
    if (usedSelector) {
        *usedSelector = used;
    }
    return collected.count > 0 ? collected : nil;
}

/// 调 dispatcher 上的清除方法，返回实际生效的 selector 名（没成功返回 nil）。
static NSString *POExternalInvokeNotificationClear(id dispatcher, id request) {
    for (NSString *name in @[@"withdrawNotificationRequest:", @"dismissNotificationRequest:",
                             @"removeNotificationRequest:", @"clearNotificationRequest:"]) {
        SEL selector = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:selector]) {
            continue;
        }
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(dispatcher, selector, request);
            return name;
        } @catch (NSException *exception) {
            POExternalNotificationDismissLog(@"清除通知：%@ 抛异常（%@）⇒ 试下一个", name, exception.reason);
        }
    }
    return nil;
}

/// 清成功后收横幅：只调**无参**的 dismissAllBanners，别的一概不猜。
/// 有些系统的 banner 源在清通知后仍挂 1~2 秒，主动收一次更贴合「点开就没了」的预期。
static void POExternalCollapseNotificationBanners(void) {
    Class bannerManagerClass = NSClassFromString(@"SBBannerManager");
    if (!bannerManagerClass) {
        return;
    }
    id manager = nil;
    for (NSString *name in @[@"sharedInstance", @"sharedManager", @"bannerManager"]) {
        SEL selector = NSSelectorFromString(name);
        if (![bannerManagerClass respondsToSelector:selector]) {
            continue;
        }
        @try {
            manager = ((id (*)(id, SEL))objc_msgSend)(bannerManagerClass, selector);
        } @catch (__unused NSException *exception) {
            manager = nil;
        }
        if (manager) {
            break;
        }
    }
    if (!manager) {
        return;
    }
    SEL dismiss = NSSelectorFromString(@"dismissAllBanners");
    if (![manager respondsToSelector:dismiss]) {
        return;
    }
    @try {
        ((void (*)(id, SEL))objc_msgSend)(manager, dismiss);
        POExternalNotificationDismissLog(@"清除通知：已收起通知横幅（SBBannerManager -dismissAllBanners）");
    } @catch (NSException *exception) {
        POExternalNotificationDismissLog(@"清除通知：收横幅抛异常（%@）", exception.reason);
    }
}

/// 按 UUID 清掉一条已投递的通知。**拿不到就什么都不做**。
static void POExternalDismissDeliveredNotification(NSString *bundleId, NSString *identifier) {
    @try {
        NSArray *dispatchers = POExternalNotificationDispatchers();
        if (dispatchers.count == 0) {
            POExternalNotificationDismissLog(@"清除通知：拿不到 notificationDispatcher（放弃，不影响开窗）");
            return;
        }
        NSMutableArray<NSString *> *triedNotes = [NSMutableArray array];
        for (id dispatcher in dispatchers) {
            POExternalDumpNotificationDispatcherSelectors(dispatcher);

            BOOL sectionScoped = NO;
            NSString *usedSelector = nil;
            NSArray *requests = POExternalCollectNotificationRequests(dispatcher, bundleId,
                                                                     &sectionScoped, &usedSelector);
            [triedNotes addObject:[NSString stringWithFormat:@"%@列表%@",
                                   NSStringFromClass(object_getClass(dispatcher)),
                                   usedSelector ?: @"(无)"]];
            if (requests.count == 0) {
                continue;
            }

            id target = nil;
            if (identifier.length > 0) {
                for (id request in requests) {
                    NSString *candidate = POExternalIdentifierOfNotificationRequest(request);
                    if ([candidate isEqualToString:identifier]) {
                        target = request;
                        break;
                    }
                }
            }
            // 兜底：UUID 没取到，但该 App 名下只剩一条 ⇒ 就是刚点的那条。
            // ★ 只在 sectionScoped 成立时用：全系统列表里「只剩一条」可能是别的 App 的通知。
            if (!target && sectionScoped && identifier.length == 0 && requests.count == 1) {
                target = requests.firstObject;
            }
            if (!target) {
                [triedNotes addObject:[NSString stringWithFormat:@"%@共 %lu 条但未匹配",
                                       usedSelector ?: @"列表",
                                       (unsigned long)requests.count]];
                continue;
            }

            NSString *clearSelector = POExternalInvokeNotificationClear(dispatcher, target);
            if (!clearSelector) {
                POExternalNotificationDismissLog(@"清除通知：%@ 上没有可用的清除方法（withdraw/dismiss/remove/clear 都不响应）",
                                                 NSStringFromClass(object_getClass(dispatcher)));
                continue;
            }
            POExternalNotificationDismissLog(@"清除通知：已清除 %@ 的 1 条（UUID=%@，%@ %@）",
                                             bundleId,
                                             identifier.length > 0 ? identifier : @"(按唯一一条兜底)",
                                             NSStringFromClass(object_getClass(dispatcher)),
                                             clearSelector);
            POExternalCollapseNotificationBanners();
            return;
        }

        // ── 最后兜底：在 dispatcher 对象图里直接找 uuid 匹配的 NCNotificationRequest ──
        if (identifier.length > 0) {
            for (id dispatcher in dispatchers) {
                POExternalGraphScanContext context;
                POExternalGraphScanInit(&context, 900, 30.0);
                id request = POExternalGraphFindNotificationRequest(dispatcher, identifier, 6, &context);
                if (!request) {
                    continue;
                }
                NSString *clearSelector = POExternalInvokeNotificationClear(dispatcher, request);
                if (clearSelector) {
                    POExternalNotificationDismissLog(@"清除通知：已清除 %@ 的 1 条（对象图兜底，%@ %@）",
                                                     bundleId, NSStringFromClass(object_getClass(dispatcher)),
                                                     clearSelector);
                    POExternalCollapseNotificationBanners();
                    return;
                }
            }
        }

        POExternalNotificationDismissLog(@"清除通知：全部路径未命中（UUID=%@，已试 [%@]）",
                                         identifier.length > 0 ? identifier : @"(无)",
                                         [triedNotes componentsJoinedByString:@" ｜ "]);
    } @catch (NSException *exception) {
        POExternalNotificationDismissLog(@"清除通知异常：%@", exception.reason);
    }
}

/// 延后 0.45s 再清：此刻 SpringBoard 正跑 OpenApplication 事务，
/// 立刻去动通知中心有撞内部断言的历史（0.6.20 控制中心那一课）。
/// 等浮窗起来再清，用户看到的是「浮窗出现 → 通知随即消失」。
static void POExternalScheduleDismissDeliveredNotification(NSString *bundleId, NSDictionary *options) {
    if (bundleId.length == 0) {
        return;
    }
    NSString *targetBundleId = [bundleId copy];
    NSDictionary *targetOptions = [options isKindOfClass:[NSDictionary class]] ? [options copy] : nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // ★【0.7.9】UUID 在这里（0.45s 后、已脱离 open 事务）才解析，而且允许对象图兜底。
        //   主链路一概不碰 —— 最坏结果只是"通知没清掉"，绝不影响开窗。
        NSString *identifier = nil;
        @try {
            identifier = POExternalNotificationIdentifierFromOptions(targetOptions, YES);
        } @catch (NSException *exception) {
            identifier = nil;
        }
        POExternalDismissDeliveredNotification(targetBundleId, identifier);
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
                      notificationOptions:(NSDictionary *)notificationOptions
                                 completion:(id)completion;
@end

@implementation POExternalActivationCoordinator

+ (instancetype)sharedInstance {
    static POExternalActivationCoordinator *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [POExternalActivationCoordinator new];
        MFLog(@"[notify] 0.7.4 P2 已启用：点通知 → 悬浮窗"
              "（开关 mfNotificationClickFloat 默认开；0.7.9 起入口 = 圆盘编辑器一级行「点通知进悬浮窗」，"
              "二级页里可选「全部应用」或「仅选中的应用」）"
              "｜识别 = launchOrigin 含 notification/bulletin/banner，或调用栈命中 NCNotification/SBNotification/Banner");
        MFLog(@"[notify] 0.7.7 已启用：点通知进浮窗后自动清除该条通知（标已读）"
              "｜UUID 取自 options.__Actions 的 notificationResponse.request.identifier"
              "｜清除 = NCNotificationDispatcher -withdrawNotificationRequest:（拿不到就不动，绝不误删）");
        MFLog(@"[notify] 0.7.8 已启用：清通知改成多路径（UUID 三路提取 + 沿父类链找 API + 对象图兜底 + 收横幅）"
              "｜上一版只试一条 notificationResponse 链、dump 又只看本类方法，所以两次都空转");
        // 【0.7.9】本版专有条幅（看到这一行 = 本版已生效）
        MFLog(@"[notify] 0.7.9 已启用：点通知恢复（UUID 提取移出主链路 + 全链路异常闸）"
              "｜0.7.9 在打日志阶段就取 UUID，取异常抛出去把整条 open 请求打死 ⇒ 点了没反应、全屏也不开");
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
    // ★★【0.7.9】0.7.8 就是在这里把整条点击打死的（log69：30 次点击全部「判定=通知」后没有下文，
    //   App 连全屏都不开 ⇒ 异常抛出去、open 请求被整条丢弃并反复重试）。
    //   现在异常一律吃掉并按原生路径放行 —— "点了没反应"这个后果从此不可能再出现。
    id notificationCompletion = nil;
    @try {
        notificationCompletion = [self routeNotificationLaunchIfNeeded:request
                                                              completion:completion];
    } @catch (NSException *exception) {
        POExternalRouteFaultLog(exception);
        notificationCompletion = nil;
    }
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
    id notificationOptions = nil;
    @try {
        notificationOptions = [self routeNotificationLaunchForTrustedApplication:application
                                                                         options:options
                                                                          origin:origin
                                                                          result:result
                                                                    routedResult:&notificationResult];
    } @catch (NSException *exception) {
        POExternalRouteFaultLog(exception);
        notificationOptions = nil;
        notificationResult = result;
    }
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
        // ★★【0.7.9】主链路上**绝不**取 UUID（0.7.8 就是死在这一步）：
        //   这里只打类名结构，零风险，而且正好是下一版定因要的证据。
        POExternalNotificationLog(@"  actions=%@", POExternalActionsSummary(dictionary));
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
                                   notificationOptions:dictionary
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
                                                   notificationOptions:dictionary
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
                      notificationOptions:(NSDictionary *)notificationOptions
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
        POExternalScheduleDismissDeliveredNotification(targetBundleId, notificationOptions);
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
    POExternalScheduleDismissDeliveredNotification(targetBundleId, notificationOptions);
    POExternalNotificationLog(@"浮窗关着 ⇒ 起 App 后开浮窗加载 %@", targetBundleId);
    return [routedCompletion copy];
}

@end
