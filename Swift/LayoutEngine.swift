import Foundation
import CoreGraphics

public struct LayoutPosition {
    public var frame: CGRect
    public var scale: CGFloat
    public var orientation: Int

    public init(frame: CGRect = .zero, scale: CGFloat = 1.0, orientation: Int = 0) {
        self.frame = frame
        self.scale = scale
        self.orientation = orientation
    }
}

public final class LayoutEngine {
    public init() {}

    public func position(for window: FloatingWindow) -> LayoutPosition {
        // TODO VERIFY: implement safe-area and private display configuration integration.
        return LayoutPosition(frame: window.frame, scale: window.scale, orientation: window.orientation)
    }

    public func applyingDrag(_ translation: CGSize, to position: LayoutPosition) -> LayoutPosition {
        var result = position
        result.frame.origin.x += translation.width
        result.frame.origin.y += translation.height
        return result
    }

    public func applyingScale(_ scale: CGFloat, to position: LayoutPosition) -> LayoutPosition {
        var result = position
        result.scale = scale
        return result
    }
}
