// MFHostBridge.swift — 0.21.0 Swift 交互层骨架（第 22 轮）
//
// 定位：Swift 交互层（浮窗壳/手势/吸附/旋转/多浮窗）访问承载核心的唯一入口。
// 本轮只做两件事：
//   1. 把 MFBridge 的 C/ObjC 面封成 Swift 友好的类型（枚举错误码 + 回调）；
//   2. 验证 Theos + roothide + arm64e 的 Swift 编译链（本轮真正的最大未知风险）。
// 行为约束：本轮无人调用它 —— 现有 ObjC++ 链路一行不动，行为与 0.20.0 完全一致。

import Foundation

/// 桥接口错误码（与 MFBridge.h 一一对应）
public enum MFBridgeError: Int32, Error {
    case notReady     = -1   // 管理器/面板尚未就绪
    case notExposed   = -2   // 能力尚未暴露（如关闭浮窗）
    case invalidParam = -3   // 参数非法
}

/// Swift 侧生命周期事件（由 MFBridge 的 NSNotification 转发）
public enum MFHostEvent {
    case hostCompleted(bundleID: String, accepted: Bool)
    case geometrySynced
}

/// 承载核心的 Swift 门面。
/// 设计为 struct + 静态入口：核心是进程级单例，Swift 侧无需再包一层单例。
public struct MFHostBridge {

    /// 浮窗是否已创建并可用
    public static var isPanelReady: Bool {
        MFBridgeIsPanelReady()
    }

    /// 承载一个 App（与现有点应用名同链路）
    @discardableResult
    public static func host(_ bundleID: String) throws {
        let rc = MFBridgeHostApp(bundleID)
        guard rc == 0 else { throw MFBridgeError(rawValue: rc) ?? .notReady }
    }

    /// 手势松手后同步 scene.frame
    @discardableResult
    public static func syncGeometry() throws {
        let rc = MFBridgeSyncGeometry()
        guard rc == 0 else { throw MFBridgeError(rawValue: rc) ?? .notReady }
    }

    /// 刷新应用列表数据源
    @discardableResult
    public static func refreshAppList() throws {
        let rc = MFBridgeRefreshAppList()
        guard rc == 0 else { throw MFBridgeError(rawValue: rc) ?? .notReady }
    }

    /// 【桩】关闭浮窗 —— 核心暂无入口，调用会抛 notExposed
    @discardableResult
    public static func closePanel() throws {
        let rc = MFBridgeClosePanel()
        guard rc == 0 else { throw MFBridgeError(rawValue: rc) ?? .notExposed }
    }

    /// 订阅承载完成事件（几何同步事件后续交互层需要时再扩）。
    /// 返回的 token 需持有；不用时调用 nc.removeObserver(token)。
    public static func observeEvents(_ handler: @escaping (MFHostEvent) -> Void) -> NSObjectProtocol {
        let nc = NotificationCenter.default
        return nc.addObserver(
            forName: NSNotification.Name(MFBridgeHostDidCompleteNotification),
            object: nil, queue: .main
        ) { note in
            let id = (note.userInfo?[MFBridgeBundleIDKey] as? String) ?? ""
            let ok = (note.userInfo?[MFBridgeAcceptedKey] as? Bool) ?? false
            handler(.hostCompleted(bundleID: id, accepted: ok))
        }
    }
}
