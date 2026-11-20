import Dependencies
import SrokaCore

/// One connected set of fakes (the tag, content and sync fakes share the library's items).
/// Keep a reference in tests to drive and inspect state:
///
/// ```swift
/// let fakes = Fakes()
/// let model = withDependencies { $0.useFakes(fakes) } operation: { LibraryViewModel() }
/// await model.archiveSwiped(id: "a1")
/// #expect(fakes.library.item(id: "a1")?.status == .archived)
/// ```
public struct Fakes: Sendable {
    public var library: FakeLibraryRepository
    public var tags: FakeTagRepository
    public var auth: FakeAuthRepository
    public var account: FakeAccountRepository
    public var settings: FakeSettingsRepository
    public var consent: FakeConsentRepository
    public var dataTransfer: FakeDataTransferRepository
    public var content: FakeContentStore
    public var pdfUploader: FakePdfUploader
    public var syncStatus: FakeSyncStatusRepository
    public var syncController: FakeSyncController
    public var telemetry: RecordingTelemetry
    public var pushRegistrar: FakePushRegistrar

    public init(
        items: [Item] = Fixtures.items,
        session: SessionState = .signedIn(email: Fixtures.email),
        preferences: UserPreferences = UserPreferences(),
        syncStatus: SyncStatus = Fixtures.syncStatus
    ) {
        library = FakeLibraryRepository(items: items)
        tags = FakeTagRepository(library: library)
        auth = FakeAuthRepository(session: session)
        account = FakeAccountRepository()
        settings = FakeSettingsRepository(preferences: preferences)
        consent = FakeConsentRepository()
        dataTransfer = FakeDataTransferRepository()
        content = FakeContentStore(library: library)
        pdfUploader = FakePdfUploader()
        self.syncStatus = FakeSyncStatusRepository(status: syncStatus)
        syncController = FakeSyncController(status: self.syncStatus)
        telemetry = RecordingTelemetry()
        pushRegistrar = FakePushRegistrar()
    }

    /// An empty, signed-in library (empty states, onboarding).
    public static var empty: Fakes { Fakes(items: [], syncStatus: SyncStatus()) }
}

extension DependencyValues {
    /// Installs every domain dependency from one `Fakes` set (previews, tests, snapshots and, until
    /// the live engine lands, the app's composition root).
    public mutating func useFakes(_ fakes: Fakes = Fakes()) {
        libraryRepository = fakes.library
        tagRepository = fakes.tags
        authRepository = fakes.auth
        accountRepository = fakes.account
        settingsRepository = fakes.settings
        consentRepository = fakes.consent
        dataTransferRepository = fakes.dataTransfer
        contentStore = fakes.content
        pdfUploader = fakes.pdfUploader
        syncStatusRepository = fakes.syncStatus
        syncController = fakes.syncController
        telemetry = fakes.telemetry
        pushRegistrar = fakes.pushRegistrar
    }
}
