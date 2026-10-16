#line 1 "PullOverX.mm"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#include <substrate.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

#import "headers.h"
#import "FBSOrientationObserver.h"
#import "FBSOrientationUpdate.h"
#import "POXWindow.h"
#import "POSplitSessionController.h"
#import "POApplicationHelper.h"
#import "POCameraGrantState.h"
#import "ContextHostManager.h"
#import "POExternalActivationCoordinator.h"
#import "POXExternalAPI.h"

static POXWindow *window;
static FBSOrientationObserver *POOrientationObserver;

typedef NS_ENUM(NSInteger, POLandscapeBehavior) {
    POLandscapeBehaviorRotate,
    POLandscapeBehaviorLock,
    POLandscapeBehaviorHide,
};

typedef NS_ENUM(NSInteger, POLandscapeVisibility) {
    POLandscapeVisibilityUnresolved,
    POLandscapeVisibilityVisible,
    POLandscapeVisibilityBehaviorHidden,
    POLandscapeVisibilityDisabled,
};

typedef NS_ENUM(NSInteger, PODeviceForm) {
    PODeviceFormPhoneFixedSpringBoard,
    PODeviceFormPadRotatingSpringBoard,
};

typedef NS_ENUM(NSInteger, PODirectionPhase) {
    PODirectionPhaseUnresolved,
    PODirectionPhaseAwaitingScene,
    PODirectionPhaseStable,
    PODirectionPhaseSuppressed,
};

typedef struct {
    POLandscapeVisibility visibility;
    UIInterfaceOrientation sourceOrientation;
    UIInterfaceOrientation targetOrientation;
} POLandscapeDecision;

typedef struct {
    UIInterfaceOrientation physicalOrientation;
    UIInterfaceOrientation springBoardOrientation;
    UIInterfaceOrientation sourceSceneOrientation;
    UIInterfaceOrientation sceneOrientation;
    UIInterfaceOrientation committedOrientation;
    UIInterfaceOrientation windowAppliedOrientation;
    BOOL sceneIsCurrent;
    BOOL committedIsCurrent;
    BOOL enabled;
    POLandscapeBehavior behavior;
    PODeviceForm deviceForm;
    NSTimeInterval requestedDuration;
    NSTimeInterval fallbackDuration;
} PODirectionResolverInput;

typedef struct {
    POLandscapeDecision decision;
    NSTimeInterval duration;
    BOOL shouldCommit;
} PODirectionResolverOutput;

@interface PODirectionState : NSObject
@property (nonatomic, assign) UIInterfaceOrientation physicalOrientation;
@property (nonatomic, assign) UIInterfaceOrientation springBoardOrientation;
@property (nonatomic, assign) UIInterfaceOrientation sceneOrientation;
@property (nonatomic, copy) NSString *sceneIdentifier;
@property (nonatomic, assign) BOOL sceneIsUsable;
@property (nonatomic, assign) UIInterfaceOrientation committedOrientation;
@property (nonatomic, copy) NSString *committedSceneIdentifier;
@property (nonatomic, assign) UIInterfaceOrientation windowAppliedOrientation;
@property (nonatomic, assign) NSTimeInterval pendingAnimationDuration;
@property (nonatomic, assign) CFTimeInterval pendingAnimationTimestamp;
@property (nonatomic, assign) NSUInteger reconcileGeneration;
@property (nonatomic, assign) POLandscapeVisibility visibility;
@property (nonatomic, assign) PODeviceForm deviceForm;
@property (nonatomic, assign) PODirectionPhase phase;
@end

@implementation PODirectionState
@end

static PODirectionState *PODirectionStateOwner(void) {
    static PODirectionState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [PODirectionState new];
        state.physicalOrientation = UIInterfaceOrientationUnknown;
        state.springBoardOrientation = UIInterfaceOrientationUnknown;
        state.sceneOrientation = UIInterfaceOrientationUnknown;
        state.committedOrientation = UIInterfaceOrientationUnknown;
        state.windowAppliedOrientation = UIInterfaceOrientationUnknown;
        state.visibility = POLandscapeVisibilityUnresolved;
        state.deviceForm = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? PODeviceFormPadRotatingSpringBoard
            : PODeviceFormPhoneFixedSpringBoard;
        state.phase = PODirectionPhaseUnresolved;
    });
    return state;
}

static void POReconcileCommittedInterfaceOrientation(NSString *trigger,
                                                      NSTimeInterval duration,
                                                      BOOL applyOrdinarySettings);

static CFStringRef const kPOSettingsChangedNotification = CFSTR("com.mlgm.pulloverx.settings-changed");

static BOOL POSettingsEnabled(NSDictionary *settings) {
    id enabled = settings[@"enabled"];
    return enabled == nil || [enabled boolValue];
}

static BOOL POIsConcreteInterfaceOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static UIInterfaceOrientation POReadInterfaceOrientation(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return UIInterfaceOrientationUnknown;
    }
    @try {
        return (UIInterfaceOrientation)((long long (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return UIInterfaceOrientationUnknown;
    }
}

static id POReadObject(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSTimeInterval POReadTimeInterval(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return 0;
    }
    @try {
        NSTimeInterval interval = ((NSTimeInterval (*)(id, SEL))objc_msgSend)(object, selector);
        return interval > 0 ? interval : 0;
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static id POFrontmostApplication(void) {
    @try {
        return [(SpringBoard *)UIApplication.sharedApplication _accessibilityFrontMostApplication];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSTimeInterval POSystemOrientationAnimationDuration(void) {
    NSTimeInterval duration = POReadTimeInterval(
        UIApplication.sharedApplication, NSSelectorFromString(@"statusBarOrientationAnimationDuration"));
    if (duration > 0) {
        return duration;
    }

    duration = UIView.inheritedAnimationDuration;
    return duration > 0 ? duration : 0;
}

static NSString *POApplicationIdentifier(id application) {
    id identifier = POReadObject(application, @selector(bundleIdentifier));
    if ([identifier isKindOfClass:[NSString class]]) {
        return identifier;
    }

    identifier = POReadObject(application, @selector(displayIdentifier));
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

static id POHomeDisplayScene(void) {
    id scene = POReadObject(
        UIApplication.sharedApplication, NSSelectorFromString(@"_mainDisplayWindowScene"));
    if (scene) {
        return scene;
    }

    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)candidate;
        if ([windowScene.session.persistentIdentifier isEqualToString:@"com.apple.springboard"]) {
            return windowScene;
        }
    }
    return nil;
}

static NSString *POSceneIdentifier(id scene) {
    id identifier = POReadObject(scene, @selector(identifier));
    if ([identifier isKindOfClass:[NSString class]]) {
        return identifier;
    }

    if ([scene isKindOfClass:[UIWindowScene class]]) {
        return ((UIWindowScene *)scene).session.persistentIdentifier;
    }
    return nil;
}

static UIInterfaceOrientation POReadSceneInterfaceOrientation(id scene) {
    id settings = POReadObject(scene, @selector(settings));
    UIInterfaceOrientation orientation = POReadInterfaceOrientation(settings, @selector(interfaceOrientation));
    if (!POIsConcreteInterfaceOrientation(orientation)) {
        orientation = POReadInterfaceOrientation(scene, @selector(interfaceOrientation));
    }
    return orientation;
}

static BOOL POHomeScreenIsActive(void) {
    Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace = POReadObject(workspaceClass, NSSelectorFromString(@"sharedInstance"));
    SEL activeSelector = NSSelectorFromString(@"isSpringBoardActive");
    return workspace && [workspace respondsToSelector:activeSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(workspace, activeSelector);
}

static BOOL POSceneIdentifierMatchesBundleIdentifier(NSString *sceneIdentifier,
                                                      NSString *bundleIdentifier) {
    if (sceneIdentifier.length == 0 || bundleIdentifier.length == 0) {
        return NO;
    }
    if ([sceneIdentifier isEqualToString:bundleIdentifier]) {
        return YES;
    }

    NSString *prefix = [bundleIdentifier stringByAppendingString:@"-"];
    NSRange range = [sceneIdentifier rangeOfString:prefix];
    return range.location == 0 ||
        (range.location != NSNotFound && [sceneIdentifier characterAtIndex:range.location - 1] == ':');
}

static BOOL POSceneIsUsableForOrientation(id scene) {
    id settings = POReadObject(scene, @selector(settings));
    SEL foregroundSelector = NSSelectorFromString(@"isForeground");
    if (settings && [settings respondsToSelector:foregroundSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(settings, foregroundSelector);
    }

    SEL activeSelector = NSSelectorFromString(@"isActive");
    if (scene && [scene respondsToSelector:activeSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(scene, activeSelector);
    }

    SEL validSelector = NSSelectorFromString(@"isValid");
    if (scene && [scene respondsToSelector:validSelector] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(scene, validSelector)) {
        return NO;
    }
    return YES;
}

static id POResolveCurrentOrientationSourceScene(void) {
    id application = POFrontmostApplication();
    NSString *bundleIdentifier = POApplicationIdentifier(application);
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive) {
        if (POHomeScreenIsActive()) {
            id homeScene = POHomeDisplayScene();
            if (homeScene && POIsConcreteInterfaceOrientation(POReadSceneInterfaceOrientation(homeScene))) {
                [splitSession updateBaseBundleIdentifier:@"com.apple.springboard" scene:homeScene];
                return homeScene;
            }
        }
        NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
        if (application && bundleIdentifier.length > 0 &&
            ![bundleIdentifier isEqualToString:hostedBundleId]) {
            for (NSString *selectorName in @[ @"mainScene", @"_mainScene", @"scene" ]) {
                id scene = POReadObject(application, NSSelectorFromString(selectorName));
                if (scene &&
                    POSceneIdentifierMatchesBundleIdentifier(POSceneIdentifier(scene), bundleIdentifier) &&
                    POSceneIsUsableForOrientation(scene)) {
                    [splitSession updateBaseBundleIdentifier:bundleIdentifier scene:scene];
                    return scene;
                }
            }

            FBScene *probedScene = [[ContextHostManager sharedInstance] probeSceneForBundleId:bundleIdentifier];
            if (probedScene &&
                POSceneIdentifierMatchesBundleIdentifier(POSceneIdentifier(probedScene), bundleIdentifier) &&
                POSceneIsUsableForOrientation(probedScene)) {
                [splitSession updateBaseBundleIdentifier:bundleIdentifier scene:probedScene];
                return probedScene;
            }
        }
        if (splitSession.baseScene) {
            return splitSession.baseScene;
        }
    }
    if (application && bundleIdentifier.length > 0) {
        for (NSString *selectorName in @[ @"mainScene", @"_mainScene", @"scene" ]) {
            id scene = POReadObject(application, NSSelectorFromString(selectorName));
            if (scene &&
                POSceneIdentifierMatchesBundleIdentifier(POSceneIdentifier(scene), bundleIdentifier) &&
                POSceneIsUsableForOrientation(scene)) {
                return scene;
            }
        }
        return nil;
    }

    id scene = POHomeDisplayScene();
    if ([POSceneIdentifier(scene) isEqualToString:@"com.apple.springboard"] &&
        POSceneIsUsableForOrientation(scene)) {
        return scene;
    }
    return nil;
}

static BOOL POIsCurrentOrientationSourceSceneIdentifier(NSString *sceneIdentifier);

static UIInterfaceOrientation POCurrentCommittedInterfaceOrientation(NSString **sceneIdentifier) {
    PODirectionState *state = PODirectionStateOwner();
    id sourceScene = POResolveCurrentOrientationSourceScene();
    NSString *currentSceneIdentifier = POSceneIdentifier(sourceScene);
    UIInterfaceOrientation orientation = POReadSceneInterfaceOrientation(sourceScene);
    if (POIsConcreteInterfaceOrientation(orientation)) {
        if (sceneIdentifier) {
            *sceneIdentifier = currentSceneIdentifier;
        }
        return orientation;
    }

    if (POIsCurrentOrientationSourceSceneIdentifier(state.committedSceneIdentifier) &&
        POIsConcreteInterfaceOrientation(state.committedOrientation)) {
        if (sceneIdentifier) {
            *sceneIdentifier = state.committedSceneIdentifier;
        }
        return state.committedOrientation;
    }

    return UIInterfaceOrientationUnknown;
}

static BOOL POIsCurrentOrientationSourceSceneIdentifier(NSString *sceneIdentifier) {
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive && splitSession.baseSceneIdentifier.length > 0) {
        return [sceneIdentifier isEqualToString:splitSession.baseSceneIdentifier];
    }
    id application = POFrontmostApplication();
    NSString *bundleIdentifier = POApplicationIdentifier(application);
    if (bundleIdentifier.length > 0) {
        return POSceneIdentifierMatchesBundleIdentifier(sceneIdentifier, bundleIdentifier);
    }
    return [sceneIdentifier isEqualToString:@"com.apple.springboard"];
}

static BOOL POIsCurrentOrientationSourceScene(id scene) {
    return POIsCurrentOrientationSourceSceneIdentifier(POSceneIdentifier(scene));
}

static POLandscapeBehavior POReadLandscapeBehavior(NSDictionary *settings) {
    id value = settings[@"landscapeBehavior"];
    if (!value) {
        return POLandscapeBehaviorRotate;
    }
    if (![value isKindOfClass:[NSString class]]) {
        return POLandscapeBehaviorRotate;
    }
    if ([value isEqualToString:@"lock"]) {
        return POLandscapeBehaviorLock;
    }
    if ([value isEqualToString:@"hide"]) {
        return POLandscapeBehaviorHide;
    }
    if ([value isEqualToString:@"rotate"]) {
        return POLandscapeBehaviorRotate;
    }
    return POLandscapeBehaviorRotate;
}

static POLandscapeDecision POComputeLandscapeDecisionForBehavior(BOOL enabled,
                                                                  POLandscapeBehavior behavior,
                                                                  UIInterfaceOrientation sourceOrientation) {
    POLandscapeDecision decision;
    decision.visibility = POLandscapeVisibilityUnresolved;
    decision.sourceOrientation = sourceOrientation;
    decision.targetOrientation = UIInterfaceOrientationUnknown;
    if (!enabled) {
        decision.visibility = POLandscapeVisibilityDisabled;
        return decision;
    }
    if (!POIsConcreteInterfaceOrientation(sourceOrientation)) {
        return decision;
    }
    if (UIInterfaceOrientationIsLandscape(sourceOrientation) &&
        behavior == POLandscapeBehaviorHide) {
        decision.visibility = POLandscapeVisibilityBehaviorHidden;
        return decision;
    }

    decision.visibility = POLandscapeVisibilityVisible;
    decision.targetOrientation = sourceOrientation;
    if (UIInterfaceOrientationIsLandscape(sourceOrientation) &&
        behavior == POLandscapeBehaviorLock) {
        decision.targetOrientation = UIInterfaceOrientationPortrait;
    }
    return decision;
}

static POLandscapeDecision POComputeLandscapeDecision(NSDictionary *settings,
                                                       UIInterfaceOrientation sourceOrientation) {
    return POComputeLandscapeDecisionForBehavior(POSettingsEnabled(settings),
                                                 POReadLandscapeBehavior(settings),
                                                 sourceOrientation);
}

static PODirectionResolverOutput POResolveDirection(PODirectionResolverInput input) {
    UIInterfaceOrientation sourceOrientation = UIInterfaceOrientationUnknown;
    if (POIsConcreteInterfaceOrientation(input.sourceSceneOrientation)) {
        sourceOrientation = input.sourceSceneOrientation;
    } else if (input.sceneIsCurrent && POIsConcreteInterfaceOrientation(input.sceneOrientation)) {
        sourceOrientation = input.sceneOrientation;
    } else if (input.committedIsCurrent && POIsConcreteInterfaceOrientation(input.committedOrientation)) {
        sourceOrientation = input.committedOrientation;
    } else if (input.deviceForm == PODeviceFormPadRotatingSpringBoard &&
               POIsConcreteInterfaceOrientation(input.springBoardOrientation)) {
        sourceOrientation = input.springBoardOrientation;
    }

    PODirectionResolverOutput output;
    output.decision = POComputeLandscapeDecisionForBehavior(input.enabled, input.behavior, sourceOrientation);
    output.shouldCommit = output.decision.visibility == POLandscapeVisibilityVisible &&
        POIsConcreteInterfaceOrientation(output.decision.targetOrientation) &&
        output.decision.targetOrientation != input.windowAppliedOrientation;
    output.duration = 0;
    if (output.shouldCommit) {
        output.duration = input.requestedDuration > 0
            ? input.requestedDuration
            : MAX(0, input.fallbackDuration);
    }
    return output;
}

static BOOL POIsDirectionPhaseTransitionAllowed(PODirectionPhase from, PODirectionPhase to) {
    switch (from) {
        case PODirectionPhaseUnresolved:
            return to == PODirectionPhaseAwaitingScene ||
                to == PODirectionPhaseStable || to == PODirectionPhaseSuppressed;
        case PODirectionPhaseAwaitingScene:
            return to == PODirectionPhaseAwaitingScene ||
                to == PODirectionPhaseStable || to == PODirectionPhaseSuppressed;
        case PODirectionPhaseStable:
            return to == PODirectionPhaseStable ||
                to == PODirectionPhaseAwaitingScene || to == PODirectionPhaseSuppressed;
        case PODirectionPhaseSuppressed:
            return to == PODirectionPhaseSuppressed ||
                to == PODirectionPhaseAwaitingScene || to == PODirectionPhaseStable;
    }
    return NO;
}

static PODirectionPhase PODirectionPhaseForResolution(PODirectionResolverOutput resolution) {
    switch (resolution.decision.visibility) {
        case POLandscapeVisibilityDisabled:
        case POLandscapeVisibilityBehaviorHidden:
            return PODirectionPhaseSuppressed;
        case POLandscapeVisibilityUnresolved:
            return PODirectionPhaseAwaitingScene;
        case POLandscapeVisibilityVisible:
            if (POIsConcreteInterfaceOrientation(resolution.decision.targetOrientation)) {
                return PODirectionPhaseStable;
            }
            break;
    }
    return PODirectionPhaseAwaitingScene;
}

static void POTransitionDirectionPhase(PODirectionPhase nextPhase) {
    PODirectionState *state = PODirectionStateOwner();
    BOOL legal = POIsDirectionPhaseTransitionAllowed(state.phase, nextPhase);
    if (!legal) {
        nextPhase = PODirectionPhaseAwaitingScene;
    }
    state.phase = nextPhase;
}

static NSUInteger POAdvanceReconcileGeneration(void) {
    PODirectionState *state = PODirectionStateOwner();
    state.reconcileGeneration += 1;
    if (state.reconcileGeneration == 0) {
        state.reconcileGeneration = 1;
    }
    return state.reconcileGeneration;
}

static void POClearTransientDirectionInputs(void) {
    PODirectionState *state = PODirectionStateOwner();
    state.pendingAnimationDuration = 0;
    state.pendingAnimationTimestamp = 0;
}

static void PORecordPendingAnimationDuration(NSTimeInterval duration) {
    if (duration <= 0) {
        return;
    }
    PODirectionState *state = PODirectionStateOwner();
    state.pendingAnimationDuration = duration;
    state.pendingAnimationTimestamp = CACurrentMediaTime();
}

static NSTimeInterval POCurrentPendingAnimationDuration(void) {
    PODirectionState *state = PODirectionStateOwner();
    if (state.pendingAnimationDuration <= 0 || state.pendingAnimationTimestamp <= 0 ||
        CACurrentMediaTime() - state.pendingAnimationTimestamp > 1.0) {
        return 0;
    }
    return state.pendingAnimationDuration;
}

static void POEnsureWindowForEnabledState(void) {
    if (!window) {
        window = [POXWindow sharedWindow];
        window.rootViewController.view.alpha = 0;
        window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
        [window makeKeyAndVisible];
        return;
    }
    if (window.hidden) {
        window.hidden = NO;
        [window makeKeyAndVisible];
    }
}

static void POApplyOrdinarySettings(NSDictionary *settings, BOOL animateSideChange) {
    if (!window) {
        return;
    }

    BOOL leftHanded = [settings[@"leftHanded"] boolValue];
    CGAffineTransform targetTransform = leftHanded
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
    static BOOL hasLastSide = NO;
    static BOOL lastLeftHanded = NO;
    BOOL sideChanged = hasLastSide && (leftHanded != lastLeftHanded);
    hasLastSide = YES;
    lastLeftHanded = leftHanded;
    if (sideChanged && animateSideChange && !window.hidden) {
        CGFloat width = CGRectGetWidth(window.bounds);
        window.transform = CGAffineTransformTranslate(targetTransform, -width, 0);
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.2
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ window.transform = targetTransform; }
                         completion:nil];
    } else {
        window.transform = targetTransform;
    }
    [window.controller applyCurrentSettings];
}

static void POFinishVisibleRecovery(NSUInteger generation) {
    PODirectionState *state = PODirectionStateOwner();
    if (!window || generation != state.reconcileGeneration) {
        return;
    }

    NSDictionary *settings = [POApplicationHelper settings];
    NSString *sceneIdentifier = nil;
    UIInterfaceOrientation source = POCurrentCommittedInterfaceOrientation(&sceneIdentifier);
    POLandscapeDecision decision = POComputeLandscapeDecision(settings, source);
    if (!POSettingsEnabled(settings) || decision.visibility != POLandscapeVisibilityVisible ||
        !POIsConcreteInterfaceOrientation(decision.targetOrientation) ||
        window.pullOverInterfaceOrientation != decision.targetOrientation) {
        POReconcileCommittedInterfaceOrientation(@"visible-recovery", 0, NO);
        return;
    }

    state.visibility = POLandscapeVisibilityVisible;
    state.windowAppliedOrientation = window.pullOverInterfaceOrientation;
    POApplyOrdinarySettings(settings, NO);
    window.rootViewController.view.alpha = 1;
    window.userInteractionEnabled = YES;
}

static void POApplyDecision(PODirectionResolverOutput resolution,
                            NSDictionary *settings,
                            BOOL applyOrdinarySettings,
                            NSUInteger generation) {
    PODirectionState *state = PODirectionStateOwner();
    POLandscapeDecision decision = resolution.decision;
    if (decision.visibility == POLandscapeVisibilityUnresolved) {
        if (window && state.visibility == POLandscapeVisibilityUnresolved) {
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
        }
        return;
    }

    if (decision.visibility == POLandscapeVisibilityDisabled) {
        if (state.visibility != POLandscapeVisibilityDisabled) {
            state.visibility = POLandscapeVisibilityDisabled;
            POClearTransientDirectionInputs();
            if (window) {
                window.rootViewController.view.alpha = 0;
                window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
                [window.controller forceCloseAndReleaseImmediately];
            }
        }
        if (window) {
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
            window.hidden = YES;
        }
        return;
    }

    if (decision.visibility == POLandscapeVisibilityBehaviorHidden) {
        if (state.visibility != POLandscapeVisibilityBehaviorHidden) {
            state.visibility = POLandscapeVisibilityBehaviorHidden;
            POClearTransientDirectionInputs();
            POEnsureWindowForEnabledState();
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
            [window.controller forceCloseAndReleaseImmediately];
        }
        if (window) {
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
            window.hidden = NO;
        }
        return;
    }

    if (decision.visibility != POLandscapeVisibilityVisible ||
        !POIsConcreteInterfaceOrientation(decision.targetOrientation)) {
        return;
    }

    POEnsureWindowForEnabledState();
    BOOL recovering = state.visibility != POLandscapeVisibilityVisible;
    BOOL targetChanged = window.pullOverInterfaceOrientation != decision.targetOrientation;
    if (!recovering && targetChanged) {
        [window.controller prepareForOrientationChange];
    }
    if (recovering) {
        window.rootViewController.view.alpha = 0;
        window.userInteractionEnabled = (window.controller.dockStripTileCount > 0);
    } else if (applyOrdinarySettings) {
        POApplyOrdinarySettings(settings, YES);
    }

    if (!resolution.shouldCommit && !recovering) {
        state.visibility = POLandscapeVisibilityVisible;
        state.windowAppliedOrientation = window.pullOverInterfaceOrientation;
        window.rootViewController.view.alpha = 1;
        window.userInteractionEnabled = YES;
        return;
    }

    BOOL accepted = [window applyInterfaceOrientation:decision.targetOrientation
                                             duration:resolution.duration
                                           completion:^{
        if (recovering) {
            POFinishVisibleRecovery(generation);
        }
    }];
    if (!accepted) {
        if (targetChanged) {
            [window.controller handleOrientationChange];
        }
        return;
    }

    state.windowAppliedOrientation = decision.targetOrientation;
    if (!recovering) {
        state.visibility = POLandscapeVisibilityVisible;
        window.rootViewController.view.alpha = 1;
        window.userInteractionEnabled = YES;
    }
}

static void POHandleSceneSettingsUpdate(id scene, id settings) {
    UIInterfaceOrientation orientation = POReadInterfaceOrientation(settings, @selector(interfaceOrientation));
    NSString *sceneIdentifier = POSceneIdentifier(scene);
    BOOL isCurrentSource = POIsCurrentOrientationSourceScene(scene);
    BOOL isUsable = POSceneIsUsableForOrientation(scene);
    if (!isCurrentSource || !isUsable ||
        !POIsConcreteInterfaceOrientation(orientation) || sceneIdentifier.length == 0) {
        return;
    }

    PODirectionState *state = PODirectionStateOwner();
    state.sceneOrientation = orientation;
    state.sceneIdentifier = sceneIdentifier;
    state.sceneIsUsable = YES;
    POReconcileCommittedInterfaceOrientation(@"scene-settings", 0, NO);
}

static void PORecordSystemRotationCandidate(UIInterfaceOrientation orientation,
                                            NSTimeInterval duration) {
    PODirectionState *state = PODirectionStateOwner();
    state.springBoardOrientation = orientation;
    NSTimeInterval effectiveDuration = duration > 0 ? duration : POSystemOrientationAnimationDuration();
    PORecordPendingAnimationDuration(effectiveDuration);
}

static void POReconcileCommittedInterfaceOrientation(NSString *trigger,
                                                      NSTimeInterval duration,
                                                      BOOL applyOrdinarySettings) {
    if (![NSThread isMainThread]) {
        NSString *triggerCopy = [trigger copy] ?: @"unknown";
        dispatch_async(dispatch_get_main_queue(), ^{
            POReconcileCommittedInterfaceOrientation(triggerCopy, duration, applyOrdinarySettings);
        });
        return;
    }

    PODirectionState *state = PODirectionStateOwner();
    NSDictionary *settings = [POApplicationHelper settings];
    id sourceScene = POResolveCurrentOrientationSourceScene();
    NSString *sourceSceneIdentifier = POSceneIdentifier(sourceScene);
    UIInterfaceOrientation sourceSceneOrientation = POReadSceneInterfaceOrientation(sourceScene);
    BOOL sceneIsCurrent = state.sceneIsUsable &&
        POIsCurrentOrientationSourceSceneIdentifier(state.sceneIdentifier);
    BOOL committedIsCurrent =
        POIsCurrentOrientationSourceSceneIdentifier(state.committedSceneIdentifier);
    NSTimeInterval pendingDuration = duration > 0 ? duration : POCurrentPendingAnimationDuration();
    UIInterfaceOrientation windowApplied = window
        ? window.pullOverInterfaceOrientation
        : state.windowAppliedOrientation;

    PODirectionResolverInput input;
    input.physicalOrientation = state.physicalOrientation;
    input.springBoardOrientation = state.springBoardOrientation;
    input.sourceSceneOrientation = sourceSceneOrientation;
    input.sceneOrientation = sceneIsCurrent ? state.sceneOrientation : UIInterfaceOrientationUnknown;
    input.committedOrientation = committedIsCurrent
        ? state.committedOrientation
        : UIInterfaceOrientationUnknown;
    input.windowAppliedOrientation = windowApplied;
    input.sceneIsCurrent = sceneIsCurrent;
    input.committedIsCurrent = committedIsCurrent;
    input.enabled = POSettingsEnabled(settings);
    input.behavior = POReadLandscapeBehavior(settings);
    input.deviceForm = state.deviceForm;
    input.requestedDuration = pendingDuration;
    input.fallbackDuration = POSystemOrientationAnimationDuration();

    PODirectionResolverOutput resolution = POResolveDirection(input);
    POTransitionDirectionPhase(PODirectionPhaseForResolution(resolution));
    NSString *resolvedSceneIdentifier = nil;
    if (POIsConcreteInterfaceOrientation(sourceSceneOrientation)) {
        resolvedSceneIdentifier = sourceSceneIdentifier;
    } else if (sceneIsCurrent && POIsConcreteInterfaceOrientation(state.sceneOrientation)) {
        resolvedSceneIdentifier = state.sceneIdentifier;
    } else if (committedIsCurrent && POIsConcreteInterfaceOrientation(state.committedOrientation)) {
        resolvedSceneIdentifier = state.committedSceneIdentifier;
    }
    if (POIsConcreteInterfaceOrientation(resolution.decision.sourceOrientation)) {
        state.committedOrientation = resolution.decision.sourceOrientation;
        state.committedSceneIdentifier = resolvedSceneIdentifier;
    }

    NSUInteger generation = POAdvanceReconcileGeneration();
    POApplyDecision(resolution, settings, applyOrdinarySettings, generation);
    if (resolution.shouldCommit &&
        state.windowAppliedOrientation == resolution.decision.targetOrientation) {
        POClearTransientDirectionInputs();
    }
}

static void POStartOrientationObserver(void) {
    if (POOrientationObserver) {
        return;
    }

    Class observerClass = NSClassFromString(@"FBSOrientationObserver");
    if (!observerClass) {
        return;
    }

    POOrientationObserver = [[observerClass alloc] init];
    if (!POOrientationObserver) {
        return;
    }

    [POOrientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
        UIInterfaceOrientation physicalOrientation = [orientationUpdate respondsToSelector:@selector(orientation)]
            ? (UIInterfaceOrientation)orientationUpdate.orientation
            : UIInterfaceOrientationUnknown;
        NSTimeInterval duration = [orientationUpdate respondsToSelector:@selector(duration)]
            ? MAX(0, orientationUpdate.duration)
            : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            PODirectionState *state = PODirectionStateOwner();
            state.physicalOrientation = physicalOrientation;
            PORecordPendingAnimationDuration(duration);
            POReconcileCommittedInterfaceOrientation(@"fbs-observer", duration, NO);
        });
    }];
}

static BOOL POSettingsApplyScheduled;

static void POApplyCurrentSettings(void) {
    POSettingsApplyScheduled = NO;
    [POApplicationHelper reloadSettings];
    POReconcileCommittedInterfaceOrientation(@"settings", 0, YES);
}

static void POSettingsDidChange(CFNotificationCenterRef __unused center,
                                void * __unused observer,
                                CFStringRef __unused name,
                                const void * __unused object,
                                CFDictionaryRef __unused userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (POSettingsApplyScheduled) {
            return;
        }
        POSettingsApplyScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            POApplyCurrentSettings();
        });
    });
}

