/// Local preferences (DECISIONS A6), per device, never synced. Stored in the App Group
/// `UserDefaults` suite under `PreferenceKey`; unknown stored values fall back to the defaults here.
/// Android's `dynamic_color` is not ported.
public struct UserPreferences: Sendable, Hashable {
    public var themeMode: ThemeMode
    public var downloadPolicy: DownloadPolicy
    public var readerTheme: ReaderTheme
    /// Clamped to `readerTextScaleRange`.
    public var readerTextScale: Double
    public var readerFont: ReaderFont
    public var readerLineSpacing: ReaderLineSpacing
    public var sortOrder: LibrarySortOrder
    /// Row swipe towards the left edge (trailing in LTR). Default: archive.
    public var swipeLeftAction: SwipeAction
    /// Row swipe towards the right edge (leading in LTR). Default: off.
    public var swipeRightAction: SwipeAction
    /// The one-time "peek" that hints at the swipe actions has played.
    public var swipeHintShown: Bool
    /// Overrides the build's default server; nil = default.
    public var serverUrl: String?

    public static let readerTextScaleRange: ClosedRange<Double> = 0.8...1.6

    public init(
        themeMode: ThemeMode = .system,
        downloadPolicy: DownloadPolicy = .wifiOnly,
        readerTheme: ReaderTheme = .auto,
        readerTextScale: Double = 1.0,
        readerFont: ReaderFont = .sans,
        readerLineSpacing: ReaderLineSpacing = .normal,
        sortOrder: LibrarySortOrder = .newest,
        swipeLeftAction: SwipeAction = .archive,
        swipeRightAction: SwipeAction = .none,
        swipeHintShown: Bool = false,
        serverUrl: String? = nil
    ) {
        self.themeMode = themeMode
        self.downloadPolicy = downloadPolicy
        self.readerTheme = readerTheme
        self.readerTextScale = Self.clampTextScale(readerTextScale)
        self.readerFont = readerFont
        self.readerLineSpacing = readerLineSpacing
        self.sortOrder = sortOrder
        self.swipeLeftAction = swipeLeftAction
        self.swipeRightAction = swipeRightAction
        self.swipeHintShown = swipeHintShown
        self.serverUrl = serverUrl
    }

    public static func clampTextScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1.0 }
        return min(max(scale, readerTextScaleRange.lowerBound), readerTextScaleRange.upperBound)
    }
}

/// Stored keys (App Group `UserDefaults`), identical to Android's DataStore keys.
public enum PreferenceKey {
    public static let themeMode = "theme_mode"
    public static let readerTheme = "reader_theme"
    public static let readerTextScale = "reader_text_scale"
    public static let readerFont = "reader_font"
    public static let readerLineSpacing = "reader_line_spacing"
    public static let sortOrder = "sort_order"
    public static let swipeLeftAction = "swipe_left_action"
    public static let swipeRightAction = "swipe_right_action"
    public static let swipeHintShown = "swipe_hint_shown"
    public static let downloadPolicy = "download_policy"
    public static let serverUrl = "server_url"
    public static let consentAnalytics = "consent_analytics"
    public static let consentCrashReports = "consent_crash_reports"
}
