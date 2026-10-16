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

/// 【0.6.13 用户 log53-② 重点排查·安全模式修复】
/// 0.6.11 的调用器把第二参数寄存器一律塞 `flagValue`（YES=0x1）——若方法实际签名是
/// **对象参数**（如 `xxxWithCompletion:(id)`），0x1 就是野指针，被调方解引用 →
/// EXC_BAD_ACCESS。`@try` 只能捕 NSException，**抓不住 BAD_ACCESS** → SpringBoard
/// 直接崩进安全模式（用户实测：点录屏图标即安全模式，日志连 [sysact] 一行都没有，
/// 与"崩在 @try 保护范围之外"完全吻合）。
/// 本版改为**按 objc type encoding 逐参数判型**：
///   '@'（对象）→ 传 nil；'c'/'B'（BOOL）→ 传 flagValue；整型（i/I/s/S/l/L/q/Q）→ 传 0；
///   浮点/结构体/指针/位域等 → 整个方法跳过（ABI 不敢乱调）。
/// 由此保证任何被调方法收到的都是类型合法的值，杜绝野指针。

/// 安全（可合法传值）的参数类型
static BOOL MFSystemActionArgTypeIsSafe(char t) {
    switch (t) {
        case '@': case '#': case ':':
        case 'c': case 'B':
        case 'i': case 'I': case 's': case 'S':
        case 'l': case 'L': case 'q': case 'Q':
            return YES;
        default:
            return NO;   // d/f 浮点、^ 指针、{} 结构体、[] 数组、b 位域、* 字符串 → 不敢调
    }
}

/// 从 method type encoding 里取第 wantIndex 个**用户参数**的类型。
/// 编码序列 = 返回类型 + id + SEL + 参数…（前 3 个 token 不是用户参数）。
/// 解析失败/复合类型一律返回 '?'（调用方按不安全跳过）。
static char MFSystemActionUserArgType(const char *encoding, NSUInteger wantIndex) {
    if (encoding == NULL) {
        return '?';
    }
    const char *p = encoding;
    NSUInteger tokenIndex = 0;
    while (*p != '\0') {
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O' || *p == 'V') {
            p++;   // 限定符不占 token
        }
        char start = *p;
        switch (start) {
            case '\0':
                return '?';
            case '@': case ':': case '#': case 'c': case 'B':
            case 'i': case 'I': case 's': case 'S':
            case 'l': case 'L': case 'q': case 'Q':
            case 'd': case 'f': case 'v':
                p++;
                break;
            case '^':
                p++;
                if (*p == '?') {
                    p++;
                } else {
                    while (*p != '\0' && (isalnum((unsigned char)*p) || *p == '_')) {
                        p++;
                    }
                }
                break;
            case 'b':   // 位域 bNUM
                p++;
                while (isdigit((unsigned char)*p)) {
                    p++;
                }
                break;
            case '{': case '(': {   // 结构体/联合：配对吞掉
                char openCh = start, closeCh = (start == '{') ? '}' : ')';
                int depth = 0;
                do {
                    if (*p == openCh) depth++;
                    else if (*p == closeCh) depth--;
                    p++;
                } while (*p != '\0' && depth > 0);
                break;
            }
            case '[':   // 数组：不安全，直接放弃整个解析
                return '?';
            default:
                return '?';
        }
        if (tokenIndex >= 3 && tokenIndex - 3 == wantIndex) {
            if (start == ':' || start == '#' || start == 'v') {
                return '?';   // SEL/Class/void 槽位不作为参数出现，防御性视为不安全
            }
            return start;
        }
        tokenIndex++;
    }
    return '?';
}

