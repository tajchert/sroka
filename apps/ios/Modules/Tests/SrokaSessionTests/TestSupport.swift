import Clocks
import Foundation
import GRDB
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSession

/// Scripted `SrokaAPI`: each call runs the matching closure; unset closures fail with `invalidRequest`.
final class FakeAPI: SrokaAPI {
    struct Handlers: Sendable {
        var sendOtp: (@Sendable (String) async throws -> Void)?
        var signIn: (@Sendable (String, String) async throws -> SignInResult)?
        var signOut: (@Sendable () async throws -> Void)?
        var me: (@Sendable () async throws -> MeDto)?
        var deleteAccount: (@Sendable () async throws -> Void)?
        var createImport: (@Sendable (URL, String, String, ImportFormat) async throws -> JobDto)?
        var importJob: (@Sendable (String) async throws -> JobDto)?
        var export: (@Sendable (ExportFormat, URL) async throws -> ExportFile)?
    }

    let handlers = Mutex(Handlers())
    let calls = Mutex<[String]>([])

    func configure(_ body: (inout Handlers) -> Void) { handlers.withLock { body(&$0) } }
    var recorded: [String] { calls.withLock { $0 } }

    private func record(_ name: String) { calls.withLock { $0.append(name) } }

    func sendOtp(email: String) async throws {
        record("sendOtp")
        guard let handler = handlers.withLock({ $0.sendOtp }) else { throw ApiError.invalidRequest }
        try await handler(email)
    }

    func signIn(email: String, otp: String) async throws -> SignInResult {
        record("signIn:\(otp)")
        guard let handler = handlers.withLock({ $0.signIn }) else { throw ApiError.invalidRequest }
        return try await handler(email, otp)
    }

    func signOut() async throws {
        record("signOut")
        guard let handler = handlers.withLock({ $0.signOut }) else { throw ApiError.invalidRequest }
        try await handler()
    }

    func push(payloads: [String]) async throws -> PushResponseDto { throw ApiError.invalidRequest }
    func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto { throw ApiError.invalidRequest }
    func item(id: String) async throws -> ItemDto { throw ApiError.invalidRequest }
    func contentUrls(itemId: String) async throws -> ContentUrlsDto { throw ApiError.invalidRequest }
    func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto { throw ApiError.invalidRequest }
    func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto {
        throw ApiError.invalidRequest
    }

    func me() async throws -> MeDto {
        record("me")
        guard let handler = handlers.withLock({ $0.me }) else { throw ApiError.invalidRequest }
        return try await handler()
    }

    func deleteAccount() async throws {
        record("deleteAccount")
        guard let handler = handlers.withLock({ $0.deleteAccount }) else { throw ApiError.invalidRequest }
        try await handler()
    }

    func createImport(source: URL, fileName: String, mimeType: String, format: ImportFormat) async throws -> JobDto {
        record("createImport")
        guard let handler = handlers.withLock({ $0.createImport }) else { throw ApiError.invalidRequest }
        return try await handler(source, fileName, mimeType, format)
    }

    func importJob(id: String) async throws -> JobDto {
        record("importJob")
        guard let handler = handlers.withLock({ $0.importJob }) else { throw ApiError.invalidRequest }
        return try await handler(id)
    }

    func export(format: ExportFormat, to destination: URL) async throws -> ExportFile {
        record("export")
        guard let handler = handlers.withLock({ $0.export }) else { throw ApiError.invalidRequest }
        return try await handler(format, destination)
    }

    func config() async throws -> ConfigDto { throw ApiError.invalidRequest }
    func download(from url: URL, to destination: URL, onProgress: ByteProgress?) async throws {
        throw ApiError.invalidRequest
    }
}

/// Records events and consent calls.
final class RecordingTelemetry: Telemetry {
    let events = Mutex<[TelemetryEvent]>([])
    let analytics = Mutex<[Bool]>([])
    let crash = Mutex<[Bool]>([])
    var isAvailable: Bool { true }
    var logged: [TelemetryEvent] { events.withLock { $0 } }
    func logEvent(_ event: TelemetryEvent) { events.withLock { $0.append(event) } }
    func setAnalyticsEnabled(_ enabled: Bool) { analytics.withLock { $0.append(enabled) } }
    func setCrashReportingEnabled(_ enabled: Bool) { crash.withLock { $0.append(enabled) } }
    let nonFatals = Mutex(0)
    func recordNonFatal(_ error: any Error) { nonFatals.withLock { $0 += 1 } }
}

