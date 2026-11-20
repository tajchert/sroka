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
