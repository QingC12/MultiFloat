//
//  MFSystemActions.m
//  PullOverMF —— 圆盘「系统动作」实现（方案 A：进程内直调，零新增 hook）
//
//  见 MFSystemActions.h 的设计说明。本文件只做两件事：
//    ① 把"动作"描述给圆盘用（伪 bundleID / 中文名 / 图标）；
//    ② 真正执行动作（每类动作给 2~3 条候选实现，逐条试探并写日志，命中哪条一目了然）。
//
//  ★ 铁律遵守：
//    · 绝不用 `-framework`（私有框架一律 `objc_getClass` 动态取，取不到就换候选）；
//    · 每次调私有接口都 `respondsToSelector` + `@try`，失败只写日志；
//    · 所有 @try 内不写 ARC 的 weakSelf->（铁律 6）。
//
#import "MFSystemActions.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "POXWindow.h"
#import "PullOverViewController.h"

NSString * const MFSystemActionIdPrefix = @"mfsys.";

static NSString * const kMFSystemActionScreenshot = @"mfsys.screenshot";
static NSString * const kMFSystemActionTranslate  = @"mfsys.translate";
// 【0.6.11 用户指令】ACR 快捷方式扩编：录屏 / 控制中心 / 通知中心（用户叫这类快捷动作"ACR"）
static NSString * const kMFSystemActionRecord     = @"mfsys.record";
static NSString * const kMFSystemActionCC         = @"mfsys.controlcenter";
static NSString * const kMFSystemActionNC         = @"mfsys.notificationcenter";

/// 圆盘收起动画 0.22s（MFRingPicker.m 的 hide）⇒ 动作统一延后 0.35s 执行，
/// 保证截图/翻译面板出现时圆盘已经不在了。
static NSTimeInterval const MFSystemActionSafeDelay = 0.35;

/// 图标渲染尺寸（pt）：足够大，缩小到圆盘/编辑器任何尺寸都清晰
static CGFloat const MFSystemActionIconPointSize = 72.0;

#pragma mark - 描述

BOOL MFSystemActionIsActionId(NSString *bundleId) {
    return [bundleId isKindOfClass:[NSString class]] && [bundleId hasPrefix:MFSystemActionIdPrefix];
}

NSString *MFSystemActionDisplayName(NSString *actionId) {
    if ([actionId isEqualToString:kMFSystemActionScreenshot]) {
        return @"截屏";
    }
    if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        return @"翻译";
    }
    if ([actionId isEqualToString:kMFSystemActionRecord]) {
        return @"录屏";
    }
    if ([actionId isEqualToString:kMFSystemActionCC]) {
        return @"控制中心";
    }
    if ([actionId isEqualToString:kMFSystemActionNC]) {
        return @"通知中心";
    }
    return nil;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MFSystemActionEditorEntries(void) {
    // 【0.6.11 用户指令】名字后面带「· ACR」——用户对这类系统快捷动作的叫法，编辑器里
    //   与"桌面 APP"一眼区分（它们置顶显示）
    return @[ @{ @"id": kMFSystemActionScreenshot, @"name": @"截屏 · ACR" },
              @{ @"id": kMFSystemActionTranslate,  @"name": @"翻译 · ACR" },
              @{ @"id": kMFSystemActionRecord,     @"name": @"录屏 · ACR" },
              @{ @"id": kMFSystemActionCC,         @"name": @"控制中心 · ACR" },
              @{ @"id": kMFSystemActionNC,         @"name": @"通知中心 · ACR" } ];
}

/// 动作对应的 SF Symbol 名（取不到会走候补符号）
static NSString *MFSystemActionSymbolName(NSString *actionId) {
    if ([actionId isEqualToString:kMFSystemActionScreenshot]) {
        return @"camera.viewfinder";
    }
    if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        return @"translate";
    }
    if ([actionId isEqualToString:kMFSystemActionRecord]) {
        return @"record.circle";   // 【0.6.11】录屏 = 红色录制圆
    }
    if ([actionId isEqualToString:kMFSystemActionCC]) {
        return @"slider.horizontal.3";   // 【0.6.11】控制中心 = 滑杆组
    }
    if ([actionId isEqualToString:kMFSystemActionNC]) {
        return @"bell";   // 【0.6.11】通知中心 = 铃铛
    }
    return nil;
}

