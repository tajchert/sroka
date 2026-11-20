import Foundation
import SrokaNetwork
import Synchronization
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

    @Test func `A token issued by another server is withheld even when the marker matches`() async throws {
        let h = try Harness()
        try h.sessionStore.save(token: "tok.b", email: "a@b.co", server: "https://b.example")
        h.preferences.accountServer = Harness.defaultServer

        let endpoint = await h.provider.endpoint()

        #expect(endpoint.token == nil)
    }

    @Test func `A session that could not be deleted reads as signed out after a reload`() throws {
        let keychain = DeleteFailingStore()
        let store = SessionStore(store: keychain)
        try store.save(token: "tok.one", email: "a@b.co", server: "https://api.example")

        store.clear()
        store.reload()

        #expect(store.current == nil)
    }
}

/// A Keychain whose deletes fail; reads and writes work.
private final class DeleteFailingStore: SecureStore {
    private let values = Mutex<[String: String]>([:])

    func read(_ key: String) throws -> String? { values.withLock { $0[key] } }
    func write(_ key: String, value: String) throws { values.withLock { $0[key] = value } }
    func delete(_ key: String) throws { throw SecureStoreError(status: -1) }
}