static BOOL MFSystemActionInvokeAdaptive(id target, SEL selector, NSString *label, BOOL flagValue) {
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (method == NULL) {
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    NSUInteger registers = method_getNumberOfArguments(method);   // 2 + 参数寄存器数
    if (registers > 4) {
        MFLog(@"[sysact] %@：参数寄存器 %lu 个，跳过（不敢乱调）",
              label, (unsigned long)(registers - 2));
        return NO;
    }
    // 逐参数判型：对象槽给 nil、BOOL 槽给 flagValue、整型槽给 0，其他类型整个跳过
    char type0 = (registers >= 3) ? MFSystemActionUserArgType(encoding, 0) : '@';
    char type1 = (registers >= 4) ? MFSystemActionUserArgType(encoding, 1) : '@';
    if ((registers >= 3 && !MFSystemActionArgTypeIsSafe(type0)) ||
        (registers >= 4 && !MFSystemActionArgTypeIsSafe(type1))) {
        MFLog(@"[sysact] %@：参数类型不安全（%c / %c），跳过（防野指针崩溃）",
              label,
              registers >= 3 ? type0 : '-',
              registers >= 4 ? type1 : '-');
        return NO;
    }
    @try {
        if (registers == 2) {
            ((void (*)(id, SEL))objc_msgSend)(target, selector);
        } else if (registers == 3) {
            uintptr_t scalar0 = (type0 == 'c' || type0 == 'B') ? (flagValue ? 1 : 0) : 0;
            // 【0.6.13】按 long 传参（寄存器值等价），绕开 ARC 的 uintptr_t→id 禁转
            ((void (*)(id, SEL, long))objc_msgSend)(target, selector, (long)scalar0);
        } else {
            uintptr_t scalar0 = (type0 == 'c' || type0 == 'B') ? (flagValue ? 1 : 0) : 0;
            uintptr_t scalar1 = (type1 == 'c' || type1 == 'B') ? (flagValue ? 1 : 0) : 0;
            ((void (*)(id, SEL, long, long))objc_msgSend)(target, selector,
                                                          (long)scalar0, (long)scalar1);
        }
        MFLog(@"[sysact] %@：命中（参数 %lu 个，类型 %c/%c）", label,
              (unsigned long)(registers - 2),
              registers >= 3 ? type0 : '-',
              registers >= 4 ? type1 : '-');
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

// 【0.6.16】旧的 `MFSystemActionSingletonInstance`（sharedInstance/mainInstance 两种来源）
//   已被 MFSystemActionResolveInstance（多 getter + 窗口层级第二来源）取代，删除以免
//   留下未使用的 static 函数（本工程 -Werror，未使用即构建中断）。

#pragma mark - 【0.6.16】录屏（RPScreenRecorder 实证路）

/// 【0.6.16 用户 log56-③ 重点修复 · 取证结论】
///   1) TrollOpen（同类多浮窗插件）的 dylib 里**唯一**的录屏相关系统类引用是
///      `_OBJC_CLASS_$_RPScreenRecorder`，与之配套的 selector 字符串正是
///      `sharedRecorder` / `startSystemRecordingWithMicrophoneEnabled:handler:` /
///      `stopSystemRecording:` / `isRecording` / `setRecording:`
///      ⇒ 系统录屏的执行者 = ReplayKit 的 RPScreenRecorder 单例（控制中心那颗按钮
///        最终也落在它身上）。log56 实机日志同样显示本机 RPScreenRecorder 响应这三件套。
///   2) 0.6.15 的"全类 selector 指纹扫描"在 log56 里选中了
///      **REMAuxiliaryChangeInfoType（提醒事项的数据模型类）** —— 幻影类，
///      在它身上调 startSystemRecording 什么都不会发生（用户实测：点了没反应）；
///      而且那趟扫描 1 万多个类在主线程占了约 0.7s（正是圆盘呼出第一下的掉帧源）。
///      ⇒ 整条"指纹扫描 + alloc/init 任意类"的路**全部删除**，只走 RPScreenRecorder。
///   3) 旧的 SBCCScreenRecording* / SBScreenRecordingManager 候选在本机**一个都没命中**
///      （历史日志里连"类存在"都没打出来过），一并删除。

static BOOL gMFSystemActionRecordActive = NO;       // 我方视角的录屏开关状态（系统 isRecording 优先）
static void (^gMFRecordStateObserver)(BOOL active); // 圆盘注册的观察者（toast + 徽章刷新）
static id gMFRecordRecorder = nil;                  // RPScreenRecorder 单例（惰性取一次）
static BOOL gMFRecordRecorderResolved = NO;

BOOL MFSystemActionRecordIsActive(void) {
    return gMFSystemActionRecordActive;
}

void MFSystemActionSetRecordStateObserver(void (^observer)(BOOL active)) {
    @try {
        gMFRecordStateObserver = [observer copy];
    } @catch (__unused NSException *exception) {
        gMFRecordStateObserver = nil;
    }
}

/// 状态落账 + 通知圆盘（主线程回调；状态没变时静默返回）
static void MFSystemActionRecordApplyState(BOOL active, NSString *reason) {
    if (gMFSystemActionRecordActive == active) {
        return;
    }
    gMFSystemActionRecordActive = active;
    MFLog(@"[sysact] 录屏状态 → %@（%@）", active ? @"录制中" : @"空闲", reason);
    void (^obs)(BOOL) = gMFRecordStateObserver;
    if (obs != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ obs(active); });
    }
}

/// ReplayKit 录制器单例：`[RPScreenRecorder sharedRecorder]`（老系统叫 `shared`）。
static id MFSystemActionRecordRecorder(void) {
    if (gMFRecordRecorderResolved) {
        return gMFRecordRecorder;
    }
    gMFRecordRecorderResolved = YES;
    @try {
        Class cls = objc_getClass("RPScreenRecorder");
        if (cls == Nil) {
            cls = NSClassFromString(@"RPScreenRecorder");
        }
        if (cls == Nil) {
            MFLog(@"[sysact] 录屏：RPScreenRecorder 类不存在（ReplayKit 未加载）");
            return nil;
        }
        for (NSString *getter in @[ @"sharedRecorder", @"shared" ]) {
            SEL selector = NSSelectorFromString(getter);
            if (![cls respondsToSelector:selector]) {
                continue;
            }
            id instance = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
            if (instance != nil) {
                gMFRecordRecorder = instance;
                MFLog(@"[sysact] 录屏：RPScreenRecorder.%@ 实例就绪", getter);
                return instance;
            }
        }
        MFLog(@"[sysact] 录屏：RPScreenRecorder 无 sharedRecorder/shared 单例");
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 录屏取录制器实例异常：%@", exception);
    }
    return nil;
}

/// 读系统侧 isRecording（录制器拿不到 / 不响应时返回 -1 = 未知）
static int MFSystemActionRecordSystemState(void) {
    id recorder = MFSystemActionRecordRecorder();
    if (recorder == nil || ![recorder respondsToSelector:@selector(isRecording)]) {
        return -1;
    }
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(recorder, @selector(isRecording)) ? 1 : 0;
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

/// 圆盘展开时对齐系统状态（用户可能从控制中心手动停了录屏）
void MFSystemActionRecordSyncState(void) {
    int state = MFSystemActionRecordSystemState();
    if (state >= 0) {
        MFSystemActionRecordApplyState(state == 1, @"系统 isRecording 对齐");
    }
}

/// start/stop 的单参 handler：被调方传什么都收，但**把内容打进日志**——
/// 权限拒绝、广播配置失败这类信息都会从这里露出来。
static void MFSystemActionRecordNoopHandler(id result) {
    if (result == nil) {
        MFLog(@"[sysact] 录屏：回调（无附加信息）");
        return;
    }
    @try {
        NSString *desc = [result description];
        if (desc.length > 300) {
            desc = [desc substringToIndex:300];
        }
        MFLog(@"[sysact] 录屏：回调：%@", desc);
    } @catch (__unused NSException *exception) {
        MFLog(@"[sysact] 录屏：回调（不可描述的结果）");
    }
}

/// 只在这条路彻底走不通时打一次方法表（下一轮日志据此钉死真实签名）。
/// 注意：**只 dump 方法名，不调用任何东西**。
static void MFSystemActionDumpRecordDiagnostics(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = objc_getClass("RPScreenRecorder");
        if (cls == Nil) {
            MFLog(@"[sysact] 录屏诊断：RPScreenRecorder 类不存在");
            return;
        }
        for (int meta = 0; meta < 2; meta++) {
            Class target = meta ? object_getClass(cls) : cls;
            unsigned int count = 0;
            Method *list = class_copyMethodList(target, &count);
            MFLog(@"[sysact] 录屏诊断：RPScreenRecorder %s方法 %u 个", meta ? "类" : "实例", count);
            for (unsigned int i = 0; i < count && i < 80; i++) {
                const char *types = method_getTypeEncoding(list[i]);
                MFLog(@"[sysact]   · %@ (%s)", NSStringFromSelector(method_getName(list[i])),
                      types ? types : "?");
            }
            if (list != NULL) {
                free(list);
            }
        }
    });
}