/// 动作底圆配色 —— 每个动作一色（简洁 + 一眼可辨）：
///   截屏=系统蓝、翻译=靛蓝、录屏=红（录制惯例色）、控制中心=青、通知中心=橙
static UIColor *MFSystemActionTintColor(NSString *actionId) {
    if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
    }
    if ([actionId isEqualToString:kMFSystemActionRecord]) {
        return [UIColor colorWithRed:0.90 green:0.26 blue:0.26 alpha:1.0];
    }
    if ([actionId isEqualToString:kMFSystemActionCC]) {
        return [UIColor colorWithRed:0.08 green:0.60 blue:0.60 alpha:1.0];
    }
    if ([actionId isEqualToString:kMFSystemActionNC]) {
        return [UIColor colorWithRed:0.95 green:0.55 blue:0.14 alpha:1.0];
    }
    return [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0];
}

/// 候补符号（老系统没有主符号时用）
static NSString *MFSystemActionFallbackSymbolName(NSString *actionId) {
    if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        return @"globe";
    }
    if ([actionId isEqualToString:kMFSystemActionRecord]) {
        return @"circle.fill";
    }
    if ([actionId isEqualToString:kMFSystemActionCC]) {
        return @"gearshape.fill";
    }
    if ([actionId isEqualToString:kMFSystemActionNC]) {
        return @"bell.fill";
    }
    return nil;
}

UIImage *MFSystemActionIcon(NSString *actionId, CGFloat pointSize) {
    NSString *symbol = MFSystemActionSymbolName(actionId);
    if (symbol.length == 0) {
        return nil;
    }
    CGFloat side = (isfinite(pointSize) && pointSize > 8.0) ? pointSize : MFSystemActionIconPointSize;
    UIImage *image = nil;
    @try {
        UIImage *glyph = [UIImage systemImageNamed:symbol];
        if (glyph == nil) {
            NSString *fallback = MFSystemActionFallbackSymbolName(actionId);
            if (fallback.length > 0) {
                glyph = [UIImage systemImageNamed:fallback];
            }
        }
        if (glyph == nil) {
            return nil;
        }
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:side * 0.52
                                                            weight:UIImageSymbolWeightSemibold];
        glyph = [glyph imageWithConfiguration:config];
        glyph = [glyph imageWithTintColor:[UIColor whiteColor]
                            renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize glyphSize = glyph.size;
        if (!(glyphSize.width > 0.5) || !(glyphSize.height > 0.5)) {
            return nil;
        }
        UIColor *background = MFSystemActionTintColor(actionId);
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
            CGRect rect = CGRectMake(0.0, 0.0, side, side);
            UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect
                                                            cornerRadius:side * 0.28];
            [background setFill];
            [path fill];
            [glyph drawInRect:CGRectMake((side - glyphSize.width) / 2.0,
                                         (side - glyphSize.height) / 2.0,
                                         glyphSize.width, glyphSize.height)];
        }];
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 生成动作图标异常（%@）：%@", actionId, exception);
        image = nil;
    }
    return image;
}

#pragma mark - 通用小工具