#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_CONST const
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_CONST
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_CONST
#endif

__asm__(".linker_option \"-framework\", \"CydiaSubstrate\"");

#pragma mark - Substrate hook declarations

@class FBScene;
@class SBHomeHardwareButton;
@class UIMutableApplicationSceneSettings;
@class SpringBoard;
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$)(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id, id);
static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id, id);
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$)(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id);
static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, unsigned long long);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, unsigned long long);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void (*_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$)(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, UIApplication *);
static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, UIApplication *);
static void (
    *_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$)(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id);
static void
_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id);
static void (*_logos_orig$_ungrouped$SpringBoard$takeScreenshot)(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST,
                                                                 SEL);
static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST,
                                                                SEL);
static void (*_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$)(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void (*POOriginalSBMainWorkspaceHandleOpenApplicationRequest)(id, SEL, id, id, id);
static void (*POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest)(id, SEL, id, id, id, id, id);
static id (*POOriginalSBToAppsWorkspaceTransactionInit)(id, SEL, id);
static id (*POOriginalSBAppToAppWorkspaceTransactionInit)(id, SEL, id);
@interface POXExternalAPI (ShortcutRouting)
+ (id)prepareShortcutOpenForApplication:(id)application
                                options:(id)options
                                 result:(id)result
                           routedResult:(id __autoreleasing *)routedResult;
@end
#pragma mark - External native activation hooks

static void POHookSBMainWorkspaceHandleOpenApplicationRequest(id self, SEL _cmd,
                                                               id systemService, id request,
                                                               id completion) {
    if (![POApplicationHelper isEnabled]) {
        POOriginalSBMainWorkspaceHandleOpenApplicationRequest(self, _cmd, systemService, request, completion);
        return;
    }
    id routedCompletion = [[POExternalActivationCoordinator sharedInstance]
        prepareOpenApplicationRequestIfNeeded:request completion:completion];
    POOriginalSBMainWorkspaceHandleOpenApplicationRequest(self, _cmd, systemService, request,
                                                          routedCompletion ?: completion);
}

static void POHookSBMainWorkspaceHandleTrustedOpenApplicationRequest(id self, SEL _cmd,
                                                                      id application, id options,
                                                                      id activationSettings, id origin,
                                                                      id result) {
    id routedResult = result;
    id shortcutOptions = [POXExternalAPI prepareShortcutOpenForApplication:application
                                                                   options:options
                                                                    result:result
                                                              routedResult:&routedResult];
    if (shortcutOptions == NSNull.null) {
        return;
    }
    if (shortcutOptions) {
        POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest(self, _cmd, application,
                                                                     shortcutOptions, activationSettings,
                                                                     origin, routedResult ?: result);
        return;
    }
    if (![POApplicationHelper isEnabled]) {
        POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest(self, _cmd, application, options,
                                                                       activationSettings, origin, result);
        return;
    }
    id routedOptions = [[POExternalActivationCoordinator sharedInstance]
        prepareTrustedWorkspaceOpenApplication:application
                                      options:options
                                       origin:origin
                                       result:result
                                 routedResult:&routedResult];
    POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest(self, _cmd, application,
                                                                 routedOptions ?: options,
                                                                 activationSettings, origin,
                                                                 routedResult ?: result);
}

static id POHookSBToAppsWorkspaceTransactionInit(id self, SEL _cmd, id transitionRequest) {
    if (![POApplicationHelper isEnabled]) {
        return POOriginalSBToAppsWorkspaceTransactionInit(self, _cmd, transitionRequest);
    }
    [[POExternalActivationCoordinator sharedInstance]
        prepareNativeTakeoverForTransitionRequestIfNeeded:transitionRequest];
    return POOriginalSBToAppsWorkspaceTransactionInit(self, _cmd, transitionRequest);
}

static id POHookSBAppToAppWorkspaceTransactionInit(id self, SEL _cmd, id transitionRequest) {
    if (![POApplicationHelper isEnabled]) {
        return POOriginalSBAppToAppWorkspaceTransactionInit(self, _cmd, transitionRequest);
    }
    [[POExternalActivationCoordinator sharedInstance]
        prepareNativeTakeoverForTransitionRequestIfNeeded:transitionRequest];
    return POOriginalSBAppToAppWorkspaceTransactionInit(self, _cmd, transitionRequest);
}

#pragma mark - Scene state hooks

static FBScene *(*_po_orig_FBSceneManager_createSceneFromRemnant)(id, SEL, id, id, id);
static FBScene *(*_po_orig_FBSceneManager_createLegacySceneFromRemnant)(id, SEL, id, id, id);

static FBScene *_po_hook_FBSceneManager_createSceneFromRemnant(id self, SEL _cmd,
                                                               id remnant, id settings,
                                                               id transitionContext) {
    if (![POApplicationHelper isEnabled]) {
        return _po_orig_FBSceneManager_createSceneFromRemnant(self, _cmd, remnant, settings, transitionContext);
    }
    id primedSettings = [ContextHostManager primePendingSceneRemnantSettings:settings
                                                                         remnant:remnant];
    FBScene *scene = _po_orig_FBSceneManager_createSceneFromRemnant(self, _cmd, remnant,
                                                                    primedSettings ?: settings,
                                                                    transitionContext);
    [ContextHostManager completePendingSceneRemnantReconnect:scene];
    return scene;
}

static FBScene *_po_hook_FBSceneManager_createLegacySceneFromRemnant(id self, SEL _cmd,
                                                                     id remnant, id settings,
                                                                     id transitionContext) {
    if (![POApplicationHelper isEnabled]) {
        return _po_orig_FBSceneManager_createLegacySceneFromRemnant(self, _cmd, remnant, settings, transitionContext);
    }
    id primedSettings = [ContextHostManager primePendingSceneRemnantSettings:settings
                                                                         remnant:remnant];
    FBScene *scene = _po_orig_FBSceneManager_createLegacySceneFromRemnant(self, _cmd, remnant,
                                                                          primedSettings ?: settings,
                                                                          transitionContext);
    [ContextHostManager completePendingSceneRemnantReconnect:scene];
    return scene;
}

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx,
    id completion) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, settings, ctx,
                                                                                          completion);
        return;
    }
    settings = [ContextHostManager prepareNativeSceneSettingsIfNeeded:settings
                                                              forScene:(FBScene *)self] ?: settings;
    if ([ContextHostManager shouldKeepForegroundForScene:(FBScene *)self]) {
        @try {
            id mutableSettings = [settings mutableCopy] ?: settings;
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [mutableSettings setDeactivationReasons:0];
            }
            [ContextHostManager reconcileHostedInterfaceOrientationInSettings:mutableSettings forScene:(FBScene *)self];
            POHandleSceneSettingsUpdate(self, mutableSettings);
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, mutableSettings,
                                                                                            ctx, completion);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    POHandleSceneSettingsUpdate(self, settings);
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, settings, ctx,
                                                                                    completion);
}

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, settings, ctx);
        return;
    }
    settings = [ContextHostManager prepareNativeSceneSettingsIfNeeded:settings
                                                              forScene:(FBScene *)self] ?: settings;
    if ([ContextHostManager shouldKeepForegroundForScene:(FBScene *)self]) {
        @try {
            id mutableSettings = [settings mutableCopy] ?: settings;
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [mutableSettings setDeactivationReasons:0];
            }
            [ContextHostManager reconcileHostedInterfaceOrientationInSettings:mutableSettings forScene:(FBScene *)self];
            POHandleSceneSettingsUpdate(self, mutableSettings);
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, mutableSettings, ctx);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    POHandleSceneSettingsUpdate(self, settings);
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, settings, ctx);
}

