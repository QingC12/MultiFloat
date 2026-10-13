import Foundation
import CoreGraphics

public enum WindowState {
    case normal
    case floating
    case mini
    case fullscreen
    case destroyed
}

public final class FloatingWindow {
    public let bundleID: String
    public let sceneIdentifier: String
    public var frame: CGRect
    public var state: WindowState
    public var scale: CGFloat
    public var orientation: Int
    public var isActive: Bool
    public var transitionGeneration: UInt64

    public init(bundleID: String,
                sceneIdentifier: String,
                frame: CGRect = .zero,
                state: WindowState = .normal,
                scale: CGFloat = 1.0,
                orientation: Int = 0) {
        self.bundleID = bundleID
        self.sceneIdentifier = sceneIdentifier
        self.frame = frame
        self.state = state
        self.scale = scale
        self.orientation = orientation
        self.isActive = false
        self.transitionGeneration = 0
    }
}
