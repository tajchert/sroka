import Dependencies

/// Analytics and crash reporting seam (repo-root D15). The app target implements it with Firebase
/// when `GoogleService-Info.plist` is present in a release build; everything else uses `NoTelemetry`.
///
/// Only `TelemetryEvent` values can be logged, so parameters are limited to the enums below:
/// never URLs, titles, search text, tag names, file names, emails or ids. Android: Telemetry.kt.
public protocol Telemetry: Sendable {
    /// False when this build carries no telemetry; the consent prompt and switches are hidden.
    var isAvailable: Bool { get }

    func logEvent(_ event: TelemetryEvent)

    /// Usage analytics collection + Consent Mode: analytics_storage granted/denied, ad_* always denied.
    func setAnalyticsEnabled(_ enabled: Bool)

    func setCrashReportingEnabled(_ enabled: Bool)

    /// Records a handled error. Its description must not contain user content.
    func recordNonFatal(_ error: any Error)
}

/// Does nothing: builds without Firebase, debug builds, previews and tests.
public struct NoTelemetry: Telemetry {
    public init() {}
    public var isAvailable: Bool { false }
    public func logEvent(_ event: TelemetryEvent) {}
    public func setAnalyticsEnabled(_ enabled: Bool) {}
    public func setCrashReportingEnabled(_ enabled: Bool) {}
    public func recordNonFatal(_ error: any Error) {}
}

public enum TelemetryScreen: String, Sendable, Hashable, CaseIterable {
    case signIn = "sign_in"
    case library
    case reader
    case search
    case tags
    case settings
    case `import`
    case export
    case share
}

public enum TelemetrySource: String, Sendable, Hashable, CaseIterable {
    case share
    case pdf
    case drag
    case `import`
    /// Typed or pasted into the add-link sheet.
    case webAdd = "web_add"
}

/// GA4 events (snake_case names; parameters only from the enums above).
public enum TelemetryEvent: Sendable, Hashable {
    case screenView(TelemetryScreen)
    case login
    case saveItem(source: TelemetrySource, kind: ItemKind)
    case openItem(kind: ItemKind)
    case archiveItem
    case unarchiveItem
    case favoriteItem(on: Bool)
    case deleteItem
    case addTag
    case searchUsed
    case importStart(source: TelemetrySource = .import)
    case export(format: ExportFormat)

    public var name: String {
        switch self {
        case .screenView: "screen_view"
        case .login: "login"
        case .saveItem: "save_item"
        case .openItem: "open_item"
        case .archiveItem: "archive_item"
        case .unarchiveItem: "unarchive_item"
        case .favoriteItem: "favorite_item"
        case .deleteItem: "delete_item"
        case .addTag: "add_tag"
        case .searchUsed: "search_used"
        case .importStart: "import_start"
        case .export: "export"
        }
    }

    public var parameters: [String: String] {
        switch self {
        case .screenView(let screen): ["screen_name": screen.rawValue]
        case .login: ["method": "email_otp"]
        case .saveItem(let source, let kind): ["source": source.rawValue, "kind": kind.rawValue]
        case .openItem(let kind): ["kind": kind.rawValue]
        case .favoriteItem(let on): ["on": on ? "true" : "false"]
        case .importStart(let source): ["source": source.rawValue]
        case .export(let format): ["format": format.rawValue]
        case .archiveItem, .unarchiveItem, .deleteItem, .addTag, .searchUsed: [:]
        }
    }
}

private enum TelemetryKey: DependencyKey {
    static let liveValue: any Telemetry = NoTelemetry()
    static let testValue: any Telemetry = NoTelemetry()
}

extension DependencyValues {
    /// Defaults to `NoTelemetry` everywhere; the app's composition root installs Firebase (stream L).
    public var telemetry: any Telemetry {
        get { self[TelemetryKey.self] }
        set { self[TelemetryKey.self] = newValue }
    }
}
