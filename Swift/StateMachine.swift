import Foundation

public final class StateMachine {
    public init() {}

    public func transition(_ current: WindowState, event: MultiFloatEvent) -> WindowState? {
        // TODO VERIFY: policy-specific transitions require target behavior validation.
        switch (current, event) {
        case (.normal, .open), (.normal, .split):
            return .floating
        case (.floating, .minimize):
            return .mini
        case (.floating, .fullscreen), (.mini, .fullscreen):
            return .fullscreen
        case (.floating, .close), (.mini, .close), (.fullscreen, .close):
            return .destroyed
        default:
            return nil
        }
    }
}
