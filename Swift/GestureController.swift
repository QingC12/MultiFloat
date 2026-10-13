import Foundation
import CoreGraphics

public enum GestureEvent {
    case edgeOpen(bundleID: String)
    case pan(sceneIdentifier: String, translation: CGSize)
    case pinch(sceneIdentifier: String, scale: CGFloat)
    case longPress(sceneIdentifier: String)
}

public final class GestureController {
    private weak var windowManager: WindowManager?

    public init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    public func handle(_ event: GestureEvent) {
        // TODO VERIFY: connect UIKit/SpringBoard gesture recognizers through Bridge.
        switch event {
        case .edgeOpen(let bundleID):
            windowManager?.requestOpen(bundleID: bundleID)
        case .pan(let sceneID, let translation):
            windowManager?.applyDrag(sceneIdentifier: sceneID, translation: translation)
        case .pinch(let sceneID, let scale):
            windowManager?.applyResize(sceneIdentifier: sceneID, scale: scale)
        case .longPress:
            // TODO VERIFY: map long press to the project policy/state machine.
            break
        }
    }
}
