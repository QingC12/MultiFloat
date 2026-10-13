import Foundation

public final class SceneManager {
    private let adapter: MultiFloatSceneAdapter?
    private var sceneHandles: [String: String] = [:]

    public init(adapter: MultiFloatSceneAdapter? = nil) {
        self.adapter = adapter
    }

    public func createScene(for request: SceneRequest,
                            completion: @escaping (SceneResult) -> Void) {
        guard let adapter else {
            completion(.rejected("scene adapter unavailable"))
            return
        }
        adapter.createScene(for: request, completion: completion)
    }

    public func reuseScene(_ record: FloatingWindow,
                           completion: @escaping (SceneResult) -> Void) {
        guard let adapter else {
            completion(.rejected("scene adapter unavailable"))
            return
        }
        adapter.reuseScene(record, completion: completion)
    }

    public func activateScene(_ record: FloatingWindow,
                              completion: @escaping (SceneResult) -> Void) {
        adapter?.activateScene(record, completion: completion)
            ?? completion(.rejected("scene adapter unavailable"))
    }

    public func deactivateScene(_ record: FloatingWindow,
                                reason: TransitionReason,
                                completion: @escaping (SceneResult) -> Void) {
        adapter?.deactivateScene(record, reason: reason, completion: completion)
            ?? completion(.rejected("scene adapter unavailable"))
    }

    public func destroyScene(_ record: FloatingWindow,
                             reason: TransitionReason,
                             completion: @escaping (SceneResult) -> Void) {
        adapter?.destroyScene(record, reason: reason, completion: completion)
            ?? completion(.rejected("scene adapter unavailable"))
    }

    public func recordSceneHandle(_ handle: String, for sceneIdentifier: String) {
        // TODO VERIFY: replace project metadata with the verified opaque handle wrapper.
        sceneHandles[sceneIdentifier] = handle
    }
}
