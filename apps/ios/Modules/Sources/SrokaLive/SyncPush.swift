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
    /// The pass succeeded; `changed` when it committed anything (items, tags or deletions).
    case synced(changed: Bool)
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
/// database hold), a sync pass, then (in the background) an automatic download batch under the policy, all within
/// `deadline` of the callback (the system allows about 30 s). Downloads that do not fit go to the `BGProcessingTask`.
public struct SyncPushHandler: Sendable {
    public struct Steps: Sendable {
        /// Finishes an interrupted wipe before any data is touched.
        public var ready: @Sendable () async -> Void
        /// Re-reads preferences and the session (another process may have written).
        public var reloadStores: @Sendable () -> Void
        public var isSignedIn: @Sendable () -> Bool
        /// Takes a database hold (not suspended) and returns its release.
        public var hold: @Sendable () async -> @Sendable () -> Void
        public var sync: @Sendable () async -> PushSyncOutcome
        /// One automatic download run under the current policy (none when Manual); stops when cancelled. True when
        /// it downloaded anything.
        public var download: @Sendable () async -> Bool
        /// Automatic downloads are on and articles wait for one (reads the database).
        public var needsBackgroundDownload: @Sendable () async -> Bool
        /// Automatic downloads are on (signed in, policy not Manual); no database read.
        public var automaticDownloads: @Sendable () -> Bool
        public var scheduleDownload: @Sendable () -> Void

        public init(
            ready: @escaping @Sendable () async -> Void,
            reloadStores: @escaping @Sendable () -> Void,
            isSignedIn: @escaping @Sendable () -> Bool,
            hold: @escaping @Sendable () async -> @Sendable () -> Void,
            sync: @escaping @Sendable () async -> PushSyncOutcome,
            download: @escaping @Sendable () async -> Bool,
            needsBackgroundDownload: @escaping @Sendable () async -> Bool,
            automaticDownloads: @escaping @Sendable () -> Bool,
            scheduleDownload: @escaping @Sendable () -> Void
        ) {
            self.ready = ready
            self.reloadStores = reloadStores
            self.isSignedIn = isSignedIn
            self.hold = hold
            self.sync = sync
            self.download = download
            self.needsBackgroundDownload = needsBackgroundDownload
            self.automaticDownloads = automaticDownloads
            self.scheduleDownload = scheduleDownload
        }
    }

    /// Leaves a few seconds of the system's ~30 s for the bookkeeping after the work.
    public static let defaultDeadline: Duration = .seconds(25)

    /// How much longer than `deadline` the handler waits for cancelled work to wind down before it returns regardless.
    public static let defaultGrace: Duration = .seconds(3)

    private let steps: Steps
    private let deadline: Duration
    private let grace: Duration
    private let clock: any Clock<Duration>

    public init(
        steps: Steps, deadline: Duration = Self.defaultDeadline, grace: Duration = Self.defaultGrace,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.steps = steps
        self.deadline = deadline
        self.grace = grace
        self.clock = clock
    }

    /// The work is cancelled `deadline` after the call and the handler returns by `deadline + grace` whatever the
    /// steps do. Its own database hold is released before it returns, so the app can be suspended at once; work still
    /// winding down stops at its next database access.
    ///
    /// - Parameter foreground: the app is active; it syncs but leaves downloads to its own automatic run.
    public func handle(foreground: Bool) async -> PushFetchResult {
        let steps = steps
        let hold = HoldSlot()
        let result = await Self.value(within: deadline + grace, clock: clock) { [deadline, clock] in
            await Self.run(within: deadline, clock: clock, otherwise: .failed) {
                await self.run(foreground: foreground, hold: hold)
            }
        }
        hold.close()
        guard let result else {
            liveLog.notice("Sync push: out of time; handing the rest to the processing task")
            if steps.automaticDownloads() { steps.scheduleDownload() }
            return .failed
        }
        return result
    }

    private func run(foreground: Bool, hold: HoldSlot) async -> PushFetchResult {
        await steps.ready()
        // Out of time already: touch nothing.
        guard !Task.isCancelled else { return .failed }
        steps.reloadStores()
        guard steps.isSignedIn() else { return .noData }
        guard await hold.take(steps.hold) else { return .failed }
        defer { hold.close() }
        let outcome = await steps.sync()
        // A failed pass means no network or no server: the downloads would fail the same way.
        guard case .synced(let changed) = outcome else { return Self.result(outcome, downloaded: false) }
        guard !foreground else { return Self.result(outcome, downloaded: false) }
        let downloaded = Task.isCancelled ? false : await steps.download()
        // Cut off by the deadline (a database read may refuse to run now) or articles still wait: finish later.
        let remaining = Task.isCancelled ? steps.automaticDownloads() : await steps.needsBackgroundDownload()
        if remaining { steps.scheduleDownload() }
        return Self.result(.synced(changed: changed), downloaded: downloaded)
    }

    static func result(_ outcome: PushSyncOutcome, downloaded: Bool) -> PushFetchResult {
        switch outcome {
        case .synced(let changed): changed || downloaded ? .newData : .noData
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

    /// Runs `work`, cancels it once `deadline` passes and returns its value when it returns.
    static func run<T: Sendable>(
        within deadline: Duration, clock: any Clock<Duration>, otherwise fallback: T,
        _ work: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await clock.sleep(for: deadline)
                return nil
            }
            // Whichever ends first, the other is cancelled; the work stops at its next cancellation check.
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            return (await group.next() ?? nil) ?? fallback
        }
    }
}

/// The push's own database hold: released when the push ends, and refused once it has (late work never takes one).
final class HoldSlot: Sendable {
    private struct State {
        var closed = false
        var release: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// Takes the hold unless the push already ended; false when refused.
    func take(_ acquire: @Sendable () async -> @Sendable () -> Void) async -> Bool {
        if state.withLock({ $0.closed }) { return false }
        let release = await acquire()
        let kept = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.release = release
            return true
        }
        if !kept { release() }
        return kept
    }

    /// Releases the hold (once) and refuses later ones.
    func close() {
        let release = state.withLock { state -> (@Sendable () -> Void)? in
            state.closed = true
            defer { state.release = nil }
            return state.release
        }
        release?()
    }
}

/// Push passes in progress. While one runs, the sync engine's deferred-download hook does not submit the processing
/// task: the push downloads at once and submits it itself only when work remains.
final class PushPasses: Sendable {
    private let count = Mutex(0)

    var active: Bool { count.withLock { $0 > 0 } }

    func during<T: Sendable>(_ body: () async -> T) async -> T {
        count.withLock { $0 += 1 }
        defer { count.withLock { $0 -= 1 } }
        return await body()
    }
}
