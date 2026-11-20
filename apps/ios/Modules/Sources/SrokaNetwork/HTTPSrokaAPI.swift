import Foundation
import SrokaCore

/// `SrokaAPI` over `URLSession`.
///
/// Rules that matter (docs/plan server contract):
/// - Never an `Origin` header (the server would treat the call as the web app and fail with 400 TURNSTILE_FAILED).
///   `URLSession` adds none; nothing here sets one. Cookies are switched off too (Better Auth also sets cookies).
/// - API calls send `Authorization: Bearer`, `X-Sroka-Device` and `User-Agent: Sroka-iOS/<version>`.
///   Content-host downloads send the `User-Agent` only.
public final class HTTPSrokaAPI: SrokaAPI {
    /// Timeout for sign-out: best effort, the app wipes locally afterwards regardless.
    static let signOutTimeout: TimeInterval = 5
    /// Per-request inactivity timeout for uploads (large files on slow links).
    static let uploadTimeout: TimeInterval = 300

    private let session: URLSession
    private let provider: any ApiSessionProvider
    private let identity: ClientIdentity
    private let now: @Sendable () -> Date

    /// `session` defaults to `makeSession()`; tests pass one whose `protocolClasses` is a stub.
    public init(
        provider: any ApiSessionProvider,
        identity: ClientIdentity,
        session: URLSession = HTTPSrokaAPI.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.identity = identity
        self.session = session
        self.now = now
    }

    /// Ephemeral session without cookies or caches.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    // MARK: Auth

    public func sendOtp(email: String) async throws {
        let request = try await apiRequest(
            "POST", "/api/auth/email-otp/send-verification-otp",
            json: SendOtpBody(email: email, type: "sign-in"))
        _ = try await perform(request)
    }

    public func signIn(email: String, otp: String) async throws -> SignInResult {
        let request = try await apiRequest(
            "POST", "/api/auth/sign-in/email-otp", json: SignInBody(email: email, otp: otp))
        let (data, response) = try await perform(request)
        guard let token = response.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty else {
            throw ApiError.malformedResponse
        }
        let signedInEmail = (try? JSONDecoder().decode(SignInResponse.self, from: data))?.user?.email
        return SignInResult(token: token, userEmail: signedInEmail ?? email)
    }

    public func signOut() async throws {
        let request = try await apiRequest(
            "POST", "/api/auth/sign-out", rawBody: Data("{}".utf8), timeout: Self.signOutTimeout)
        _ = try await perform(request)
    }

    // MARK: Sync

    public func push(payloads: [String]) async throws -> PushResponseDto {
        guard payloads.count <= Limits.maxOpsPerPush else { throw ApiError.invalidRequest }
        // The ops go out exactly as the canonical payloads were stored: no decode/re-encode round trip.
        let deviceId = await provider.deviceId()
        guard let device = try? JSONEncoder().encode(deviceId), let deviceJson = String(data: device, encoding: .utf8)
        else {
            throw ApiError.invalidRequest
        }
        let body = Data("{\"deviceId\":\(deviceJson),\"ops\":[\(payloads.joined(separator: ","))]}".utf8)
        let request = try await apiRequest("POST", "/v1/sync/push", rawBody: body)
        return try decode(try await perform(request).data)
    }

    public func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto {
        var query = [("cursor", String(cursor)), ("limit", String(limit))]
        if full { query.append(("full", "1")) }
        let request = try await apiRequest("GET", "/v1/sync/pull", query: query)
        return try decode(try await perform(request).data)
    }

    // MARK: Items

    public func item(id: String) async throws -> ItemDto {
        let request = try await apiRequest("GET", "/v1/items/\(Self.segment(id))")
        let data = try await perform(request).data
        return (try decode(data) as ItemEnvelope).item
    }

    public func contentUrls(itemId: String) async throws -> ContentUrlsDto {
        let request = try await apiRequest("GET", "/v1/items/\(Self.segment(itemId))/content")
        return try decode(try await perform(request).data)
    }

