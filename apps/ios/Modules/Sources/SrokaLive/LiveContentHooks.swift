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
    }

    private let content: any ContentEngine
    private let policy: @Sendable () -> DownloadPolicy
    private let wipeGuard: WipeGuard
    private let onDeferred: @Sendable () -> Void
    private let state = Mutex(State())
    private let progress = ValueSubject<SyncDownloadProgress?>(nil)

    /// - Parameters:
    ///   - policy: the current download policy (read on every request).
    ///   - onDeferred: called when an automatic run was requested but cannot start now (app in background).
    public init(
        content: any ContentEngine,
        policy: @escaping @Sendable () -> DownloadPolicy,
        guard wipeGuard: WipeGuard,
        onDeferred: @escaping @Sendable () -> Void = {}
    ) {
        self.content = content
        self.policy = policy
        self.wipeGuard = wipeGuard
        self.onDeferred = onDeferred
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
        if policy() == .manual || wipeGuard.isWiping { return }
        let started = state.withLock { state -> Bool in
            guard state.foreground else { return false }
            if state.task != nil {
                state.rerun = true
                return true
            }
            startLocked(&state)
            return true
        }
        if !started { onDeferred() }
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
    /// in progress instead of starting a second one. Cancelling the calling task cancels the run.
    public func runAutomaticNow() async {
        if policy() == .manual || wipeGuard.isWiping { return }
        let task = state.withLock { state -> Task<Void, Never> in
            if let task = state.task { return task }
            return startLocked(&state)
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the running automatic run (backgrounding, policy change). Returns without waiting for it to stop.
    public func cancelAutomatic() {
        takeTask()?.cancel()
        progress.send(nil)
    }

    /// Cancels the running automatic run and returns once it has stopped (wipe: no download may write files after the
    /// content is removed).
    public func cancelAutomaticAndWait() async {
        let task = takeTask()
        task?.cancel()
        await task?.value
        progress.send(nil)
    }

    /// The download policy changed: stop the run under the old policy and, unless Manual, start one under the new.
    public func policyChanged(_ policy: DownloadPolicy) {
        cancelAutomatic()
        guard policy != .manual else { return }
        Task { await self.queueAutomaticDownloads() }
    }

    // MARK: Private

    private func takeTask() -> Task<Void, Never>? {
        state.withLock { state -> Task<Void, Never>? in
            let task = state.task
            state.task = nil
            state.rerun = false
            state.taskId += 1
            return task
        }
    }

    @discardableResult
    private func startLocked(_ state: inout State) -> Task<Void, Never> {
        state.taskId += 1
        let id = state.taskId
        let task = Task { [self] in
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
