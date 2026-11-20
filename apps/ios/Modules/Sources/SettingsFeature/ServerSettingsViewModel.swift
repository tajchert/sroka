import Dependencies
import Foundation
import Observation
import SrokaCore

/// Custom server entry (Android `ServerDialog`). https only (http for localhost and 127.0.0.1), no
/// query, fragment or credentials. Switching to another server while signed in signs out and wipes
/// local data, so the form says so and the button reads "Sign out and switch".
@Observable @MainActor
public final class ServerSettingsViewModel {
    public enum Outcome: Sendable, Hashable {
        /// Saved without changing the effective server.
        case saved
        /// The effective server changed: the repository signed out and wiped.
        case switched
    }

    public var text: String {
        didSet {
            if oldValue != text, isInvalid { isInvalid = false }
        }
    }
    public private(set) var isInvalid = false
    public private(set) var isSaving = false

    @ObservationIgnored public var onFinished: (Outcome) async -> Void

    @ObservationIgnored private let initialServer: String
    @ObservationIgnored @Dependency(\.settingsRepository) private var settings

    /// - Parameter currentServer: the effective server now (custom or build default).
    public init(currentServer: String, onFinished: @escaping (Outcome) async -> Void = { _ in }) {
        initialServer = currentServer
        text = currentServer
        self.onFinished = onFinished
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when saving would point the app at a different server.
    public var isSwitching: Bool {
        let target = trimmed.isEmpty ? settings.defaultServerUrl : trimmed
        return Self.stripSlash(target) != Self.stripSlash(initialServer)
    }

    public func saveTapped() async {
        guard !isSaving else { return }
        guard ServerURLInput.isValid(trimmed) else {
            isInvalid = true
            return
        }
        let switching = isSwitching
        isSaving = true
        let accepted = await settings.setServerUrl(trimmed.isEmpty ? nil : trimmed)
        isSaving = false
        guard accepted else {
            isInvalid = true
            return
        }
        await onFinished(switching ? .switched : .saved)
    }

    private static func stripSlash(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// Same rule as the sign-in screen's server sheet (features may not import each other).
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
}
