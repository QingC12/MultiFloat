import Foundation
import CoreGraphics

public final class WindowManager {
    public private(set) var windows: [String: FloatingWindow] = [:]
    public private(set) var activeWindow: FloatingWindow?
    public let sceneManager: SceneManager
    public let layoutEngine: LayoutEngine
    public let stateMachine: StateMachine
    public let preferences: Preferences
    private let clock: MultiFloatClock

    public init(sceneManager: SceneManager,
                layoutEngine: LayoutEngine,
                stateMachine: StateMachine,
                preferences: Preferences,
                clock: MultiFloatClock) {
        self.sceneManager = sceneManager
        self.layoutEngine = layoutEngine
        self.stateMachine = stateMachine
        self.preferences = preferences
        self.clock = clock
    }

    public func requestOpen(bundleID: String) {
        guard preferences.enabled else { return }
        // TODO VERIFY: resolve Bundle ID to a system Scene request through Bridge.
        let sceneID = "pending-\(clock.monotonicTick())"
        let window = FloatingWindow(bundleID: bundleID, sceneIdentifier: sceneID)
        windows[sceneID] = window
        activeWindow = window
    }

    public func applyDrag(sceneIdentifier: String, translation: CGSize) {
        guard let window = windows[sceneIdentifier], window.state != .destroyed else { return }
        let position = layoutEngine.position(for: window)
        let updated = layoutEngine.applyingDrag(translation, to: position)
        window.frame = updated.frame
    }

    public func applyResize(sceneIdentifier: String, scale: CGFloat) {
        guard let window = windows[sceneIdentifier], window.state != .destroyed else { return }
        let position = layoutEngine.position(for: window)
        window.scale = layoutEngine.applyingScale(scale, to: position).scale
    }

    public func minimize(sceneIdentifier: String) {
        guard let window = windows[sceneIdentifier], let next = stateMachine.transition(window.state, event: .minimize(sceneIdentifier: sceneIdentifier)) else { return }
        window.state = next
    }

    public func fullscreen(sceneIdentifier: String) {
        guard let window = windows[sceneIdentifier], let next = stateMachine.transition(window.state, event: .fullscreen(sceneIdentifier: sceneIdentifier)) else { return }
        window.state = next
    }

    public func close(sceneIdentifier: String) {
        guard let window = windows[sceneIdentifier] else { return }
        // TODO VERIFY: restore vs keep-process vs destroy policy.
        window.state = .destroyed
        activeWindow = activeWindow?.sceneIdentifier == sceneIdentifier ? nil : activeWindow
    }
}