func jobDto(
    id: String = "job1", status: String = "queued", format: String? = "pocket_csv", done: Int = 0,
    total: Int? = nil
) -> JobDto {
    var fields: [String: Any] = [
        "id": id, "status": status, "done": done, "skipped": 0, "createdAt": 1_700_000_000_000,
        "updatedAt": 1_700_000_000_000,
    ]
    if let format { fields["format"] = format }
    if let total { fields["total"] = total }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(JobDto.self, from: data)
}

func meDto(extensionClient: Bool, android: Bool, ios: Bool) -> MeDto {
    let json = """
        {"user":{"id":"u","email":"a@b.co"},"clients":{"extension":\(extensionClient),"android":\(android),"ios":\(ios)}}
        """
    return try! JSONDecoder().decode(MeDto.self, from: Data(json.utf8))
}

func httpError(_ status: Int, code: String? = nil, retryAfter: TimeInterval? = nil) -> ApiError {
    .http(status: status, code: code, message: nil, retryAfter: retryAfter)
}

/// Everything the session module needs, wired as the composition root will, on in-memory stores.
struct Harness {
    static let defaultServer = "https://api.sroka.app"

    let api = FakeAPI()
    let keychain = InMemorySecureStore()
    let defaults: UserDefaults
    let preferences: PreferencesStore
    let sessionStore: SessionStore
    let provider: LiveApiSessionProvider
    let database: AppDatabase
    let jobs: ImportJobStore
    let wiper: LocalDataWiper
    let auth: LiveAuthRepository
    let settings: LiveSettingsRepository
    /// Never advanced by default (timeouts never fire); pass an `ImmediateClock` to test them.
    let clock: any Clock<Duration>
    let syncRequests = Locked(0)
    let cachesDirectory: URL

    init(
        defaults: UserDefaults? = nil, keychain values: [String: String] = [:],
        clock: any Clock<Duration> = TestClock()
    ) throws {
        self.defaults = defaults ?? Self.freshDefaults()
        for (key, value) in values { try keychain.write(key, value: value) }
        preferences = PreferencesStore(defaults: self.defaults)
        sessionStore = SessionStore(store: keychain, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        provider = LiveApiSessionProvider(
            sessionStore: sessionStore, preferences: preferences, defaultServerUrl: Self.defaultServer)
        database = try AppDatabase.inMemory()
        jobs = ImportJobStore(preferences: preferences)
        cachesDirectory = FileManager.default.temporaryDirectory.appending(path: "sroka-session-\(UUID().uuidString)")
        wiper = LocalDataWiper.databaseOnly(
            database,
            transferDirectories: [
                cachesDirectory.appending(path: "imports"), cachesDirectory.appending(path: "exports"),
            ],
            sessionStore: sessionStore, preferences: preferences, importJobs: jobs)
        self.clock = clock
        let counter = syncRequests
        let database = database
        auth = LiveAuthRepository(
            api: api, sessionStore: sessionStore, preferences: preferences, provider: provider, wiper: wiper,
            hasLocalData: { await LiveAuthRepository.hasAccountData(in: database) },
            requestSync: { counter.withLock { $0 += 1 } }, clock: clock)
        settings = LiveSettingsRepository(
            store: preferences, sessionStore: sessionStore, auth: auth, defaultServerUrl: Self.defaultServer,
            onDownloadPolicyChanged: { _ in })
    }

    static func freshDefaults() -> UserDefaults {
        let name = "sroka-session-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Signs in through the repository with a server that accepts any code.
    func signIn(_ email: String, token: String = "tok.en=") async -> AuthResult {
        api.configure { $0.signIn = { _, _ in SignInResult(token: token, userEmail: email) } }
        return await auth.signIn(email: email, code: "123456")
    }

    func insertItem(id: String = "item1") async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (id, url, canonical_url, content_private, parse_status, status, is_favorite,
                      progress, saved_at, fts_rowid)
                    VALUES (?, 'https://e.com', 'https://e.com', 0, 'OK', 'UNREAD', 0, 0, 0, 1)
                    """, arguments: [id])
        }
    }

    func insertPendingOp() async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO pending_ops (op_id, type, payload, created_at) VALUES ('op1', 'item.add', '{}', 0)")
        }
    }

    func itemCount() async throws -> Int {
        try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0 }
    }

    func pendingOpCount() async throws -> Int {
        try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_ops") ?? 0 }
    }
}

/// A copyable, sendable box around a `Mutex`.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// Lets spawned tasks reach their next suspension point (e.g. register a sleep on the test clock).
func settle() async {
    for _ in 0..<200 { await Task.yield() }
}
