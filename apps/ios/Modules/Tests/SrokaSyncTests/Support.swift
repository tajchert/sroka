import Foundation
import GRDB
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSync

// MARK: - Time

/// A settable wall clock in milliseconds (Android tests' `now`).
final class TestTime: Sendable {
    private let value = Mutex<Int64>(1_700_000_000_000)

    var now: Int64 { value.withLock { $0 } }
    func advance(_ millis: Int64) { value.withLock { $0 += millis } }
    var closure: @Sendable () -> Int64 { { [self] in now } }
}

/// A clock whose time moves only when a test calls `advance`; records every requested sleep.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextId = 0
        var sleepers: [Sleeper] = []
        var requested: [Duration] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    /// Durations of every sleep requested so far, in order.
    var requested: [Duration] { state.withLock { $0.requested } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextId += 1
            return state.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.requested.append(state.now.duration(to: deadline))
                    if deadline <= state.now { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits (yielding) until `count` sleepers are registered.
    func waitForSleepers(_ count: Int = 1) async {
        await eventually { self.sleeperCount >= count }
    }
}

/// Yields until `condition` holds (bounded); records an issue when it never does.
func eventually(
    _ condition: @Sendable () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<2_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition not met in time", sourceLocation: sourceLocation)
}

// MARK: - Fake API

enum SyncCall: Equatable, Sendable {
    case push([String])
    case pull(cursor: Int64, full: Bool)

    var isPull: Bool {
        if case .pull = self { return true }
        return false
    }
}

/// Scripted `/v1/sync` server: queued replies first, then the `serve` handler.
final class FakeSyncAPI: SrokaAPI {
    enum Reply: Sendable {
        case json(String)
        case error(ApiError)
    }

    private struct State {
        var calls: [SyncCall] = []
        var queue: [Reply] = []
        var handler: (@Sendable (SyncCall) async throws -> Reply)?
    }

    private let state = Mutex(State())

    var calls: [SyncCall] { state.withLock { $0.calls } }
    var pushes: [[String]] {
        calls.compactMap {
            if case .push(let payloads) = $0 { return payloads }
            return nil
        }
    }
    var pulls: [SyncCall] { calls.filter(\.isPull) }

    func enqueue(_ json: String) { state.withLock { $0.queue.append(.json(json)) } }
    func enqueue(status: Int, code: String? = nil) {
        state.withLock { $0.queue.append(.error(.http(status: status, code: code, message: nil, retryAfter: nil))) }
    }
    func enqueue(error: ApiError) { state.withLock { $0.queue.append(.error(error)) } }
    func serve(_ handler: @escaping @Sendable (SyncCall) async throws -> Reply) {
        state.withLock { $0.handler = handler }
    }

    func push(payloads: [String]) async throws -> PushResponseDto {
        try decode(await respond(.push(payloads)))
    }

    func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto {
        try decode(await respond(.pull(cursor: cursor, full: full)))
    }

    private func respond(_ call: SyncCall) async throws -> String {
        let (queued, handler) = state.withLock { state -> (Reply?, (@Sendable (SyncCall) async throws -> Reply)?) in
            state.calls.append(call)
            if !state.queue.isEmpty { return (state.queue.removeFirst(), nil) }
            return (nil, state.handler)
        }
        let reply: Reply
        if let queued {
            reply = queued
        } else if let handler {
            reply = try await handler(call)
        } else {
            Issue.record("unexpected call \(call)")
            throw ApiError.http(status: 599, code: nil, message: nil, retryAfter: nil)
        }
        switch reply {
        case .json(let json): return json
        case .error(let error): throw error
        }
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // Not used by sync.
    func sendOtp(email: String) async throws { throw ApiError.invalidRequest }
    func signIn(email: String, otp: String) async throws -> SignInResult { throw ApiError.invalidRequest }
    func signOut() async throws { throw ApiError.invalidRequest }
    func item(id: String) async throws -> ItemDto { throw ApiError.invalidRequest }
    func contentUrls(itemId: String) async throws -> ContentUrlsDto { throw ApiError.invalidRequest }
    func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto { throw ApiError.invalidRequest }
    func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto {
        throw ApiError.invalidRequest
    }
    func me() async throws -> MeDto { throw ApiError.invalidRequest }
    func deleteAccount() async throws { throw ApiError.invalidRequest }
    func putPushToken(_ body: PushTokenRequestDto) async throws { throw ApiError.invalidRequest }
    func deletePushToken() async throws { throw ApiError.invalidRequest }
    func createImport(source: URL, fileName: String, mimeType: String, format: ImportFormat) async throws -> JobDto {
        throw ApiError.invalidRequest
    }
    func importJob(id: String) async throws -> JobDto { throw ApiError.invalidRequest }
    func export(format: ExportFormat, to destination: URL) async throws -> ExportFile { throw ApiError.invalidRequest }
    func config() async throws -> ConfigDto { throw ApiError.invalidRequest }
    func download(from url: URL, to destination: URL, onProgress: ByteProgress?) async throws {
        throw ApiError.invalidRequest
    }
}

// MARK: - JSON (Android DataTestBase)

func itemJson(
    _ id: String,
    seq: Int64,
    title: String? = nil,
    status: String = "unread",
    favorite: Bool = false,
    progress: Double = 0,
    tags: [String] = [],
    savedAt: Int64 = 1_000
) -> String {
    let tagList = tags.map { "\"\($0)\"" }.joined(separator: ",")
    return """
        {"id":"\(id)","url":"https://example.com/\(id)","canonicalUrl":"https://example.com/\(id)",\
        "title":"\(title ?? "Server \(id)")","parseStatus":"ok","status":"\(status)","isFavorite":\(favorite),\
        "progress":\(progress),"savedAt":\(savedAt),"tags":[\(tagList)],"seq":\(seq),"contentId":"c-\(id)"}
        """
}

func pullJson(
    _ cursor: Int64,
    items: [String] = [],
    hasMore: Bool = false,
    deletedItems: [String] = [],
    tags: String = ""
) -> String {
    let deleted = deletedItems.map { "\"\($0)\"" }.joined(separator: ",")
    return """
        {"cursor":\(cursor),"hasMore":\(hasMore),"items":[\(items.joined(separator: ","))],"tags":[\(tags)],\
        "deleted":{"items":[\(deleted)],"tags":[]}}
        """
}

func pushJson(applied: [String] = [], rejected: [(String, String)] = [], aliases: [String: String] = [:], cursor: Int64)
    -> String
{
    let appliedList = applied.map { "\"\($0)\"" }.joined(separator: ",")
    let rejectedList = rejected.map { "{\"opId\":\"\($0.0)\",\"reason\":\"\($0.1)\"}" }.joined(separator: ",")
    let aliasList = aliases.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\"\($0.value)\"" }
        .joined(separator: ",")
    return """
        {"applied":[\(appliedList)],"rejected":[\(rejectedList)],"aliases":{\(aliasList)},"cursor":\(cursor)}
        """
}

// MARK: - Session, hooks, controller

final class FakeSession: SyncSession {
    let subject = ValueSubject<SessionState>(.signedIn(email: "reader@example.com"))

    var state: SessionState { subject.value }
    func set(_ state: SessionState) { subject.send(state) }

    func currentState() async -> SessionState { subject.value }
    func observeState() -> AsyncStream<SessionState> { subject.stream() }
    func markExpired() async {
        if case .signedIn(let email) = subject.value { subject.send(.expired(email: email)) }
    }
}

final class RecordingHooks: SyncContentHooks {
    private struct State {
        var deleted: [String] = []
        var automaticDownloads = 0
        var evictions = 0
        var fetches = 0
        var itemDownloads: [String] = []
        var fetchResult = SyncEvent.fetchCompleted(newlyDownloaded: 0)
    }

    private let state = Mutex(State())
    let progress = ValueSubject<SyncDownloadProgress?>(nil)

    var deleted: [String] { state.withLock { $0.deleted } }
    var automaticDownloads: Int { state.withLock { $0.automaticDownloads } }
    var evictions: Int { state.withLock { $0.evictions } }
    var fetches: Int { state.withLock { $0.fetches } }
    var itemDownloads: [String] { state.withLock { $0.itemDownloads } }
    func setFetchResult(_ event: SyncEvent) { state.withLock { $0.fetchResult = event } }

    func deleteItemFiles(itemIds: [String]) async { state.withLock { $0.deleted += itemIds } }
    func queueAutomaticDownloads() async { state.withLock { $0.automaticDownloads += 1 } }
    func evict() async { state.withLock { $0.evictions += 1 } }
    func fetchDownloads() async -> SyncEvent {
        state.withLock { state in
            state.fetches += 1
            return state.fetchResult
        }
    }
    func downloadItemNow(itemId: String) async { state.withLock { $0.itemDownloads.append(itemId) } }
    func observeDownloadProgress() -> AsyncStream<SyncDownloadProgress?> { progress.stream() }
}

final class CountingSyncController: SyncController {
    private let counts = Mutex((sync: 0, fetch: 0))

    var syncRequests: Int { counts.withLock { $0.sync } }
    func requestSync() { counts.withLock { $0.sync += 1 } }
    func fetchNewArticles() { counts.withLock { $0.fetch += 1 } }
    func downloadItemNow(itemId: String) {}
}

final class SettableNetwork: NetworkStatus {
    let online = ValueSubject(true)
    func observeOnline() -> AsyncStream<Bool> { online.stream() }
}

// MARK: - Harness

/// One in-memory library with a scripted server (Android `DataTestBase`).
struct Harness {
    let time = TestTime()
    let db: AppDatabase
    let api = FakeSyncAPI()
    let session = FakeSession()
    let hooks = RecordingHooks()
    let controller = CountingSyncController()
    let writer: OpWriter
    let engine: SyncEngine
    let library: LiveLibraryRepository
    let tags: LiveTagRepository

    init() throws {
        db = try AppDatabase.inMemory()
        let time = time
        writer = OpWriter(database: db, opClock: OpClock(now: time.closure), now: time.closure)
        engine = SyncEngine(database: db, api: api, session: session, hooks: hooks, now: time.closure)
        library = LiveLibraryRepository(database: db, writer: writer, syncController: controller, hooks: hooks)
        tags = LiveTagRepository(database: db, writer: writer, syncController: controller)
    }

    var now: Int64 { time.now }

    /// An item the server knows (`serverSeq` 1), as Android's `entity(id)`.
    static func entity(
        _ id: String,
        title: String? = nil,
        savedAt: Int64 = 1_000,
        status: ItemStatus = .unread,
        favorite: Bool = false
    ) -> ItemRecord {
        ItemRecord(
            id: id,
            url: "https://example.com/\(id)",
            canonicalUrl: "https://example.com/\(id)",
            title: title ?? "Title \(id)",
            wordCount: 500,
            readingMinutes: 3,
            contentId: "c-\(id)",
            parseStatus: .ok,
            status: status,
            isFavorite: favorite,
            savedAt: savedAt,
            serverSeq: 1
        )
    }

    func insert(_ id: String, tags: [String] = []) async throws {
        let record = Self.entity(id)
        try await db.write { db in try ItemDao.upsert(db, record, tags: tags) }
    }

    func item(_ id: String) async throws -> ItemRecord? {
        try await db.read { db in try ItemDao.item(db, id: id) }
    }

    func tagNames(_ id: String) async throws -> [String] {
        try await db.read { db in try ItemDao.tagNames(db, itemId: id) }
    }

    func queued() async throws -> [PendingOpRecord] {
        try await db.read { db in try PendingOpDao.batch(db, limit: 10_000) }
    }

    func queuedOps() async throws -> [WireOp] {
        try await queued().compactMap { WireOp.parse(payload: $0.payload) }
    }

    func pendingCount() async throws -> Int {
        try await db.read { db in try PendingOpDao.count(db) }
    }

    func syncState() async throws -> SyncStateRecord {
        try await db.read { db in try SyncStateDao.get(db) }
    }

    func updateSyncState(_ change: @escaping @Sendable (inout SyncStateRecord) -> Void) async throws {
        try await db.write { db in try SyncStateDao.update(db, change) }
    }

    func enqueue(_ op: WireOp) async throws {
        let record = op.pendingRecord(createdAt: time.now)
        try await db.write { db in _ = try PendingOpDao.enqueue(db, record) }
    }

    func savedId(_ url: String, title: String? = nil, tags: [String] = [], source: SaveSource = .share)
        async throws -> String
    {
        let result = await library.save(url: url, title: title, tags: tags, source: source)
        guard case .saved(let id, _) = result else {
            Issue.record("save failed: \(result)")
            throw CancellationError()
        }
        return id
    }
}
