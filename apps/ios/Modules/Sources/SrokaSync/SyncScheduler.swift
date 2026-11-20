import Foundation
import SrokaCore
import Synchronization

/// The live `SyncController`: debounces sync requests and runs background passes with retries, in
/// process (iOS has no WorkManager). Android: `SyncControllerImpl` + `WorkScheduler` + `SyncWorker`.
///
/// - `requestSync()` waits `debounce` (2 s) after the last call, then enqueues a background sync with
///   WorkManager's `APPEND_OR_REPLACE` semantics: a sync that is waiting (for a network or in backoff)
///   picks up new ops itself, so nothing is added; a running one gets one follow-up pass.
/// - A background sync waits for a network (Android `CONNECTED` constraint), then retries network and
///   server failures with exponential backoff from `baseBackoff` (30 s), up to `maxRetries` (5) retries
///   per trigger (Android `runAttemptCount < 5`). Auth failures and skipped passes are not retried.
/// - `fetchNewArticles()` runs one pass at once (any network, no retry), then the content hooks'
///   download step; its result arrives as a `SyncEvent`.
public final class SyncScheduler: SyncController, Sendable {
    private let engine: SyncEngine
    private let session: any SyncSession
    private let hooks: any SyncContentHooks
    private let network: any NetworkStatus
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let baseBackoff: Duration
    private let maxRetries: Int

    private enum WorkerPhase { case idle, waiting, running }

    private struct State {
        var debounceTask: Task<Void, Never>?
        var debounceGeneration = 0
        var worker: Task<Void, Never>?
        var workerId = 0
        var phase = WorkerPhase.idle
        var rerun = false
        var fetchTask: Task<Void, Never>?
        var fetchGeneration = 0
    }

    private let state = Mutex(State())
    let eventSubject = EventSubject<SyncEvent>()
    /// Every pass outcome this scheduler ran (tests).
    let passOutcomes = EventSubject<SyncOutcome>()

    public init(
        engine: SyncEngine,
        session: any SyncSession,
        hooks: any SyncContentHooks = NoContentHooks(),
        network: any NetworkStatus = AlwaysOnline(),
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .seconds(2),
        baseBackoff: Duration = .seconds(30),
        maxRetries: Int = 5
    ) {
        self.engine = engine
        self.session = session
        self.hooks = hooks
        self.network = network
        self.clock = clock
        self.debounce = debounce
        self.baseBackoff = baseBackoff
        self.maxRetries = maxRetries
    }

    /// One-shot results of user fetches (hot, not replayed).
    public var events: AsyncStream<SyncEvent> { eventSubject.stream() }

    /// True while a pass runs, current value first.
    public func observeRunning() -> AsyncStream<Bool> { engine.observeRunning() }

    // MARK: SyncController

    public func requestSync() {
        state.withLock { state in
            state.debounceTask?.cancel()
            state.debounceGeneration += 1
            let generation = state.debounceGeneration
            state.debounceTask = Task { [self] in
                do {
                    try await clock.sleep(for: debounce)
                } catch {
                    return
                }
                // A newer request, a fetch or a wipe may have superseded this one after the sleep returned.
                self.state.withLock { state in
                    guard state.debounceGeneration == generation else { return }
                    state.debounceTask = nil
                    enqueueSync(&state)
                }
            }
        }
    }

    public func fetchNewArticles() {
        state.withLock { state in
            state.debounceTask?.cancel()
            state.debounceTask = nil
            state.debounceGeneration += 1
            // REPLACE: a newer fetch supersedes a running one.
            state.fetchTask?.cancel()
            state.fetchGeneration += 1
            let generation = state.fetchGeneration
            state.fetchTask = Task { [self] in await runFetch(generation: generation) }
        }
    }

    public func downloadItemNow(itemId: String) {
        Task { [hooks] in await hooks.downloadItemNow(itemId: itemId) }
    }

    // MARK: Direct entry points

    /// One background-style pass now, no debounce and no retries (e.g. the app returning to the
    /// foreground after a long time). Cancelling the caller cancels the pass.
    public func syncNow() async -> SyncOutcome {
        await runPass(user: false)
    }