/// SpringBoard 当前最顶层的可 present 控制器（找不到返回 nil）
static UIViewController *MFSystemActionTopViewController(void) {
    UIWindow *keyWindow = nil;
    @try {
        UIApplication *application = [UIApplication sharedApplication];
        for (UIWindow *window in application.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (keyWindow == nil) {
            keyWindow = application.windows.firstObject;
        }
    } @catch (__unused NSException *exception) {
        keyWindow = nil;
    }
    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

/// 以**浮窗**打开某个 App（复用插件已有的 pin + open 能力，不打断用户当前在用的 App）
static BOOL MFSystemActionOpenInFloatWindow(NSString *bundleId) {
    // ★ 不用 `objc_getClass`+performSelector 那套：POXWindow.h 已 import，直接按类型取更干净
    //   （ARC 下 performSelector: 的返回值会被 -Warc-performSelector-leaks 判成可能泄漏，
    //    而本项目 Theos 全量 -Werror ⇒ 会直接中断构建）。
    POXWindow *sharedWindow = (POXWindow *)[POXWindow sharedWindow];
    if (![sharedWindow isKindOfClass:[UIWindow class]]) {
        return NO;
    }
    PullOverViewController *controller = sharedWindow.controller;
    if (controller == nil) {
        return NO;
    }
    SEL pinSelector = NSSelectorFromString(@"pinAppWithBundleId:");
    SEL openSelector = NSSelectorFromString(@"open");
    if (![controller respondsToSelector:pinSelector] || ![controller respondsToSelector:openSelector]) {
        return NO;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(controller, pinSelector, bundleId);
    ((void (*)(id, SEL))objc_msgSend)(controller, openSelector);
    return YES;
}

/// 系统里装没装这个 App（LSApplicationWorkspace；查不到时返回 NO 只影响兜底顺序）
static BOOL MFSystemActionAppIsInstalled(NSString *bundleId) {
    BOOL installed = NO;
    @try {
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
        if (workspaceClass != Nil && [workspaceClass respondsToSelector:defaultSelector]) {
            id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
            SEL checkSelector = NSSelectorFromString(@"applicationIsInstalled:");
            if (workspace != nil && [workspace respondsToSelector:checkSelector]) {
                installed = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, checkSelector, bundleId);
            }
        }
    } @catch (__unused NSException *exception) {
        installed = NO;
    }
    return installed;
}

#pragma mark - 动作①：截屏

/// 【0.4.12 用户 log37】0.4.12 的三条候选在用户设备上**静默全灭**（日志只有"所有候选都没成功"，
/// 连一条候选日志都没有 —— 类不存在 / selector 不响应都被无声跳过）。这一版：
///   ① 每条候选都打"类是否存在 / 是否响应 / 实际调用"诊断日志；
///   ② 已知类列表扩到 SBScreenShotter / SBScreenshotManager，类方法和实例方法都试；
///   ③ 全失败时**运行时扫描**：把本机所有名字含 Screenshot 的类、以及它们含 screenshot 字样的
///      方法全部打到日志 —— 下一轮日志直接把可用 API 钉死，不再靠猜。
/// 按"参数寄存器个数"自适应调用（0~2 个参数：对象参数一律给 nil / BOOL 给 NO），
/// 参数更多的签名不敢乱调（怕把 0 当非空对象 → 绕不过 @try 的 BAD_ACCESS）。
static BOOL MFSystemActionInvokeScreenshotSelector(id target, SEL selector, NSString *label) {
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (method == NULL) {
        return NO;
    }
    NSUInteger registers = method_getNumberOfArguments(method);   // 2 + 参数寄存器数
    @try {
        if (registers == 2) {
            ((void (*)(id, SEL))objc_msgSend)(target, selector);
        } else if (registers == 3) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, selector, nil);
        } else if (registers == 4) {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(target, selector, NO, nil);
        } else {
            MFLog(@"[sysact] 截屏 %@：参数寄存器 %lu 个，跳过（不敢乱调）", label, (unsigned long)(registers - 2));
            return NO;
        }
        MFLog(@"[sysact] 截屏：命中 %@（参数 %lu 个）", label, (unsigned long)(registers - 2));
        return YES;
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 截屏 %@ 调用异常：%@", label, exception);
        return NO;
    }
}

