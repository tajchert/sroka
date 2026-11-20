import Foundation
import SrokaContent
import SrokaCore
import SrokaSync
import Synchronization

/// What the content hooks need from the content engine. `LiveContentStore` conforms; tests use a stub.
public protocol ContentEngine: Sendable {
    func fetch(itemId: String) async -> DownloadResult
    func runAutomaticDownloads(policy: DownloadPolicy, progress: (@Sendable (DownloadProgress) -> Void)?) async
        -> DownloadRunResult
    func downloadAll(progress: (@Sendable (DownloadProgress) -> Void)?) async -> DownloadRunResult
    func eligibleCount() async -> Int
    func evict() async
    func deleteFiles(itemIds: [String])
    func removeAllContent() async
    func recoverInterrupted() async
}

extension LiveContentStore: ContentEngine {}

/// The sync engine's content port backed by `LiveContentStore`.
///
/// Automatic downloads run in one tracked, cancellable task at a time, whichever entry point starts them (a request
/// while one runs reruns it once it ends). Sync requests start them only in the foreground and never during a wipe; in
/// the background they are handed to the `BGProcessingTask` through `onDeferred`, which joins the same task with
/// `runAutomaticNow()`.
public final class LiveContentHooks: SyncContentHooks {
    private struct State {
        var task: Task<Void, Never>?
        var taskId = 0
        var rerun = false
        var foreground = false
        /// Cancelled runs that have not exited yet: the next run waits for them, and the wipe joins them.
        var retiring: [Int: Task<Void, Never>] = [:]
    }

    private let content: any ContentEngine
    private let policy: @Sendable () -> DownloadPolicy
    private let wipeGuard: WipeGuard
    private let onDeferred: @Sendable () -> Void
    private let joinTimeout: Duration
    private let state = Mutex(State())
    private let progress = ValueSubject<SyncDownloadProgress?>(nil)

    /// - Parameters:
    ///   - policy: the current download policy (read on every request).
    ///   - onDeferred: called when an automatic run was requested but cannot start now (app in background).
    ///   - joinTimeout: how long the wipe waits for cancelled runs (one can sit behind a slow reader download).
    public init(
        content: any ContentEngine,
        policy: @escaping @Sendable () -> DownloadPolicy,
        guard wipeGuard: WipeGuard,
        onDeferred: @escaping @Sendable () -> Void = {},
        joinTimeout: Duration = .seconds(5)
    ) {
        self.content = content
        self.policy = policy
        self.wipeGuard = wipeGuard
        self.onDeferred = onDeferred
        self.joinTimeout = joinTimeout
    }

    /// Foreground state from the scene; automatic runs start only while true.
    public func setForeground(_ foreground: Bool) {
        state.withLock { $0.foreground = foreground }
    }

    // MARK: SyncContentHooks

    public func deleteItemFiles(itemIds: [String]) async {
        content.deleteFiles(itemIds: itemIds)
    }

    public func queueAutomaticDownloads() async {
        if policy() == .manual { return }
        // The wipe raises its guard before it takes the runs to join, so checking it under this lock means a run
        // either starts before the wipe looks or not at all.
        let deferred = state.withLock { state -> Bool in
            if wipeGuard.isWiping { return false }
            guard state.foreground else { return true }
            if state.task != nil {
                state.rerun = true
            } else {
                startLocked(&state)
            }
            return false
        }
        if deferred { onDeferred() }
    }

    public func evict() async {
        await content.evict()
    }

    public func fetchDownloads() async -> SyncEvent {
        let progress = progress
        let result = await content.downloadAll { value in
            progress.send(SyncDownloadProgress(done: value.done, total: value.total, currentTitle: value.currentTitle))
        }
        progress.send(nil)
        if let failure = result.failure { return .fetchFailed(failure) }
        return .fetchCompleted(newlyDownloaded: result.downloaded)
    }

    public func downloadItemNow(itemId: String) async {
        _ = await content.fetch(itemId: itemId)
    }

    public func observeDownloadProgress() -> AsyncStream<SyncDownloadProgress?> { progress.stream() }

    // MARK: App lifecycle

