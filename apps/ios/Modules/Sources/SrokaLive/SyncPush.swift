import Foundation
import Synchronization

/// What a silent push handler tells the system (`UIBackgroundFetchResult`).
public enum PushFetchResult: Sendable, Hashable {
    case newData
    case noData
    case failed
}

/// The outcome of the sync pass a push ran.
public enum PushSyncOutcome: Sendable, Hashable {
    /// The pass succeeded; `pulled` changes came down.
    case synced(pulled: Int)
    /// Nothing ran (signed out or the session expired).
    case skipped
    /// Network or server failure.
    case failed
    /// Cancelled (deadline, wipe).
    case cancelled
}

/// The silent "sync" push (D17, api.md "Push tokens"): `{"aps":{"content-available":1},"type":"sync"}`.
public enum SyncPushMessage {
    /// True for a message whose `type` is `"sync"`; any other type is ignored.
    public static func isSync(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["type"] as? String) == "sync"
    }
}

/// Runs the work of one silent "sync" push: the background refresh's guarded path (launch recovery, fresh stores,
/// database hold), a sync pass, then an automatic download batch under the policy, all within `deadline` (the system
/// allows about 30 s). Downloads that do not fit go to the `BGProcessingTask`.
public struct SyncPushHandler: Sendable {
    public struct Steps: Sendable {
        /// Finishes an interrupted wipe before any data is touched.
        public var ready: @Sendable () async -> Void
        /// Re-reads preferences and the session (another process may have written).
        public var reloadStores: @Sendable () -> Void
        public var isSignedIn: @Sendable () -> Bool
        /// Foreground: the normal debounced sync, which downloads on its own.
        public var requestSync: @Sendable () -> Void
        /// Runs the body with the database held (not suspended).
        public var holding: @Sendable (@escaping @Sendable () async -> Void) async -> Void
        public var sync: @Sendable () async -> PushSyncOutcome
        /// One automatic download run under the current policy (none when Manual); stops when cancelled.
        public var download: @Sendable () async -> Void
        public var needsBackgroundDownload: @Sendable () async -> Bool
        public var scheduleDownload: @Sendable () -> Void

        public init(
            ready: @escaping @Sendable () async -> Void,
            reloadStores: @escaping @Sendable () -> Void,
            isSignedIn: @escaping @Sendable () -> Bool,
            requestSync: @escaping @Sendable () -> Void,
            holding: @escaping @Sendable (@escaping @Sendable () async -> Void) async -> Void,
            sync: @escaping @Sendable () async -> PushSyncOutcome,
            download: @escaping @Sendable () async -> Void,
            needsBackgroundDownload: @escaping @Sendable () async -> Bool,
            scheduleDownload: @escaping @Sendable () -> Void
        ) {
            self.ready = ready
            self.reloadStores = reloadStores
            self.isSignedIn = isSignedIn
            self.requestSync = requestSync
            self.holding = holding
            self.sync = sync
            self.download = download
            self.needsBackgroundDownload = needsBackgroundDownload
            self.scheduleDownload = scheduleDownload
        }
    }

    /// Leaves a few seconds of the system's ~30 s for the bookkeeping after the work.
    public static let defaultDeadline: Duration = .seconds(25)

    private let steps: Steps
    private let deadline: Duration
    private let clock: any Clock<Duration>

    /// How much longer than `deadline` the whole handler may take (launch recovery, database hold, bookkeeping)
    /// before it returns regardless.
    public static let defaultGrace: Duration = .seconds(3)

    private let grace: Duration

    public init(
        steps: Steps, deadline: Duration = Self.defaultDeadline, grace: Duration = Self.defaultGrace,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.steps = steps
        self.deadline = deadline
        self.grace = grace
        self.clock = clock
    }

    /// Returns within `deadline + grace` whatever the steps do: past that, the work is cancelled and left to wind down
    /// (it keeps its database hold until it does), and the processing task is scheduled to pick up the rest.
    ///
    /// - Parameter foreground: the app is active; its own sync then downloads as usual.
    public func handle(foreground: Bool) async -> PushFetchResult {
        let steps = steps
        let result = await Self.value(within: deadline + grace, clock: clock) {
            await self.run(foreground: foreground)
        }
        guard let result else {
            liveLog.notice("Sync push: out of time; handing the rest to the processing task")
            steps.scheduleDownload()
            return .failed
        }
        return result
    }

    private func run(foreground: Bool) async -> PushFetchResult {
        await steps.ready()
        // Out of time already (`handle` returned): touch nothing.
        guard !Task.isCancelled else { return .failed }
        steps.reloadStores()
        guard steps.isSignedIn() else { return .noData }
        if foreground {
            steps.requestSync()
            return .newData
        }
        let outcome = Mutex<PushSyncOutcome>(.cancelled)
        let steps = steps
        await steps.holding { [deadline, clock] in
            await Self.run(within: deadline, clock: clock) {
                let result = await steps.sync()
                outcome.withLock { $0 = result }
                // A failed pass means no network or no server: the downloads would fail the same way.
                guard case .synced = result, !Task.isCancelled else { return }
                await steps.download()
            }
        }
        // Time ran out or the network dropped: the processing task finishes later.
        if await steps.needsBackgroundDownload() { steps.scheduleDownload() }
        return Self.result(outcome.withLock { $0 })
    }

    static func result(_ outcome: PushSyncOutcome) -> PushFetchResult {
        switch outcome {
        case .synced(let pulled): pulled > 0 ? .newData : .noData
        case .skipped: .noData
        case .failed, .cancelled: .failed
        }
    }

    /// `work`'s value, or nil once `limit` passes first. Never waits for `work` past `limit`: it is cancelled and left
    /// to finish on its own.
    static func value<T: Sendable>(
        within limit: Duration, clock: any Clock<Duration>, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let slot = Mutex<CheckedContinuation<T?, Never>?>(nil)
        let finish: @Sendable (T?) -> Void = { value in
            slot.withLock { continuation in
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        var tasks: [Task<Void, Never>] = []
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            slot.withLock { $0 = continuation }
            tasks.append(Task { finish(await work()) })
            tasks.append(
                Task {
                    try? await clock.sleep(for: limit)
                    finish(nil)
                })
        }
        for task in tasks { task.cancel() }
        return value
    }

    /// Runs `work` and cancels it once `deadline` passes; returns when `work` has returned.
    static func run(
        within deadline: Duration, clock: any Clock<Duration>, _ work: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await clock.sleep(for: deadline) }
            // Whichever ends first, the other is cancelled; the work stops at its next cancellation check.
            await group.next()
            group.cancelAll()
        }
    }
}
