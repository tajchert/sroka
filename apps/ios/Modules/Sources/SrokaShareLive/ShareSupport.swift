import Foundation
import GRDB
import OSLog
import SrokaContent
import SrokaCore
import SrokaNetwork
import SrokaSession
import SrokaSync
import Synchronization

let shareLog = Logger(subsystem: "app.sroka", category: "share")

/// The account the sheet was opened for, checked against the Keychain item the app writes.
///
/// The app may sign out, switch account or wipe while the sheet is up; its local queue then belongs to nobody or to
/// another account. Every local write (`ShareWriteGate`, and again at commit: `ShareCommitCheck`) and every request
/// (`ShareAPI`, `ShareApiSessionProvider`) requires that the Keychain still holds the launch token. The app's wipe
/// clears the token and then the tables a second time, so a share commits before that clear (and is removed) or is
/// refused.
struct ShareAccount: Sendable {
    /// The session read once at launch.
    let launch: StoredSession?
    /// Reads the Keychain item fresh, without writing it.
    let stored: @Sendable () -> StoredSession?
    /// The stored device id, never created here.
    let deviceId: @Sendable () -> String?
    /// The App Group account marker; the wipe clears it even when deleting the Keychain item fails.
    let accountServer: @Sendable () -> String?

    /// The Keychain still holds the token the sheet was opened with (expired or not), and the account marker is set
    /// (for the launch session's server, when it recorded one).
    var isCurrent: Bool {
        guard let launch, let now = stored(), now.token == launch.token, now.server == launch.server,
            let marker = accountServer()
        else { return false }
        return launch.server == nil || launch.server == marker
    }

    /// Requests may go out: the account is current and the app has created the device id.
    var canSend: Bool { isCurrent && deviceId() != nil }
}

/// The app signed out or switched account since the sheet opened.
struct ShareAccountGone: Error {}

/// Admits the extension's local writes (`OpWriter`): only for the launch account, and none after `closeAndDrain`,
/// which waits for the admitted ones so the database is not suspended under a commit.
final class ShareWriteGate: OpWriteAdmission {
    private struct State {
        var closed = false
        var writes = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    /// Thrown by `admit` once the sheet is closing.
    struct Closed: Error {}

    private let account: ShareAccount
    private let state = Mutex(State())

    init(account: ShareAccount) {
        self.account = account
    }

    func admit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard account.isCurrent else { throw ShareAccountGone() }
        let admitted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.writes += 1
            return true
        }
        guard admitted else { throw Closed() }
        defer { finishWrite() }
        return try await body()
    }

    /// Refuses new writes and returns once the admitted ones finished.
    func closeAndDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                state.closed = true
                guard state.writes > 0 else { return true }
                state.drainWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    private func finishWrite() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.writes -= 1
            guard state.writes == 0 else { return [] }
            defer { state.drainWaiters = [] }
            return state.drainWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Rolls back any commit on the extension's connection once the launch account is gone. Inside the transaction, so
/// it is ordered against the app's wipe by SQLite's write lock (the gate's check runs before the transaction).
final class ShareCommitCheck: TransactionObserver, Sendable {
    let account: ShareAccount

    init(account: ShareAccount) {
        self.account = account
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}

    func databaseWillCommit() throws {
        guard account.isCurrent else { throw ShareAccountGone() }
    }

    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

/// The session as the extension's `SyncEngine` sees it: the Keychain item the app wrote, read once at launch, and
/// signed out once the app no longer holds it. The extension never writes the Keychain: on a 401 the ops stay queued
/// and the app, whose own push gets the same 401, marks the session expired. (A write here could race the app's
/// sign-in and overwrite its new token.)
struct ShareSyncSession: SyncSession {
    let store: SessionStore
    let account: ShareAccount

    func currentState() async -> SessionState {
        guard account.isCurrent else { return .signedOut }
        return store.current?.state ?? .signedOut
    }

    func observeState() -> AsyncStream<SessionState> { store.state }
    func markExpired() async {}
}

/// `LiveApiSessionProvider` (token bound to its issuing server and the account marker) without its one Keychain
/// write, and only for the launch account: otherwise the endpoint is not an HTTP URL, so `HTTPSrokaAPI` throws
/// `invalidRequest` before anything is sent, not even an unauthenticated request.
struct ShareApiSessionProvider: ApiSessionProvider {
    let base: LiveApiSessionProvider
    let account: ShareAccount

    /// Not an HTTP(S) origin: requests to it are refused locally.
    static let refused = URL(filePath: "/")

    func endpoint() async -> ApiEndpoint {
        let endpoint = await base.endpoint()
        guard account.canSend, let token = endpoint.token, token == account.launch?.token else {
            return ApiEndpoint(baseUrl: Self.refused, token: nil)
        }
        return ApiEndpoint(baseUrl: endpoint.baseUrl, token: token)
    }

