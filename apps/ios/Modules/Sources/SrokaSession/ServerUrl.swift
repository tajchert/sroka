import Foundation
import SrokaNetwork

/// Custom server rules: `https://host[:port][/path]`, or `http` only for `localhost` and `127.0.0.1`. No query,
/// fragment or credentials. Returns the URL with a lowercased scheme and host and no trailing slash, or nil when the
/// input is not acceptable. Android: `normalizeServerUrl` in SettingsRepositoryImpl.kt.
public func normalizeServerUrl(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
        var components = URLComponents(string: trimmed),
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(), !host.isEmpty,
        components.query == nil, components.fragment == nil,
        components.user == nil, components.password == nil
    else { return nil }
    let cleartextHosts: Set<String> = ["localhost", "127.0.0.1"]
    guard scheme == "https" || (scheme == "http" && cleartextHosts.contains(host)) else { return nil }
    if let port = components.port, !(1...65535).contains(port) { return nil }
    components.scheme = scheme
    components.percentEncodedHost = components.percentEncodedHost?.lowercased()
    guard var result = components.string else { return nil }
    while result.hasSuffix("/") { result.removeLast() }
    // A bare "https://" would leave nothing after the scheme.
    guard URL(string: result)?.host?.isEmpty == false else { return nil }
    return result
}

/// Feeds the API client: token and device id from the session store, base URL from the preferences (custom server)
/// or the build default. Android: SessionProviderImpl.kt.
///
/// As a second guard behind "changing server signs out", the token is withheld when the account marker says the
/// session belongs to a different server than the one requests now go to.
public final class LiveApiSessionProvider: ApiSessionProvider {
    private let sessionStore: SessionStore
    private let preferences: PreferencesStore
    private let defaultServerUrl: String

    public init(sessionStore: SessionStore, preferences: PreferencesStore, defaultServerUrl: String) {
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.defaultServerUrl = defaultServerUrl
    }

    /// The effective server as a string without a trailing slash.
    public func currentServer() -> String {
        var server = preferences.preferences.serverUrl ?? defaultServerUrl
        while server.hasSuffix("/") { server.removeLast() }
        return server
    }

    public func baseUrl() async -> URL { endpointSnapshot().baseUrl }

    public func token() async -> String? { endpointSnapshot().token }

    /// Base URL and token from one read of the server preference: the token is only paired with the server it was
    /// issued for.
    public func endpoint() async -> ApiEndpoint { endpointSnapshot() }

    func endpointSnapshot() -> ApiEndpoint {
        let server = currentServer()
        guard let url = URL(string: server) else {
            // The stored value was validated when it was set; a corrupt one falls back to the build default, and a
            // fallback URL never carries a token.
            let fallback = URL(string: defaultServerUrl) ?? URL(string: "https://api.sroka.app")!
            return ApiEndpoint(baseUrl: fallback, token: nil)
        }
        // Sign-in always records the server; a token without that record (e.g. a Keychain delete that failed during a
        // wipe), or recorded for another server, is never sent anywhere.
        guard let token = sessionStore.token, preferences.accountServer == server else {
            return ApiEndpoint(baseUrl: url, token: nil)
        }
        return ApiEndpoint(baseUrl: url, token: token)
    }

    public func deviceId() async -> String { sessionStore.deviceId() }
}
