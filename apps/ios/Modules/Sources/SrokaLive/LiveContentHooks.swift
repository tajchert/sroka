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
/// Automatic downloads after a sync run in one cancellable task at a time (a request while one runs reruns it once
/// it ends). They start only in the foreground and never during a wipe; in the background they are handed to the
/// `BGProcessingTask` through `onDeferred`, which runs them with `runAutomaticNow()`.
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

    /// Runs the automatic downloads now and returns when they end (background processing task). Cancelling the
    /// calling task cancels the run.
    public func runAutomaticNow() async {
        let policy = policy()
        if policy == .manual || wipeGuard.isWiping { return }
        _ = await runOnce(policy: policy)
    }

    /// Cancels the running automatic run (backgrounding, policy change, wipe).
    public func cancelAutomatic() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.task
            state.task = nil
            state.rerun = false
            state.taskId += 1
            return task
        }
        task?.cancel()
        progress.send(nil)
    }

    /// The download policy changed: stop the run under the old policy and, unless Manual, start one under the new.
    public func policyChanged(_ policy: DownloadPolicy) {
        cancelAutomatic()
        guard policy != .manual else { return }
        Task { await self.queueAutomaticDownloads() }
    }

    // MARK: Private

    private func startLocked(_ state: inout State) {
        state.taskId += 1
        let id = state.taskId
        state.task = Task { [self] in
            while true {
                let policy = policy()
                if policy == .manual || wipeGuard.isWiping || Task.isCancelled { break }
                _ = await runOnce(policy: policy)
                let again = self.state.withLock { state -> Bool in
                    guard state.taskId == id, state.rerun, !Task.isCancelled else { return false }
                    state.rerun = false
                    return true
                }
                if !again { break }
            }
            self.state.withLock { state in
                if state.taskId == id {
                    state.task = nil
                    state.rerun = false
                }
            }
        }
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
