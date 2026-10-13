import Foundation

public final class Preferences {
    public var enabled: Bool = true
    public var singleWindowMode: Bool = true
    public var schedulerMode: Bool = true
    public var maxWindowCount: Int = 3
    public var persistLayout: Bool = true
    public var initialScale: Double = 0.62
    public var allowMiniMode: Bool = true
    public var allowResidentMode: Bool = false

    public init() {}

    public func reload() {
        // TODO VERIFY: bind to com.example.multifloat Preferences.plist.
    }
}
