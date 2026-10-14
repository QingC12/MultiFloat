#import "POXExternalAPI.h"
#import "POApplicationHelper.h"
#import "POXWindow.h"
#import <dlfcn.h>
#import <objc/message.h>

@interface POXExternalAPI ()
@property(nonatomic, copy) POXOpenCompletion pendingCompletion;
@property(nonatomic, copy) NSString *pendingBundleID;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL pendingShortcut;
@property(nonatomic) BOOL shortcutRequestClaimed;
@end

@implementation POXExternalAPI

+ (NSUInteger)apiVersion {
    return 1;
}

+ (instancetype)sharedAPI {
    static POXExternalAPI *api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api = [POXExternalAPI new];
    });
    return api;
}

+ (void)openApplication:(NSString *)bundleID completion:(POXOpenCompletion)completion {
    [[self sharedAPI] startBundleID:bundleID completion:completion];
}

+ (void)activateShortcutForApplication:(NSString *)bundleID
                                   type:(NSString *)type
                               userInfo:(NSDictionary *)userInfo
                             completion:(POXOpenCompletion)completion {
    [[self sharedAPI] startShortcutForBundleID:bundleID type:type userInfo:userInfo completion:completion];
}

+ (id)prepareShortcutOpenForApplication:(id)application
                                options:(id)options
                                 result:(id)result
                           routedResult:(id __autoreleasing *)routedResult {
    POXExternalAPI *api = [self sharedAPI];
    if (!api.pendingShortcut || api.shortcutRequestClaimed || !api.pendingCompletion) {
        return nil;
    }
    NSString *bundleID = [application isKindOfClass:NSString.class]
        ? application
        : ([application respondsToSelector:@selector(bundleIdentifier)]
            ? ((id (*)(id, SEL))objc_msgSend)(application, @selector(bundleIdentifier)) : nil);
    if (![bundleID isEqualToString:api.pendingBundleID]) {
        return nil;
    }
    NSDictionary *dictionary = [options isKindOfClass:NSDictionary.class]
        ? options
        : ([options respondsToSelector:@selector(dictionary)]
            ? ((id (*)(id, SEL))objc_msgSend)(options, @selector(dictionary)) : nil);
    if (![dictionary isKindOfClass:NSDictionary.class] ||
        ![dictionary[@"__LaunchOrigin"] isEqual:@"SBSLaunchOriginShortcutItem"] ||
        ![dictionary[@"__Actions"] isKindOfClass:NSArray.class] ||
        [dictionary[@"__Actions"] count] == 0) {
        return nil;
    }
    NSString * __unsafe_unretained *symbol = (NSString * __unsafe_unretained *)dlsym(
        RTLD_DEFAULT, "FBSOpenApplicationOptionKeyActivateSuspended");
    NSString *key = symbol ? *symbol : nil;
    if (key.length == 0) {
        [api finish:POXOpenOutcomeUnsupported];
        if (result) ((void (^)(NSError *))result)([NSError errorWithDomain:@"POXExternalAPI" code:1 userInfo:nil]);
        return NSNull.null;
    }
    NSMutableDictionary *prepared = [dictionary mutableCopy];
    prepared[key] = @YES;
    id preparedOptions = [options isKindOfClass:NSDictionary.class] ? [prepared copy] : options;
    if (preparedOptions == options) {
        SEL setter = NSSelectorFromString(@"setDictionary:");
        if (![options respondsToSelector:setter]) {
            [api finish:POXOpenOutcomeUnsupported];
            if (result) ((void (^)(NSError *))result)([NSError errorWithDomain:@"POXExternalAPI" code:1 userInfo:nil]);
            return NSNull.null;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(options, setter, prepared);
    }
    api.shortcutRequestClaimed = YES;
    NSUInteger generation = api.generation;
    void (^originalResult)(NSError *) = result;
    void (^wrappedResult)(NSError *) = ^(NSError *error) {
        if (originalResult) originalResult(error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != api.generation || !api.pendingCompletion) return;
            if (error) {
                [api finish:POXOpenOutcomeFailed];
                return;
            }
            POXWindow *window = (POXWindow *)[POXWindow sharedWindow];
            if (![window.controller beginExternalHostedApplication:api.pendingBundleID]) {
                [api finish:POXOpenOutcomeUnavailable];
                return;
            }
            [api checkVisibilityForGeneration:generation attempts:0];
        });
    };
    if (routedResult) *routedResult = [wrappedResult copy];
    return preparedOptions;
}

- (void)finish:(POXOpenOutcome)outcome {
    POXOpenCompletion completion = self.pendingCompletion;
    self.pendingCompletion = nil;
    self.pendingBundleID = nil;
    self.pendingShortcut = NO;
    self.shortcutRequestClaimed = NO;
    self.generation += 1;
    if (completion) {
        completion(outcome);
    }
}