    func baseUrl() async -> URL { await endpoint().baseUrl }
    func token() async -> String? { await endpoint().token }
    func deviceId() async -> String { account.deviceId() ?? "" }
}

/// The calls the extension makes (push, PDF and thumbnail upload), each only while the launch account is current,
/// the device id exists and the endpoint carries a token. Otherwise they throw a 401, which leaves ops and PDFs
/// queued for the app (an `invalidRequest` from the refused endpoint would fail a PDF permanently); the other calls
/// are never used here and throw `invalidRequest`.
struct ShareAPI: SrokaAPI {
    let base: any SrokaAPI
    let account: ShareAccount
    /// The provider would attach a token (server and account marker match).
    let endpointUsable: @Sendable () async -> Bool

    private func authorize() async throws {
        guard account.canSend, await endpointUsable() else {
            throw ApiError.http(status: 401, code: nil, message: nil, retryAfter: nil)
        }
    }

    func push(payloads: [String]) async throws -> PushResponseDto {
        try await authorize()
        return try await base.push(payloads: payloads)
    }

    func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto {
        try await authorize()
        return try await base.uploadPdf(
            file: file, fileName: fileName, tags: tags, source: source, onProgress: onProgress)
    }

    func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto {
        try await authorize()
        return try await base.uploadThumbnail(itemId: itemId, data: data, contentType: contentType)
    }

    func sendOtp(email: String) async throws { throw ApiError.invalidRequest }
    func signIn(email: String, otp: String) async throws -> SignInResult { throw ApiError.invalidRequest }
    func signOut() async throws { throw ApiError.invalidRequest }
    func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto { throw ApiError.invalidRequest }
    func item(id: String) async throws -> ItemDto { throw ApiError.invalidRequest }
    func contentUrls(itemId: String) async throws -> ContentUrlsDto { throw ApiError.invalidRequest }
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

/// The extension's `PdfUploader`: a PDF copied into the shared queue after the app signed out or switched account
/// is removed again (the app's wipe may already have emptied the queue).
struct SharePdfUploader: PdfUploader {
    let base: LivePdfUploader
    let account: ShareAccount

    var uploads: AsyncStream<[PdfUpload]> { base.uploads }

    func enqueue(_ fileURLs: [URL]) async -> [PdfUpload] {
        guard account.isCurrent else {
            return fileURLs.map { url in
                PdfUpload(
                    id: UUID().uuidString, fileName: url.lastPathComponent, sizeBytes: 0, state: .failed(.unknown))
            }
        }
        // Each sidecar carries the launch account's owner key: if this races a sign-out, the app never uploads the
        // file under the next account (it deletes it on resume).
        let uploads = await base.enqueue(fileURLs)
        guard account.isCurrent else {
            for upload in uploads { await base.cancel(id: upload.id) }
            return uploads.map { upload in
                var upload = upload
                if upload.isActive { upload.state = .failed(.unknown) }
                return upload
            }
        }
        return uploads
    }

    func cancel(id: String) async { await base.cancel(id: id) }
    func clearFinished() { base.clearFinished() }
}

/// `AuthRepository` for the save sheet: only `session` is used (signed out shows "Sign in to Sroka"). Signing in
/// happens in the app, so the other calls do nothing.
struct ShareAuthRepository: AuthRepository {
    let store: SessionStore

    var session: AsyncStream<SessionState> { store.state }
    func sendCode(email: String) async -> AuthResult { .failure(.server) }
    func signIn(email: String, code: String) async -> AuthResult { .failure(.server) }
    func signOut() async {}
}

/// The extension starts no background sync: the save sheet calls `ShareGraph.pushOnce` itself, and the app pushes
/// whatever is left on its next activation.
struct ShareSyncController: SyncController {
    func requestSync() {}
    func fetchNewArticles() {}
    func downloadItemNow(itemId: String) {}
}

extension StoredSession {
    fileprivate var state: SessionState { expired ? .expired(email: email) : .signedIn(email: email) }
}

/// Waits for `operation` at most `timeout`, or until the caller is cancelled, then returns. The operation is
/// cancelled and left to finish on its own; an already-cancelled caller does not start it.
func withTimeout(
    _ timeout: Duration,
    clock: any Clock<Duration>,
    _ operation: @escaping @Sendable () async -> Void
) async {
    if Task.isCancelled { return }
    let gate = Mutex<(waiter: CheckedContinuation<Void, Never>?, done: Bool)>((nil, false))
    let finish: @Sendable () -> Void = {
        let waiter = gate.withLock { state -> CheckedContinuation<Void, Never>? in
            state.done = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
    let work = Task {
        await operation()
        finish()
    }
    let timer = Task {
        try? await clock.sleep(for: timeout)
        finish()
    }
    await withTaskCancellationHandler {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let resumeNow = gate.withLock { state -> Bool in
                if state.done { return true }
                state.waiter = waiter
                return false
            }
            if resumeNow { waiter.resume() }
        }
    } onCancel: {
        finish()
    }
    work.cancel()
    timer.cancel()
}
