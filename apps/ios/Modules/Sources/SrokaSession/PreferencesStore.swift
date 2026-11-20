import Foundation
import OSLog
import SrokaCore

let sessionLog = Logger(subsystem: "app.sroka", category: "session")

/// Device-local settings in the App Group `UserDefaults` suite, readable by the share extension. Android:
/// UserPreferencesDataSource.kt and ConsentStore.kt.
///
/// Keys and values are the plan's preference table (`PreferenceKey`): enums are stored by their raw value, and an
/// unknown or mistyped stored value reads as the default. Besides the table, the suite holds the account marker
/// (`account_email`, `account_server`) and the active import job (`active_import`), which are not preferences.
///
/// Observation covers writes made through this instance; call `reload()` when another process may have written
/// (app activation).
public final class PreferencesStore: Sendable {
    /// `UserDefaults` is thread-safe; it is not marked `Sendable` in every SDK.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let preferencesValue: CurrentValue<UserPreferences>
    private let consentValue: CurrentValue<Consent>
    private let writeLock = NSLock()

    enum InternalKey {
        static let accountEmail = "account_email"
        static let accountServer = "account_server"
        static let activeImport = "active_import"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        preferencesValue = CurrentValue(Self.readPreferences(defaults))
        consentValue = CurrentValue(Self.readConsent(defaults))
    }

    /// The App Group suite (`group.app.sroka` / `group.app.sroka.dev`); nil when the group is not provisioned.
    public convenience init?(appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        self.init(defaults: defaults)
    }

    /// Re-reads everything (another process may have written).
    public func reload() {
        writeLock.withLock { publish() }
    }

    // MARK: Preferences

    public var preferences: UserPreferences { preferencesValue.value }

    public func preferencesStream() -> AsyncStream<UserPreferences> { preferencesValue.stream() }

    public func setThemeMode(_ value: ThemeMode) { set(value.rawValue, PreferenceKey.themeMode) }
    public func setDownloadPolicy(_ value: DownloadPolicy) { set(value.rawValue, PreferenceKey.downloadPolicy) }
    public func setReaderTheme(_ value: ReaderTheme) { set(value.rawValue, PreferenceKey.readerTheme) }
    public func setReaderTextScale(_ value: Double) {
        set(UserPreferences.clampTextScale(value), PreferenceKey.readerTextScale)
    }
    public func setReaderFont(_ value: ReaderFont) { set(value.rawValue, PreferenceKey.readerFont) }
    public func setReaderLineSpacing(_ value: ReaderLineSpacing) {
        set(value.rawValue, PreferenceKey.readerLineSpacing)
    }
    public func setSortOrder(_ value: LibrarySortOrder) { set(value.rawValue, PreferenceKey.sortOrder) }
    public func setSwipeLeftAction(_ value: SwipeAction) { set(value.rawValue, PreferenceKey.swipeLeftAction) }
    public func setSwipeRightAction(_ value: SwipeAction) { set(value.rawValue, PreferenceKey.swipeRightAction) }
    public func setSwipeHintShown() { set(true, PreferenceKey.swipeHintShown) }
    /// nil removes the override (build default server).
    public func setServerUrl(_ value: String?) { set(value, PreferenceKey.serverUrl) }

    private func set(_ value: Any?, _ key: String) {
        // Write, read back and publish as one step, so a slower setter never publishes a stale snapshot last.
        writeLock.withLock {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            publish()
        }
    }

    private func publish() {
        preferencesValue.send(Self.readPreferences(defaults))
        consentValue.send(Self.readConsent(defaults))
    }

    static func readPreferences(_ defaults: UserDefaults) -> UserPreferences {
        func value<E: RawRepresentable<String>>(_ key: String, _ fallback: E) -> E {
            (defaults.object(forKey: key) as? String).flatMap(E.init(rawValue:)) ?? fallback
        }
        let fallback = UserPreferences()
        let scale = (defaults.object(forKey: PreferenceKey.readerTextScale) as? NSNumber)?.doubleValue
        let server = (defaults.object(forKey: PreferenceKey.serverUrl) as? String).flatMap { $0.isEmpty ? nil : $0 }
        return UserPreferences(
            themeMode: value(PreferenceKey.themeMode, fallback.themeMode),
            downloadPolicy: value(PreferenceKey.downloadPolicy, fallback.downloadPolicy),
            readerTheme: value(PreferenceKey.readerTheme, fallback.readerTheme),
            readerTextScale: scale ?? fallback.readerTextScale,
            readerFont: value(PreferenceKey.readerFont, fallback.readerFont),
            readerLineSpacing: value(PreferenceKey.readerLineSpacing, fallback.readerLineSpacing),
            sortOrder: value(PreferenceKey.sortOrder, fallback.sortOrder),
            swipeLeftAction: value(PreferenceKey.swipeLeftAction, fallback.swipeLeftAction),
            swipeRightAction: value(PreferenceKey.swipeRightAction, fallback.swipeRightAction),
            swipeHintShown: bool(defaults, PreferenceKey.swipeHintShown) ?? fallback.swipeHintShown,
            serverUrl: server
        )
    }

    // MARK: Consent

    public var consent: Consent { consentValue.value }

    public func consentStream() -> AsyncStream<Consent> { consentValue.stream() }

    public func setAnalytics(_ enabled: Bool) { set(enabled, PreferenceKey.consentAnalytics) }
    public func setCrashReports(_ enabled: Bool) { set(enabled, PreferenceKey.consentCrashReports) }

    static func readConsent(_ defaults: UserDefaults) -> Consent {
        Consent(
            analytics: bool(defaults, PreferenceKey.consentAnalytics),
            crashReports: bool(defaults, PreferenceKey.consentCrashReports) ?? true
        )
    }

    /// Only a real boolean counts (`NSNumber` from a bool); strings and other numbers read as absent.
    private static func bool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    // MARK: Account marker (not a preference)

    /// Email of the account whose data is in the local database; outside the Keychain so it survives token loss.
    public var accountEmail: String? {
        get { defaults.object(forKey: InternalKey.accountEmail) as? String }
        set { store(newValue, InternalKey.accountEmail) }
    }

    /// Server the local data came from; nil = unknown.
    public var accountServer: String? {
        get { defaults.object(forKey: InternalKey.accountServer) as? String }
        set { store(newValue, InternalKey.accountServer) }
    }

    // MARK: Active import (not a preference)

    var activeImportData: Data? {
        get { defaults.object(forKey: InternalKey.activeImport) as? Data }
        set { store(newValue, InternalKey.activeImport) }
    }

    private func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
