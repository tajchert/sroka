import Dependencies
import Foundation
import GRDB
import ShareFeature
import SrokaContent
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import SrokaSession
import SrokaSync

/// Build values the share extension reads from its Info.plist.
public struct ShareConfiguration: Sendable, Equatable {
    /// Keychain service of the session item; the app's composition root uses the same one.
    public static let keychainService = "app.sroka.session"

    public var environment: AppEnvironment
    public var appVersion: String
    /// `$(AppIdentifierPrefix)` (team id plus a dot); empty or unexpanded in unsigned builds.
    public var appIdentifierPrefix: String

    public init(environment: AppEnvironment, appVersion: String, appIdentifierPrefix: String) {
        self.environment = environment
        self.appVersion = appVersion
        self.appIdentifierPrefix = appIdentifierPrefix
    }

    public init?(infoDictionary: [String: Any]) {
        guard let environment = AppEnvironment(infoDictionary: infoDictionary) else { return nil }
        self.init(
            environment: environment,
            appVersion: infoDictionary["CFBundleShortVersionString"] as? String ?? "0",
            appIdentifierPrefix: infoDictionary["AppIdentifierPrefix"] as? String ?? ""
        )
    }

    /// The shared Keychain access group, or nil (default group) when the build carries no team prefix.
    public var keychainAccessGroup: String? {
        if appIdentifierPrefix.isEmpty || appIdentifierPrefix.hasPrefix("$(") { return nil }
        return appIdentifierPrefix + environment.keychainAccessGroup
    }
}

/// The share extension's live services over the App Group database the app created.
///
/// The extension never migrates, never wipes and never downloads articles: it writes ops locally (each write is one
/// committed `IMMEDIATE` transaction, so the app sees it on its next read) and pushes once. The app must call
/// `AppDatabase.notifyExternalChanges()` when it becomes active to refresh its observations.
public struct ShareGraph: Sendable {
    /// How long the sheet waits for one push before giving up; the app pushes the rest later.
    public static let pushTimeout: Duration = .seconds(3)

    public let environment: AppEnvironment
    let database: AppDatabase
    let library: LiveLibraryRepository
    let tags: LiveTagRepository
    let auth: ShareAuthRepository
    let uploader: SharePdfUploader
    let engine: SyncEngine
    let account: ShareAccount
    let gate: ShareWriteGate
    let clock: any Clock<Duration>

    /// The graph, or why the sheet cannot save.
    public enum Opening: Sendable {
        case ready(ShareGraph)
        case failed(ShareStartup)
    }

    /// Opens the live graph from the extension's configuration.
    public static func open(_ configuration: ShareConfiguration) -> Opening {
        let environment = configuration.environment
        let group = environment.appGroupIdentifier
        let databaseURL = AppDatabase.sharedFileURL(groupIdentifier: group)
        let database: AppDatabase
        switch startup(databaseURL: databaseURL, open: AppDatabase.openForExtension(at:)) {
        case .opened(let opened): database = opened
        case .failed(let startup): return .failed(startup)
        }
        guard let paths = ContentPaths.appGroup(group),
            let preferences = PreferencesStore(appGroup: group)
        else {
            shareLog.error("share storage unavailable")
            return .failed(.unavailable)
        }
        let keychain = KeychainSecureStore(
            service: ShareConfiguration.keychainService, accessGroup: configuration.keychainAccessGroup)
        let sessionStore = SessionStore(store: keychain)
        let epochURL = WipeEpoch.url(besideDatabaseAt: databaseURL ?? URL(filePath: database.writer.path))
        let account = ShareAccount(
            launch: sessionStore.current,
            stored: { SessionStore(store: keychain).current },
            deviceId: { sessionStore.existingDeviceId() },
            accountServer: { preferences.accountServer },
            launchEpoch: epochURL.flatMap(WipeEpoch.read(at:)),
            epoch: { epochURL.flatMap(WipeEpoch.read(at:)) })
        let provider = ShareApiSessionProvider(
            base: LiveApiSessionProvider(
                sessionStore: sessionStore, preferences: preferences,
                defaultServerUrl: environment.apiBaseURL.absoluteString),
            account: account)
        let api = HTTPSrokaAPI(provider: provider, identity: ClientIdentity(appVersion: configuration.appVersion))
        return .ready(
            ShareGraph(
                environment: environment, database: database, api: api,
                endpointUsable: { await provider.endpoint().token != nil }, sessionStore: sessionStore,
                account: account, clockStore: DefaultsOpClockStore.appGroup(group), paths: paths))
    }

