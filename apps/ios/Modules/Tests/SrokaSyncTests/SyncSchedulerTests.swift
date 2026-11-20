import Foundation
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSync

/// The in-process replacement for Android's `WorkScheduler` + `SyncWorker`.
struct SyncSchedulerTests {
    let h: Harness
    let clock = ManualClock()
    let network = SettableNetwork()
    let scheduler: SyncScheduler

    init() throws {
        h = try Harness()
        scheduler = SyncScheduler(
            engine: h.engine, session: h.session, hooks: h.hooks, network: network, clock: clock)
    }

    /// Collects pass outcomes from now on.
    func outcomes() -> Recorder<SyncOutcome> { Recorder(scheduler.passOutcomes.stream()) }

    @Test func `Sync requests are debounced by two seconds after the last one`() async throws {
        let passes = outcomes()
        h.api.serve { _ in .json(pullJson(1)) }

        scheduler.requestSync()
        await clock.waitForSleepers()
        clock.advance(by: .seconds(1))
        scheduler.requestSync()
        await eventually { clock.requested.count == 2 && clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(1_500))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.api.calls.isEmpty)

        clock.advance(by: .milliseconds(500))
        await passes.waitFor(1)
        #expect(passes.values == [.success(pulledItems: 0)])
        #expect(h.api.pulls.count == 1)
        #expect(h.hooks.automaticDownloads == 1)
        #expect(h.hooks.evictions == 1)
    }

    @Test func `Failures back off from 30 seconds, doubling, for at most 5 retries`() async throws {
        let passes = outcomes()
        h.api.serve { _ in .error(.http(status: 503, code: nil, message: nil, retryAfter: nil)) }

        scheduler.enqueueSync()
        for (index, seconds) in [30, 60, 120, 240, 480].enumerated() {
            await passes.waitFor(index + 1)
            await clock.waitForSleepers()
            clock.advance(by: .seconds(seconds))
        }
        await passes.waitFor(6)
        try await Task.sleep(for: .milliseconds(20))

        #expect(passes.values == Array(repeating: .failure(.server), count: 6))
        #expect(clock.requested == [30, 60, 120, 240, 480].map { Duration.seconds($0) })
        #expect(clock.sleeperCount == 0)
        #expect(h.hooks.evictions == 0)
    }

    @Test func `A network failure is retried silently`() async throws {
        let passes = outcomes()
        h.api.enqueue(error: .transport(.networkConnectionLost))
        h.api.enqueue(pullJson(1))

        scheduler.enqueueSync()
        await passes.waitFor(1)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(30))
        await passes.waitFor(2)

        #expect(passes.values == [.failure(.network), .success(pulledItems: 0)])
        #expect(try await h.syncState().lastError == nil)
    }

    @Test func `An auth failure is not retried`() async throws {
        let passes = outcomes()
        h.api.enqueue(status: 401)

        scheduler.enqueueSync()
        await passes.waitFor(1)
        try await Task.sleep(for: .milliseconds(20))

        #expect(passes.values == [.failure(.auth)])
        #expect(clock.sleeperCount == 0)
        #expect(h.session.state == .expired(email: "reader@example.com"))
    }

    @Test func `A background sync waits for a network`() async throws {
        let passes = outcomes()
        network.online.send(false)
        h.api.serve { _ in .json(pullJson(1)) }

        scheduler.enqueueSync()
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.api.calls.isEmpty)

        network.online.send(true)
        await passes.waitFor(1)
        #expect(passes.values == [.success(pulledItems: 0)])
    }

    @Test func `A request during a running pass adds exactly one follow-up pass`() async throws {
        let passes = outcomes()
        let gate = Gate()
        let calls = Mutex(0)
        h.api.serve { _ in
            if calls.withLock({ count in
                count += 1
                return count
            }) == 1 {
                await gate.wait()
            }
            return .json(pullJson(1))
        }

        scheduler.enqueueSync()
        await eventually { calls.withLock { $0 } == 1 }
        scheduler.enqueueSync()
        scheduler.enqueueSync()
        await gate.open()
        await passes.waitFor(2)
        try await Task.sleep(for: .milliseconds(20))

        #expect(passes.values.count == 2)
        #expect(h.api.pulls.count == 2)
    }

    @Test func `A request while one waits for a network adds nothing`() async throws {
        let passes = outcomes()
        network.online.send(false)
        h.api.serve { _ in .json(pullJson(1)) }

        scheduler.enqueueSync()
        scheduler.enqueueSync()
        network.online.send(true)
        await passes.waitFor(1)
        try await Task.sleep(for: .milliseconds(20))

        #expect(passes.values.count == 1)
    }

    @Test func `Fetching new articles syncs, downloads and reports the result`() async throws {
        let events = Recorder(scheduler.events)
        h.hooks.setFetchResult(.fetchCompleted(newlyDownloaded: 3))
        h.api.serve { _ in .json(pullJson(1)) }

        scheduler.fetchNewArticles()
        await events.waitFor(1)

        #expect(events.values == [.fetchCompleted(newlyDownloaded: 3)])
        #expect(h.hooks.fetches == 1)
        #expect(h.hooks.automaticDownloads == 0)
        #expect(h.hooks.evictions == 1)
    }

    @Test func `A failed fetch reports its kind and is not retried`() async throws {
        let events = Recorder(scheduler.events)
        h.api.enqueue(status: 500)

        scheduler.fetchNewArticles()
        await events.waitFor(1)
        try await Task.sleep(for: .milliseconds(20))

        #expect(events.values == [.fetchFailed(.server)])
        #expect(h.hooks.fetches == 0)
        #expect(h.api.calls.count == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func `A fetch with an expired session reports auth without calling the server`() async throws {
        let events = Recorder(scheduler.events)
        h.session.set(.expired(email: "reader@example.com"))

        scheduler.fetchNewArticles()
        await events.waitFor(1)

        #expect(events.values == [.fetchFailed(.auth)])
        #expect(h.api.calls.isEmpty)
    }

    @Test func `A fetch cancels the pending debounced request`() async throws {
        let events = Recorder(scheduler.events)
        h.api.serve { _ in .json(pullJson(1)) }

        scheduler.requestSync()
        await clock.waitForSleepers()
        scheduler.fetchNewArticles()
        await events.waitFor(1)
        await eventually { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))

        #expect(h.api.pulls.count == 1)
    }

    @Test func `Background refresh reports success and failure`() async throws {
        h.api.enqueue(pullJson(1))
        #expect(await scheduler.handleBackgroundRefresh())
        #expect(h.hooks.automaticDownloads == 1)

        h.api.enqueue(status: 500)
        #expect(await !scheduler.handleBackgroundRefresh())

        h.session.set(.signedOut)
        #expect(await scheduler.handleBackgroundRefresh())
    }

    @Test func `Wipe drops the debounced request and a worker in backoff`() async throws {
        let passes = outcomes()
        h.api.enqueue(status: 500)

        scheduler.enqueueSync()
        await passes.waitFor(1)
        await clock.waitForSleepers()
        scheduler.requestSync()
        await clock.waitForSleepers(2)

        try await scheduler.wipe {}
        await eventually { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(600))
        try await Task.sleep(for: .milliseconds(20))

        #expect(passes.values.count == 1)
        #expect(h.api.calls.count == 1)

        // The scheduler still works afterwards.
        h.api.enqueue(pullJson(1))
        scheduler.enqueueSync()
        await passes.waitFor(2)
    }

    @Test func `Wipe never interleaves with a running scheduled pass`() async throws {
        let passes = outcomes()
        let gate = Gate()
        let log = Mutex<[String]>([])
        h.api.serve { _ in
            log.withLock { $0.append("pass") }
            await gate.wait()
            return .json(pullJson(1))
        }

        scheduler.enqueueSync()
        await eventually { log.withLock { $0 } == ["pass"] }
        let wipe = Task { [scheduler] in await scheduler.wipe { log.withLock { $0.append("wipe") } } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.withLock { $0 } == ["pass"])

        await gate.open()
        await wipe.value
        await passes.waitFor(1)

        #expect(log.withLock { $0 } == ["pass", "wipe"])
        #expect(passes.values == [.cancelled])
    }
}

