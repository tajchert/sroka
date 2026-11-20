/// Authentication state of the app (DECISIONS A3).
public enum SessionState: Sendable, Hashable {
    case signedOut
    case signedIn(email: String)
    /// The server rejected the token (401). Local data is kept; the user is asked to sign in again.
    case expired(email: String)

    public var email: String? {
        switch self {
        case .signedOut: nil
        case .signedIn(let email), .expired(let email): email
        }
    }
}

/// Outcome of saving a URL locally.
public enum SaveResult: Sendable, Hashable {
    /// Saved (or re-added when `alreadySaved`) as item `itemId`.
    case saved(itemId: String, alreadySaved: Bool)
    /// Not an http(s) URL.
    case invalidUrl
}
