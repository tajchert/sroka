import Foundation
import Synchronization

@testable import SrokaNetwork

/// A request as the server would see it.
struct CapturedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data
    var timeout: TimeInterval
    var handlesCookies: Bool

    /// Case-insensitive header lookup.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var path: String { url.path(percentEncoded: true) }
    var query: String { url.query(percentEncoded: true) ?? "" }
    var bodyText: String { String(decoding: body, as: UTF8.self) }
}

struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// Fails the request at the transport level.
    var error: URLError?
    /// Never answers (for cancellation tests).
    var hang = false

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    static func failure(_ code: URLError.Code) -> StubResponse { StubResponse(error: URLError(code)) }
}

/// Answers requests for hosts registered by a test; tests use unique hosts so they can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (CapturedRequest) -> StubResponse
    private static let handlers = Mutex<[String: Handler]>([:])

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        handlers.withLock { $0[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let captured = CapturedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request),
            timeout: request.timeoutInterval,
            handlesCookies: request.httpShouldHandleCookies
        )
        let stub = handler(captured)
        if stub.hang { return }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

struct FixedProvider: ApiSessionProvider {
    var base: URL
    var tokenValue: String?
    var device = "ios_0192f3c4-1111-7222-8333-444455556666"

    func baseUrl() async -> URL { base }
    func token() async -> String? { tokenValue }
    func deviceId() async -> String { device }
}

/// One API client wired to a stub server on its own host; records every request.
final class Harness: Sendable {
    static let token = "abc.def.ghi=="
    static let device = "ios_0192f3c4-1111-7222-8333-444455556666"
    static let userAgent = "Sroka-iOS/1.0 (7)"

    let host: String
    let api: HTTPSrokaAPI
    private let recorder = Recorder()

    var requests: [CapturedRequest] { recorder.all }
    var last: CapturedRequest { requests.last! }

    init(
        base: String? = nil,
        token: String? = Harness.token,
        now: @escaping @Sendable () -> Date = { Date() },
        respond: @escaping @Sendable (CapturedRequest) -> StubResponse
    ) {
        let host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let baseURL = URL(string: base.map { $0.replacingOccurrences(of: "{host}", with: host) } ?? "https://\(host)")!
        let sink = recorder
        StubProtocol.register(host: host) { request in
            sink.append(request)
            return respond(request)
        }
        api = HTTPSrokaAPI(
            provider: FixedProvider(base: baseURL, tokenValue: token),
            identity: ClientIdentity(appVersion: "1.0 (7)"),
            session: URLSession(configuration: configuration),
            now: now
        )
    }

    deinit { StubProtocol.unregister(host: host) }

    /// A host whose calls all succeed with an empty JSON object; for header checks.
    static func always(_ response: StubResponse = .json("{}")) -> Harness { Harness { _ in response } }
}

func temporaryFile(_ contents: Data, name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sroka-test-\(name)")
    try contents.write(to: url)
    return url
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sroka-test-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Recorder: Sendable {
    private let storage = Mutex<[CapturedRequest]>([])

    var all: [CapturedRequest] { storage.withLock { $0 } }

    func append(_ request: CapturedRequest) { storage.withLock { $0.append(request) } }
}
