#import <Foundation/Foundation.h>

static NSString * const POCameraGrantDomain = @"com.mlgm.pulloverx";
static NSString * const POCameraGrantBundleIdentifierKey = @"__cameraForegroundGrantBundleId";
static NSString * const POCameraGrantStateChangedNotification = @"com.mlgm.pulloverx.camera-state-changed";
static NSString *POCameraCachedGrantBundleIdentifier;
static CFAbsoluteTime POCameraGrantCacheTimestamp;
static BOOL POCameraGrantCacheValid;

NS_INLINE void POCameraGrantStateInvalidateCaches(void) {
    @synchronized (POCameraGrantDomain) {
        POCameraGrantCacheValid = NO;
    }
}

NS_INLINE void POSetCameraForegroundGrantBundleIdentifier(NSString *bundleIdentifier) {
    @synchronized (POCameraGrantDomain) {
        CFStringRef domain = (__bridge CFStringRef)POCameraGrantDomain;
        CFStringRef key = (__bridge CFStringRef)POCameraGrantBundleIdentifierKey;
        CFPropertyListRef value = bundleIdentifier.length > 0
            ? (__bridge CFPropertyListRef)bundleIdentifier
            : NULL;
        CFPreferencesSetAppValue(key, value, domain);
        CFPreferencesAppSynchronize(domain);
        POCameraCachedGrantBundleIdentifier = [bundleIdentifier copy];
        POCameraGrantCacheTimestamp = CFAbsoluteTimeGetCurrent();
        POCameraGrantCacheValid = YES;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)POCameraGrantStateChangedNotification,
                                         NULL,
                                         NULL,
                                         true);
}

/// 【0.4.0】通道②：NSUserDefaults + 套件名。
/// 实证依据：TrollOpen 的相机 dylib（注入 mediaserverd，root）就是用
/// `[[NSUserDefaults alloc] initWithSuiteName:...]` 读 SpringBoard 侧写的偏好 ——
/// 说明这条通道在相机守护进程里确实通。CFPreferences 在 root 守护进程里会因为
/// "当前用户域"不同而读不到 mobile 的数据，NSUserDefaults 的套件路径解析不一样。
NS_INLINE NSString *POCameraGrantBundleIdentifierFromUserDefaultsSuite(void) {
    NSString *bundleIdentifier = nil;
    @try {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:POCameraGrantDomain];
        id value = [defaults objectForKey:POCameraGrantBundleIdentifierKey];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            bundleIdentifier = (NSString *)value;
        }
    } @catch (NSException *exception) {
        bundleIdentifier = nil;
    }
    return bundleIdentifier;
}

/// 【0.4.0】通道④（最终兜底）：直接读 mobile 用户的偏好 plist。
/// 写入方 SpringBoard 以 **mobile** 运行，读方相机守护进程以 **root** 运行，
/// 前三条通道全部失效时，root 直接 open
/// `/var/mobile/Library/Preferences/<domain>.plist` 一定成功。不缓存（只有前面的通道
/// 都失败才会走到这里）。
#define POCameraGrantMobilePreferencesPath "/var/mobile/Library/Preferences/com.mlgm.pulloverx.plist"

NS_INLINE NSString *POCameraGrantBundleIdentifierFromMobilePreferences(void) {
    NSDictionary *preferences = nil;
    @try {
        preferences = [NSDictionary dictionaryWithContentsOfFile:@POCameraGrantMobilePreferencesPath];
    } @catch (NSException *exception) {
        preferences = nil;
    }
    if (![preferences isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id value = preferences[POCameraGrantBundleIdentifierKey];
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

/// 读"当前被浮窗承载、应当享有前台相机权"的 App。
/// 【0.4.0 四通道】① 本进程用户域 → ② NSUserDefaults 套件 → ③ 任意用户/任意主机域
///                  → ④ 直读 mobile 偏好 plist。
/// 上游只有①，在相机守护进程（root）里读不到 SpringBoard（mobile）写的值，
/// 这是"浮窗里的 App 用不了相机"的一大块原因。
NS_INLINE NSString *POCameraForegroundGrantBundleIdentifier(void) {
    @synchronized (POCameraGrantDomain) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (POCameraGrantCacheValid && now - POCameraGrantCacheTimestamp < 0.25) {
            return POCameraCachedGrantBundleIdentifier;
        }

        CFStringRef domain = (__bridge CFStringRef)POCameraGrantDomain;
        CFStringRef key = (__bridge CFStringRef)POCameraGrantBundleIdentifierKey;
        NSString *bundleIdentifier = nil;

        // ① 本进程当前用户域（SpringBoard 侧写入后，同域进程读到的就是这一份）
        CFPreferencesAppSynchronize(domain);
        CFPropertyListRef value = CFPreferencesCopyAppValue(key, domain);
        if (value) {
            if (CFGetTypeID(value) == CFStringGetTypeID()) {
                bundleIdentifier = [(__bridge NSString *)value copy];
            }
            CFRelease(value);
        }

        // ② NSUserDefaults 套件（TrollOpen 同款；守护进程里这条最常命中）
        if (bundleIdentifier.length == 0) {
            bundleIdentifier = POCameraGrantBundleIdentifierFromUserDefaultsSuite();
        }

        // ③ 任意用户 / 任意主机域
        if (bundleIdentifier.length == 0) {
            value = CFPreferencesCopyValue(key, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
            if (value) {
                if (CFGetTypeID(value) == CFStringGetTypeID()) {
                    bundleIdentifier = [(__bridge NSString *)value copy];
                }
                CFRelease(value);
            }
        }

        // ④ 直读 mobile 偏好文件（跨用户域的最终兜底）
        if (bundleIdentifier.length == 0) {
            bundleIdentifier = POCameraGrantBundleIdentifierFromMobilePreferences();
        }

        POCameraCachedGrantBundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : nil;
        POCameraGrantCacheTimestamp = now;
        POCameraGrantCacheValid = YES;
        return POCameraCachedGrantBundleIdentifier;
    }
}