    public func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto {
        var query = [("name", fileName), ("source", source == .unknown ? "api" : source.rawValue)]
        query.append(contentsOf: tags.map { ("tag", $0) })
        var request = try await apiRequest(
            "POST", "/v1/items/pdf", query: query, timeout: Self.uploadTimeout)
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        return try decode(try await perform(request, uploadFile: file, progress: onProgress).data)
    }

    public func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto {
        guard contentType == "image/webp" || contentType == "image/jpeg", data.count <= Limits.maxThumbnailBytes else {
            throw ApiError.invalidRequest
        }
        var request = try await apiRequest(
            "PUT", "/v1/items/\(Self.segment(itemId))/thumbnail", rawBody: data, timeout: Self.uploadTimeout)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let responseData = try await perform(request).data
        return (try decode(responseData) as ItemEnvelope).item
    }

    // MARK: Account

    public func me() async throws -> MeDto {
        let request = try await apiRequest("GET", "/v1/me")
        return try decode(try await perform(request).data)
    }

    public func deleteAccount() async throws {
        let request = try await apiRequest("DELETE", "/v1/account", json: DeleteAccountBody(confirm: "DELETE"))
        _ = try await perform(request)
    }

    public func config() async throws -> ConfigDto {
        let request = try await apiRequest("GET", "/v1/config")
        return try decode(try await perform(request).data)
    }

    // MARK: Import / export

    public func createImport(
        source: URL, fileName: String, mimeType: String, format: ImportFormat
    ) async throws -> JobDto {
        // Endpoint first: the caller checked the session just before, and building the body can take a while.
        var request = try await apiRequest("POST", "/v1/imports", timeout: Self.uploadTimeout)
        let body = try MultipartBody.make(
            fields: [("format", format.rawValue)], fileField: "file", fileName: fileName, mimeType: mimeType,
            source: source)
        defer { try? FileManager.default.removeItem(at: body.fileURL) }
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await perform(request, uploadFile: body.fileURL).data
        return (try decode(data) as JobEnvelope).job
    }

    public func importJob(id: String) async throws -> JobDto {
        let request = try await apiRequest("GET", "/v1/imports/\(Self.segment(id))")
        return (try decode(try await perform(request).data) as JobEnvelope).job
    }

    public func export(format: ExportFormat, to destination: URL) async throws -> ExportFile {
        let request = try await apiRequest("GET", "/v1/exports", query: [("format", format.rawValue)])
        let (bytes, response) = try await downloadFile(request, to: destination, progress: nil)
        let name = exportFileName(
            header: response.value(forHTTPHeaderField: "Content-Disposition"), format: format, today: now())
        return ExportFile(fileName: name, bytes: bytes)
    }

    // MARK: Content host

