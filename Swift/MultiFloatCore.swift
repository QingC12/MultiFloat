import Foundation
import CoreGraphics

public protocol MultiFloatEventSink: AnyObject {
    func handle(_ event: MultiFloatEvent)
}

public protocol MultiFloatSceneAdapter: AnyObject {
    func createScene(for request: SceneRequest, completion: @escaping (SceneResult) -> Void)
    func reuseScene(_ record: FloatingWindow, completion: @escaping (SceneResult) -> Void)
    func activateScene(_ record: FloatingWindow, completion: @escaping (SceneResult) -> Void)
    func deactivateScene(_ record: FloatingWindow, reason: TransitionReason, completion: @escaping (SceneResult) -> Void)
    func destroyScene(_ record: FloatingWindow, reason: TransitionReason, completion: @escaping (SceneResult) -> Void)
}

public protocol MultiFloatClock {
    func monotonicTick() -> UInt64
}

public struct SystemClock: MultiFloatClock {
    public init() {}
    public func monotonicTick() -> UInt64 { 0 }
}

public enum MultiFloatEvent {
    case open(bundleID: String)
    case split(bundleID: String)
    case drag(sceneIdentifier: String, translation: CGSize)
    case resize(sceneIdentifier: String, scale: CGFloat)
    case minimize(sceneIdentifier: String)
    case fullscreen(sceneIdentifier: String)
    case close(sceneIdentifier: String)
}

public enum SceneResult {
    case accepted
    case pending
    case rejected(String)
    case failed(String)
}

public enum TransitionReason {
    case userAction
    case policy
    case system
    case stale
}

public struct SceneRequest {
    public let bundleID: String
    public let preferredSceneIdentifier: String?

    public init(bundleID: String, preferredSceneIdentifier: String? = nil) {
        self.bundleID = bundleID
        self.preferredSceneIdentifier = preferredSceneIdentifier
    }
}

public final class MultiFloatCore: MultiFloatEventSink {
    public let windowManager: WindowManager
    public let sceneManager: SceneManager
    public let layoutEngine: LayoutEngine
    public let gestureController: GestureController
    public let stateMachine: StateMachine
    public let appRegistry: AppRegistry
    public let preferences: Preferences

    public init(sceneAdapter: MultiFloatSceneAdapter? = nil,
                clock: MultiFloatClock = SystemClock()) {
        self.preferences = Preferences()
        self.appRegistry = AppRegistry()
        self.layoutEngine = LayoutEngine()
        self.stateMachine = StateMachine()
        self.sceneManager = SceneManager(adapter: sceneAdapter)
        self.windowManager = WindowManager(sceneManager: self.sceneManager,
                                           layoutEngine: self.layoutEngine,
                                           stateMachine: self.stateMachine,
                                           preferences: self.preferences,
                                           clock: clock)
        self.gestureController = GestureController(windowManager: self.windowManager)
    }

    public func handle(_ event: MultiFloatEvent) {
        // TODO VERIFY: connect normalized bridge events to the policy engine.
        switch event {
        case .open(let bundleID), .split(let bundleID):
            windowManager.requestOpen(bundleID: bundleID)
        case .drag(let sceneID, let translation):
            windowManager.applyDrag(sceneIdentifier: sceneID, translation: translation)
        case .resize(let sceneID, let scale):
            windowManager.applyResize(sceneIdentifier: sceneID, scale: scale)
        case .minimize(let sceneID):
            windowManager.minimize(sceneIdentifier: sceneID)
        case .fullscreen(let sceneID):
            windowManager.fullscreen(sceneIdentifier: sceneID)
        case .close(let sceneID):
            windowManager.close(sceneIdentifier: sceneID)
        }
    }
}
