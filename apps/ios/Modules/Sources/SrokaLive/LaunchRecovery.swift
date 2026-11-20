import Foundation
import Synchronization

/// Work that must finish, once per process, before the account is used: finishing a wipe a dead process left in
/// progress (`LocalDataWiper.finishInterruptedWipe()`).
///
/// Every path that uses the account awaits `ready()` first: the session reaching `AppModel`, scene activation, the
/// backgrounding flush and both background tasks. The first caller starts the work; later and concurrent callers
/// wait for that same run.
public final class LaunchRecovery: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let work: @Sendable () async -> Void

    public init(_ work: @escaping @Sendable () async -> Void) {
        self.work = work
    }

    /// Nothing to recover (fakes, previews).
    public static var none: LaunchRecovery { LaunchRecovery {} }

    public func ready() async {
        let work = work
        let run = task.withLock { task in
            if let task { return task }
            let started = Task { await work() }
            task = started
            return started
        }
        await run.value
    }
}