#pragma mark - Application scene settings hooks

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    unsigned long long reasons) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, reasons);
        return;
    }
    if (reasons != 0) {
        NSString *identifier = [ContextHostManager privateSceneIdentityStringFromSettings:self];
        if (!identifier) {
            identifier = [ContextHostManager sceneIdentityStringFromSettings:self];
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, 0);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, reasons);
}

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    BOOL foreground) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, foreground);
        return;
    }
    if (!foreground) {
        NSString *identifier = [ContextHostManager privateSceneIdentityStringFromSettings:self];
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, YES);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, foreground);
}

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    BOOL backgrounded) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, backgrounded);
        return;
    }
    if (backgrounded) {
        NSString *identifier = [ContextHostManager privateSceneIdentityStringFromSettings:self];
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, NO);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, backgrounded);
}

#pragma mark - SpringBoard hooks

static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, UIApplication *arg1) {
    _logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$(self, _cmd, arg1);

    NSDictionary *settings = [POApplicationHelper settings];
    if (!POSettingsEnabled(settings)) {
        return;
    }

    POStartOrientationObserver();
    POReconcileCommittedInterfaceOrientation(@"launch", 0, NO);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      POApplyCurrentSettings();
    });
}

static void
_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, long long arg1,
    double arg2, BOOL arg3, BOOL arg4, id arg5) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
            self, _cmd, arg1, arg2, arg3, arg4, arg5);
        return;
    }
    PORecordSystemRotationCandidate((UIInterfaceOrientation)arg1, arg2);
    _logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
        self, _cmd, arg1, arg2, arg3, arg4, arg5);
    POReconcileCommittedInterfaceOrientation(@"springboard-commit", MAX(0, arg2), NO);
}