/// SpringBoard sharedApplication（拿 screenshotManager 属性用）。
static id MFSystemActionSpringBoardApp(void) {
    Class sbClass = objc_getClass("SpringBoard");
    if (sbClass == Nil || ![sbClass respondsToSelector:@selector(sharedApplication)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(sbClass, @selector(sharedApplication));
}

static void MFSystemActionDumpScreenshotMethods(Class cls, NSString *label);

/// 对单个"疑似截图管理"类：打存在性日志 → 尽一切可能拿到**实例** → 已知 selector 逐个试。
/// 实例来源（log38 实证 + AppleWiki iOS 9.3 起实证：SBScreenShotter 已被 SBScreenshotManager 取代，
/// 实例挂在 SpringBoard 的 screenshotManager 属性上——0.4.12 只试了类方法所以全灭）：
///   ① 类的 sharedInstance；
///   ② SpringBoard sharedApplication 的 screenshotManager 属性（是本类的实例才收）；
///   ③ 类名含 ScreenshotProvider 的（_SBMainScreenScreenshotProvider 等，无 sharedInstance）→ alloc/init。
/// 全部未命中时把类的方法清单 dump 进日志（下轮日志钉真实 API）。
static BOOL MFSystemActionProbeScreenshotClass(NSString *className) {
    Class cls = objc_getClass(className.UTF8String);
    if (cls == Nil) {
        MFLog(@"[sysact] 截屏候选 %@：类不存在", className);
        return NO;
    }
    MFLog(@"[sysact] 截屏候选 %@：类存在", className);
    NSMutableArray<id> *instances = [NSMutableArray array];
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        @try {
            id instance = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            if (instance != nil) {
                [instances addObject:instance];
                MFLog(@"[sysact] 截屏候选 %@：sharedInstance 可用", className);
            }
        } @catch (NSException *exception) {
            MFLog(@"[sysact] !! %@ sharedInstance 异常：%@", className, exception);
        }
    }
    id sbApp = MFSystemActionSpringBoardApp();
    if (sbApp != nil && [sbApp respondsToSelector:@selector(screenshotManager)]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(sbApp, @selector(screenshotManager));
        if (manager != nil && [manager isKindOfClass:cls]) {
            [instances addObject:manager];
            MFLog(@"[sysact] 截屏候选 %@：SpringBoard.screenshotManager 实例可用", className);
        }
    }
    if (instances.count == 0 && [className containsString:@"ScreenshotProvider"]) {
        @try {
            id instance = [[cls alloc] init];
            if (instance != nil) {
                [instances addObject:instance];
                MFLog(@"[sysact] 截屏候选 %@：alloc/init 实例可用（Provider 类）", className);
            }
        } @catch (NSException *exception) {
            MFLog(@"[sysact] !! %@ alloc/init 异常：%@", className, exception);
        }
    }
    if (instances.count == 0) {
        MFLog(@"[sysact] 截屏候选 %@：三种实例来源全部落空，只试了类方法", className);
    }
    NSArray<NSString *> *names = @[
        @"saveScreenshot:withCompletion:",
        @"saveScreenshotWithCompletion:",
        @"saveScreenshotsWithCompletion:",
        @"takeScreenshot",
        @"saveScreenshot",
        @"captureScreenshot",
        @"captureScreenshotWithCompletion:",
        @"requestScreenshot",
        @"saveScreenshotForTrustedClient",
    ];
    for (NSString *selectorName in names) {
        SEL selector = NSSelectorFromString(selectorName);
        NSString *label = [NSString stringWithFormat:@"%@ %@", className, selectorName];
        if ([cls respondsToSelector:selector]) {
            if (MFSystemActionInvokeScreenshotSelector(cls, selector,
                                                       [label stringByAppendingString:@" (类方法)"])) {
                return YES;
            }
        }
        for (id instance in instances) {
            if ([instance respondsToSelector:selector]) {
                if (MFSystemActionInvokeScreenshotSelector(instance, selector, label)) {
                    return YES;
                }
            }
        }
    }
    MFSystemActionDumpScreenshotMethods(cls, className);
    MFLog(@"[sysact] 截屏候选 %@：已知 selector 全部未响应", className);
    return NO;
}

/// 把一个类的"含 screenshot 字样"方法全打出来（类方法 + 实例方法，封顶 40 行防爆日志）。
static void MFSystemActionDumpScreenshotMethods(Class cls, NSString *label) {
    for (Class probeClass = cls, metaClass = object_getClass(cls);
         probeClass != nil;
         probeClass = (probeClass == metaClass ? nil : metaClass)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(probeClass, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *selectorName = NSStringFromSelector(method_getName(methods[i]));
            if ([selectorName localizedCaseInsensitiveContainsString:@"screenshot"]) {
                MFLog(@"[sysact]   %@ 方法：%@（参数 %u）", label, selectorName,
                      method_getNumberOfArguments(methods[i]) - 2);
            }
        }
        if (methods != NULL) {
            free(methods);
        }
        if (probeClass == metaClass) {
            break;
        }
    }
}

static BOOL MFSystemActionTakeScreenshot(void) {
    // ① / ② 已知截图管理类（log38 实证：SBScreenShotter 在用户系统上已不存在；
    //    AppleWiki：iOS 9.3 起 SBScreenshotManager 实例挂 SpringBoard.screenshotManager）
    for (NSString *className in @[ @"SBScreenshotManager", @"SBScreenShotter" ]) {
        if (MFSystemActionProbeScreenshotClass(className)) {
            return YES;
        }
    }

    // ③ SBUIController 的 _takeScreenshot / takeScreenshot（老路兜底）
    @try {
        Class uiControllerClass = objc_getClass("SBUIController");
        if (uiControllerClass == Nil) {
            MFLog(@"[sysact] 截屏候选 SBUIController：类不存在");
        } else if (![uiControllerClass respondsToSelector:@selector(sharedInstance)]) {
            MFLog(@"[sysact] 截屏候选 SBUIController：无 sharedInstance");
        } else {
            id uiController = ((id (*)(id, SEL))objc_msgSend)(uiControllerClass, @selector(sharedInstance));
            for (NSString *selectorName in @[ @"_takeScreenshot", @"takeScreenshot" ]) {
                SEL selector = NSSelectorFromString(selectorName);
                if ([uiController respondsToSelector:selector]) {
                    ((void (*)(id, SEL))objc_msgSend)(uiController, selector);
                    MFLog(@"[sysact] 截屏：命中 SBUIController %@", selectorName);
                    return YES;
                }
            }
            MFLog(@"[sysact] 截屏候选 SBUIController：_takeScreenshot / takeScreenshot 均未响应");
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 截屏 SBUIController 异常：%@", exception);
    }

    // ④ 运行时扫描（全失败的定位手段）：把本机所有 Screenshot 相关类和方法打到日志。
    //    下一轮把这段日志回传，就能按真实 API 精确补候选 —— 不再猜。
    MFLog(@"[sysact] 截屏：已知候选全失败，开始运行时扫描（结果在下面，请回传日志）");
    @try {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        unsigned int loggedLines = 0;
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if (![name localizedCaseInsensitiveContainsString:@"screenshot"]) {
                continue;
            }
            if (loggedLines < 40) {
                MFLog(@"[sysact] 扫描：发现类 %@", name);
                loggedLines++;
                MFSystemActionDumpScreenshotMethods(classes[i], name);
            }
            // 名字像截图管理的类顺手试一遍已知 selector（自适应参数 + @try 保护）
            if (MFSystemActionProbeScreenshotClass(name)) {
                if (classes != NULL) {
                    free(classes);
                }
                return YES;
            }
        }
        if (classes != NULL) {
            free(classes);
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 截屏运行时扫描异常：%@", exception);
    }
    return NO;
}

#pragma mark - 动作②：翻译

/// 翻译（两级）：
///   ① 真·系统翻译面板：`LTUITranslationViewController`（TranslationUI 私有框架），
///      把剪贴板里的文字直接填进去并 present —— 这是"翻译"最贴切的系统入口；
///   ② 任一环节对不上（类不存在 / 取不到文本属性 / present 失败）⇒ 兜底**以浮窗打开
///      系统「翻译」App**（不打断用户当前在用的 App）。
static BOOL MFSystemActionPresentTranslationPanel(void) {
    NSString *clipboardText = nil;
    @try {
        clipboardText = [UIPasteboard generalPasteboard].string;
    } @catch (__unused NSException *exception) {
        clipboardText = nil;
    }

    UIViewController *host = MFSystemActionTopViewController();
    if (host == nil) {
        MFLog(@"[sysact] 翻译：找不到可 present 的宿主控制器");
        return NO;
    }

    @try {
        Class panelClass = NSClassFromString(@"LTUITranslationViewController");
        if (panelClass == Nil) {
            MFLog(@"[sysact] 翻译：没有 LTUITranslationViewController 这个类（走兜底）");
            return NO;
        }
        id panel = [[panelClass alloc] init];
        if (panel == nil || ![panel isKindOfClass:[UIViewController class]]) {
            MFLog(@"[sysact] 翻译：LTUITranslationViewController 初始化失败（走兜底）");
            return NO;
        }
        // 文本属性名各版本不一：text / sourceText 都试一下（KVC 取不到会抛，已包 @try）
        BOOL textSet = NO;
        if (clipboardText.length > 0) {
            for (NSString *key in @[ @"text", @"sourceText" ]) {
                @try {
                    [panel setValue:clipboardText forKey:key];
                    textSet = YES;
                    break;
                } @catch (__unused NSException *exception) {
                }
            }
        }
        [host presentViewController:panel animated:YES completion:nil];
        MFLog(@"[sysact] 翻译：已弹出系统翻译面板（剪贴板文字 %@）",
              textSet ? @"已自动填入" : @"为空，未填入");
        return YES;
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 翻译面板异常：%@", exception);
    }
    return NO;
}

/// 兜底：以浮窗打开系统「翻译」App
static BOOL MFSystemActionOpenTranslateApp(void) {
    for (NSString *bundleId in @[ @"com.apple.Translate", @"com.apple.translate" ]) {
        if (!MFSystemActionAppIsInstalled(bundleId)) {
            continue;
        }
        if (MFSystemActionOpenInFloatWindow(bundleId)) {
            MFLog(@"[sysact] 翻译：已用浮窗打开 %@", bundleId);
            return YES;
        }
    }
    MFLog(@"[sysact] !! 翻译：系统「翻译」App 未安装，且未能以浮窗打开");
    return NO;
}

#pragma mark - 【0.6.11】通用自适应调用器（录屏 / 控制中心 / 通知中心共用）

/// 按方法签名自适应调用（0~2 个参数寄存器）：BOOL 参数给 `flagValue`，对象参数一律 nil。
/// 与截屏同款保护：method 不存在 / 参数再多不敢乱调 / @try 兜底，全程写日志。
static BOOL MFSystemActionInvokeAdaptive(id target, SEL selector, NSString *label, BOOL flagValue) {
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (method == NULL) {
        return NO;
    }
    NSUInteger registers = method_getNumberOfArguments(method);   // 2 + 参数寄存器数
    @try {
        if (registers == 2) {
            ((void (*)(id, SEL))objc_msgSend)(target, selector);
        } else if (registers == 3) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, flagValue);
        } else if (registers == 4) {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(target, selector, flagValue, nil);
        } else {
            MFLog(@"[sysact] %@：参数寄存器 %lu 个，跳过（不敢乱调）",
                  label, (unsigned long)(registers - 2));
            return NO;
        }
        MFLog(@"[sysact] %@：命中（参数 %lu 个）", label, (unsigned long)(registers - 2));
        return YES;
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! %@ 调用异常：%@", label, exception);
        return NO;
    }
}