/// 录屏开关主路（0.6.16）：`[RPScreenRecorder sharedRecorder]` 上直调，
/// 私有 system 变体优先、公共 ReplayKit API 兜底；两种都是 (BOOL + block) 或 (block)
/// 的确定签名 ⇒ 不存在 0.6.11 那种"塞 0x1 当对象"的野指针风险。
/// 返回 YES 仅表示"已发起"，真实状态以 0.5s / 1.5s 两次 isRecording 复核为准。
static BOOL MFSystemActionToggleScreenRecording(void) {
    id recorder = MFSystemActionRecordRecorder();
    if (recorder == nil) {
        MFLog(@"[sysact] 录屏：RPScreenRecorder 不可用（无 ReplayKit 单例）");
        MFSystemActionDumpRecordDiagnostics();
        return NO;
    }
    int state = MFSystemActionRecordSystemState();
    BOOL active = (state >= 0) ? (state == 1) : gMFSystemActionRecordActive;
    MFLog(@"[sysact] 录屏：RPScreenRecorder 当前状态=%@，执行%@",
          state < 0 ? @"未知(用我方缓存)" : (active ? @"录制中" : @"空闲"),
          active ? @"停止" : @"开始");

    void (^oneArg)(id) = ^(id result) {
        MFSystemActionRecordNoopHandler(result);
    };
    // 公共 stopRecordingWithHandler: 的 block 是两参 (previewViewController, error)
    void (^twoArg)(id, id) = ^(id preview, id error) {
        MFLog(@"[sysact] 录屏：停止回调 preview=%@", preview ? @"有" : @"无");
        MFSystemActionRecordNoopHandler(error);
    };
    BOOL wasActive = active;

    @try {
        if (active) {
            SEL systemStop = @selector(stopSystemRecording:);
            SEL publicStop = @selector(stopRecordingWithHandler:);
            if ([recorder respondsToSelector:systemStop]) {
                ((void (*)(id, SEL, id))objc_msgSend)(recorder, systemStop, oneArg);
                MFLog(@"[sysact] 录屏：已调 stopSystemRecording:");
            } else if ([recorder respondsToSelector:publicStop]) {
                ((void (*)(id, SEL, id))objc_msgSend)(recorder, publicStop, twoArg);
                MFLog(@"[sysact] 录屏：已调 stopRecordingWithHandler:（公共 API 退路）");
            } else {
                MFLog(@"[sysact] 录屏：RPScreenRecorder 两种停止 selector 都不响应");
                MFSystemActionDumpRecordDiagnostics();
                return NO;
            }
        } else {
            SEL systemStart = @selector(startSystemRecordingWithMicrophoneEnabled:handler:);
            SEL publicStart = @selector(startRecordingWithMicrophoneEnabled:handler:);
            SEL plainStart  = @selector(startRecordingWithHandler:);
            if ([recorder respondsToSelector:systemStart]) {
                // 麦克风默认关（贴系统录屏按钮的默认行为）
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(recorder, systemStart, NO, oneArg);
                MFLog(@"[sysact] 录屏：已调 startSystemRecordingWithMicrophoneEnabled:NO");
            } else if ([recorder respondsToSelector:publicStart]) {
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(recorder, publicStart, NO, oneArg);
                MFLog(@"[sysact] 录屏：已调 startRecordingWithMicrophoneEnabled:NO（公共 API 退路）");
            } else if ([recorder respondsToSelector:plainStart]) {
                ((void (*)(id, SEL, id))objc_msgSend)(recorder, plainStart, oneArg);
                MFLog(@"[sysact] 录屏：已调 startRecordingWithHandler:（最老 API 退路）");
            } else {
                MFLog(@"[sysact] 录屏：RPScreenRecorder 三种开始 selector 都不响应");
                MFSystemActionDumpRecordDiagnostics();
                return NO;
            }
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 录屏直调异常：%@", exception);
        return NO;
    }

    // 开始/停止都是异步：0.5s 与 1.5s 各复核一次 isRecording，状态一律以系统为准
    for (NSNumber *delay in @[ @0.5, @1.5 ]) {
        NSTimeInterval seconds = delay.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            int now = MFSystemActionRecordSystemState();
            if (now < 0) {
                return;
            }
            MFSystemActionRecordApplyState(now == 1, wasActive ? @"停止后复核 isRecording"
                                                               : @"开始后复核 isRecording");
        });
    }
    return YES;
}

