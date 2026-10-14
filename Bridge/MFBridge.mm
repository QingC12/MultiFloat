// MFBridge.mm — 0.21.0 桥接口实现（第 22 轮）
//
// 包装 MFFloat.xm 的 MFFloatManager 现有能力。零新行为：
//   - host/sync/refresh 只是转发给 shared manager（与点应用名/拖拽松手完全同链路）；
//   - 关闭浮窗核心暂无入口，如实返回 -2；
//   - 事件用 NSNotification 外抛，Swift 侧 NotificationCenter 观察。
//
// 说明：MFFloatManager/MFFloatPanel 的完整 @interface 在 MFFloat.xm 内部，
// 这里按 ObjC 动态特性做最小声明（同名类运行期直接匹配），不复制实现细节。

#import "MFBridge.h"
#import <UIKit/UIKit.h>

// ---- 最小类声明（只列桥接用到的成员，避免与 .xm 重复维护） ----
@class MFFloatPanel;

@interface MFFloatManager : NSObject
@property (nonatomic, strong) MFFloatPanel *panel;
@property (nonatomic, strong) UIWindow *window;
+ (instancetype)shared;
- (void)hostBundleID:(NSString *)bundleID;
- (void)syncContentGeometry;
- (void)refreshAppList;
@end

// ---- 通知常量 ----
NSString * const MFBridgeHostDidCompleteNotification  = @"MFBridgeHostDidCompleteNotification";
NSString * const MFBridgeGeometryDidSyncNotification  = @"MFBridgeGeometryDidSyncNotification";
NSString * const MFBridgeBundleIDKey                  = @"bundleID";
NSString * const MFBridgeAcceptedKey                  = @"accepted";

// ---- 内部工具：主线程执行 + 通知 ----
static void MFBridgePostHostResult(NSString *bundleID, BOOL accepted) {
    [[NSNotificationCenter defaultCenter]
     postNotificationName:MFBridgeHostDidCompleteNotification
     object:nil
     userInfo:@{ MFBridgeBundleIDKey : bundleID ?: @"",
                 MFBridgeAcceptedKey : @(accepted) }];
}

// ---- 实现 ----
BOOL MFBridgeIsPanelReady(void) {
    BOOL ready = NO;
    @try {
        MFFloatManager *mgr = [MFFloatManager shared];
        ready = (mgr != nil && mgr.panel != nil && mgr.window != nil);
    } @catch (NSException *e) {
        ready = NO;
    }
    return ready;
}

int MFBridgeHostApp(NSString *bundleID) {
    if (bundleID.length == 0) return -3;
    MFFloatManager *mgr = nil;
    @try { mgr = [MFFloatManager shared]; } @catch (NSException *e) { mgr = nil; }
    if (mgr == nil) return -1;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [mgr hostBundleID:bundleID];
            MFBridgePostHostResult(bundleID, YES);
        } @catch (NSException *e) {
            // 私有链路兜底：异常不外抛，如实标记未受理
            MFBridgePostHostResult(bundleID, NO);
        }
    });
    return 0;
}

int MFBridgeSyncGeometry(void) {
    MFFloatManager *mgr = nil;
    @try { mgr = [MFFloatManager shared]; } @catch (NSException *e) { mgr = nil; }
    if (mgr == nil) return -1;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [mgr syncContentGeometry];
            [[NSNotificationCenter defaultCenter]
             postNotificationName:MFBridgeGeometryDidSyncNotification object:nil];
        } @catch (NSException *e) {
            // 静默兜底：几何同步失败不致命，核心守护会按住掰回
        }
    });
    return 0;
}

int MFBridgeRefreshAppList(void) {
    MFFloatManager *mgr = nil;
    @try { mgr = [MFFloatManager shared]; } @catch (NSException *e) { mgr = nil; }
    if (mgr == nil) return -1;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [mgr refreshAppList]; } @catch (NSException *e) { }
    });
    return 0;
}

int MFBridgeClosePanel(void) {
    // 【桩】核心暂无"关闭浮窗+停守护"入口；不造行为，如实返回 -2。
    return -2;
}
