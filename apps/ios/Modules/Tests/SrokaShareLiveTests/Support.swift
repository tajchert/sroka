import Foundation
import GRDB
import SrokaContent
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import SrokaSession
import SrokaSync
import Synchronization

@testable import SrokaShareLive

/// `SrokaAPI` for the extension's calls: push and PDF upload. Everything else is a test failure (throws).
final class ShareFakeAPI: SrokaAPI {
    typealias PushHandler = @Sendable ([String]) async throws -> PushResponseDto
    typealias UploadHandler = @Sendable (URL, String) async throws -> PdfUploadResponseDto

    private let state = Mutex(
        (push: PushHandler?.none, upload: UploadHandler?.none, events: [String](), pushed: [String]()))

    /// Calls in order: `push` and `upload:<fileName>`.
    var events: [String] { state.withLock { $0.events } }
    /// Every payload sent to `/v1/sync/push`.
    var pushed: [String] { state.withLock { $0.pushed } }

    func onPush(_ handler: @escaping PushHandler) { state.withLock { $0.push = handler } }
    func onUpload(_ handler: @escaping UploadHandler) { state.withLock { $0.upload = handler } }

    func push(payloads: [String]) async throws -> PushResponseDto {
        let handler = state.withLock { state in
            state.events.append("push")
            state.pushed += payloads
            return state.push
        }
        guard let handler else { throw ApiError.invalidRequest }
        return try await handler(payloads)
    }

    func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto {
        let handler = state.withLock { state in
            state.events.append("upload:\(fileName)")
            return state.upload
        }
        guard let handler else { throw ApiError.invalidRequest }
        return try await handler(file, fileName)
    }

    func sendOtp(email: String) async throws { throw ApiError.invalidRequest }
    func signIn(email: String, otp: String) async throws -> SignInResult { throw ApiError.invalidRequest }
    func signOut() async throws { throw ApiError.invalidRequest }
    func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto { throw ApiError.invalidRequest }
    func item(id: String) async throws -> ItemDto { throw ApiError.invalidRequest }
    func contentUrls(itemId: String) async throws -> ContentUrlsDto { throw ApiError.invalidRequest }
    func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto {
        throw ApiError.invalidRequest
    }
    func me() async throws -> MeDto { throw ApiError.invalidRequest }
    func deleteAccount() async throws { throw ApiError.invalidRequest }
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

/// Holds callers in `wait()` until `open()`.
final class Gate: Sendable {
    private let waiters = Mutex<(open: Bool, list: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = waiters.withLock { state -> Bool in
                if state.open { return true }
                state.list.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let list = waiters.withLock { state in
            state.open = true
            defer { state.list.removeAll() }
            return state.list
        }
        for continuation in list { continuation.resume() }
    }
}

/// The App Group as the app leaves it: a migrated database, the content directories and a signed-in session.
final class AppGroupFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: "sroka-share-\(UUID().uuidString)")
    var databaseURL: URL { root.appending(path: "Database").appending(path: AppDatabase.fileName) }
    var paths: ContentPaths { ContentPaths(root: root.appending(path: "Content")) }
    let secureStore = InMemorySecureStore()
    /// The App Group account marker (`PreferencesStore.accountServer`).
    let marker = Mutex<String?>(nil)
    let environment = AppEnvironment(
        name: "Test", apiBaseURL: URL(string: "https://api.example.test")!, appGroupIdentifier: "group.test",
        keychainAccessGroup: "test.session", urlScheme: "sroka-test")

    deinit { try? FileManager.default.removeItem(at: root) }

    static let server = "https://api.example.test"

    /// The app opened once (created and migrated the file) and the user signed in.
    func appOpened(signedIn: Bool = true, deviceId: Bool = true) throws {
        _ = try AppDatabase.openShared(at: databaseURL)
        guard signedIn else { return }
        let session = SessionStore(store: secureStore)
        try session.save(token: "token", email: "reader@example.test", server: Self.server)
        marker.withLock { $0 = Self.server }
        if deviceId { _ = session.deviceId() }
    }

    /// The app signed out (`signedInAs: nil`) or another account signed in.
    func appSwitched(signedInAs token: String? = nil) throws {
        let session = SessionStore(store: secureStore)
        session.clear()
        marker.withLock { $0 = nil }
        if let token {
            try session.save(token: token, email: "other@example.test", server: Self.server)
            marker.withLock { $0 = Self.server }
        }
    }

    /// The share's account as the graph builds it, over the fixture's Keychain.
    func account() -> ShareAccount {
        let store = SessionStore(store: secureStore)
        return ShareAccount(
            launch: store.current,
            stored: { [secureStore] in SessionStore(store: secureStore).current },
            deviceId: { store.existingDeviceId() },
            accountServer: { [self] in marker.withLock { $0 } })
    }

    func graph(
        api: any SrokaAPI, clock: any Clock<Duration> = ContinuousClock(),
        endpointUsable: @escaping @Sendable () async -> Bool = { true }
    ) throws -> ShareGraph {
        ShareGraph(
            environment: environment, database: try AppDatabase.openForExtension(at: databaseURL),
            api: api, endpointUsable: endpointUsable, sessionStore: SessionStore(store: secureStore),
            account: account(),
            clockStore: FileOpClockStore(besideDatabaseAt: databaseURL), paths: paths, clock: clock)
    }

    func itemCount() async throws -> Int {
        let database = try AppDatabase.openShared(at: databaseURL)
        return try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0 }
    }

    func queuedOps() async throws -> [PendingOpRecord] {
        let database = try AppDatabase.openShared(at: databaseURL)
        return try await database.read { db in try PendingOpDao.all(db) }
    }
}

func pushAnswer(_ payloads: [String]) -> PushResponseDto {
    PushResponseDto(applied: payloads.compactMap(opId), cursor: 1)
}

func opId(_ payload: String) -> String? {
    let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    return object?["opId"] as? String
}

func type(_ payload: String) -> String? {
    let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    return object?["type"] as? String
}
