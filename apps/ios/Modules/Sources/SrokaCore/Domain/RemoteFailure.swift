/// Why a network-backed operation failed; mapped to strings in the UI.
public enum RemoteFailure: String, Sendable, Hashable, Error {
    /// No connection / timeout.
    case network
    /// Session expired (401).
    case unauthorized
    /// 429; try again later.
    case rateLimited
    /// 5xx or an unexpected response.
    case server
}
