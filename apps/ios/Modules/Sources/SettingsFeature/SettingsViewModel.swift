import Dependencies
import Foundation
import Observation
import SrokaCore

/// Pushed screens inside the settings sheet.
public enum SettingsRoute: Hashable, Sendable {
    case server
    case export
    case `import`
}

/// The settings form (Android `SettingsViewModel`): every row writes straight through the
/// repositories; destructive rows confirm first.
@Observable @MainActor
public final class SettingsViewModel {
    /// Text-size steps offered by the picker (reader scale range is 0.8...1.6).
    public static let textScaleSteps: [Double] = [0.8, 0.9, 1.0, 1.15, 1.3, 1.45, 1.6]
    /// Reader body size at scale 1.0, in points.
    public static let readerBasePoints = 18
    public static let privacyPolicyURL = URL(string: "https://sroka.app/privacy")!
    public static let termsURL = URL(string: "https://sroka.app/terms")!
    static let messageSeconds = 3

    public private(set) var preferences = UserPreferences()
    public private(set) var consent = Consent()
    /// nil when signed out.
    public private(set) var email: String?
    public private(set) var storageBytes: Int64 = 0
    /// Effective server (custom or build default).
    public private(set) var serverURL = ""
    public private(set) var isBusy = false
    /// One-shot message shown as a toast for a few seconds.
    public private(set) var message: LocalizedStringResource?

    public var path: [SettingsRoute] = []
    public var isConfirmingSignOut = false
    public var isConfirmingRemoveDownloads = false
    public var isConfirmingDeleteAccount = false
    /// Typed into the delete alert; must match the account email.
    public var deleteConfirmationText = ""

    public let appVersion: String

    @ObservationIgnored public var onIntent: (SettingsIntent) async -> Void

    @ObservationIgnored @Dependency(\.settingsRepository) private var settings
    @ObservationIgnored @Dependency(\.authRepository) private var auth
    @ObservationIgnored @Dependency(\.accountRepository) private var account
    @ObservationIgnored @Dependency(\.consentRepository) private var consentRepository
    @ObservationIgnored @Dependency(\.contentStore) private var content
    @ObservationIgnored @Dependency(\.syncController) private var sync
    @ObservationIgnored @Dependency(\.telemetry) private var telemetry
    @ObservationIgnored @Dependency(\.continuousClock) private var clock
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    public init(
        appVersion: String = SettingsViewModel.bundleVersion(),
        onIntent: @escaping (SettingsIntent) async -> Void = { _ in }
    ) {
        self.appVersion = appVersion
        self.onIntent = onIntent
    }

    isolated deinit { messageTask?.cancel() }

    /// "1.5.0 (42)" from the main bundle.
    public static func bundleVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }

    // MARK: Loading

    /// Observes preferences, session and consent until cancelled; reads storage use once.
    public func task() async {
        let tasks = [
            Task { await observePreferences() },
            Task { await observeSession() },
            Task { await observeConsent() },
            Task { await refreshStorage() },
        ]
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    private func observePreferences() async {
        for await value in settings.preferences {
            preferences = value
            serverURL = value.serverUrl ?? settings.defaultServerUrl
        }
    }

    private func observeSession() async {
        for await session in auth.session { email = session.email }
    }

    private func observeConsent() async {
        for await value in consentRepository.consent { consent = value }
    }

    public func refreshStorage() async {
        storageBytes = await content.storageUsageBytes()
    }

    public var isTelemetryAvailable: Bool { telemetry.isAvailable }

    // MARK: Reading and swipe actions

    public func themeSelected(_ mode: ThemeMode) async { await settings.setThemeMode(mode) }
    public func readerThemeSelected(_ theme: ReaderTheme) async { await settings.setReaderTheme(theme) }
    public func textScaleSelected(_ scale: Double) async { await settings.setReaderTextScale(scale) }
    public func swipeLeftSelected(_ action: SwipeAction) async { await settings.setSwipeLeftAction(action) }
    public func swipeRightSelected(_ action: SwipeAction) async { await settings.setSwipeRightAction(action) }

    /// The step closest to the stored scale, so the picker always has a selection.
    public var nearestTextScaleStep: Double {
        Self.textScaleSteps.min { abs($0 - preferences.readerTextScale) < abs($1 - preferences.readerTextScale) }
            ?? 1.0
    }

    public static func textPoints(scale: Double) -> Int {
        Int((Double(readerBasePoints) * scale).rounded())
    }

    // MARK: Library

    public func downloadPolicySelected(_ policy: DownloadPolicy) async {
        await settings.setDownloadPolicy(policy)
    }

    public func downloadAllNowTapped() {
        sync.fetchNewArticles()
        show(LocalizedStringResource("Fetching new articles", bundle: #bundle))
    }

    public func removeDownloadsTapped() { isConfirmingRemoveDownloads = true }

    public func removeDownloadsConfirmed() async {
        await content.clearDownloads()
        await refreshStorage()
        show(LocalizedStringResource("Downloaded articles removed", bundle: #bundle))
    }

    // MARK: Privacy

    public func analyticsToggled(_ enabled: Bool) async { await consentRepository.setAnalytics(enabled) }
    public func crashReportsToggled(_ enabled: Bool) async { await consentRepository.setCrashReports(enabled) }

    // MARK: Account

    public func signOutTapped() { isConfirmingSignOut = true }

    public func signOutConfirmed() async {
        isBusy = true
        await auth.signOut()
        isBusy = false
        await onIntent(.signedOut)
    }

    public func deleteAccountTapped() {
        deleteConfirmationText = ""
        isConfirmingDeleteAccount = true
    }

    /// Enabled once the typed text equals the account email (trimmed, case-insensitive).
    public var isDeleteConfirmed: Bool {
        Self.isDeleteConfirmed(typed: deleteConfirmationText, email: email)
    }

    public static func isDeleteConfirmed(typed: String, email: String?) -> Bool {
        guard let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(email.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    public func deleteAccountConfirmed() async {
        guard isDeleteConfirmed else { return }
        isBusy = true
        let result = await account.deleteAccount()
        isBusy = false
        switch result {
        case .deleted:
            deleteConfirmationText = ""
            await onIntent(.signedOut)
        case .failed:
            show(
                LocalizedStringResource(
                    "Could not delete the account. Check your connection and try again.",
                    bundle: #bundle
                )
            )
        }
    }

    // MARK: Navigation

    public func serverTapped() { path.append(.server) }
    public func exportTapped() { path.append(.export) }
    public func importTapped() { path.append(.import) }

    public func doneTapped() async { await onIntent(.dismissed) }

    /// Called by the Server screen after it saved a different server while signed in: the
    /// repository has signed out and wiped, so the root must leave the sheet.
    public func serverSwitched() async {
        path.removeAll()
        await onIntent(.signedOut)
    }

    // MARK: Messages

    private func show(_ text: LocalizedStringResource) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [clock] in
            do { try await clock.sleep(for: .seconds(Self.messageSeconds)) } catch { return }
            self.message = nil
        }
    }
}