/// 在实例上按"名字含关键字"扫描可调方法（封顶 12 个，避免日志爆炸）。
/// `preferKeywords` 命中的排前面（toggle/start/begin 这类动作词优先于 get/query）。
static BOOL MFSystemActionScanAndInvoke(id target, NSArray<NSString *> *keywords,
                                        NSArray<NSString *> *preferKeywords,
                                        NSString *label, BOOL flagValue) {
    if (target == nil) {
        return NO;
    }
    Class cls = object_getClass(target);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (method_getNumberOfArguments(methods[i]) > 4) {
            continue;   // 只调 ≤2 参数寄存器的
        }
        for (NSString *keyword in keywords) {
            if ([name localizedCaseInsensitiveContainsString:keyword]) {
                [candidates addObject:name];
                break;
            }
        }
    }
    if (methods != NULL) {
        free(methods);
    }
    // 偏好词置前
    [candidates sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        for (NSString *prefer in preferKeywords) {
            BOOL aHit = [a localizedCaseInsensitiveContainsString:prefer];
            BOOL bHit = [b localizedCaseInsensitiveContainsString:prefer];
            if (aHit != bHit) {
                return aHit ? NSOrderedAscending : NSOrderedDescending;
            }
        }
        return NSOrderedSame;
    }];
    for (NSUInteger i = 0; i < candidates.count && i < 12; i++) {
        SEL selector = NSSelectorFromString(candidates[i]);
        if (MFSystemActionInvokeAdaptive(target, selector,
                                         [NSString stringWithFormat:@"%@ %@",
                                          label, candidates[i]], flagValue)) {
            return YES;
        }
    }
    if (candidates.count > 0) {
        MFLog(@"[sysact] %@：候选 %@ 全部未成功", label,
              [candidates subarrayWithRange:NSMakeRange(0, MIN(candidates.count, 6))]);
    }
    return NO;
}

