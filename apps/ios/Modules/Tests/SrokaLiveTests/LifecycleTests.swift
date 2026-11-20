import Foundation
import SrokaContent
import SrokaCore
import SrokaDatabase
import SrokaSession
import SrokaSync
import Synchronization
import Testing

@testable import SrokaLive

/// A gate that suspends callers of `wait()` until `open()`.
final class Latch: Sendable {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    func wait() async {
        await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
    }
    var waiting: Int { waiters.withLock { $0.count } }
    func open() {
        let all = waiters.withLock { waiters in
            defer { waiters = [] }
            return waiters
        }
        for waiter in all { waiter.resume() }
    }
}

/// Records the order of named steps from any thread.
final class StepLog: Sendable {
    private let steps = Mutex<[String]>([])
    func add(_ step: String) { steps.withLock { $0.append(step) } }
    var all: [String] { steps.withLock { $0 } }
}

private func actions(
    log: StepLog, signedIn: Bool, pendingOps: Int = 0, needsDownload: Bool = false,
    notify: @escaping @Sendable () async -> Void = {}
) -> LifecycleActions {
    LifecycleActions(
        enterForeground: { log.add("foreground") },
        enterBackground: { log.add("background") },
        holdDatabase: {
            log.add("hold")
            return { log.add("release") }
        },
        reloadStores: { log.add("reload") },
        notifyExternalChanges: {
            log.add("notify")
            await notify()
        },
        isSignedIn: { signedIn },
        recoverInterrupted: { log.add("recover") },
        resumePendingUploads: { log.add("uploads") },
        resumeImport: { log.add("import") },
        requestSync: { log.add("requestSync") },
        pendingOpCount: { pendingOps },
        syncNow: { log.add("syncNow") },
        cancelAutomaticDownloads: { log.add("cancelDownloads") },
        setDownloadsForeground: { log.add($0 ? "downloadsForeground" : "downloadsBackground") },
        scheduleRefresh: { log.add("scheduleRefresh") },
        needsBackgroundDownload: { needsDownload },
        scheduleDownload: { log.add("scheduleDownload") },
        expireBackground: { log.add("expire") })
}

@MainActor
struct AppLifecycleTests {
    @Test func `Activation reloads before it resumes work, in order`() async {
        let log = StepLog()
        await AppLifecycle(actions: actions(log: log, signedIn: true)).activate()
        #expect(
            log.all == [
                "foreground", "downloadsForeground", "reload", "notify", "recover", "uploads", "import",
                "requestSync",
            ])
    }

    @Test func `Activation while signed out starts no account work`() async {
        let log = StepLog()
        await AppLifecycle(actions: actions(log: log, signedIn: false)).activate()
        #expect(log.all == ["foreground", "downloadsForeground", "reload", "notify"])
    }

    @Test func `Backgrounding during activation stops the activation's account work`() async throws {
        let log = StepLog()
        let latch = Latch()
        let lifecycle = AppLifecycle(actions: actions(log: log, signedIn: true, notify: { await latch.wait() }))
        let activation = Task { await lifecycle.activate() }
        try await waitFor { latch.waiting == 1 }
        await lifecycle.enterBackground()
        latch.open()
        await activation.value
        #expect(!log.all.contains("recover"))
        #expect(!log.all.contains("requestSync"))
    }

    @Test func `Backgrounding pushes queued ops and schedules tasks while the database is held`() async {
        let log = StepLog()
        await AppLifecycle(actions: actions(log: log, signedIn: true, pendingOps: 2, needsDownload: true))
            .enterBackground()
        #expect(
            log.all == [
                "hold", "downloadsBackground", "cancelDownloads", "background", "syncNow", "scheduleRefresh",
                "scheduleDownload", "release",
            ])
    }

    @Test func `Backgrounding with nothing queued skips the push`() async {
        let log = StepLog()
        await AppLifecycle(actions: actions(log: log, signedIn: true)).enterBackground()
        #expect(!log.all.contains("syncNow"))
        #expect(!log.all.contains("scheduleDownload"))
        #expect(log.all.contains("scheduleRefresh"))
    }

    @Test func `Background time running out suspends only while that backgrounding is current`() async {
        let log = StepLog()
        let lifecycle = AppLifecycle(actions: actions(log: log, signedIn: false))
        let first = lifecycle.beginBackground()
        await lifecycle.flush(first)
        await lifecycle.activate()
        lifecycle.backgroundExpired(first)
        #expect(!log.all.contains("expire"))

        let second = lifecycle.beginBackground()
        let third = lifecycle.beginBackground()
        lifecycle.backgroundExpired(second)
        #expect(!log.all.contains("expire"))
        lifecycle.backgroundExpired(third)
        #expect(log.all.filter { $0 == "expire" }.count == 1)
        await lifecycle.flush(second)
        await lifecycle.flush(third)
    }

    @Test func `Signing in resumes paused uploads and import polling, then syncs`() {
        let log = StepLog()
        let afterSignIn = LiveGraph.afterSignIn(
            requestSync: { log.add("requestSync") },
            resumePendingUploads: { log.add("uploads") },
            resumeImport: { log.add("import") })
        afterSignIn()
        #expect(log.all == ["uploads", "import", "requestSync"])
    }

    @Test func `Backgrounding while signed out schedules nothing`() async {
        let log = StepLog()
        await AppLifecycle(actions: actions(log: log, signedIn: false, pendingOps: 3, needsDownload: true))
            .enterBackground()
        #expect(log.all == ["hold", "downloadsBackground", "cancelDownloads", "background", "release"])
    }
}

