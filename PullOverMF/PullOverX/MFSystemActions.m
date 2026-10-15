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
    return nil;
}

NSArray<NSDictionary<NSString *, NSString *> *> *MFSystemActionEditorEntries(void) {
    // 名字后面带「· 系统动作」便于在编辑器里一眼区分（它们会置顶显示）
    return @[ @{ @"id": kMFSystemActionScreenshot, @"name": @"截屏 · 系统动作" },
              @{ @"id": kMFSystemActionTranslate,  @"name": @"翻译 · 系统动作" } ];
}

/// 动作对应的 SF Symbol 名（取不到会走候补符号）
static NSString *MFSystemActionSymbolName(NSString *actionId) {
    if ([actionId isEqualToString:kMFSystemActionScreenshot]) {
        return @"camera.viewfinder";
    }
    if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        return @"translate";
    }
    return nil;
}

/// 动作底圆配色（截图=系统蓝、翻译=靛蓝）—— 在浅色底/深色 App 上都能看清白字形
static UIColor *MFSystemActionTintColor(NSString *actionId) {
    if ([actionId isEqualToString:kMFSystemActionTranslate]) {
        return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
    }
    return [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0];
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
        if (glyph == nil && [actionId isEqualToString:kMFSystemActionTranslate]) {
            glyph = [UIImage systemImageNamed:@"globe"];   // 老系统没有 translate 符号时的兜底
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

/// 方案 A 多候选（按越狱圈实证覆盖度排序）：
///   ① `SBScreenShotter` sharedInstance → saveScreenshot:withCompletion:（iOS 13~17 通用）
///   ② 同类的 saveScreenshotWithCompletion: / takeScreenshot（签名随版本变）
///   ③ `SBUIController` 的 _takeScreenshot / takeScreenshot（老路兜底）
static BOOL MFSystemActionTakeScreenshot(void) {
    // ① / ② SBScreenShotter
    @try {
        Class shotterClass = objc_getClass("SBScreenShotter");
        if (shotterClass != Nil && [shotterClass respondsToSelector:@selector(sharedInstance)]) {
            id shotter = ((id (*)(id, SEL))objc_msgSend)(shotterClass, @selector(sharedInstance));
            if (shotter != nil) {
                // 2a) saveScreenshot:withCompletion:（BOOL + block：用 IMP 强转才安全）
                SEL twoArgSelector = NSSelectorFromString(@"saveScreenshot:withCompletion:");
                if ([shotter respondsToSelector:twoArgSelector]) {
                    void (*imp)(id, SEL, BOOL, id) =
                        (void (*)(id, SEL, BOOL, id))[shotter methodForSelector:twoArgSelector];
                    if (imp != NULL) {
                        imp(shotter, twoArgSelector, NO, nil);
                        MFLog(@"[sysact] 截屏：命中 SBScreenShotter saveScreenshot:withCompletion:");
                        return YES;
                    }
                }
                // 2b) saveScreenshotWithCompletion:（只有 block）
                SEL blockSelector = NSSelectorFromString(@"saveScreenshotWithCompletion:");
                if ([shotter respondsToSelector:blockSelector]) {
                    void (*imp)(id, SEL, id) =
                        (void (*)(id, SEL, id))[shotter methodForSelector:blockSelector];
                    if (imp != NULL) {
                        imp(shotter, blockSelector, nil);
                        MFLog(@"[sysact] 截屏：命中 SBScreenShotter saveScreenshotWithCompletion:");
                        return YES;
                    }
                }
                // 2c) takeScreenshot（无参）
                SEL plainSelector = NSSelectorFromString(@"takeScreenshot");
                if ([shotter respondsToSelector:plainSelector]) {
                    ((void (*)(id, SEL))objc_msgSend)(shotter, plainSelector);
                    MFLog(@"[sysact] 截屏：命中 SBScreenShotter takeScreenshot");
                    return YES;
                }
            }
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 截屏 SBScreenShotter 异常：%@", exception);
    }

    // ③ SBUIController
    @try {
        Class uiControllerClass = objc_getClass("SBUIController");
        if (uiControllerClass != Nil && [uiControllerClass respondsToSelector:@selector(sharedInstance)]) {
            id uiController = ((id (*)(id, SEL))objc_msgSend)(uiControllerClass, @selector(sharedInstance));
            if (uiController != nil) {
                for (NSString *selectorName in @[ @"_takeScreenshot", @"takeScreenshot" ]) {
                    SEL selector = NSSelectorFromString(selectorName);
                    if ([uiController respondsToSelector:selector]) {
                        ((void (*)(id, SEL))objc_msgSend)(uiController, selector);
                        MFLog(@"[sysact] 截屏：命中 SBUIController %@", selectorName);
                        return YES;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        MFLog(@"[sysact] !! 截屏 SBUIController 异常：%@", exception);
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
