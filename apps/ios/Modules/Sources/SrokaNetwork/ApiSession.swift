import Foundation

/// What the API client needs to know about the current session. The session stream implements this later (token
/// in the Keychain, base URL from settings); the network layer never touches storage itself.
public protocol ApiSessionProvider: Sendable {
    /// Server origin without a trailing path, e.g. `https://api.sroka.app` or `http://localhost:8787`.
    func baseUrl() async -> URL
    /// Bearer token, or nil when signed out. Sent verbatim (it contains `.` and may contain `=`).
    func token() async -> String?
    /// `ios_<uuidv7>`, generated once per install and kept across sign-out. Sent as `X-Sroka-Device`.
    func deviceId() async -> String
    /// Base URL and token taken from ONE snapshot of the session and settings, so a request can never pair one
    /// server's URL with another server's token. Every API request uses this, not `baseUrl()` + `token()`.
    func endpoint() async -> ApiEndpoint
}

/// Where a request goes and which token (if any) it carries, read together.
public struct ApiEndpoint: Sendable, Hashable {
    public var baseUrl: URL
    public var token: String?

    public init(baseUrl: URL, token: String?) {
        self.baseUrl = baseUrl
        self.token = token
    }
}

extension ApiSessionProvider {
    /// For providers whose base URL never changes (tests). A provider whose server can change at runtime must
    /// implement `endpoint()` itself and read both values from one snapshot.
    public func endpoint() async -> ApiEndpoint {
        ApiEndpoint(baseUrl: await baseUrl(), token: await token())
    }
}

/// Static client identity sent as `User-Agent: Sroka-iOS/<version>`.
public struct ClientIdentity: Sendable, Hashable {
    public var userAgent: String

    public init(appVersion: String) { userAgent = "Sroka-iOS/\(appVersion)" }
}

/// Result of a successful sign-in.
public struct SignInResult: Sendable, Equatable {
    /// The verbatim `set-auth-token` response header value.
    public var token: String
    public var userEmail: String

    public init(token: String, userEmail: String) {
        self.token = token
        self.userEmail = userEmail
    }
}

/// A finished export download (the file is at the destination given to `SrokaAPI.export`).
public struct ExportFile: Sendable, Equatable {
    /// Bare file name from `Content-Disposition`, or `sroka-export-YYYY-MM-DD.<ext>`.
    public var fileName: String
    public var bytes: Int64

    public init(fileName: String, bytes: Int64) {
        self.fileName = fileName
        self.bytes = bytes
    }
}

/// Reports `(bytesDone, bytesTotal)`; total is -1 when unknown.
public typealias ByteProgress = @Sendable (_ done: Int64, _ total: Int64) -> Void