    /// Runs the automatic downloads now and returns when they end (background processing task). Joins a run already
    /// in progress instead of starting a second one. Cancelling the calling task cancels the run, unless the app is in
    /// the foreground again by then (the run then belongs to the foreground and may have a rerun queued).
    public func runAutomaticNow() async {
        if policy() == .manual { return }
        let joined = state.withLock { state -> Task<Void, Never>? in
            if wipeGuard.isWiping { return nil }
            if let task = state.task { return task }
            return startLocked(&state)
        }
        guard let task = joined else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // Retired under the lock, so a foreground request arriving before the run exits starts a new one instead
            // of setting a rerun the cancelled run would drop.
            let cancel = state.withLock { state -> Bool in
                guard !state.foreground else { return false }
                if state.task == task {
                    state.retiring[state.taskId] = task
                    state.task = nil
                    state.rerun = false
                    state.taskId += 1
                }
                return true
            }
            if cancel { task.cancel() }
        }
    }

    /// Cancels the running automatic run (backgrounding, policy change). Returns without waiting for it to stop; the
    /// next run starts only after it has.
    public func cancelAutomatic() {
        takeTasks().current?.cancel()
        progress.send(nil)
    }

    /// Cancels the running automatic run and returns once it and every earlier cancelled run have stopped, or after
    /// `joinTimeout` (wipe). A run still queued behind a reader download then finds the content generation changed
    /// and writes nothing; the wait only keeps the common case tidy and must not hold sign-out hostage.
    public func cancelAutomaticAndWait() async {
        let (current, retiring) = takeTasks()
        current?.cancel()
        let all = (current.map { [$0] } ?? []) + retiring
        if !all.isEmpty {
            let joined = await Self.join(all, timeout: joinTimeout)
            if !joined { liveLog.notice("Wipe: automatic downloads still stopping; continuing") }
        }
        progress.send(nil)
    }

    /// The download policy changed: stop the run under the old policy and, unless Manual, start one under the new.
    public func policyChanged(_ policy: DownloadPolicy) {
        cancelAutomatic()
        guard policy != .manual else { return }
        Task { await self.queueAutomaticDownloads() }
    }

    // MARK: Private

    /// True when every task ended within `timeout`. The tasks keep running either way.
    private static func join(_ tasks: [Task<Void, Never>], timeout: Duration) async -> Bool {
        let outcome = Mutex<Bool?>(nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: @Sendable (Bool) -> Void = { joined in
                let first = outcome.withLock { value -> Bool in
                    guard value == nil else { return false }
                    value = joined
                    return true
                }
                if first { continuation.resume(returning: joined) }
            }
            Task {
                for task in tasks { await task.value }
                finish(true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish(false)
            }
        }
    }

    /// Detaches the current run (kept in `retiring` until it exits) and returns it with the earlier retiring runs.
    private func takeTasks() -> (current: Task<Void, Never>?, retiring: [Task<Void, Never>]) {
        state.withLock { state in
            let retiring = Array(state.retiring.values)
            let current = state.task
            if let current { state.retiring[state.taskId] = current }
            state.task = nil
            state.rerun = false
            state.taskId += 1
            return (current, retiring)
        }
    }

    @discardableResult
    private func startLocked(_ state: inout State) -> Task<Void, Never> {
        state.taskId += 1
        let id = state.taskId
        let previous = Array(state.retiring.values)
        let task = Task { [self] in
            // Never overlap a cancelled run that is still winding down.
            for earlier in previous { await earlier.value }
            while true {
                let policy = policy()
                let proceed = !(policy == .manual || wipeGuard.isWiping || Task.isCancelled)
                if proceed { _ = await runOnce(policy: policy) }
                // One step decides between rerunning and retiring, so a request arriving now is never lost.
                let again = self.state.withLock { state -> Bool in
                    guard state.taskId == id else { return false }
                    if proceed, state.rerun, !Task.isCancelled {
                        state.rerun = false
                        return true
                    }
                    state.task = nil
                    state.rerun = false
                    return false
                }
                if !again { break }
            }
            self.state.withLock { _ = $0.retiring.removeValue(forKey: id) }
        }
        state.task = task
        return task
    }

    private func runOnce(policy: DownloadPolicy) async -> DownloadRunResult {
        let progress = progress
        let result = await content.runAutomaticDownloads(policy: policy) { value in
            progress.send(SyncDownloadProgress(done: value.done, total: value.total, currentTitle: value.currentTitle))
        }
        progress.send(nil)
        return result
    }
}
