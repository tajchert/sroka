import Foundation
import SrokaNetwork
import Testing

@testable import SrokaSession

struct EndpointTests {
    @Test func `The endpoint pairs the token with the server it was issued for`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "tok.one")

        let endpoint = await h.provider.endpoint()

        #expect(endpoint.baseUrl.absoluteString == Harness.defaultServer)
        #expect(endpoint.token == "tok.one")
    }

    @Test func `A server change without a wipe yields the new URL and no token`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "tok.one")
        // Bypasses the repository's sign-out, as a stale process view of the preferences would.
        h.preferences.setServerUrl("https://other.example")

        let endpoint = await h.provider.endpoint()

        #expect(endpoint.baseUrl.absoluteString == "https://other.example")
        #expect(endpoint.token == nil)
    }

    @Test func `A corrupt stored server falls back to the default without a token`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "tok.one")
        h.preferences.setServerUrl("http://[bad")
        h.preferences.accountServer = "http://[bad"

        let endpoint = await h.provider.endpoint()

        #expect(endpoint.baseUrl.absoluteString == Harness.defaultServer)
        #expect(endpoint.token == nil)
    }
}