struct SuspensionGateTests {
    @Test func `The database suspends only in the background with no holds`() {
        let log = StepLog()
        let gate = SuspensionGate(suspend: { log.add("suspend") }, resume: { log.add("resume") })
        gate.enterForeground()
        #expect(log.all.isEmpty)
        let hold = gate.hold()
        gate.enterBackground()
        #expect(log.all.isEmpty)
        hold.release()
        hold.release()
        #expect(log.all == ["suspend"])
        let second = gate.hold()
        #expect(log.all == ["suspend", "resume"])
        second.release()
        gate.enterForeground()
        #expect(log.all == ["suspend", "resume", "suspend", "resume"])
    }
}

extension SuspensionGateTests {
    @Test func `Expiry suspends despite earlier holds, and a later hold resumes`() {
        let log = StepLog()
        let gate = SuspensionGate(suspend: { log.add("suspend") }, resume: { log.add("resume") })
        gate.enterForeground()
        let flush = gate.hold()
        gate.enterBackground()
        gate.expire()
        #expect(log.all == ["suspend"])
        // A background task while the expired flush has not let go yet.
        let task = gate.hold()
        #expect(log.all == ["suspend", "resume"])
        flush.release()
        #expect(log.all == ["suspend", "resume"])
        task.release()
        #expect(log.all == ["suspend", "resume", "suspend"])
    }
}

struct WipeGuardTests {
    @Test func `A wipe waits for running local writes and refuses new ones`() async throws {
        let wipeGuard = WipeGuard()
        let log = StepLog()
        let latch = Latch()
        let write = Task {
            try await wipeGuard.admit {
                await latch.wait()
                log.add("write")
            }
        }
        try await waitFor { latch.waiting == 1 }
        let wipe = Task {
            await wipeGuard.during {
                await wipeGuard.drainWrites()
                log.add("clear")
            }
        }
        try await waitFor { wipeGuard.isWiping }
        await #expect(throws: WipeGuard.LocalWritesClosed.self) {
            try await wipeGuard.admit { log.add("late") }
        }
        latch.open()
        try await write.value
        await wipe.value
        #expect(log.all == ["write", "clear"])
    }

    @Test func `The sync session reads signed out for the whole wipe`() async throws {
        let database = try AppDatabase.inMemory()
        let secure = InMemorySecureStore()
        let sessionStore = SessionStore(store: secure)
        try sessionStore.save(token: "t", email: "a@b.c")
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let wipeGuard = WipeGuard()
        let syncSession = LiveSyncSession(store: sessionStore, guard: wipeGuard)
        let log = StepLog()
        let observe: @Sendable (String) async -> Void = { step in
            let state = await syncSession.currentState()
            log.add("\(step):\(state == .signedOut ? "out" : "in")")
        }
        let wiper = GuardedWiper(
            LocalDataWiper(
                database: database,
                cancelAllWork: { await observe("cancel") },
                clearTables: {
                    await observe("tables")
                    // A 401 from a pass that was still running: must not resurrect an expired session.
                    await syncSession.markExpired()
                },
                deleteFiles: { await observe("files") },
                transferDirectories: [],
                sessionStore: sessionStore,
                preferences: preferences,
                importJobs: ImportJobStore(preferences: preferences)),
            guard: wipeGuard)

        #expect(await syncSession.currentState() == .signedIn(email: "a@b.c"))
        await wiper.wipe()
        #expect(log.all == ["cancel:out", "tables:out", "files:out", "tables:out", "files:out"])
        #expect(sessionStore.current == nil)
        #expect(!wipeGuard.isWiping)
        #expect(await syncSession.currentState() == .signedOut)
    }

    @Test func `A 401 outside a wipe marks the session expired`() async throws {
        let sessionStore = SessionStore(store: InMemorySecureStore())
        try sessionStore.save(token: "t", email: "a@b.c")
        let syncSession = LiveSyncSession(store: sessionStore, guard: WipeGuard())
        await syncSession.markExpired()
        #expect(await syncSession.currentState() == .expired(email: "a@b.c"))
    }
}

