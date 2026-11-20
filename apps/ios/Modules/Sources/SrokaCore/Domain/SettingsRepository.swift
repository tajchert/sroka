import Dependencies

/// Local preferences (DECISIONS A6). Android: SettingsRepository.kt (without `setDynamicColor`).
public protocol SettingsRepository: Sendable {
    /// Current preferences; emits immediately (defaults when nothing is stored).
    var preferences: AsyncStream<UserPreferences> { get }

    /// Server used when `UserPreferences.serverUrl` is nil (build default).
    var defaultServerUrl: String { get }

    func setThemeMode(_ mode: ThemeMode) async

    /// Changing the policy re-evaluates pending downloads.
    func setDownloadPolicy(_ policy: DownloadPolicy) async

    func setReaderTheme(_ theme: ReaderTheme) async

    /// Clamped to `UserPreferences.readerTextScaleRange`.
    func setReaderTextScale(_ scale: Double) async

    func setReaderFont(_ font: ReaderFont) async

    func setReaderLineSpacing(_ spacing: ReaderLineSpacing) async

    func setSortOrder(_ order: LibrarySortOrder) async

    /// Action of a row swipe towards the left edge.
    func setSwipeLeftAction(_ action: SwipeAction) async

    /// Action of a row swipe towards the right edge.
    func setSwipeRightAction(_ action: SwipeAction) async

    /// Records that the one-time swipe hint has played, so it never plays again.
    func setSwipeHintShown() async

    /// Custom server base URL; nil restores `defaultServerUrl`. Invalid URLs return false.
    /// Changing it while signed in signs out and wipes.
    func setServerUrl(_ url: String?) async -> Bool
}

private struct UnimplementedSettingsRepository: SettingsRepository {
    private func fail(_ method: String) {
        reportUnimplemented("SettingsRepository.\(method)", key: "settingsRepository")
    }

    var preferences: AsyncStream<UserPreferences> {
        fail("preferences")
        return .finished
    }
    var defaultServerUrl: String {
        fail("defaultServerUrl")
        return ""
    }
    func setThemeMode(_ mode: ThemeMode) async { fail("setThemeMode") }
    func setDownloadPolicy(_ policy: DownloadPolicy) async { fail("setDownloadPolicy") }
    func setReaderTheme(_ theme: ReaderTheme) async { fail("setReaderTheme") }
    func setReaderTextScale(_ scale: Double) async { fail("setReaderTextScale") }
    func setReaderFont(_ font: ReaderFont) async { fail("setReaderFont") }
    func setReaderLineSpacing(_ spacing: ReaderLineSpacing) async { fail("setReaderLineSpacing") }
    func setSortOrder(_ order: LibrarySortOrder) async { fail("setSortOrder") }
    func setSwipeLeftAction(_ action: SwipeAction) async { fail("setSwipeLeftAction") }
    func setSwipeRightAction(_ action: SwipeAction) async { fail("setSwipeRightAction") }
    func setSwipeHintShown() async { fail("setSwipeHintShown") }
    func setServerUrl(_ url: String?) async -> Bool {
        fail("setServerUrl")
        return false
    }
}

private enum SettingsRepositoryKey: TestDependencyKey {
    static let testValue: any SettingsRepository = UnimplementedSettingsRepository()
}

extension DependencyValues {
    public var settingsRepository: any SettingsRepository {
        get { self[SettingsRepositoryKey.self] }
        set { self[SettingsRepositoryKey.self] = newValue }
    }
}