/// 拿某个单例类的实例（sharedInstance 优先，mainInstance/alloc/init 兜底）
static id MFSystemActionSingletonInstance(NSString *className, NSString *label) {
    Class cls = objc_getClass(className.UTF8String);
    if (cls == Nil) {
        MFLog(@"[sysact] %@：类 %@ 不存在", label, className);
        return nil;
    }
    for (NSString *getter in @[ @"sharedInstance", @"mainInstance", @"defaultInstance" ]) {
        SEL selector = NSSelectorFromString(getter);
        if ([cls respondsToSelector:selector]) {
            @try {
                id instance = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
                if (instance != nil) {
                    MFLog(@"[sysact] %@：%@.%@ 可用", label, className, getter);
                    return instance;
                }
            } @catch (NSException *exception) {
                MFLog(@"[sysact] !! %@ %@.%@ 异常：%@", label, className, getter, exception);
            }
        }
    }
    return nil;
}

#pragma mark - 动作③：录屏（【0.6.11 用户指令】）

/// 录屏开关（iOS 11+ 的"屏幕录制"由 SpringBoard 侧录制器执行）。
/// 真实 API 随版本变化 ⇒ 与截屏同套路：已知类/选择器逐个试 + 运行时扫描
/// （扫所有名字含 ScreenRecording 的类与含 record 字样的方法，结果进日志，
///   用户回传日志即可钉死本机真实 API）。
static BOOL MFSystemActionToggleScreenRecording(void) {
    NSArray<NSString *> *knownClasses = @[
        @"SBCCScreenRecordingControlsModule",
        @"SBCCScreenRecordingModule",
        @"SBScreenRecordingManager",
        @"_SBCCScreenRecordingManager",
    ];
    for (NSString *className in knownClasses) {
        id instance = MFSystemActionSingletonInstance(className, @"录屏");
        if (instance == nil) {
            continue;
        }
        // 先试显式已知选择器，再按关键字扫描该实例的方法
        for (NSString *name in @[ @"toggleScreenRecording", @"startRecording",
                                  @"startScreenRecording", @"toggleRecording",
                                  @"beginRecording" ]) {
            SEL selector = NSSelectorFromString(name);
            if ([instance respondsToSelector:selector] &&
                MFSystemActionInvokeAdaptive(instance, selector,
                                             [NSString stringWithFormat:@"录屏 %@.%@", className, name],
                                             YES)) {
                return YES;
            }
        }
        if (MFSystemActionScanAndInvoke(instance, @[ @"recording" ], @[ @"toggle", @"start", @"begin" ],
                                        [NSString stringWithFormat:@"录屏 %@", className], YES)) {
            return YES;
        }
    }
    // 运行时扫描：所有名字含 ScreenRecording 的类
    MFLog(@"[sysact] 录屏：已知类全失败，开始运行时扫描（结果在下面，请回传日志）");
    @try {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        unsigned int logged = 0;
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if (![name localizedCaseInsensitiveContainsString:@"screenrecording"]) {
                continue;
            }
            if (logged < 10) {
                MFLog(@"[sysact] 录屏扫描：发现类 %@", name);
                logged++;
            }
            id instance = MFSystemActionSingletonInstance(name, @"录屏扫描");
            if (instance == nil) {
                @try {
                    instance = [[classes[i] alloc] init];
                } @catch (__unused NSException *exception) {
                    instance = nil;
                }
            }
            if (instance != nil &&
                MFSystemActionScanAndInvoke(instance, @[ @"recording" ], @[ @"toggle", @"start", @"begin" ],
                                            [NSString stringWithFormat:@"录屏扫描 %@", name], YES)) {
                if (classes != NULL) {
                    free(classes);
                }
                return YES;
            }
        }
        if (classes != NULL) {
            free(classes);
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 录屏运行时扫描异常：%@", exception);
    }
    return NO;
}