static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
        return;
    }
    BOOL enabled = [[POApplicationHelper settings][@"hideOnScreenshot"] boolValue];
    POHandle *handle = window.controller.handle;
    if (handle && enabled && !handle.hidden) {
        CGFloat previousAlpha = handle.alpha;
        handle.hidden = YES;
        handle.alpha = 0;

        [CATransaction flush];
        _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          handle.hidden = NO;
          handle.alpha = previousAlpha;
        });
        return;
    }
    _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
}

#pragma mark - Hardware and screen-state handling

static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$(self, _cmd, arg1);
        return;
    }
    if ([window.controller isPanelActive]) {
        [window.controller close];
    } else {
        _logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$(self, _cmd, arg1);
    }
}

static void PORegisterScreenBlankObserver(void) {
    static dispatch_once_t onceToken;
    static int token = 0;
    dispatch_once(&onceToken, ^{
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            if (notify_get_state(t, &state) != NOTIFY_STATUS_OK || state == 0) {
                return;
            }
            [window.controller forceCloseAndReleaseImmediately];
        });
    });
}

#pragma mark - 系统手势呼出 hook（0.2.4：唯一新增 hook）

// 崩溃自解除标记（纯 C 文件操作 —— constructor 阶段 Foundation 尚未就绪，铁律 1）
static const char *kPOGestureGuardPath = "/var/mobile/PullOverMF.gestureguard";

