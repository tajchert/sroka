import Foundation
import OSLog
import SrokaCore
import SrokaNetwork
import SrokaSession
import SrokaSync
import Synchronization

let shareLog = Logger(subsystem: "app.sroka", category: "share")

/// The session as the extension's `SyncEngine` sees it: the Keychain item the app wrote, read once at launch.
/// The extension never writes the Keychain: on a 401 the ops stay queued and the app, whose own push gets the
/// same 401, marks the session expired. (A write here could race the app's sign-in and overwrite its new token.)
struct ShareSyncSession: SyncSession {
    let store: SessionStore

    func currentState() async -> SessionState { store.current?.state ?? .signedOut }
    func observeState() -> AsyncStream<SessionState> { store.state }
    func markExpired() async {}
}

/// `LiveApiSessionProvider` without its one Keychain write: the device id must already exist (the app creates it
/// at sign-in). Without it no token is sent, and `ShareGraph` skips the network altogether.
///
/// Token and server stay one snapshot: the token comes from the session cached at launch (never re-read, since
/// nothing here calls `reload` or `markExpired`), and `LiveApiSessionProvider` withholds it unless the live account
/// marker matches the server the extension sends to.
struct ShareApiSessionProvider: ApiSessionProvider {
    let base: LiveApiSessionProvider
    let store: SessionStore

    func baseUrl() async -> URL { await base.baseUrl() }

    func token() async -> String? {
        guard store.existingDeviceId() != nil else { return nil }
        return await base.token()
    }

    func deviceId() async -> String { store.existingDeviceId() ?? "" }
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