#pragma mark - 【0.6.16】实例获取（控制中心 / 通知中心共用）

/// 在 SpringBoard 的窗口层级里找某个类的实例（递归，深度封顶防炸栈）。
static id MFSystemActionFindInstanceInView(UIView *view, Class cls, int depth) {
    if (view == nil || depth > 12) {
        return nil;
    }
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:cls]) {
            return sub;
        }
        id hit = MFSystemActionFindInstanceInView(sub, cls, depth + 1);
        if (hit != nil) {
            return hit;
        }
    }
    return nil;
}

/// 【0.6.16】通用实例获取：单例族 → **SpringBoard 窗口层级**（第二来源）。
/// log56 教训：0.6.11 的控制中心分支在"单例取不到"时拿着 nil 继续调（等于什么都没做，
/// 日志还一片安静）⇒ 用户看到的就是"点了没反应"。控制中心控制器本身就是控制中心窗口的
/// rootViewController ⇒ 窗口层级这条路一定找得到。
static id MFSystemActionResolveInstance(NSString *className, NSString *label) {
    Class cls = objc_getClass(className.UTF8String);
    if (cls == Nil) {
        cls = NSClassFromString(className);
    }
    if (cls == Nil) {
        MFLog(@"[sysact] %@：类 %@ 不存在", label, className);
        return nil;
    }
    for (NSString *getter in @[ @"sharedInstance", @"sharedInstanceIfExists", @"mainInstance",
                                @"defaultInstance", @"shared", @"standardInstance",
                                @"sharedController", @"sharedManager" ]) {
        SEL selector = NSSelectorFromString(getter);
        if (![cls respondsToSelector:selector]) {
            continue;
        }
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
    @try {
        UIApplication *application = [UIApplication sharedApplication];
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        [windows addObjectsFromArray:application.windows];
        for (UIWindow *window in windows) {
            if ([window isKindOfClass:cls]) {
                MFLog(@"[sysact] %@：窗口层级命中 %@（window 本体）", label, className);
                return window;
            }
            UIViewController *controller = window.rootViewController;
            int guard = 0;
            while (controller != nil && guard < 12) {
                if ([controller isKindOfClass:cls]) {
                    MFLog(@"[sysact] %@：窗口层级命中 %@（%@ 的控制器链）", label, className,
                          NSStringFromClass([window class]));
                    return controller;
                }
                controller = controller.presentedViewController;
                guard++;
            }
            id hit = MFSystemActionFindInstanceInView(window, cls, 0);
            if (hit != nil) {
                MFLog(@"[sysact] %@：窗口层级命中 %@（%@ 视图树）", label, className,
                      NSStringFromClass([window class]));
                return hit;
            }
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! %@ 窗口层级查找异常：%@", label, exception);
    }
    MFLog(@"[sysact] %@：单例与窗口层级都没找到 %@ 的实例", label, className);
    return nil;
}

/// 失败时把方法名（含关键字）打进日志——只 dump，不调用。
static void MFSystemActionDumpMethodsMatching(id target, NSArray<NSString *> *keywords,
                                              NSString *label) {
    if (target == nil) {
        return;
    }
    Class cls = object_getClass(target);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    MFLog(@"[sysact] %@ 诊断：%@ 方法 %u 个，含关键字的结果如下", label,
          NSStringFromClass(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        for (NSString *keyword in keywords) {
            if ([name localizedCaseInsensitiveContainsString:keyword]) {
                const char *types = method_getTypeEncoding(methods[i]);
                MFLog(@"[sysact]   · %@ (%s)", name, types ? types : "?");
                break;
            }
        }
    }
    if (methods != NULL) {
        free(methods);
    }
}

#pragma mark - 动作④：控制中心（【0.6.11 用户指令】）

/// 【0.6.16】控制中心：单例 / 窗口层级两路取实例 → 已知 selector 逐个试 →
/// 再按关键字扫一遍 → 全失败才 dump。每一条都走类型安全的自适应调用器
/// （BOOLEAN 槽给 YES、对象槽给 nil），失败只写日志。
static BOOL MFSystemActionPresentControlCenter(void) {
    id controller = MFSystemActionResolveInstance(@"SBControlCenterController", @"控制中心");
    if (controller != nil) {
        NSArray<NSString *> *names = @[ @"presentAnimated:completion:",
                                        @"presentAnimated:withCompletion:",
                                        @"presentControlCenterAnimated:",
                                        @"presentAnimated:",
                                        @"present" ];
        for (NSString *name in names) {
            SEL selector = NSSelectorFromString(name);
            if ([controller respondsToSelector:selector] &&
                MFSystemActionInvokeAdaptive(controller, selector,
                                             [NSString stringWithFormat:@"控制中心 SBControlCenterController %@",
                                              name], YES)) {
                return YES;
            }
        }
        if (MFSystemActionScanAndInvoke(controller, @[ @"present", @"show", @"toggle", @"controlcenter" ],
                                        @[ @"present", @"toggle" ],
                                        @"控制中心 SBControlCenterController", YES)) {
            return YES;
        }
        MFSystemActionDumpMethodsMatching(controller, @[ @"present", @"show", @"toggle", @"center" ],
                                          @"控制中心");
    }
    // 兜底：另一套常见命名（新版 SpringBoard 把 CC 也挂在 presentation manager 上）
    for (NSString *className in @[ @"SBMainDisplaySceneController", @"SBControlCenterSystemAgent",
                                   @"SBControlCenterPresentationManager" ]) {
        id other = MFSystemActionResolveInstance(className, @"控制中心兜底");
        if (other == nil) {
            continue;
        }
        if (MFSystemActionScanAndInvoke(other, @[ @"controlcenter", @"present" ], @[ @"present" ],
                                        [NSString stringWithFormat:@"控制中心兜底 %@", className], YES)) {
            return YES;
        }
    }
    MFLog(@"[sysact] 控制中心：所有候选都没成功（见上面诊断）");
    return NO;
}

#pragma mark - 动作⑤：通知中心（【0.6.11 用户指令】）

/// 【0.6.16】通知中心：同上——实例两路取，4 参数那个 setCoverSheetPresented 显式调用
/// （自适应器只支持 ≤2 参数），其余已知 selector 走自适应。
static BOOL MFSystemActionPresentNotificationCenter(void) {
    id manager = MFSystemActionResolveInstance(@"SBCoverSheetPresentationManager", @"通知中心");
    if (manager != nil) {
        // ① 4 参数主路（新版签名）：BOOL presented + BOOL animated + id options + id completion
        SEL four = NSSelectorFromString(@"setCoverSheetPresented:animated:options:completion:");
        if ([manager respondsToSelector:four]) {
            @try {
                ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(manager, four, YES, YES, nil, nil);
                MFLog(@"[sysact] 通知中心：命中 setCoverSheetPresented:animated:options:completion:");
                return YES;
            } @catch (NSException *exception) {
                MFLog(@"[sysact] !! 通知中心 4 参数调用异常：%@", exception);
            }
        }
        // ② 其余签名走自适应（≤2 参数）
        NSArray<NSString *> *names = @[ @"setCoverSheetPresented:animated:withCompletion:",
                                        @"setCoverSheetPresented:animated:",
                                        @"presentNotificationCenterAnimated:",
                                        @"presentAnimated:" ];
        for (NSString *name in names) {
            SEL selector = NSSelectorFromString(name);
            if ([manager respondsToSelector:selector] &&
                MFSystemActionInvokeAdaptive(manager, selector,
                                             [NSString stringWithFormat:@"通知中心 SBCoverSheetPresentationManager %@",
                                              name], YES)) {
                return YES;
            }
        }
        if (MFSystemActionScanAndInvoke(manager, @[ @"coversheet", @"present", @"notification" ],
                                        @[ @"present", @"coversheet" ],
                                        @"通知中心 SBCoverSheetPresentationManager", YES)) {
            return YES;
        }
        MFSystemActionDumpMethodsMatching(manager, @[ @"coversheet", @"present", @"slide" ], @"通知中心");
    }
    MFLog(@"[sysact] 通知中心：所有候选都没成功（见上面诊断）");
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