static BOOL POPosixFileExists(const char *path) {
    return access(path, F_OK) == 0;
}

static void POPosixWriteFile(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        ssize_t written = write(fd, "armed", 5);
        (void)written;
        close(fd);
    }
}

static void POPosixDeleteFile(const char *path) {
    unlink(path);
}

// hook 目标（0.2.5）：按 Stheno 逆向清单**多候选探测注册**。
// 0.2.4 只试了 SBReachabilityGestureRecognizer/_handlePullGesture: —— iOS 17.3.1 上不存在
// （用户日志实证"不注册"）。这里把 Stheno hook 过的类/方法逐个探测，存在哪个注册哪个；
// hook 内部再按"触点是否在贴边触发带±60pt"决定接管或放行 —— 手势起自屏幕中部时
// （回桌面/多任务/控制中心）系统行为完全不受影响。
//
// 【0.2.7】Stheno 5 个候选在 iOS 17.3.1 **全部不存在**（log11/12 实证）⇒ 全屏 App 呼出
// 换 **SBSystemGestureManager 系统边缘手势**路线（triggr 开源 GPL 实证 iOS 15~18）：
//   1. hook `SBMainDisplaySystemGestureManager _init` —— SpringBoard 建好管理器后
//      （不能替它先建，iOS 17 实测 abort）调用 MFRingInstallEdgePanGesture() 注册
//      贴边 UIScreenEdgePanGestureRecognizer（type=2 私有 init + 自定义 withType 号）；
//   2. hook `SBSystemGestureManager _isGestureWithTypeAllowed:` /
//      `_shouldEnableSystemGestureWithType:` —— 对自定义 type 直接放行，其余原样。
// 启动 10 秒后兜底再装一次（幂等），防 _init hook 没触发。
// ⚠️ 铁律 2：MFRingPicker.m 是 ObjC（C 链接），本文件是 ObjC++ —— 声明必须 extern "C"，
// 否则 C++ 修饰名（__Z29MFRing…）未定义 → dyld 拒绝加载整个 dylib（0.2.4 自检曾抓到）。
extern "C" {
BOOL MFRingWantsSystemGestureSummon(void);
BOOL MFRingPointNearTriggerEdge(CGPoint point);
void MFRingSummonFromSystemGestureAtPoint(CGPoint point);
// 0.2.7：SBSystemGestureManager 系统边缘手势（triggr 实证路线，iOS 15~18 同一实现，
// App 内也收得到 —— 归档 38"SB 普通窗口收不到全屏 App 触摸"死结的解法）
void MFRingInstallEdgePanGesture(void);
BOOL MFRingIsEdgeGestureType(unsigned long long type);
}

static void (*_po_orig_SystemGestureHandler)(id, SEL, id);

static void _po_hook_SystemGestureHandler(id self, SEL _cmd, id gesture) {
    @try {
        if (MFRingWantsSystemGestureSummon() && [gesture isKindOfClass:[UIGestureRecognizer class]]) {
            UIGestureRecognizer *recognizer = (UIGestureRecognizer *)gesture;
            if (recognizer.state != UIGestureRecognizerStateEnded &&
                recognizer.state != UIGestureRecognizerStateCancelled &&
                recognizer.state != UIGestureRecognizerStateFailed) {
                CGPoint location = [recognizer locationInView:nil];
                if (!isnan(location.x) && !isnan(location.y) &&
                    MFRingPointNearTriggerEdge(location)) {
                    MFRingSummonFromSystemGestureAtPoint(location);
                    return;   // 只接管"贴边开始"的手势；mfRingGestureSummon=false 可还原
                }
            }
        }
    } @catch (NSException *gestureException) {
        (void)gestureException;   // 失败放行：绝不把异常抛回系统手势代码
    }
    if (_po_orig_SystemGestureHandler != NULL) {
        _po_orig_SystemGestureHandler(self, _cmd, gesture);
    }
}

// ---------- 0.2.7：SBSystemGestureManager 系统边缘手势 ----------
//
// 三个 hook 全部是"转发一行"的薄壳，异常不可能从这里抛出（无 ObjC 分配、无解析）；
// 真正干活的 MFRingInstallEdgePanGesture() 在 MFRingPicker.m 里 @try 全包。

static id (*_po_orig_SBMainDisplaySystemGestureManager_init)(id, SEL);

static id _po_hook_SBMainDisplaySystemGestureManager_init(id self, SEL _cmd) {
    id manager = (_po_orig_SBMainDisplaySystemGestureManager_init != NULL)
                     ? _po_orig_SBMainDisplaySystemGestureManager_init(self, _cmd)
                     : self;
    // SpringBoard 手势管理器就绪 → 注册贴边识别器（内部幂等 + 主线程 + @try）
    dispatch_async(dispatch_get_main_queue(), ^{
        MFRingInstallEdgePanGesture();
    });
    return manager;   // ⚠️ init 的返回值必须原样转返（0.1.x 教训：错乱 x0 = 不可预测）
}

static BOOL (*_po_orig_SBSystemGestureManager_typeAllowed)(id, SEL, unsigned long long);

static BOOL _po_hook_SBSystemGestureManager_typeAllowed(id self, SEL _cmd, unsigned long long type) {
    if (MFRingIsEdgeGestureType(type)) {
        return YES;   // 自定义 type 放行；系统 type 原样
    }
    if (_po_orig_SBSystemGestureManager_typeAllowed != NULL) {
        return _po_orig_SBSystemGestureManager_typeAllowed(self, _cmd, type);
    }
    return NO;
}

static BOOL (*_po_orig_SBSystemGestureManager_shouldEnable)(id, SEL, unsigned long long);

static BOOL _po_hook_SBSystemGestureManager_shouldEnable(id self, SEL _cmd, unsigned long long type) {
    if (MFRingIsEdgeGestureType(type)) {
        return YES;
    }
    if (_po_orig_SBSystemGestureManager_shouldEnable != NULL) {
        return _po_orig_SBSystemGestureManager_shouldEnable(self, _cmd, type);
    }
    return NO;
}

#pragma mark - Hook registration

