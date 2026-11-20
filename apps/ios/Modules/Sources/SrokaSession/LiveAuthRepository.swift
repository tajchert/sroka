import Foundation
import GRDB
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization

/// Email one-time-code sign-in (api.md §2.1, DECISIONS A5/A6). Android: AuthRepositoryImpl.kt.
///
/// A 401 anywhere else only marks the session expired (`markSessionExpired()`); library data is kept.
public final class LiveAuthRepository: AuthRepository {
    public static let signOutTimeout: Duration = .seconds(5)

    private let api: any SrokaAPI
    private let sessionStore: SessionStore
    private let preferences: PreferencesStore
    private let provider: LiveApiSessionProvider
    private let wiper: any LocalDataWiping
    private let hasLocalData: @Sendable () async -> Bool
    private let requestSync: @Sendable () -> Void
    private let clock: any Clock<Duration>
    /// Sign-in completion, sign-out, wipes and server switches never interleave.
    private let gate = SerialGate()
    /// Bumped by every sign-out or wipe, so a sign-in that was in flight across one does not restore a session.
    private let generation = Mutex(0)

    /// - Parameters:
    ///   - hasLocalData: true when the database holds items or pending ops (`LiveAuthRepository.hasAccountData(in:)`).
    ///   - requestSync: starts a sync after sign-in.
    public init(
        api: any SrokaAPI,
        sessionStore: SessionStore,
        preferences: PreferencesStore,
        provider: LiveApiSessionProvider,
        wiper: any LocalDataWiping,
        hasLocalData: @escaping @Sendable () async -> Bool,
        requestSync: @escaping @Sendable () -> Void,
        clock: any Clock<Duration>
    ) {
        self.api = api
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.provider = provider
        self.wiper = wiper
        self.hasLocalData = hasLocalData
        self.requestSync = requestSync
        self.clock = clock
    }

    public var session: AsyncStream<SessionState> { sessionStore.state }

