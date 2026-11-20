import Foundation
import SrokaCore
import SrokaNetwork
import Synchronization

/// `PushRegistrar` over `PUT`/`DELETE /v1/push-token` (D17). Android: PlayPushRegistrar.kt.
///
/// The device token lives in the App Group suite (it belongs to the install); the record of the last successful
/// registration names the account it was made for and goes with the sign-out wipe.
///
/// Races it closes:
/// - Calls run one at a time and each reads the latest device token when it runs, so an older token never replaces a
///   newer one on the server.
/// - `unregister()` revokes the current session at once, before it waits its turn: a registration queued during the
///   sign-out (a sign-in's late task, a token callback) finds the session revoked and sends nothing.
/// - A registration whose session changed while the request was in flight records nothing, so a late success for one
///   account never makes the next account skip its own registration.
public final class LivePushRegistrar: PushRegistrar {
    /// A registration of the same token is repeated after this long, so the server row stays fresh.
    public static let refreshInterval: Int64 = 7 * 24 * 60 * 60 * 1000

    /// The usable session a registration is made for.
    public struct Session: Sendable, Hashable {
        /// The account the device is registered for (`StoredSession.ownerKey`: server and email).
        public var owner: String
        /// Tells two sign-ins of the same account apart.
        public var token: String

        public init(owner: String, token: String) {
            self.owner = owner
            self.token = token
        }
    }

    private let api: any SrokaAPI
    private let preferences: PreferencesStore
    private let environment: PushEnvironment
    private let session: @Sendable () -> Session?
    private let now: @Sendable () -> Int64
    private let gate = SerialGate()
    /// The session token a sign-out is removing; no registration is made for it again.
    private let revoked = Mutex<String?>(nil)

    /// - Parameters:
    ///   - environment: APNs environment and topic of this build, sent with every registration.
    ///   - session: the stored session when it is usable (not expired, no wipe running), else nil.
    ///   - now: Unix milliseconds.
    public init(
        api: any SrokaAPI,
        preferences: PreferencesStore,
        environment: PushEnvironment,
        session: @escaping @Sendable () -> Session?,
        now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    ) {
        self.api = api
        self.preferences = preferences
        self.environment = environment
        self.session = session
        self.now = now
    }

    public func deviceTokenReceived(_ token: String) {
        let token = token.lowercased()
        guard Self.isValidToken(token) else {
            sessionLog.error("Push: ignoring a malformed device token")
            return
        }
        preferences.apnsDeviceToken = token
    }

    public func register() async {
        await gate.run { await registerLocked() }
    }

    public func unregister() async {
        // At once, not when this call's turn comes: everything queued behind a sign-out sees it.
        if let token = session()?.token { revoked.withLock { $0 = token } }
        await gate.run {
            // No token ever arrived: this install was never registered.
            guard preferences.apnsDeviceToken != nil || preferences.pushRegistration != nil else { return }
            do {
                try await api.deletePushToken()
            } catch {
                sessionLog.notice("Push: unregister failed: \(Self.describe(error), privacy: .public)")
            }
            preferences.pushRegistration = nil
        }
    }

    private func registerLocked() async {
        guard let current = usableSession(), let token = preferences.apnsDeviceToken else { return }
        let at = now()
        guard Self.needsRegistration(token: token, owner: current.owner, record: preferences.pushRegistration, now: at)
        else { return }
        do {
            try await api.putPushToken(.apns(token: token, environment: environment))
        } catch {
            sessionLog.notice("Push: register failed: \(Self.describe(error), privacy: .public)")
            return
        }
        // Signed out, revoked or another account meanwhile: the server row (if any) is the next call's business.
        guard usableSession() == current else {
            sessionLog.notice("Push: registration result dropped: the session changed during the request")
            return
        }
        preferences.pushRegistration = PushRegistrationRecord(token: token, owner: current.owner, registeredAtMs: at)
        sessionLog.info("Push: device registered")
    }

    private func usableSession() -> Session? {
        guard let current = session() else { return nil }
        return revoked.withLock { $0 } == current.token ? nil : current
    }

    // MARK: Rules

    /// True unless `record` holds the same token for the same account, registered less than `refreshInterval` ago.
    static func needsRegistration(token: String, owner: String, record: PushRegistrationRecord?, now: Int64) -> Bool {
        guard let record, record.token == token, record.owner == owner else { return true }
        let age = now - record.registeredAtMs
        // A clock set back makes the age negative: register rather than trust it.
        return age < 0 || age >= refreshInterval
    }

    /// Lowercase hex, 1...4096 characters (the server's limit).
    static func isValidToken(_ token: String) -> Bool {
        (1...4096).contains(token.utf8.count)
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Lowercase hex of the APNs device token bytes.
    public static func hex(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: any Error) -> String {
        if let api = error as? ApiError, case .http(let status, _, _, _) = api { return "http \(status)" }
        return String(describing: type(of: error))
    }
}