/// A content engine whose automatic runs block until released.
final class StubContent: ContentEngine {
    let log = StepLog()
    private let gates = Mutex<[CheckedContinuation<Void, Never>]>([])
    let blockRuns: Bool
    let fetchResult: DownloadRunResult

    init(blockRuns: Bool = false, fetchResult: DownloadRunResult = DownloadRunResult()) {
        self.blockRuns = blockRuns
        self.fetchResult = fetchResult
    }

    func releaseRuns() {
        let waiting = gates.withLock { gates in
            defer { gates = [] }
            return gates
        }
        for gate in waiting { gate.resume() }
    }

    var waitingRuns: Int { gates.withLock { $0.count } }

    func fetch(itemId: String) async -> DownloadResult {
        log.add("fetch")
        return .downloaded
    }
    func runAutomaticDownloads(policy: DownloadPolicy, progress: (@Sendable (DownloadProgress) -> Void)?) async
        -> DownloadRunResult
    {
        log.add("auto:\(policy)")
        if blockRuns {
            await withCheckedContinuation { continuation in gates.withLock { $0.append(continuation) } }
        }
        return DownloadRunResult()
    }
    func downloadAll(progress: (@Sendable (DownloadProgress) -> Void)?) async -> DownloadRunResult {
        log.add("all")
        return fetchResult
    }
    func eligibleCount() async -> Int { 0 }
    func evict() async { log.add("evict") }
    func deleteFiles(itemIds: [String]) { log.add("delete:\(itemIds.joined(separator: ","))") }
    func removeAllContent() async {}
    func recoverInterrupted() async {}
}

struct LiveContentHooksTests {
    @Test func `Manual policy queues nothing`() async {
        let content = StubContent()
        let deferred = StepLog()
        let hooks = LiveContentHooks(
            content: content, policy: { .manual }, guard: WipeGuard(), onDeferred: { deferred.add("deferred") })
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        await hooks.runAutomaticNow()
        #expect(content.log.all.isEmpty)
        #expect(deferred.all.isEmpty)
    }

    @Test func `In the background the run is deferred to the background task`() async {
        let content = StubContent()
        let deferred = StepLog()
        let hooks = LiveContentHooks(
            content: content, policy: { .wifiOnly }, guard: WipeGuard(), onDeferred: { deferred.add("deferred") })
        await hooks.queueAutomaticDownloads()
        #expect(deferred.all == ["deferred"])
        #expect(content.log.all.isEmpty)
        await hooks.runAutomaticNow()
        #expect(content.log.all == ["auto:wifiOnly"])
    }