static __attribute__((constructor)) void POInstallSpringBoardHooks(int __unused argc, char __unused **argv,
                                                                    char __unused **envp) {
    if (!objc_getClass("SpringBoard")) {
        return;
    }
    // ⚠️ constructor 阶段 Foundation/UIKit 尚未就绪 —— 这里只能用纯 C 日志。
    // 0.1.2 正是在这里调用 NSDateFormatter / [UIDevice currentDevice] 把整个 tweak 拖崩，
    // 结果 dylib 加载失败、桌面连手柄都不显示。
    // ===== 【0.4.0】v0.3.x 终结 → v0.4.0 起：相机兼容拆包 =====
    //  浮窗里的 App（微信"扫一扫" / QQ 拍照）用不了相机的根因：
    //  画面被搬进 SpringBoard 了，但那个 App 自身仍是**后台** ⇒ 相机服务 cameracaptured
    //  拒绝为它出帧。修法只能往相机守护进程注入、放宽"前台相机权"的判定。
    //  ⚠️ 但**绝不能**把本 dylib 注进去：本 dylib 的未定义符号里有
    //  `_UIApplicationLaunchOptionsSourceApplicationKey` / `_kCACornerCurveContinuous` /
    //  `_OBJC_CLASS_$_UIApplication` 这类**加载期即绑定**（non-lazy）的 UIKit / QuartzCore
    //  符号，而相机守护进程不加载这两个框架 ⇒ 注入即在 dyld 绑定阶段 "Symbol not found"
    //  崩掉相机服务（比不修还糟）。
    //  ⇒ 相机兼容独立成 **POCaptureCompat.dylib**（零 UIKit/零 QuartzCore 依赖，
    //    plist 只注 cameracaptured）。见 Makefile / POCameraCompatibility.m /
    //    POCaptureCompat.plist。本文件（主 dylib）依旧只注入 SpringBoard，
    //    **一行新 hook 都没加**（前期"不要多个 hook，确保不卡开机"的要求继续满足）。
    //  取证工具：`.workbuddy-ai/tmp/probe_undef.py <deb>` 列未定义符号并标出加载期绑定的全局量。
    MFLogRawC("=== PullOverMF 0.6.13 加载（SpringBoard）===");

    // 【MF 0.1.3】Stheno 风格圆盘选择器：延迟 2 秒安装（等屏幕就绪）。
    // 零 hook；安装失败只损失圆盘，不影响浮窗与手柄。
    // 【0.1.9】挂到 PullOver 自己的窗口（POXWindow），不自建窗口（保留）。
    // 【0.2.0】修掉"边缘一滑就注销"的真凶：MFRingPicker 内属性 setter 死递归。
    // 【0.2.1】圆盘变双圈；新增应用编辑器（长按边缘触发条打开，自己挑 App）。
    // 【0.2.2】容量 24 + 两圈外圈铺满/内圈自适应半径 + 停靠点下移 + 触摸到达诊断。
    // 【0.2.3】宿主改为**优先状态栏窗口**（全屏 App 上也收得到触摸；找不到就退回 POXWindow，零 hook）
    //          + 圆盘大小随 App 数量自适应（50% / 85% / 100%）+ 全窗口清单诊断日志。
    // 【0.2.4】状态栏窗口默认关闭（实测挡桌面滑动）；系统手势 hook 改多候选（见 0.2.5）。
    // 【0.2.5】等距双圈（外圈多内圈少、无巨大空隙）+ 图标按数量分档 + 编辑器找回系统应用
    //          + 手势 hook 多候选探测（Stheno 清单：Reachability/GrabberTongue/FluidSwitcher）。
    // 【0.2.6】编辑器过滤改「桌面图标模型」判据（SBIconModel applicationIconForBundleIdentifier:
    //          非 nil = 桌面上真的有图标；0.2.5 的兜底占位图导致"跳过无图标 0 个"，白图标全进列表）。
    // 【0.2.7】全屏 App 呼出圆盘：Stheno 5 候选全部不存在（log12 实证）→ 换
    //          SBSystemGestureManager 系统边缘手势（triggr 实证 iOS 15~18，App 内有效）。
    // 【0.2.8】log13 实证：注册/呼出全成功，但呼出触摸被识别器吃掉 ⇒ 圆盘卡"跟随手指"。
    //          修法在 MFRingPicker.m：识别器自己驱动完整交互（跟随/停靠/悬停/松手打开）。
    // 【0.2.9】log14 实证：全屏下只有呼出触摸能驱动悬停 ⇒ 离右缘远的图标没法选、
    //          要二次点击才开。修法：展开容器挂悬停平移手势（见 MFRingPicker.m）。
    // 【0.2.10】log15 实证：防误开 22pt 守卫反复清掉悬停选中 ⇒ 松手打不开。
    //          修法：守卫只在首次真移开前生效（见 MFRingPicker.m updateSelectionForPoint）。
    // 【0.2.11】log16 + 用户实证：拖着圆盘全屏 App 跟着滚 = 触摸被同时喂给 App，
    //          识别器事件流被饿死 ⇒ 悬停稀疏、松手无选中。修法：cancelsTouchesInView=YES
    //          （识别器独占触摸，triggr 默认同款）。
    // 【0.2.12】log17 实证：松手点常已离开圆盘回到边缘一带（桌面呼出现在也走边缘手势）
    //          ⇒ 当前选中早已清空 = 仍要二次点击。修法：松手回退开时间窗内最近悬停选中
    //          （见 MFRingPicker.m releaseOpenBundleIdForPoint:）。
    // 【0.2.13】log18 实证：回退窗口 2.0s 差 0.275s 没够着；悬停事件流离边即断。
    // 【0.2.14】按用户硬性要求重做：自查发现"只有右边能选中"真凶是展开后仍有的带门
    //          （呼出后手指滑离触发带，事件全被自己丢掉）。修法：展开后去带门（全屏
    //          任意位置 跟随/停靠/悬停/松手）+ 恢复跟随 + 松手必关圆盘（见 MFRingPicker.m）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MFRingPickerInstall();
    });

    // 【0.2.5→0.2.7】系统手势呼出圆盘：
    //  · Stheno 多候选探测（0.2.5）—— iOS 17.3.1 实测 5 个全部不存在，仅兼容保留；
    //  · 0.2.7 新增 SBSystemGestureManager 系统边缘手势（triggr 实证路线，全屏 App 内有效）。
    // 共用同一"崩溃自解除"：任何手势 hook 注册前立标记，存活 20 秒自动撤；
    // 下次启动见标记则本轮不注册（删除 /var/mobile/PullOverMF.gestureguard 可重试）。
    {
        if (POPosixFileExists(kPOGestureGuardPath)) {
            MFLogRawC("PullOverMF 0.6.13: 检测到手势 hook 崩溃标记 -> 本轮不注册（删除 /var/mobile/PullOverMF.gestureguard 可重试）");
        } else {
            int registered = 0;
            char summary[384];
            int summaryLen = 0;
            summary[0] = '\0';

            // —— ① Stheno 多候选探测（0.2.5，兼容保留；本机全不存在，零开销）——
            static const struct { const char *className; const char *methodName; } kGestureCandidates[] = {
                { "SBReachabilityGestureRecognizer", "_handlePullGesture:" },
                { "SBReachabilityManager", "_handlePullGesture:" },
                { "SBGrabberTongue", "_handlePan:" },
                { "SBFluidSwitcherGestureManager", "_handlePan:" },
                { "_SBFluidSwitcherPanGestureRecognizer", "_handlePan:" },
            };
            const int kCandidateCount = (int)(sizeof(kGestureCandidates) / sizeof(kGestureCandidates[0]));
            for (int i = 0; i < kCandidateCount; i++) {
                Class targetClass = objc_getClass(kGestureCandidates[i].className);
                SEL handlerSelector = sel_registerName(kGestureCandidates[i].methodName);
                if (targetClass == nil || ![targetClass instancesRespondToSelector:handlerSelector]) {
                    continue;
                }
                _po_orig_SystemGestureHandler = NULL;
                MSHookMessageEx(targetClass, handlerSelector,
                                (IMP)&_po_hook_SystemGestureHandler,
                                (IMP *)&_po_orig_SystemGestureHandler);
                registered++;
                int written = snprintf(summary + summaryLen, sizeof(summary) - (size_t)summaryLen,
                                       "%s%s.%s", (registered > 1 ? " | " : ""),
                                       kGestureCandidates[i].className, kGestureCandidates[i].methodName);
                if (written > 0 && summaryLen + written < (int)sizeof(summary)) {
                    summaryLen += written;
                }
            }
            if (registered == 0) {
                MFLogRawC("PullOverMF 0.6.13: Stheno 候选手势类全部不存在（预期内）-> 走 SBSystemGestureManager 边缘手势路线");
            }

            // —— ② 0.2.7 注册 / 0.2.8 完整驱动：SBSystemGestureManager 系统边缘手势（triggr 实证 iOS 15~18）——
            Class mainDisplayMgrClass = objc_getClass("SBMainDisplaySystemGestureManager");
            SEL managerInitSelector = sel_registerName("_init");
            if (mainDisplayMgrClass != nil &&
                [mainDisplayMgrClass instancesRespondToSelector:managerInitSelector]) {
                _po_orig_SBMainDisplaySystemGestureManager_init = NULL;
                MSHookMessageEx(mainDisplayMgrClass, managerInitSelector,
                                (IMP)&_po_hook_SBMainDisplaySystemGestureManager_init,
                                (IMP *)&_po_orig_SBMainDisplaySystemGestureManager_init);
                registered++;
            }
            Class sysGestureClass = objc_getClass("SBSystemGestureManager");
            SEL typeAllowedSelector = sel_registerName("_isGestureWithTypeAllowed:");
            SEL shouldEnableSelector = sel_registerName("_shouldEnableSystemGestureWithType:");
            if (sysGestureClass != nil &&
                [sysGestureClass instancesRespondToSelector:typeAllowedSelector]) {
                _po_orig_SBSystemGestureManager_typeAllowed = NULL;
                MSHookMessageEx(sysGestureClass, typeAllowedSelector,
                                (IMP)&_po_hook_SBSystemGestureManager_typeAllowed,
                                (IMP *)&_po_orig_SBSystemGestureManager_typeAllowed);
                registered++;
            }
            if (sysGestureClass != nil &&
                [sysGestureClass instancesRespondToSelector:shouldEnableSelector]) {
                _po_orig_SBSystemGestureManager_shouldEnable = NULL;
                MSHookMessageEx(sysGestureClass, shouldEnableSelector,
                                (IMP)&_po_hook_SBSystemGestureManager_shouldEnable,
                                (IMP *)&_po_orig_SBSystemGestureManager_shouldEnable);
                registered++;
            }

            if (registered > 0) {
                char line[512];
                snprintf(line, sizeof(line),
                         "PullOverMF 0.6.13: 手势 hook 已注册 %d 个（崩溃自解除已布防）: %s",
                         registered, (summaryLen > 0 ? summary : "SBSystemGestureManager 边缘手势"));
                MFLogRawC(line);
                POPosixWriteFile(kPOGestureGuardPath);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    POPosixDeleteFile(kPOGestureGuardPath);
                    MFLog(@"[ring] 手势 hook 已存活 20 秒，崩溃标记已撤除");
                });
                // 兜底：即使 _init hook 没触发，10 秒后再尝试安装边缘识别器（幂等）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    MFRingInstallEdgePanGesture();
                });
            } else {
                MFLogRawC("PullOverMF 0.6.13: 手势 hook 目标全部不存在 -> 不注册（系统手势原样放行）");
            }
        }
    }

    POSetCameraForegroundGrantBundleIdentifier(nil);
    if (POSettingsEnabled([POApplicationHelper settings])) {
        PORegisterScreenBlankObserver();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, POSettingsDidChange,
                                        kPOSettingsChangedNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    {
        Class sceneManagerClass = objc_getClass("FBSceneManager");
        SEL remnantSelector = NSSelectorFromString(@"createSceneFromRemnant:withSettings:transitionContext:");
        if ([sceneManagerClass instancesRespondToSelector:remnantSelector]) {
            MSHookMessageEx(sceneManagerClass,
                            remnantSelector,
                            (IMP)&_po_hook_FBSceneManager_createSceneFromRemnant,
                            (IMP *)&_po_orig_FBSceneManager_createSceneFromRemnant);
        }
        SEL legacyRemnantSelector = NSSelectorFromString(@"createLegacySceneFromRemnant:withSettings:transitionContext:");
        if ([sceneManagerClass instancesRespondToSelector:legacyRemnantSelector]) {
            MSHookMessageEx(sceneManagerClass,
                            legacyRemnantSelector,
                            (IMP)&_po_hook_FBSceneManager_createLegacySceneFromRemnant,
                            (IMP *)&_po_orig_FBSceneManager_createLegacySceneFromRemnant);
        }

        Class _logos_class$_ungrouped$FBScene = objc_getClass("FBScene");
        {
            MSHookMessageEx(_logos_class$_ungrouped$FBScene,
                            @selector(updateSettings:withTransitionContext:completion:),
                            (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$,
                            (IMP *)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$FBScene, @selector(updateSettings:withTransitionContext:),
                            (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$,
                            (IMP *)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$);
        }
        Class _logos_class$_ungrouped$UIMutableApplicationSceneSettings =
            objc_getClass("UIMutableApplicationSceneSettings");
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings,
                            @selector(setDeactivationReasons:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setForeground:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setBackgrounded:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$);
        }
        Class mainWorkspaceClass = objc_getClass("SBMainWorkspace");
        SEL handleOpenSelector = NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
        if ([mainWorkspaceClass instancesRespondToSelector:handleOpenSelector]) {
            MSHookMessageEx(mainWorkspaceClass,
                            handleOpenSelector,
                            (IMP)&POHookSBMainWorkspaceHandleOpenApplicationRequest,
                            (IMP *)&POOriginalSBMainWorkspaceHandleOpenApplicationRequest);
        }
        SEL trustedOpenSelector = NSSelectorFromString(@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:");
        if ([mainWorkspaceClass instancesRespondToSelector:trustedOpenSelector]) {
            MSHookMessageEx(mainWorkspaceClass,
                            trustedOpenSelector,
                            (IMP)&POHookSBMainWorkspaceHandleTrustedOpenApplicationRequest,
                            (IMP *)&POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest);
        }
        SEL toAppsInitSelector = NSSelectorFromString(@"initWithTransitionRequest:");
        Class toAppsTransactionClass = objc_getClass("SBToAppsWorkspaceTransaction");
        if ([toAppsTransactionClass instancesRespondToSelector:toAppsInitSelector]) {
            MSHookMessageEx(toAppsTransactionClass,
                            toAppsInitSelector,
                            (IMP)&POHookSBToAppsWorkspaceTransactionInit,
                            (IMP *)&POOriginalSBToAppsWorkspaceTransactionInit);
        }
        Class appToAppTransactionClass = objc_getClass("SBAppToAppWorkspaceTransaction");
        if ([appToAppTransactionClass instancesRespondToSelector:toAppsInitSelector]) {
            MSHookMessageEx(appToAppTransactionClass,
                            toAppsInitSelector,
                            (IMP)&POHookSBAppToAppWorkspaceTransactionInit,
                            (IMP *)&POOriginalSBAppToAppWorkspaceTransactionInit);
        }

        Class _logos_class$_ungrouped$SpringBoard = objc_getClass("SpringBoard");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(applicationDidFinishLaunching:),
                            (IMP)&_logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$,
                            (IMP *)&_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$);
        }
        {
            MSHookMessageEx(
                _logos_class$_ungrouped$SpringBoard,
                NSSelectorFromString(@"noteInterfaceOrientationChanged:duration:updateMirroredDisplays:force:logMessage:"),
                (IMP)&_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$,
                (IMP *)&_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, NSSelectorFromString(@"takeScreenshot"),
                            (IMP)&_logos_method$_ungrouped$SpringBoard$takeScreenshot,
                            (IMP *)&_logos_orig$_ungrouped$SpringBoard$takeScreenshot);
        }
        Class _logos_class$_ungrouped$SBHomeHardwareButton = objc_getClass("SBHomeHardwareButton");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SBHomeHardwareButton, NSSelectorFromString(@"singlePressUp:"),
                            (IMP)&_logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$,
                            (IMP *)&_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$);
        }
    }
}