    /// `BGAppRefreshTask` handler: one pass; true when it succeeded (or there was nothing to do).
    /// Cancel the calling task from the task's expiration handler.
    public func handleBackgroundRefresh() async -> Bool {
        switch await runPass(user: false) {
        case .success, .skipped: true
        case .failure, .cancelled: false
        }
    }

    /// Sign-out / account deletion: drops the debounced request, the background worker and a running
    /// fetch, then runs `body` inside the engine (never interleaved with a pass).
    public func wipe(_ body: @Sendable () async throws -> Void) async rethrows {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            let tasks = [state.debounceTask, state.worker, state.fetchTask].compactMap { $0 }
            state.debounceTask = nil
            state.debounceGeneration += 1
            state.worker = nil
            state.workerId += 1
            state.phase = .idle
            state.rerun = false
            state.fetchTask = nil
            state.fetchGeneration += 1
            return tasks
        }
        for task in tasks { task.cancel() }
        try await engine.wipe(body)
    }

    // MARK: Background worker

    /// Android `WorkScheduler.enqueueSync`.
    func enqueueSync() {
        state.withLock { enqueueSync(&$0) }
    }

    private func enqueueSync(_ state: inout State) {
        switch state.phase {
        case .waiting:
            return
        case .running:
            state.rerun = true
        case .idle:
            state.phase = .waiting
            state.workerId += 1
            let id = state.workerId
            state.worker = Task { [self] in await workerLoop(id: id) }
        }
    }

    private func workerLoop(id: Int) async {
        while true {
            await runWithRetries(id: id)
            let again = state.withLock { state -> Bool in
                guard state.workerId == id else { return false }
                if state.rerun, !Task.isCancelled {
                    state.rerun = false
                    state.phase = .waiting
                    return true
                }
                state.phase = .idle
                state.rerun = false
                state.worker = nil
                return false
            }
            if !again { return }
        }
    }

    private func runWithRetries(id: Int) async {
        var retries = 0
        while true {
            await waitForNetwork()
            if Task.isCancelled { return }
            setPhase(.running, id: id)
            let outcome = await runPass(user: false)
            guard outcome.isRetryable, retries < maxRetries, !Task.isCancelled else { return }
            setPhase(.waiting, id: id)
            let delay = baseBackoff * (1 << retries)
            retries += 1
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func setPhase(_ phase: WorkerPhase, id: Int) {
        state.withLock { state in
            if state.workerId == id { state.phase = phase }
        }
    }

    private func waitForNetwork() async {
        for await online in network.observeOnline() where online { return }
    }

    // MARK: Passes

    /// A replaced fetch (REPLACE) or a wipe bumps `fetchGeneration` and cancels this task; a
    /// superseded fetch reports nothing.
    private func runFetch(generation: Int) async {
        switch await session.currentState() {
        case .signedOut:
            return
        case .expired:
            send(.fetchFailed(.auth), generation)
            return
        case .signedIn:
            break
        }
        switch await runPass(user: true) {
        case .success:
            if Task.isCancelled { return }
            send(await hooks.fetchDownloads(), generation)
        case .failure(let kind):
            send(.fetchFailed(kind), generation)
        case .skipped:
            if case .expired = await session.currentState() { send(.fetchFailed(.auth), generation) }
        case .cancelled:
            break
        }
    }

    /// Publishes under the lock that replacement and wipe take, so a superseded fetch never publishes.
    private func send(_ event: SyncEvent, _ generation: Int) {
        state.withLock { state in
            if state.fetchGeneration == generation { eventSubject.send(event) }
        }
    }

    /// One engine pass plus the post-sync maintenance of `SyncWorker`: automatic downloads (background
    /// passes only; a user fetch downloads in its own step) and eviction.
    private func runPass(user: Bool) async -> SyncOutcome {
        let outcome = await engine.sync()
        if case .success = outcome {
            if !user { await hooks.queueAutomaticDownloads() }
            await hooks.evict()
        }
        passOutcomes.send(outcome)
        return outcome
    }
}
