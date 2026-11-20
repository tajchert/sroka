import Dependencies

/// Email one-time-code sign-in (api.md §2.1, DECISIONS A5/A6). Android: AuthRepository.kt.
public protocol AuthRepository: Sendable {
    /// Current session; emits immediately, then on every change.
    var session: AsyncStream<SessionState> { get }

    /// Sends a 6-digit code to `email`.
    func sendCode(email: String) async -> AuthResult

    /// Verifies `code` and stores the session token. Signing in as a different account (or server)
    /// than the one whose data is on the device wipes local data first; the same account keeps it.
    func signIn(email: String, code: String) async -> AuthResult

    /// Signs out (best-effort server call, 5 s), wipes local library data, files and pending ops.
    func signOut() async
}

public enum AuthResult: Sendable, Hashable {
    case success
    case failure(AuthError)
}

public enum AuthError: Sendable, Hashable, Error {
    case invalidEmail
    /// Wrong code (`INVALID_OTP`).
    case invalidCode
    /// `OTP_EXPIRED`: request a new code.
    case codeExpired
    /// `TOO_MANY_ATTEMPTS`: request a new code.
    case tooManyAttempts
    /// 429; `retryAfterSeconds` from `Retry-After` / `X-Retry-After` when present.
    case rateLimited(retryAfterSeconds: Int?)
    case network
    case server
}

private struct UnimplementedAuthRepository: AuthRepository {
    private func fail(_ method: String) { reportUnimplemented("AuthRepository.\(method)", key: "authRepository") }

    var session: AsyncStream<SessionState> {
        fail("session")
        return .finished
    }
    func sendCode(email: String) async -> AuthResult {
        fail("sendCode")
        return .failure(.server)
    }
    func signIn(email: String, code: String) async -> AuthResult {
        fail("signIn")
        return .failure(.server)
    }
    func signOut() async { fail("signOut") }
}

private enum AuthRepositoryKey: TestDependencyKey {
    static let testValue: any AuthRepository = UnimplementedAuthRepository()
}

extension DependencyValues {
    public var authRepository: any AuthRepository {
        get { self[AuthRepositoryKey.self] }
        set { self[AuthRepositoryKey.self] = newValue }
    }
}