- (void)startShortcutForBundleID:(NSString *)bundleID
                            type:(NSString *)type
                        userInfo:(NSDictionary *)userInfo
                      completion:(POXOpenCompletion)completion {
    if (!completion) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startShortcutForBundleID:bundleID type:type userInfo:userInfo completion:completion];
        });
        return;
    }
    if (self.pendingCompletion) {
        completion(POXOpenOutcomeBusy);
        return;
    }
    POXWindow *window = (POXWindow *)[POXWindow sharedWindow];
    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    Class iconClass = NSClassFromString(@"SBIconView");
    SEL activate = NSSelectorFromString(@"activateShortcut:withBundleIdentifier:forIconView:");
    NSString * __unsafe_unretained *suspendedKey = (NSString * __unsafe_unretained *)dlsym(
        RTLD_DEFAULT, "FBSOpenApplicationOptionKeyActivateSuspended");
    if (bundleID.length == 0 || type.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleID] ||
        !itemClass || ![itemClass instancesRespondToSelector:@selector(setType:)] ||
        ![iconClass respondsToSelector:activate] ||
        !suspendedKey || (*suspendedKey).length == 0) {
        completion(POXOpenOutcomeUnsupported);
        return;
    }
    if (![POApplicationHelper isEnabled] || window.hidden ||
        window.rootViewController.view.alpha < 0.1 || !window.controller ||
        window.controller.isPanelTransitioning ||
        [[POApplicationHelper frontMostBundleId] isEqualToString:bundleID]) {
        completion(POXOpenOutcomeUnavailable);
        return;
    }
    id item = [itemClass new];
    if (!item) {
        completion(POXOpenOutcomeUnsupported);
        return;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setType:), type);
        if (userInfo && [item respondsToSelector:@selector(setUserInfo:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setUserInfo:), userInfo);
        }
    } @catch (__unused NSException *exception) {
        completion(POXOpenOutcomeFailed);
        return;
    }
    self.pendingBundleID = [bundleID copy];
    self.pendingCompletion = [completion copy];
    self.pendingShortcut = YES;
    self.shortcutRequestClaimed = NO;
    NSUInteger generation = ++self.generation;
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)((id)iconClass, activate, item, bundleID, nil);
    } @catch (__unused NSException *exception) {
        [self finish:POXOpenOutcomeFailed];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.generation && self.pendingShortcut &&
            !self.shortcutRequestClaimed) {
            [self finish:POXOpenOutcomeTimedOut];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == self.generation && self.pendingShortcut &&
            self.pendingCompletion) {
            [self finish:POXOpenOutcomeTimedOut];
        }
    });
}

- (void)checkVisibilityForGeneration:(NSUInteger)generation attempts:(NSUInteger)attempts {
    if (generation != self.generation || !self.pendingCompletion) {
        return;
    }
    POXWindow *window = (POXWindow *)[POXWindow sharedWindow];
    PullOverViewController *controller = window.controller;
    if (![POApplicationHelper isEnabled] || window.hidden ||
        window.rootViewController.view.alpha < 0.1) {
        [self finish:POXOpenOutcomeUnavailable];
        return;
    }
    if ([controller isExternallyHostedApplicationVisible:self.pendingBundleID]) {
        [self finish:POXOpenOutcomeHostedVisible];
        return;
    }
    if (attempts >= 40) {
        [self finish:POXOpenOutcomeTimedOut];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self checkVisibilityForGeneration:generation attempts:attempts + 1];
    });
}

- (void)startBundleID:(NSString *)bundleID completion:(POXOpenCompletion)completion {
    if (!completion) {
        return;
    }
    if (![NSThread isMainThread]) {
        NSString *copiedBundleID = [bundleID copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startBundleID:copiedBundleID completion:completion];
        });
        return;
    }
    if (self.pendingCompletion) {
        completion(POXOpenOutcomeBusy);
        return;
    }
    if (bundleID.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleID]) {
        completion(POXOpenOutcomeUnsupported);
        return;
    }
    POXWindow *window = (POXWindow *)[POXWindow sharedWindow];
    if (![POApplicationHelper isEnabled] || window.hidden ||
        window.rootViewController.view.alpha < 0.1 ||
        !window.controller ||
        ![window.controller beginExternalHostedApplication:bundleID]) {
        completion(POXOpenOutcomeUnavailable);
        return;
    }
    self.pendingBundleID = [bundleID copy];
    self.pendingCompletion = [completion copy];
    NSUInteger generation = ++self.generation;
    [self checkVisibilityForGeneration:generation attempts:0];
}

@end
