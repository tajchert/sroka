import Foundation
import SrokaCore
import Synchronization

/// The session as stored on the device.
public struct StoredSession: Sendable, Hashable {
    public var token: String
    public var email: String
    public var expired: Bool

    public init(token: String, email: String, expired: Bool) {
        self.token = token
        self.email = email
        self.expired = expired
    }

    var state: SessionState { expired ? .expired(email: email) : .signedIn(email: email) }
}

/// Session token, signed-in email, expired flag and the install's device id, all in the Keychain (shared access group,
/// so the share extension reads the same session). Android: SessionStore.kt.
///
/// The token, email and flag are one Keychain item, written atomically. The device id is a separate item that sign-out
/// never touches. A session that cannot be read (Keychain unavailable, corrupt item) reads as signed out; local library
/// data is untouched.
public final class SessionStore: Sendable {
    static let sessionKey = "session"
    static let deviceIdKey = "device_id"
    static let devicePrefix = "ios_"

    private struct Stored: Codable {
        var token: String
        var email: String
        var expired: Bool
    }

    private let store: any SecureStore
    private let now: @Sendable () -> Date
    private let value: CurrentValue<StoredSession?>
    /// Serialises writes and device id creation.
    private let lock = Mutex<String?>(nil)

    public init(store: any SecureStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        value = CurrentValue(Self.load(store))
    }

    /// Current session state; emits immediately, then on every change.
    public var state: AsyncStream<SessionState> {
        let source = value.stream()
        return AsyncStream { continuation in
            let task = Task {
                var last: SessionState?
                for await stored in source {
                    let state = stored?.state ?? .signedOut
                    if state != last { continuation.yield(state) }
                    last = state
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var current: StoredSession? { value.value }

    public var token: String? { value.value?.token }

    /// Re-reads the Keychain (the share extension may have marked the session expired).
    public func reload() {
        lock.withLock { _ in value.send(Self.load(store)) }
    }

    /// Stores a fresh session (also clears the expired flag). Throws when the Keychain refuses the write.
    public func save(token: String, email: String) throws {
        try lock.withLock { _ in
            let session = StoredSession(token: token, email: email, expired: false)
            try write(session)
            value.send(session)
        }
    }

    /// The server rejected the token (401): keep the email and data so the UI can ask to sign in again.
    public func markExpired() {
        lock.withLock { _ in
            guard var session = value.value, !session.expired else { return }
            // The app and the share extension share the item: if the other process signed out or in since this value
            // was cached, adopt what is stored instead of writing the old token back.
            let stored = Self.load(store)
            guard stored?.token == session.token else {
                value.send(stored)
                return
            }
            session.expired = true
            do {
                try write(session)
            } catch {
                sessionLog.error("Could not persist the expired flag: \(error.localizedDescription, privacy: .public)")
            }
            value.send(session)
        }
    }

    /// Signs out locally: removes the token and email. The device id is kept.
    public func clear() {
        lock.withLock { _ in
            do {
                try store.delete(Self.sessionKey)
            } catch {
                sessionLog.error("Could not delete the session item: \(error.localizedDescription, privacy: .public)")
            }
            value.send(nil)
        }
    }

    /// `ios_<uuidv7>`, generated once per install and never changed (not even by sign-out).
    public func deviceId() -> String {
        lock.withLock { cached in
            if let cached { return cached }
            if let stored = try? store.read(Self.deviceIdKey), stored.hasPrefix(Self.devicePrefix) {
                cached = stored
                return stored
            }
            let created = Self.devicePrefix + UUIDv7.next(at: now())
            do {
                try store.write(Self.deviceIdKey, value: created)
            } catch {
                // Keep the id for this process anyway; the next launch retries the write.
                sessionLog.error("Could not persist the device id: \(error.localizedDescription, privacy: .public)")
            }
            cached = created
            return created
        }
    }

    private func write(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(
            Stored(token: session.token, email: session.email, expired: session.expired))
        try store.write(Self.sessionKey, value: String(decoding: data, as: UTF8.self))
    }

    private static func load(_ store: any SecureStore) -> StoredSession? {
        let raw: String?
        do {
            raw = try store.read(sessionKey)
        } catch {
            sessionLog.error("Session item unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let raw, let stored = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8)),
            !stored.token.isEmpty, !stored.email.isEmpty
        else { return nil }
        return StoredSession(token: stored.token, email: stored.email, expired: stored.expired)
    }
}
