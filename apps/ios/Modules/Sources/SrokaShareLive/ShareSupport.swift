import Foundation
import OSLog
import SrokaCore
import SrokaSession
import SrokaSync
import Synchronization

let shareLog = Logger(subsystem: "app.sroka", category: "share")

/// The session as the extension's `SyncEngine` sees it: the Keychain item the app wrote. A 401 marks it expired
/// (shared with the app, which then asks the user to sign in again); the extension never signs in or refreshes.
struct ShareSyncSession: SyncSession {
    let store: SessionStore

    func currentState() async -> SessionState { store.current?.state ?? .signedOut }
    func observeState() -> AsyncStream<SessionState> { store.state }
    func markExpired() async { store.markExpired() }
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

/// Waits for `operation` at most `timeout`, then returns; the operation is cancelled and left to finish on its own.
func withTimeout(
    _ timeout: Duration,
    clock: any Clock<Duration>,
    _ operation: @escaping @Sendable () async -> Void
) async {
    let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let resumeOnce: @Sendable () -> Void = {
        gate.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }
    var tasks: [Task<Void, Never>] = []
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        gate.withLock { $0 = continuation }
        tasks.append(
            Task {
                await operation()
                resumeOnce()
            })
        tasks.append(
            Task {
                try? await clock.sleep(for: timeout)
                resumeOnce()
            })
    }
    for task in tasks { task.cancel() }
}
