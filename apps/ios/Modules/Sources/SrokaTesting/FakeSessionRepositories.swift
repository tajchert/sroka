import Foundation
import SrokaCore

/// In-memory `AuthRepository`. Any well-formed email gets a code; `validCode` signs in.
public final class FakeAuthRepository: AuthRepository {
    public let state: FakeSubject<SessionState>
    public let validCode: String
    /// Returned by `sendCode` / `signIn` instead of the normal flow when set.
    public let forcedFailure: FakeSubject<AuthError?>
    public let calls = CallRecorder<String>()

    public init(session: SessionState = .signedIn(email: Fixtures.email), validCode: String = "123456") {
        state = FakeSubject(session)
        self.validCode = validCode
        forcedFailure = FakeSubject(nil)
    }

    public var session: AsyncStream<SessionState> { state.stream() }

    public func sendCode(email: String) async -> AuthResult {
        calls.record("sendCode")
        if let failure = forcedFailure.value { return .failure(failure) }
        return Self.isValidEmail(email) ? .success : .failure(.invalidEmail)
    }

    public func signIn(email: String, code: String) async -> AuthResult {
        calls.record("signIn")
        if let failure = forcedFailure.value { return .failure(failure) }
        guard Self.isValidEmail(email) else { return .failure(.invalidEmail) }
        let stripped = code.filter { !$0.isWhitespace }
        guard stripped == validCode else { return .failure(.invalidCode) }
        state.send(.signedIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines)))
        return .success
    }

    public func signOut() async {
        calls.record("signOut")
        state.send(.signedOut)
    }

    /// `^[^\s@]+@[^\s@]+\.[^\s@]+$`, at most 254 characters (same rule as Android).
    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 254 else { return false }
        return trimmed.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil
    }
}

/// In-memory `AccountRepository` with configurable answers.
public final class FakeAccountRepository: AccountRepository {
    public let deleteResult: FakeSubject<DeleteAccountResult>
    public let clients: FakeSubject<ConnectedClients?>
    public let calls = CallRecorder<String>()

    public init(
        deleteResult: DeleteAccountResult = .deleted,
        clients: ConnectedClients? = ConnectedClients(extensionClient: true, android: false, ios: true)
    ) {
        self.deleteResult = FakeSubject(deleteResult)
        self.clients = FakeSubject(clients)
    }

    public func deleteAccount() async -> DeleteAccountResult {
        calls.record("deleteAccount")
        return deleteResult.value
    }

    public func connectedClients() async -> ConnectedClients? { clients.value }
}

/// In-memory `SettingsRepository`.
public final class FakeSettingsRepository: SettingsRepository {
    public let state: FakeSubject<UserPreferences>
    public let defaultServerUrl: String

    public init(preferences: UserPreferences = UserPreferences(), defaultServerUrl: String = "https://api.sroka.app") {
        state = FakeSubject(preferences)
        self.defaultServerUrl = defaultServerUrl
    }

    public var preferences: AsyncStream<UserPreferences> { state.stream() }

    public func setThemeMode(_ mode: ThemeMode) async { state.update { $0.themeMode = mode } }
    public func setDownloadPolicy(_ policy: DownloadPolicy) async { state.update { $0.downloadPolicy = policy } }
    public func setReaderTheme(_ theme: ReaderTheme) async { state.update { $0.readerTheme = theme } }
    public func setReaderTextScale(_ scale: Double) async {
        state.update { $0.readerTextScale = UserPreferences.clampTextScale(scale) }
    }
    public func setReaderFont(_ font: ReaderFont) async { state.update { $0.readerFont = font } }
    public func setReaderLineSpacing(_ spacing: ReaderLineSpacing) async {
        state.update { $0.readerLineSpacing = spacing }
    }
    public func setSortOrder(_ order: LibrarySortOrder) async { state.update { $0.sortOrder = order } }
    public func setSwipeLeftAction(_ action: SwipeAction) async { state.update { $0.swipeLeftAction = action } }
    public func setSwipeRightAction(_ action: SwipeAction) async { state.update { $0.swipeRightAction = action } }
    public func setSwipeHintShown() async { state.update { $0.swipeHintShown = true } }

    /// Accepts https, or http only for localhost / 127.0.0.1; no query, fragment or credentials.
    public func setServerUrl(_ url: String?) async -> Bool {
        guard let url, !url.isEmpty else {
            state.update { $0.serverUrl = nil }
            return true
        }
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil, components.user == nil
        else { return false }
        let localHost = host == "localhost" || host == "127.0.0.1"
        guard components.scheme == "https" || (components.scheme == "http" && localHost) else { return false }
        state.update { $0.serverUrl = url }
        return true
    }
}

/// In-memory `ConsentRepository`.
public final class FakeConsentRepository: ConsentRepository {
    public let state: FakeSubject<Consent>

    public init(consent: Consent = Consent()) {
        state = FakeSubject(consent)
    }

    public var consent: AsyncStream<Consent> { state.stream() }
    public func setAnalytics(_ enabled: Bool) async { state.update { $0.analytics = enabled } }
    public func setCrashReports(_ enabled: Bool) async { state.update { $0.crashReports = enabled } }
}

/// In-memory `DataTransferRepository` with configurable answers.
public final class FakeDataTransferRepository: DataTransferRepository {
    public let active: FakeSubject<ImportJob?>
    /// nil = start a queued job; otherwise fail with this error.
    public let importFailure: FakeSubject<ImportError?>
    public let exportResult: FakeSubject<ExportResult>
    public let calls = CallRecorder<String>()

    public init(
        activeImport: ImportJob? = nil,
        importFailure: ImportError? = nil,
        exportResult: ExportResult = .ready(
            fileURL: URL(filePath: NSTemporaryDirectory()).appending(path: "sroka-export.csv"),
            fileName: "sroka-export.csv",
            bytes: 2048
        )
    ) {
        active = FakeSubject(activeImport)
        self.importFailure = FakeSubject(importFailure)
        self.exportResult = FakeSubject(exportResult)
    }

    public func startImport(fileURL: URL, format: ImportFormat) async -> ImportStartResult {
        calls.record("startImport")
        if let failure = importFailure.value { return .failed(failure) }
        let job = ImportJob(
            id: "fake-import",
            status: .queued,
            format: format,
            createdAt: Fixtures.now,
            updatedAt: Fixtures.now
        )
        active.send(job)
        return .started(job)
    }

    public func activeImport() -> AsyncStream<ImportJob?> { active.stream() }
    public func resumeTracking(jobId: String) { calls.record("resumeTracking") }
    public func dismissImport() async { active.send(nil) }

    public func export(format: ExportFormat) async -> ExportResult {
        calls.record("export")
        return exportResult.value
    }

    public func fileInfo(_ fileURL: URL) -> PickedFile? {
        PickedFile(name: fileURL.lastPathComponent, sizeBytes: 4096)
    }
}
