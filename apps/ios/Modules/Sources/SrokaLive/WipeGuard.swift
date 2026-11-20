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
public final class WipeGuard: Sendable {
    private let depth = Mutex(0)

    public init() {}

    public var isWiping: Bool { depth.withLock { $0 > 0 } }

    /// Runs `body` with the guard raised. Nested and concurrent wipes keep it raised until the last one ends.
    public func during<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        depth.withLock { $0 += 1 }
        defer { depth.withLock { $0 -= 1 } }
        return await body()
    }
}

/// Wraps the session module's wiper so the guard is up for the whole wipe, before its first step.
public struct GuardedWiper: LocalDataWiping {
    private let inner: any LocalDataWiping
    private let wipeGuard: WipeGuard

    public init(_ inner: any LocalDataWiping, guard wipeGuard: WipeGuard) {
        self.inner = inner
        self.wipeGuard = wipeGuard
    }

    @discardableResult public func wipe() async -> Bool {
        let inner = inner
        return await wipeGuard.during { await inner.wipe() }
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