#pragma mark - 动作④：控制中心（【0.6.11 用户指令】）

static BOOL MFSystemActionPresentControlCenter(void) {
    id controller = MFSystemActionSingletonInstance(@"SBControlCenterController", @"控制中心");
    if (controller != nil) {
        for (NSString *name in @[ @"presentAnimated:completion:", @"presentAnimated:",
                                  @"presentControlCenterAnimated:", @"present" ]) {
            SEL selector = NSSelectorFromString(name);
            if ([controller respondsToSelector:selector] &&
                MFSystemActionInvokeAdaptive(controller, selector,
                                             [NSString stringWithFormat:@"控制中心 SBControlCenterController %@",
                                              name], YES)) {
                return YES;
            }
        }
    }
    // 兜底：扫控制中心相关单例的 present 系方法
    @try {
        Class cls = objc_getClass("SBControlCenterController");
        if (cls != Nil) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                SEL selector = method_getName(methods[i]);
                NSString *name = NSStringFromSelector(selector);
                if (method_getNumberOfArguments(methods[i]) <= 4 &&
                    [name localizedCaseInsensitiveContainsString:@"present"]) {
                    if (MFSystemActionInvokeAdaptive(controller, selector,
                                                     [NSString stringWithFormat:@"控制中心扫描 %@",
                                                      name], YES)) {
                        if (methods != NULL) {
                            free(methods);
                        }
                        return YES;
                    }
                }
            }
            if (methods != NULL) {
                free(methods);
            }
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 控制中心扫描异常：%@", exception);
    }
    return NO;
}