    /// The startup decision: the database must exist and be fully migrated by the app.
    static func startup(
        databaseURL: URL?,
        open: (URL) throws -> AppDatabase
    ) -> DatabaseStartup {
        guard let databaseURL else {
            shareLog.error("share app group unavailable")
            return .failed(.unavailable)
        }
        do {
            return .opened(try open(databaseURL))
        } catch DatabaseOpenError.needsAppUpdate, DatabaseOpenError.supersededSchema {
            // Missing, unmigrated (app never opened or an update is pending) or written by a newer app.
            return .failed(.needsApp)
        } catch {
            shareLog.error("share database open failed")
            return .failed(.unavailable)
        }
    }

    enum DatabaseStartup {
        case opened(AppDatabase)
        case failed(ShareStartup)
    }

    init(
        environment: AppEnvironment,
        database: AppDatabase,
        api: any SrokaAPI,
        endpointUsable: @escaping @Sendable () async -> Bool = { true },
        sessionStore: SessionStore,
        account: ShareAccount,
        clockStore: any OpClockStore,
        paths: ContentPaths,
        now: @escaping @Sendable () -> Int64 = systemNowMillis,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let controller = ShareSyncController()
        let api = ShareAPI(base: api, account: account, endpointUsable: endpointUsable)
        let gate = ShareWriteGate(account: account)
        // Every commit on this connection re-checks the account inside its transaction.
        database.writer.add(transactionObserver: ShareCommitCheck(account: account), extent: .databaseLifetime)
        let writer = OpWriter(
            database: database, opClock: OpClock(now: now, store: clockStore), now: now, admission: gate)
        self.environment = environment
        self.database = database
        self.clock = clock
        library = LiveLibraryRepository(
            database: database, writer: writer, syncController: controller, thumbnailBase: paths.root)
        tags = LiveTagRepository(database: database, writer: writer, syncController: controller)
        auth = ShareAuthRepository(store: sessionStore)
        // Copies each PDF into the App Group queue first, then uploads while the sheet is up; the app's
        // `resumePendingUploads()` finishes whatever the extension could not.
        // No thumbnail here: PDFKit may decode a first-page scan at full size, past the extension's memory limit.
        uploader = SharePdfUploader(
            base: LivePdfUploader(
                api: api, paths: paths, syncController: controller, renderThumbnail: { _ in nil },
                owner: { [launch = account.launch] in launch?.ownerKey }),
            account: account)
        self.account = account
        self.gate = gate
        engine = SyncEngine(
            database: database, api: api, session: ShareSyncSession(store: sessionStore, account: account), now: now)
    }

    /// Sets the services the save sheet and the tag editor use.
    public func install(into values: inout DependencyValues) {
        values.appEnvironment = environment
        values.libraryRepository = library
        values.tagRepository = tags
        values.authRepository = auth
        values.pdfUploader = uploader
        values.syncController = ShareSyncController()
    }

    /// One push batch, at most `pushTimeout`. Never throws: a failed or slow push leaves the ops queued for the app.
    public func pushOnce() async {
        // Without the app's device id, or signed out / another account since launch (the queue may now be the new
        // account's): leave the push to the app.
        guard account.canSend else { return }
        let engine = engine
        let gate = gate
        await withTimeout(Self.pushTimeout, clock: clock) {
            // Through the write gate: a push the timeout cancelled may still be writing its bookkeeping, and
            // `closeWrites` must wait for it before the database is suspended.
            let outcome = try? await gate.admit { await engine.pushOnce() }
            if case .success? = outcome { return }
            shareLog.info("share push deferred to the app")
        }
    }

    /// The sheet is closing: refuses new local writes and pushes and waits for the running ones (a tag save the editor
    /// left behind, a favorite, a cancelled push still unwinding), so the database is never suspended under a commit.
    public func closeWrites() async {
        await gate.closeAndDrain()
    }
}
