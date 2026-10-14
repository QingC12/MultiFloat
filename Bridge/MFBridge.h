// MFBridge.h — 0.21.0 桥接口（第 22 轮）
//
// 用途：Swift 交互层 ↔ ObjC++ 承载核心（MFFloat.xm，冻结区）之间的唯一通道。
// 原则：
//   1. 只暴露"承载核心已有能力"的稳定 C 面，不暴露任何 SpringBoard 私有类型；
//   2. 本轮（0.21.0）只搭通道，不切换任何调用方 —— 现有 ObjC++ 链路行为不变；
//   3. 生命周期事件通过 NSNotification 回调（对 Swift 最友好，C 函数指针太硬）。
//
// 通知（Swift 侧用 NotificationCenter 观察）：
//   MFBridgeHostDidCompleteNotification   — 一次承载动作受理完成
//     userInfo: MFBridgeBundleIDKey(NSString) / MFBridgeAcceptedKey(NSNumber bool)
//   MFBridgeGeometryDidSyncNotification   — scene.frame 已按内容区同步
//
// 线程约定：所有函数可在任意线程调用；内部切主线程执行。
// 返回码（MFBridgeCode）：
//   0  受理成功
//  -1  管理器/面板尚未就绪（配置未加载或浮窗未创建）
//  -2  能力尚未暴露（如关闭浮窗，等核心提供入口后再接）
//  -3  参数非法（bundleID 为空）

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// ---- 通知名 ----
FOUNDATION_EXPORT NSString * const MFBridgeHostDidCompleteNotification;
FOUNDATION_EXPORT NSString * const MFBridgeGeometryDidSyncNotification;
// ---- userInfo 键 ----
FOUNDATION_EXPORT NSString * const MFBridgeBundleIDKey;
FOUNDATION_EXPORT NSString * const MFBridgeAcceptedKey;

// ---- 查询 ----
/// 浮窗是否已创建并可用（决定 Swift 侧能否发起承载）
BOOL MFBridgeIsPanelReady(void);

// ---- 动作 ----
/// 承载一个 App（S1~S7 全链）。等价于现有点应用名链路。
/// @return 0 受理；-1 未就绪；-3 bundleID 为空
int MFBridgeHostApp(NSString *bundleID);

/// 手势松手后把 scene.frame 同步成内容区尺寸（保持画面比例）
/// @return 0 受理；-1 未就绪
int MFBridgeSyncGeometry(void);

/// 刷新应用列表数据源
/// @return 0 受理；-1 未就绪
int MFBridgeRefreshAppList(void);

/// 【桩】关闭浮窗 + 停守护 —— 核心暂无对应入口，0.21.x+ 再接
/// @return 恒为 -2
int MFBridgeClosePanel(void);

NS_ASSUME_NONNULL_END