    @Test func `A request during a run reruns it once`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: WipeGuard())
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        try await waitFor { content.waitingRuns == 1 }
        await hooks.queueAutomaticDownloads()
        await hooks.queueAutomaticDownloads()
        content.releaseRuns()
        try await waitFor { content.waitingRuns == 1 }
        content.releaseRuns()
        try await waitFor { content.log.all.count == 2 }
        #expect(content.log.all == ["auto:anyNetwork", "auto:anyNetwork"])
    }

    @Test func `The wipe's cancel returns only once the run has stopped`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: WipeGuard())
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        try await waitFor { content.waitingRuns == 1 }
        let log = StepLog()
        let cancel = Task {
            await hooks.cancelAutomaticAndWait()
            log.add("joined")
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.all.isEmpty)
        content.releaseRuns()
        await cancel.value
        #expect(log.all == ["joined"])
    }

    @Test func `The wipe also joins a run cancelled earlier that is still stopping`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: WipeGuard())
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        try await waitFor { content.waitingRuns == 1 }
        hooks.cancelAutomatic()
        let log = StepLog()
        let wipe = Task {
            await hooks.cancelAutomaticAndWait()
            log.add("joined")
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.all.isEmpty)
        content.releaseRuns()
        await wipe.value
        #expect(log.all == ["joined"])
    }

    @Test func `A new run waits for a cancelled one to stop`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: WipeGuard())
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        try await waitFor { content.waitingRuns == 1 }
        hooks.cancelAutomatic()
        await hooks.queueAutomaticDownloads()
        try await Task.sleep(for: .milliseconds(20))
        #expect(content.log.all == ["auto:anyNetwork"])
        content.releaseRuns()
        try await waitFor { content.waitingRuns == 1 }
        content.releaseRuns()
        try await waitFor { content.log.all.count == 2 }
    }

    @Test func `A background caller's expiry leaves a run the foreground now owns`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: WipeGuard())
        let background = Task { await hooks.runAutomaticNow() }
        try await waitFor { content.waitingRuns == 1 }
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        background.cancel()
        content.releaseRuns()
        try await waitFor { content.waitingRuns == 1 }
        content.releaseRuns()
        try await waitFor { content.log.all.count == 2 }
        await background.value
    }

    @Test func `The wipe stops waiting for a stuck run after the join timeout`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(
            content: content, policy: { .anyNetwork }, guard: WipeGuard(), joinTimeout: .milliseconds(50))
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        try await waitFor { content.waitingRuns == 1 }
        await hooks.cancelAutomaticAndWait()
        content.releaseRuns()
    }

    @Test func `A foreground request after a background expiry starts a new run`() async throws {
        let content = StubContent(blockRuns: true)
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: WipeGuard())
        let background = Task { await hooks.runAutomaticNow() }
        try await waitFor { content.waitingRuns == 1 }
        background.cancel()
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        content.releaseRuns()
        try await waitFor { content.waitingRuns == 1 }
        content.releaseRuns()
        try await waitFor { content.log.all.count == 2 }
        await background.value
    }

    @Test func `The background task joins a run already in progress`() async throws {
        let content = StubContent(blockRuns: true)
        // Every entry point reads the policy first, so a read count says when the background call has begun.
        let policyReads = Mutex(0)
        let hooks = LiveContentHooks(
            content: content,
            policy: {
                policyReads.withLock { $0 += 1 }
                return .anyNetwork
            }, guard: WipeGuard())
        hooks.setForeground(true)
        await hooks.queueAutomaticDownloads()
        try await waitFor { content.waitingRuns == 1 }
        let readsBefore = policyReads.withLock { $0 }
        let background = Task { await hooks.runAutomaticNow() }
        // The call joins the running task under its lock straight after that read, before it can suspend.
        try await waitFor { policyReads.withLock { $0 } > readsBefore }
        content.releaseRuns()
        await background.value
        #expect(content.log.all == ["auto:anyNetwork"])
    }

    @Test func `A caller that joined another's run stops waiting without cancelling it`() async throws {
        let content = StubContent(blockRuns: true)
        let policyReads = Mutex(0)
        let hooks = LiveContentHooks(
            content: content,
            policy: {
                policyReads.withLock { $0 += 1 }
                return .anyNetwork
            }, guard: WipeGuard())
        let processing = Task { await hooks.runAutomaticNow() }
        try await waitFor { content.waitingRuns == 1 }
        // A silent push joins the processing task's run, then runs out of time.
        let readsBeforePush = policyReads.withLock { $0 }
        let push = Task { await hooks.runAutomaticNow() }
        try await waitFor { policyReads.withLock { $0 } > readsBeforePush }
        push.cancel()
        await push.value
        // The run is still the current one: a later caller joins it instead of starting another.
        let readsBeforeLater = policyReads.withLock { $0 }
        let later = Task { await hooks.runAutomaticNow() }
        try await waitFor { policyReads.withLock { $0 } > readsBeforeLater }
        content.releaseRuns()
        await processing.value
        await later.value
        #expect(content.log.all == ["auto:anyNetwork"])
    }

    @Test func `No automatic run starts during a wipe`() async {
        let content = StubContent()
        let wipeGuard = WipeGuard()
        let hooks = LiveContentHooks(content: content, policy: { .anyNetwork }, guard: wipeGuard)
        hooks.setForeground(true)
        await wipeGuard.during {
            await hooks.queueAutomaticDownloads()
            await hooks.runAutomaticNow()
        }
        #expect(content.log.all.isEmpty)
    }

    @Test func `A fetch reports its downloads or why it stopped`() async {
        let ok = LiveContentHooks(
            content: StubContent(fetchResult: DownloadRunResult(downloaded: 3)), policy: { .manual },
            guard: WipeGuard())
        #expect(await ok.fetchDownloads() == .fetchCompleted(newlyDownloaded: 3))
        let failed = LiveContentHooks(
            content: StubContent(fetchResult: DownloadRunResult(downloaded: 1, failure: .network)),
            policy: { .manual }, guard: WipeGuard())
        #expect(await failed.fetchDownloads() == .fetchFailed(.network))
    }
}

func waitFor(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Condition not met in time")
}