    public func download(from url: URL, to destination: URL, onProgress: ByteProgress?) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            throw ApiError.invalidRequest
        }
        // Signed URL on the content host: User-Agent only. No Authorization, no X-Sroka-Device.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        // Signed URLs may redirect to a storage host: no credentials go with them.
        _ = try await downloadFile(request, to: destination, progress: onProgress, sameOriginOnly: false)
    }

    // MARK: Plumbing

    /// Request to the API host with the three identity headers.
    private func apiRequest(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        rawBody: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> URLRequest {
        // One snapshot: the token always belongs to the server the request goes to.
        let endpoint = await provider.endpoint()
        let base = endpoint.baseUrl
        guard let scheme = base.scheme?.lowercased(), scheme == "https" || scheme == "http",
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw ApiError.invalidRequest }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        components.percentEncodedQuery =
            query.isEmpty ? nil : query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        guard let url = components.url else { throw ApiError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(await provider.deviceId(), forHTTPHeaderField: "X-Sroka-Device")
        if let token = endpoint.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let rawBody {
            request.httpBody = rawBody
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func apiRequest<Body: Encodable>(
        _ method: String, _ path: String, json body: Body
    ) async throws -> URLRequest {
        guard let data = try? JSONEncoder().encode(body) else { throw ApiError.invalidRequest }
        return try await apiRequest(method, path, rawBody: data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ApiError.malformedResponse }
    }

    /// Sends the request (with `uploadFile` as the body when given) and returns a 2xx answer.
    private func perform(
        _ request: URLRequest, uploadFile: URL? = nil, progress: ByteProgress? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        do {
            let data: Data
            let response: URLResponse
            // API requests carry a token or an OTP: never follow a redirect to another origin, and never accept an answer
            // (such as a sign-in token) from a server other than the one the request was made to.
            let delegate = ProgressDelegate(progress, sameOriginOnly: true)
            if let uploadFile {
                (data, response) = try await session.upload(for: request, fromFile: uploadFile, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse, Self.sameOrigin(http.url, request.url) else {
                throw ApiError.malformedResponse
            }
            guard (200..<300).contains(http.statusCode) else { throw ErrorParsing.error(from: http, body: data) }
            return (data, http)
        } catch {
            throw Self.map(error)
        }
    }

    /// Downloads to a temporary file, then moves it onto `destination` (replacing it). Returns bytes written.
    private func downloadFile(
        _ request: URLRequest, to destination: URL, progress: ByteProgress?, sameOriginOnly: Bool = true
    ) async throws -> (bytes: Int64, response: HTTPURLResponse) {
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(
                for: request, delegate: ProgressDelegate(progress, sameOriginOnly: sameOriginOnly))
        } catch {
            throw Self.map(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw ApiError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Error bodies are small JSON; read a bounded prefix only.
            let body = (try? FileHandle(forReadingFrom: temporary).read(upToCount: 64 * 1024)) ?? Data()
            throw ErrorParsing.error(from: http, body: body)
        }
        do {
            let size =
                (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                // Never replace a directory; replaceItemAt swaps a file in one step.
                if isDirectory.boolValue { throw ApiError.transport(.cannotWriteToFile) }
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            progress?(size, size)
            return (size, http)
        } catch {
            throw ApiError.transport(.cannotWriteToFile)
        }
    }

    /// Same scheme, host and port (default ports filled in).
    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs, let leftScheme = lhs.scheme?.lowercased(), let rightScheme = rhs.scheme?.lowercased(),
            let leftHost = lhs.host?.lowercased(), let rightHost = rhs.host?.lowercased()
        else { return false }
        func port(_ url: URL, _ scheme: String) -> Int? {
            url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }
        return leftScheme == rightScheme && leftHost == rightHost && port(lhs, leftScheme) == port(rhs, rightScheme)
    }

    private static func map(_ error: any Error) -> any Error {
        if let apiError = error as? ApiError { return apiError }
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return ApiError.transport(urlError.code)
        }
        if Task.isCancelled { return CancellationError() }
        return ApiError.transport(.unknown)
    }

    /// Strict percent-encoding (unreserved characters only): `+`, `&`, `=` and `/` in names and tags must survive.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func segment(_ id: String) -> String { encode(id) }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

private struct SendOtpBody: Encodable {
    var email: String
    var type: String
}

private struct SignInBody: Encodable {
    var email: String
    var otp: String
}

private struct SignInResponse: Decodable {
    struct User: Decodable { var email: String? }
    var user: User?
}

private struct DeleteAccountBody: Encodable {
    var confirm: String
}

/// Forwards byte progress; also satisfies the download-delegate callbacks the async download API reports through.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let handler: ByteProgress?
    private let sameOriginOnly: Bool

    init(_ handler: ByteProgress?, sameOriginOnly: Bool) {
        self.handler = handler
        self.sameOriginOnly = sameOriginOnly
    }

    /// A refused redirect hands the 3xx answer to the caller, which treats it as an error.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard sameOriginOnly else { return request }
        return HTTPSrokaAPI.sameOrigin(task.originalRequest?.url, request.url) ? request : nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // The async download API hands the file to the caller; nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
}
