import Foundation

public final class AppRegistry {
    public private(set) var selectedBundleIDs: Set<String> = []
    public private(set) var excludedBundleIDs: Set<String> = []

    public init() {}

    public func allows(_ bundleID: String) -> Bool {
        // TODO VERIFY: connect to project-owned Preferences only.
        return !bundleID.isEmpty && !excludedBundleIDs.contains(bundleID)
    }

    public func select(_ bundleID: String) {
        selectedBundleIDs.insert(bundleID)
    }

    public func exclude(_ bundleID: String) {
        excludedBundleIDs.insert(bundleID)
    }
}
