import Foundation
import SrokaCore
import SrokaSession
import SrokaSync
import Synchronization

/// Marks the time a local wipe (sign-out, account switch, account deletion, server switch) is running.
///
/// The wipe clears the tables inside the sync engine but removes the token only at its end. In between, a sync
/// requested by a late write would still see a signed-in session and pull the old account's library back. While
/// `isWiping` is true the sync session reads as signed out and no automatic downloads start.
///
/// It also admits local writes (`OpWriter`): none start while the guard is up, and `drainWrites()` waits for the ones
/// admitted before it went up, so no old-account op commits after the tables are cleared.
public final class WipeGuard: OpWriteAdmission {
    private struct State {
        var depth = 0
        var writes = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    /// Thrown by `admit` while a wipe runs.
    public struct LocalWritesClosed: Error {}

    private let state = Mutex(State())

    public init() {}

    public var isWiping: Bool { state.withLock { $0.depth > 0 } }

    /// Runs `body` with the guard raised. Nested and concurrent wipes keep it raised until the last one ends.
    public func during<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        state.withLock { $0.depth += 1 }
        defer { state.withLock { $0.depth -= 1 } }
        return await body()
    }

    public func admit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let admitted = state.withLock { state -> Bool in
            guard state.depth == 0 else { return false }
            state.writes += 1
            return true
        }
        guard admitted else { throw LocalWritesClosed() }
        defer { finishWrite() }
        return try await body()
    }

    /// Returns once no admitted write is running. Call with the guard raised, so none can start meanwhile.
    public func drainWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
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

/// Wraps the session module's wiper so the guard is up for the whole wipe, before its first step, and the database
/// stays running (not suspended for 0xDEAD10CC) until the wipe ends, even if the app moves to the background.
public struct GuardedWiper: LocalDataWiping {
    private let inner: any LocalDataWiping
    private let wipeGuard: WipeGuard
    private let suspension: SuspensionGate?

    public init(_ inner: any LocalDataWiping, guard wipeGuard: WipeGuard, suspension: SuspensionGate? = nil) {
        self.inner = inner
        self.wipeGuard = wipeGuard
        self.suspension = suspension
    }

    @discardableResult public func wipe() async -> Bool {
        let inner = inner
        return await guarded { await inner.wipe() }
    }

    /// Runs another wipe entry point (finishing an interrupted wipe) the same way: guard up, database held.
    @discardableResult public func guarded(_ body: @Sendable () async -> Bool) async -> Bool {
        let hold = suspension?.hold()
        defer { hold?.release() }
        return await wipeGuard.during { await body() }
    }
}

/// The session as the sync engine sees it: the Keychain session store, read as signed out while a wipe runs.
public struct LiveSyncSession: SyncSession {
    private let store: SessionStore
    private let wipeGuard: WipeGuard

    public init(store: SessionStore, guard wipeGuard: WipeGuard) {
        self.store = store
        self.wipeGuard = wipeGuard
    }

    public func currentState() async -> SessionState {
        if wipeGuard.isWiping { return .signedOut }
        guard let session = store.current else { return .signedOut }
        return session.expired ? .expired(email: session.email) : .signedIn(email: session.email)
    }

    public func observeState() -> AsyncStream<SessionState> { store.state }

    /// A 401 from a pass: keep every row. Ignored during a wipe, which is about to remove the session anyway.
    public func markExpired() async {
        if wipeGuard.isWiping { return }
        store.markExpired()
    }
}
