import Dependencies
import Foundation
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
    let uploader: LivePdfUploader
    let engine: SyncEngine
    let sessionStore: SessionStore
    let storedToken: @Sendable () -> String?
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
        guard let databaseURL, let paths = ContentPaths.appGroup(group),
            let preferences = PreferencesStore(appGroup: group)
        else {
            shareLog.error("share storage unavailable")
            return .failed(.unavailable)
        }
        let keychain = KeychainSecureStore(
            service: ShareConfiguration.keychainService, accessGroup: configuration.keychainAccessGroup)
        let sessionStore = SessionStore(store: keychain)
        let api = HTTPSrokaAPI(
            provider: ShareApiSessionProvider(
                base: LiveApiSessionProvider(
                    sessionStore: sessionStore, preferences: preferences,
                    defaultServerUrl: environment.apiBaseURL.absoluteString),
                store: sessionStore,
                storedToken: { SessionStore(store: keychain).token }),
            identity: ClientIdentity(appVersion: configuration.appVersion))
        return .ready(
            ShareGraph(
                environment: environment, database: database, databaseURL: databaseURL, api: api,
                sessionStore: sessionStore, storedToken: { SessionStore(store: keychain).token }, paths: paths))
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
        databaseURL: URL,
        api: any SrokaAPI,
        sessionStore: SessionStore,
        storedToken: @escaping @Sendable () -> String?,
        paths: ContentPaths,
        now: @escaping @Sendable () -> Int64 = systemNowMillis,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let controller = ShareSyncController()
        let writer = OpWriter(
            database: database, opClock: OpClock(now: now, store: FileOpClockStore(besideDatabaseAt: databaseURL)),
            now: now)
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
        uploader = LivePdfUploader(
            api: api, paths: paths, syncController: controller, renderThumbnail: { _ in nil })
        self.sessionStore = sessionStore
        self.storedToken = storedToken
        engine = SyncEngine(database: database, api: api, session: ShareSyncSession(store: sessionStore), now: now)
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
        // The app creates the device id at sign-in; without it, leave the push to the app.
        guard sessionStore.existingDeviceId() != nil else { return }
        // Signed out or another account since launch: the queue may now be the new account's.
        guard let token = sessionStore.token, storedToken() == token else { return }
        let engine = engine
        await withTimeout(Self.pushTimeout, clock: clock) {
            let outcome = await engine.pushOnce()
            if case .success = outcome { return }
            shareLog.info("share push deferred to the app")
        }
    }
}