#pragma mark - 动作⑤：通知中心（【0.6.11 用户指令】）

static BOOL MFSystemActionPresentNotificationCenter(void) {
    id manager = MFSystemActionSingletonInstance(@"SBCoverSheetPresentationManager", @"通知中心");
    if (manager != nil) {
        for (NSString *name in @[ @"setCoverSheetPresented:animated:withOptions:withCompletion:",
                                  @"setCoverSheetPresented:animated:options:completion:",
                                  @"presentNotificationCenterAnimated:",
                                  @"presentAnimated:" ]) {
            SEL selector = NSSelectorFromString(name);
            if ([manager respondsToSelector:selector] &&
                MFSystemActionInvokeAdaptive(manager, selector,
                                             [NSString stringWithFormat:@"通知中心 %@",
                                              name], YES)) {
                return YES;
            }
        }
        // setCoverSheetPresented 系签名参数多（BOOL+BOOL+对象+对象），单独按 4 参数调用
        SEL selector = NSSelectorFromString(@"setCoverSheetPresented:animated:options:completion:");
        if ([manager respondsToSelector:selector]) {
            @try {
                ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(manager, selector, YES, YES, nil, nil);
                MFLog(@"[sysact] 通知中心：命中 setCoverSheetPresented:animated:options:completion:（4 参数显式调用）");
                return YES;
            } @catch (NSException *exception) {
                MFLog(@"[sysact] !! 通知中心 setCoverSheetPresented 异常：%@", exception);
            }
        }
    }
    MFLog(@"[sysact] 通知中心：所有候选都没成功");
    return NO;
}

#pragma mark - 执行入口

static void MFSystemActionRun(NSString *actionId) {
    MFLog(@"[sysact] >>> 执行系统动作：%@", actionId);
    BOOL handled = NO;
    if ([actionId isEqualToString:kMFSystemActionScreenshot]) {
        handled = MFSystemActionTakeScreenshot();
        if (handled) {
            @try {
                UINotificationFeedbackGenerator *feedback =
                    [[UINotificationFeedbackGenerator alloc] init];
                [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
            } @catch (__unused NSException *exception) {
            }
        }
    } else if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        handled = MFSystemActionPresentTranslationPanel();
        if (!handled) {
            handled = MFSystemActionOpenTranslateApp();
        }
    } else if ([actionId isEqualToString:kMFSystemActionRecord]) {
        // 【0.6.11】录屏 = 开/关切换（再点一次即停）；红条由系统自己画
        handled = MFSystemActionToggleScreenRecording();
    } else if ([actionId isEqualToString:kMFSystemActionCC]) {
        handled = MFSystemActionPresentControlCenter();
    } else if ([actionId isEqualToString:kMFSystemActionNC]) {
        handled = MFSystemActionPresentNotificationCenter();
    } else {
        MFLog(@"[sysact] !! 未知动作：%@", actionId);
        return;
    }
    MFLog(@"[sysact] <<< 系统动作 %@：%@", actionId, handled ? @"已完成" : @"所有候选都没成功（看上面日志）");
}

void MFSystemActionPerform(NSString *actionId, NSTimeInterval delay) {
    if (!MFSystemActionIsActionId(actionId)) {
        return;
    }
    NSTimeInterval effective = (isfinite(delay) && delay > 0.0) ? delay : MFSystemActionSafeDelay;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(effective * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            MFSystemActionRun(actionId);
        } @catch (NSException *exception) {
            MFLog(@"[sysact] !! 动作执行异常（%@）：%@", actionId, exception);
        }
    });
}
