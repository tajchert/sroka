import Synchronization

/// The fresh-install check (`LiveGraph.clearEarlierInstall`), tried at launch and again before every session reload
/// until it resolves once. While unresolved, the stored session is not read and the app counts as signed out.
final class InstallCheck: Sendable {
    private let resolved = Mutex(false)
    private let attempt: @Sendable () -> Bool

    init(_ attempt: @escaping @Sendable () -> Bool) {
        self.attempt = attempt
    }

    var isResolved: Bool { resolved.withLock { $0 } }

    /// Tries again unless resolved; true once resolved.
    @discardableResult func resolve() -> Bool {
        resolved.withLock { done in
            if !done { done = attempt() }
            return done
        }
    }
}