/// Phase priority, as Android `SyncStatusRepositoryImpl.phaseOf`.
struct SyncStatusTests {
    private func phase(
        syncing: Bool = false,
        downloading: SyncDownloadProgress? = nil,
        state: SyncStateRecord = SyncStateRecord(),
        online: Bool = true,
        expired: Bool = false
    ) -> SyncPhase {
        LiveSyncStatusRepository.phaseOf(
            syncing: syncing, downloading: downloading, state: state, online: online, expired: expired)
    }

    @Test func `Phases follow the Android priority order`() {
        let progress = SyncDownloadProgress(done: 1, total: 4, currentTitle: "T")
        #expect(phase(syncing: true, state: .init(fullResync: true), online: false, expired: true) == .error(.auth))
        #expect(
            phase(syncing: true, downloading: progress, state: .init(fullResync: true)) == .resyncing(fraction: nil))
        #expect(phase(syncing: true, downloading: progress, online: false) == .syncing)
        #expect(phase(downloading: progress, online: false) == .downloading(done: 1, total: 4, currentTitle: "T"))
        #expect(phase(state: .init(lastError: "server"), online: false) == .offline)
        #expect(phase(state: .init(lastError: "server")) == .error(.server))
        #expect(phase(state: .init(lastError: "network")) == .idle)
        #expect(phase(state: .init(lastError: "http_500")) == .idle)
        #expect(phase() == .idle)
    }

    @Test func `Status combines counts, last sync and phase`() async throws {
        let h = try Harness()
        let network = SettableNetwork()
        let scheduler = SyncScheduler(engine: h.engine, session: h.session, hooks: h.hooks, network: network)
        let repository = LiveSyncStatusRepository(
            database: h.db, scheduler: scheduler, session: h.session, hooks: h.hooks, network: network)
        let statuses = Recorder(repository.status)

        await statuses.waitUntil { $0 == SyncStatus() }
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        await statuses.waitUntil { $0.pendingOps == 1 }

        try await h.updateSyncState { $0.lastSuccessAt = 2_000 }
        await statuses.waitUntil { $0.lastSyncAt == Date(timeIntervalSince1970: 2) }

        network.online.send(false)
        await statuses.waitUntil { $0.phase == .offline }

        h.session.set(.expired(email: "reader@example.com"))
        await statuses.waitUntil { $0.phase == .error(.auth) }
    }
}

/// Records every element of a stream in the background.
final class Recorder<Element: Sendable>: Sendable {
    private final class Storage: Sendable {
        let values = Mutex<[Element]>([])
    }

    private let storage = Storage()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Element>) {
        let storage = storage
        task = Task {
            for await value in stream { storage.values.withLock { $0.append(value) } }
        }
    }

    deinit { task.cancel() }

    var values: [Element] { storage.values.withLock { $0 } }

    func waitFor(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await eventually({ self.values.count >= count }, sourceLocation: sourceLocation)
    }

    func waitUntil(
        sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @escaping @Sendable (Element) -> Bool
    ) async {
        await eventually({ self.values.last.map(predicate) ?? false }, sourceLocation: sourceLocation)
    }
}
