import Dependencies
import Foundation

/// Build-time environment (Dev/Prod) surfaced at runtime.
///
/// Values come from the xcconfig files (`Config/Dev.xcconfig`, `Config/Prod.xcconfig`,
/// `Config/Shared.xcconfig`) through Info.plist of the app and the share extension.
/// Access it anywhere via `@Dependency(\.appEnvironment)`.
public struct AppEnvironment: Equatable, Sendable {
    public var name: String
    /// Build default server (`UserPreferences.serverUrl` overrides it).
    public var apiBaseURL: URL
    /// App Group holding the database, article files and the preferences suite. Differs per
    /// environment so Dev and Prod never read or reset each other's data.
    public var appGroupIdentifier: String
    /// Keychain access group for the session token, without the team prefix
    /// (the Keychain store prepends it at runtime).
    public var keychainAccessGroup: String
    /// URL scheme for deep links: `<scheme>://item/{id}` (`sroka` / `sroka-dev`).
    public var urlScheme: String

    public init(
        name: String,
        apiBaseURL: URL,
        appGroupIdentifier: String,
        keychainAccessGroup: String,
        urlScheme: String
    ) {
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.urlScheme = urlScheme
    }

    /// Reads `AppEnvironmentName`, `APIBaseURL`, `AppGroupIdentifier`, `KeychainAccessGroup` and
    /// `URLScheme` from an Info.plist dictionary. nil when any key is missing, malformed or empty.
    public init?(infoDictionary: [String: Any]) {
        guard
            let name = infoDictionary["AppEnvironmentName"] as? String,
            let urlString = infoDictionary["APIBaseURL"] as? String,
            let url = URL(string: urlString),
            let appGroupIdentifier = infoDictionary["AppGroupIdentifier"] as? String,
            !appGroupIdentifier.isEmpty,
            let keychainAccessGroup = infoDictionary["KeychainAccessGroup"] as? String,
            !keychainAccessGroup.isEmpty,
            let urlScheme = infoDictionary["URLScheme"] as? String,
            !urlScheme.isEmpty
        else { return nil }
        self.init(
            name: name,
            apiBaseURL: url,
            appGroupIdentifier: appGroupIdentifier,
            keychainAccessGroup: keychainAccessGroup,
            urlScheme: urlScheme
        )
    }

    /// Deep link to an item: `<scheme>://item/{id}`.
    public func itemURL(id: String) -> URL? {
        guard isValidItemId(id) else { return nil }
        return URL(string: "\(urlScheme)://item/\(id)")
    }
}

extension AppEnvironment: DependencyKey {
    /// Reads from the main bundle. Crashes with a clear message when the Info.plist keys are
    /// missing: a misconfigured build must not ship.
    public static var liveValue: AppEnvironment {
        guard let environment = AppEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            fatalError(
                """
                Missing AppEnvironmentName/APIBaseURL/AppGroupIdentifier/KeychainAccessGroup/URLScheme \
                in Info.plist. Check Config/*.xcconfig and the target's INFOPLIST_FILE.
                """
            )
        }
        return environment
    }

    public static let testValue = AppEnvironment(
        name: "Test",
        apiBaseURL: URL(string: "http://localhost:8787")!,
        appGroupIdentifier: "group.app.sroka.test",
        keychainAccessGroup: "app.sroka.test.shared",
        urlScheme: "sroka-test"
    )

    public static var previewValue: AppEnvironment { testValue }
}

extension DependencyValues {
    public var appEnvironment: AppEnvironment {
        get { self[AppEnvironment.self] }
        set { self[AppEnvironment.self] = newValue }
    }
}