    public func sendCode(email: String) async -> AuthResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(address) else { return .failure(.invalidEmail) }
        switch await apiCall({ try await api.sendOtp(email: address) }) {
        case .success: return .success
        case .failure(let error): return .failure(Self.authError(error))
        }
    }

    public func signIn(email: String, code: String) async -> AuthResult {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(address) else { return .failure(.invalidEmail) }
        let otp = String(code.filter { !$0.isWhitespace })
        guard !otp.isEmpty else { return .failure(.invalidCode) }
        // Generation before server: a switch bumps the generation before it changes the server, so any switch that
        // could redirect this request either changes the generation read here or leaves the server read below stale.
        let started = generation.withLock { $0 }
        let server = provider.currentServer()
        switch await apiCall({ try await api.signIn(email: address, otp: otp) }) {
        case .failure(let error):
            return .failure(Self.authError(error))
        case .success(let result):
            // The token is valid on the server now: finish storing it even if the caller goes away.
            return await Task {
                await gate.run {
                    // The token belongs to the server that issued it; drop it if the user switched servers or signed
                    // out meanwhile.
                    guard provider.currentServer() == server, generation.withLock({ $0 }) == started else {
                        sessionLog.notice("Sign-in result dropped: server or session changed during the request")
                        return .failure(.server)
                    }
                    return await finishSignIn(result, address: address, server: server)
                }
            }.value
        }
    }

    private func finishSignIn(_ result: SignInResult, address: String, server: String) async -> AuthResult {
        let trimmedEmail = result.userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let signedInAs = trimmedEmail.isEmpty ? address : trimmedEmail
        let owner = preferences.accountEmail ?? sessionStore.current?.email
        let dataServer = preferences.accountServer
        let otherAccount: Bool
        if let owner {
            // Same email on a different server is a different account.
            otherAccount =
                owner.caseInsensitiveCompare(signedInAs) != .orderedSame || (dataServer != nil && dataServer != server)
        } else {
            otherAccount = await hasLocalData()
        }
        if otherAccount {
            // Never show the previous account's rows or send its queued ops under the new account.
            guard await wipeLocked() else { return .failure(.server) }
        }
        do {
            try sessionStore.save(token: result.token, email: signedInAs, server: server)
        } catch {
            sessionLog.error("Could not store the session: \(String(describing: error), privacy: .public)")
            return .failure(.server)
        }
        preferences.accountEmail = signedInAs
        preferences.accountServer = server
        requestSync()
        return .success
    }

    public func signOut() async {
        await gate.run { await signOutLocked() }
    }

    /// Wipes local data and the session. Also used after account deletion.
    public func clearLocal() async {
        await gate.run { _ = await wipeLocked() }
    }

    /// Runs `finish` (completing a wipe that a dead process left) under the transition gate, so it never runs beside a
    /// sign-out, a wipe or a sign-in's completion.
    public func finishInterruptedWipe(_ finish: @escaping @Sendable () async -> Void) async {
        await gate.run { await finish() }
    }

    /// Marks the current account state; pass it to `clearLocal(ifUnchangedSince:)`.
    public func transitionMark() -> Int { generation.withLock { $0 } }

    /// The transition mark and `pin()` (a snapshot of the current credentials) taken together under the transition
    /// gate: no wipe or sign-in is halfway through, so both belong to the same account.
    public func transitionMark<T: Sendable>(pinning pin: @escaping @Sendable () async -> T) async -> (
        mark: Int, pinned: T
    ) {
        await gate.run { (generation.withLock { $0 }, await pin()) }
    }

    /// Wipes like `clearLocal()`, but only if no sign-out, wipe, server switch or sign-in as another account (which
    /// wipes) happened since `mark`: a late answer for one account never clears the next one's data.
    public func clearLocal(ifUnchangedSince mark: Int) async {
        await gate.run {
            guard generation.withLock({ $0 }) == mark else {
                sessionLog.notice("Local clear skipped: the account changed meanwhile")
                return
            }
            _ = await wipeLocked()
        }
    }

    /// Switches the server with `apply`, signing out (revoke against the old server, then wipe) first when a session
    /// exists. Runs under the transition gate so no sign-in completes between the two.
    public func switchServer(_ apply: @escaping @Sendable () -> Void) async {
        await gate.run {
            if sessionStore.current != nil { await signOutLocked() }
            // A sign-in in flight belongs to the old server even if the user switches back before it returns.
            generation.withLock { $0 += 1 }
            apply()
        }
    }

    private func signOutLocked() async {
        // Best effort: never block sign-out on the network. The token is still stored, so the call carries it.
        let api = api
        await runWithTimeout(Self.signOutTimeout, clock: clock) { _ = try? await api.signOut() }
        _ = await wipeLocked()
    }

    private func wipeLocked() async -> Bool {
        generation.withLock { $0 += 1 }
        return await wiper.wipe()
    }

    /// The 401 entry point for the sync, content and upload engines: marks the session expired and keeps all data.
    public func markSessionExpired() {
        sessionStore.markExpired()
    }

    // MARK: Rules

    /// `^[^\s@]+@[^\s@]+\.[^\s@]+$`, at most 254 characters.
    public static func isValidEmail(_ email: String) -> Bool {
        guard email.count <= 254 else { return false }
        return email.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil
    }

    static func authError(_ error: ApiError) -> AuthError {
        switch error {
        case .transport: return .network
        case .malformedResponse, .invalidRequest: return .server
        case .http(let status, let code, _, let retryAfter):
            if status == 429 {
                return .rateLimited(retryAfterSeconds: retryAfter.flatMap { Int(exactly: $0.rounded(.up)) })
            }
            switch code {
            case "INVALID_OTP": return .invalidCode
            case "OTP_EXPIRED": return .codeExpired
            case "TOO_MANY_ATTEMPTS": return .tooManyAttempts
            case "INVALID_EMAIL": return .invalidEmail
            default: return .server
            }
        }
    }
}

extension LiveAuthRepository {
    /// `hasLocalData` for the app database: any item or pending op. An unreadable database counts as holding data,
    /// so a sign-in with no recorded owner wipes rather than risks showing someone else's library.
    public static func hasAccountData(in database: AppDatabase) async -> Bool {
        do {
            return try await database.read { db in
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM items) OR EXISTS(SELECT 1 FROM pending_ops)") ?? true
            }
        } catch {
            return true
        }
    }
}
