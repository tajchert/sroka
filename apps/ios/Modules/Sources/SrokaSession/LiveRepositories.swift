import Foundation
import SrokaCore
import SrokaNetwork

/// Local preferences. Android: SettingsRepositoryImpl.kt.
public final class LiveSettingsRepository: SettingsRepository {
    private let store: PreferencesStore
    private let sessionStore: SessionStore
    private let auth: LiveAuthRepository
    private let onDownloadPolicyChanged: @Sendable (DownloadPolicy) -> Void
    public let defaultServerUrl: String

    /// - Parameter onDownloadPolicyChanged: re-evaluates pending downloads (content engine).
    public init(
        store: PreferencesStore,
        sessionStore: SessionStore,
        auth: LiveAuthRepository,
        defaultServerUrl: String,
        onDownloadPolicyChanged: @escaping @Sendable (DownloadPolicy) -> Void
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.auth = auth
        self.defaultServerUrl = defaultServerUrl
        self.onDownloadPolicyChanged = onDownloadPolicyChanged
    }

    public var preferences: AsyncStream<UserPreferences> { store.preferencesStream() }

    public func setThemeMode(_ mode: ThemeMode) async { store.setThemeMode(mode) }

    public func setDownloadPolicy(_ policy: DownloadPolicy) async {
        store.setDownloadPolicy(policy)
        onDownloadPolicyChanged(policy)
    }

    public func setReaderTheme(_ theme: ReaderTheme) async { store.setReaderTheme(theme) }
    public func setReaderTextScale(_ scale: Double) async { store.setReaderTextScale(scale) }
    public func setReaderFont(_ font: ReaderFont) async { store.setReaderFont(font) }
    public func setReaderLineSpacing(_ spacing: ReaderLineSpacing) async { store.setReaderLineSpacing(spacing) }
    public func setSortOrder(_ order: LibrarySortOrder) async { store.setSortOrder(order) }
    public func setSwipeLeftAction(_ action: SwipeAction) async { store.setSwipeLeftAction(action) }
    public func setSwipeRightAction(_ action: SwipeAction) async { store.setSwipeRightAction(action) }
    public func setSwipeHintShown() async { store.setSwipeHintShown() }

    public func setServerUrl(_ url: String?) async -> Bool {
        let normalized: String?
        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let valid = normalizeServerUrl(url) else { return false }
            normalized = valid
        } else {
            normalized = nil
        }
        let stored = normalized == Self.trimmed(defaultServerUrl) ? nil : normalized
        guard stored != store.preferences.serverUrl else { return true }
        // The token, library, cursor and queued ops belong to the old server: never send them to the new host.
        // Sign out first if signed in (revokes the token against the old base URL and wipes), then switch.
        let store = store
        await auth.switchServer { store.setServerUrl(stored) }
        return true
    }

    private static func trimmed(_ url: String) -> String {
        var url = url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

/// Account-level server calls. Android: AccountRepositoryImpl.kt.
public final class LiveAccountRepository: AccountRepository {
    private let api: any SrokaAPI
    private let auth: LiveAuthRepository

    public init(api: any SrokaAPI, auth: LiveAuthRepository) {
        self.api = api
        self.auth = auth
    }

    public func connectedClients() async -> ConnectedClients? {
        guard case .success(let me) = await apiCall({ try await api.me() }) else { return nil }
        return ConnectedClients(
            extensionClient: me.clients.chromeExtension, android: me.clients.android, ios: me.clients.ios)
    }

    public func deleteAccount() async -> DeleteAccountResult {
        switch await apiCall({ try await api.deleteAccount() }) {
        case .success:
            await auth.clearLocal()
            return .deleted
        case .failure(let error):
            if error.isUnauthorized { auth.markSessionExpired() }
            return .failed(error.remoteFailure)
        }
    }
}

/// Telemetry consent. Android: ConsentRepositoryImpl.kt.
public final class LiveConsentRepository: ConsentRepository {
    private let store: PreferencesStore

    public init(store: PreferencesStore) {
        self.store = store
    }

    public var consent: AsyncStream<Consent> { store.consentStream() }
    public func setAnalytics(_ enabled: Bool) async { store.setAnalytics(enabled) }
    public func setCrashReports(_ enabled: Bool) async { store.setCrashReports(enabled) }
}
