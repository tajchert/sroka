import Foundation
import Synchronization
import Testing

@testable import SrokaNetwork

/// A provider whose separate getters disagree with its snapshot, as during a server switch: the base URL getter
/// already answers the new server while the token getter still answers the old token.
private struct SwitchingProvider: ApiSessionProvider {
    var snapshot: ApiEndpoint
    var staleBase: URL
    var staleToken: String?

    func baseUrl() async -> URL { staleBase }
    func token() async -> String? { staleToken }
    func deviceId() async -> String { Harness.device }
    func endpoint() async -> ApiEndpoint { snapshot }
}

struct EndpointSnapshotTests {
    @Test func `Requests take base URL and token from one endpoint snapshot`() async throws {
        let host = "snap\(UUID().uuidString.prefix(8).lowercased()).test"
        let recorder = Recorder()
        StubProtocol.register(host: host) { request in
            recorder.append(request)
            return .json("{}")
        }
        defer { StubProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = SwitchingProvider(
            snapshot: ApiEndpoint(baseUrl: URL(string: "https://\(host)")!, token: "new.token"),
            staleBase: URL(string: "https://stale-\(host)")!,
            staleToken: "old.token")
        let api = HTTPSrokaAPI(
            provider: provider, identity: ClientIdentity(appVersion: "1"),
            session: URLSession(configuration: configuration))

        _ = try? await api.me()

        let request = try #require(recorder.all.last)
        #expect(request.url.host == host)
        #expect(request.header("Authorization") == "Bearer new.token")
    }

    @Test func `A snapshot without a token sends no Authorization header`() async throws {
        let host = "snap\(UUID().uuidString.prefix(8).lowercased()).test"
        let recorder = Recorder()
        StubProtocol.register(host: host) { request in
            recorder.append(request)
            return .json("{}")
        }
        defer { StubProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = SwitchingProvider(
            snapshot: ApiEndpoint(baseUrl: URL(string: "https://\(host)")!, token: nil),
            staleBase: URL(string: "https://\(host)")!,
            staleToken: "old.token")
        let api = HTTPSrokaAPI(
            provider: provider, identity: ClientIdentity(appVersion: "1"),
            session: URLSession(configuration: configuration))

        _ = try? await api.me()

        let request = try #require(recorder.all.last)
        #expect(request.header("Authorization") == nil)
    }
}
