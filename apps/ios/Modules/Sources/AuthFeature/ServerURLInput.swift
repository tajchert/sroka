import Foundation

/// Validation of a self-hosted server address (plan "Custom server"): https only, http only for
/// `localhost` and `127.0.0.1`, no query, fragment or credentials. Empty means "use the default".
/// The repository validates again; this gives the form its inline error.
enum ServerURLInput {
    static func isValid(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil,
            components.user == nil, components.password == nil
        else { return false }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        return scheme == "https" || (scheme == "http" && isLocal)
    }

    /// Host shown next to "Self-hosting?" when a custom server is set.
    static func host(of input: String) -> String? {
        URLComponents(string: input)?.host
    }
}

extension AsyncStream where Element: Sendable {
    /// The current value of a "current value first" observation stream.
    func firstValue() async -> Element? {
        for await value in self { return value }
        return nil
    }
}
