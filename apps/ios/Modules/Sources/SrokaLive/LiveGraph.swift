import Dependencies
import Foundation
import SrokaContent
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import SrokaSession
import SrokaSync

/// Persists the op clock in the App Group suite, which the share extension shares.
public struct DefaultsOpClockStore: OpClockStore {
    public static let key = "sroka.opClock.last"
    /// `UserDefaults` is thread-safe; it is not marked `Sendable` in every SDK (same as `PreferencesStore`).
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> Int64 {
        (defaults.object(forKey: Self.key) as? NSNumber)?.int64Value ?? 0
    }

    public func save(_ value: Int64) {
        defaults.set(NSNumber(value: value), forKey: Self.key)
    }
}

/// Inputs of the live graph that come from the app bundle.
public struct LiveConfiguration: Sendable {
    public var environment: AppEnvironment
    /// `CFBundleShortVersionString`, sent as the User-Agent.
    public var appVersion: String
    /// `CFBundleVersion` as a number, compared with `/v1/config` `minVersions.ios`.
    public var build: Int?
    /// The team prefix (`ABCDE12345.`) from Info.plist `AppIdentifierPrefix`; nil or empty uses the default group.
    public var appIdentifierPrefix: String?
    /// The crash/analytics SDK (stream M). Wrapped in consent gating here.
    public var telemetry: any Telemetry
    public var backgroundScheduler: any BackgroundScheduling

    public init(
        environment: AppEnvironment,
        appVersion: String,
        build: Int?,
        appIdentifierPrefix: String?,
        telemetry: any Telemetry = NoTelemetry(),
        backgroundScheduler: any BackgroundScheduling = SystemBackgroundScheduler()
    ) {
        self.environment = environment
        self.appVersion = appVersion
        self.build = build
        self.appIdentifierPrefix = appIdentifierPrefix
        self.telemetry = telemetry
        self.backgroundScheduler = backgroundScheduler
    }

    /// Keychain service for the session item. The share extension must use the same value.
    public static let keychainService = "app.sroka.session"

    /// The full Keychain access group, or nil when the team prefix is unknown (simulator builds without a team).
    public var keychainAccessGroup: String? {
        guard let prefix = appIdentifierPrefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty,
            !prefix.hasPrefix("$(")
        else { return nil }
        return prefix + environment.keychainAccessGroup
    }
}

/// The app's one dependency graph: database in the App Group, network, session, sync, content and the repositories
/// the features use. Built once per process by the composition root.
public final class LiveGraph: Sendable {
    public let configuration: LiveConfiguration
    public let database: AppDatabase
    public let sessionStore: SessionStore
    public let preferences: PreferencesStore
    public let api: HTTPSrokaAPI
    public let content: LiveContentStore
    public let uploader: LivePdfUploader
    public let hooks: LiveContentHooks
    public let scheduler: SyncScheduler
    public let wipeGuard: WipeGuard
    public let suspension: SuspensionGate
    public let importTracker: ImportTracker
    public let syncSession: LiveSyncSession

    public let library: any LibraryRepository
    public let tags: any TagRepository
    public let auth: LiveAuthRepository
    public let account: any AccountRepository
    public let settings: any SettingsRepository
    public let consent: any ConsentRepository
    public let dataTransfer: any DataTransferRepository
    public let pdfUploader: any PdfUploader
    public let syncStatus: any SyncStatusRepository
    public let telemetry: any Telemetry
    private let consentApplier: ConsentApplier
    private let provider: LiveApiSessionProvider

    public init(configuration: LiveConfiguration) {
        self.configuration = configuration
        let environment = configuration.environment
        let group = environment.appGroupIdentifier
        let background = configuration.backgroundScheduler

        // Stores. A missing App Group (unsigned build) falls back to app-private storage: the app works, the share
        // extension does not see its data.
        let preferences: PreferencesStore
        if let shared = PreferencesStore(appGroup: group) {
            preferences = shared
        } else {
            liveLog.error("App Group unavailable: preferences fall back to the app's own defaults")
            preferences = PreferencesStore(defaults: .standard)
        }
        let opClockDefaults = UserDefaults(suiteName: group) ?? .standard
        let sessionStore = SessionStore(
            store: KeychainSecureStore(
                service: LiveConfiguration.keychainService, accessGroup: configuration.keychainAccessGroup))
        let database = Self.openDatabase(group: group)
        let paths = ContentPaths.appGroup(group) ?? Self.fallbackContentPaths()

        // Network: the provider pairs each token with the server that issued it.
        let provider = LiveApiSessionProvider(
            sessionStore: sessionStore, preferences: preferences,
            defaultServerUrl: environment.apiBaseURL.absoluteString)
        let identity = ClientIdentity(appVersion: configuration.appVersion)
        let api = HTTPSrokaAPI(provider: provider, identity: identity)
        let wifiOnlyAPI = HTTPSrokaAPI(
            provider: provider, identity: identity, session: LiveContentStore.makeWifiOnlySession())

        // Session as sync sees it; a 401 anywhere marks it expired (ignored during a wipe).
        let wipeGuard = WipeGuard()
        let suspension = SuspensionGate(suspend: { AppDatabase.suspend() }, resume: { AppDatabase.resume() })
        let syncSession = LiveSyncSession(store: sessionStore, guard: wipeGuard)
        let onUnauthorized: @Sendable () async -> Void = { await syncSession.markExpired() }

        // Content and sync.
        let content = LiveContentStore(
            database: database, api: api, wifiOnlyAPI: wifiOnlyAPI, paths: paths, onUnauthorized: onUnauthorized)
        let hooks = LiveContentHooks(
            content: content,
            policy: { preferences.preferences.downloadPolicy },
            guard: wipeGuard,
            onDeferred: { background.scheduleDownload() })
        let network = PathNetworkStatus()
        let engine = SyncEngine(database: database, api: api, session: syncSession, hooks: hooks)
        let scheduler = SyncScheduler(engine: engine, session: syncSession, hooks: hooks, network: network)
        let writer = OpWriter(
            database: database,
            opClock: OpClock(now: systemNowMillis, store: DefaultsOpClockStore(defaults: opClockDefaults)),
            admission: wipeGuard)
        let uploader = LivePdfUploader(
            api: api, paths: paths, syncController: scheduler, onUnauthorized: onUnauthorized)

        // Session engine.
        let importJobs = ImportJobStore(preferences: preferences)
        let importTracker = ImportTracker(
            api: api, store: importJobs, sessionStore: sessionStore, clock: ContinuousClock(),
            onFinished: { _ in scheduler.requestSync() })
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dataTransfer = LiveDataTransferRepository(
            api: api, jobs: importJobs, tracker: importTracker, sessionStore: sessionStore, cachesDirectory: caches)
        let wiper = GuardedWiper(
            LocalDataWiper(
                database: database,
                cancelAllWork: {
                    // Joined, not just cancelled: no automatic download may write files after the content is removed.
                    await hooks.cancelAutomaticAndWait()
                    uploader.cancelAll()
                    importTracker.stop()
                    background.cancelAll()
                },
                clearTables: {
                    // The guard is up, so no local write starts; let the ones already running commit first.
                    await wipeGuard.drainWrites()
                    try await scheduler.wipe { try await database.write { try MaintenanceDao.wipeAll($0) } }
                },
                deleteFiles: { await content.removeAllContent() },
                transferDirectories: dataTransfer.transferDirectories,
                sessionStore: sessionStore,
                preferences: preferences,
                importJobs: importJobs),
            guard: wipeGuard, suspension: suspension)
        let auth = LiveAuthRepository(
            api: api, sessionStore: sessionStore, preferences: preferences, provider: provider, wiper: wiper,
            hasLocalData: { await LiveAuthRepository.hasAccountData(in: database) },
            requestSync: { scheduler.requestSync() },
            clock: ContinuousClock())

        // Telemetry: consent gated; the decorators log enum-only events.
        let telemetry = ConsentGatedTelemetry(configuration.telemetry, consent: { preferences.consent })
        let consent = LiveConsentRepository(store: preferences)

        self.database = database
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.api = api
        self.content = content
        self.uploader = uploader
        self.hooks = hooks
        self.scheduler = scheduler
        self.wipeGuard = wipeGuard
        self.suspension = suspension
        self.provider = provider
        self.importTracker = importTracker
        self.syncSession = syncSession
        self.auth = auth
        self.library = TelemetryLibraryRepository(
            LiveLibraryRepository(
                database: database, writer: writer, syncController: scheduler, hooks: hooks, thumbnailBase: paths.root),
            telemetry: telemetry)
        self.tags = LiveTagRepository(database: database, writer: writer, syncController: scheduler)
        self.account = LiveAccountRepository(api: api, auth: auth)
        self.settings = LiveSettingsRepository(
            store: preferences, sessionStore: sessionStore, auth: auth,
            defaultServerUrl: environment.apiBaseURL.absoluteString,
            onDownloadPolicyChanged: { hooks.policyChanged($0) })
        self.consent = consent
        self.dataTransfer = TelemetryDataTransferRepository(dataTransfer, telemetry: telemetry)
        self.pdfUploader = TelemetryPdfUploader(uploader, telemetry: telemetry)
        self.syncStatus = LiveSyncStatusRepository(
            database: database, scheduler: scheduler, session: syncSession, hooks: hooks, network: network)
        self.telemetry = telemetry
        // The SDK starts with collection off (Info.plist); the applier turns on what the stored consent allows.
        self.consentApplier = ConsentApplier(consent: consent, telemetry: telemetry)
    }

    /// Registers every live implementation for its `@Dependency` key and starts applying telemetry consent.
    public func install(into dependencies: inout DependencyValues) {
        consentApplier.start()
        dependencies.appEnvironment = configuration.environment
        dependencies.libraryRepository = library
        dependencies.tagRepository = tags
        dependencies.authRepository = auth
        dependencies.accountRepository = account
        dependencies.settingsRepository = settings
        dependencies.consentRepository = consent
        dependencies.dataTransferRepository = dataTransfer
        dependencies.contentStore = content
        dependencies.pdfUploader = pdfUploader
        dependencies.syncStatusRepository = syncStatus
        dependencies.syncController = scheduler
        dependencies.telemetry = telemetry
    }

    // MARK: Session

    /// Signed in and not in the middle of a wipe: the state in which sync, uploads and imports may run.
    public var isSignedIn: Bool {
        guard !wipeGuard.isWiping, let session = sessionStore.current else { return false }
        return !session.expired
    }

    /// The server requests go to now (custom server or the build default); version answers are keyed by it.
    public func currentServer() -> String { provider.currentServer() }

    /// `/v1/config` `minVersions.ios`; nil when the read failed.
    public func fetchMinimumBuild() async -> Int?? {
        do {
            return .some(try await api.config().minVersions.ios)
        } catch {
            liveLog.notice("Config check failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    // MARK: Lifecycle

    public func lifecycleActions() -> LifecycleActions {
        let background = configuration.backgroundScheduler
        return LifecycleActions(
            enterForeground: { [suspension] in suspension.enterForeground() },
            enterBackground: { [suspension] in suspension.enterBackground() },
            holdDatabase: { [suspension] in
                let hold = suspension.hold()
                return { hold.release() }
            },
            reloadStores: { [sessionStore, preferences] in
                sessionStore.reload()
                preferences.reload()
            },
            notifyExternalChanges: { [database] in
                do {
                    try await database.notifyExternalChanges()
                } catch {
                    liveLog.error("External change check failed: \(String(describing: error), privacy: .public)")
                }
            },
            isSignedIn: { [self] in isSignedIn },
            recoverInterrupted: { [content] in await content.recoverInterrupted() },
            resumePendingUploads: { [uploader] in uploader.resumePendingUploads() },
            resumeImport: { [importTracker] in importTracker.resumeIfNeeded() },
            requestSync: { [scheduler] in scheduler.requestSync() },
            pendingOpCount: { [database] in
                (try? await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_ops") ?? 0 })
                    ?? 0
            },
            syncNow: { [scheduler] in _ = await scheduler.syncNow() },
            cancelAutomaticDownloads: { [hooks] in hooks.cancelAutomatic() },
            setDownloadsForeground: { [hooks] in hooks.setForeground($0) },
            scheduleRefresh: { background.scheduleRefresh() },
            needsBackgroundDownload: { [self] in await needsBackgroundDownload() },
            scheduleDownload: { background.scheduleDownload() })
    }

    /// The work of the background tasks.
    public func backgroundJobs() -> BackgroundJobs {
        let background = configuration.backgroundScheduler
        return BackgroundJobs(
            refresh: { [self] in
                sessionStore.reload()
                preferences.reload()
                // Signed out: nothing to sync, and no next refresh until the user signs in again.
                guard isSignedIn else { return true }
                background.scheduleRefresh()
                return await suspension.holding {
                    try? await self.database.notifyExternalChanges()
                    return await self.scheduler.handleBackgroundRefresh()
                }
            },
            download: { [self] in
                preferences.reload()
                sessionStore.reload()
                guard isSignedIn else { return true }
                await suspension.holding {
                    await self.content.recoverInterrupted()
                    await self.hooks.runAutomaticNow()
                }
                if Task.isCancelled { return false }
                // Anything left (time ran out, network dropped): try again in a later window.
                if await needsBackgroundDownload() { background.scheduleDownload() }
                return true
            })
    }

    private func needsBackgroundDownload() async -> Bool {
        guard isSignedIn, preferences.preferences.downloadPolicy != .manual else { return false }
        return await content.eligibleCount() > 0
    }

    // MARK: Opening

    private static func openDatabase(group: String) -> AppDatabase {
        let url =
            AppDatabase.sharedFileURL(groupIdentifier: group)
            ?? URL.applicationSupportDirectory.appending(path: AppDatabase.fileName)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try AppDatabase.openShared(at: url)
        } catch {
            liveLog.fault("Database open failed, using memory: \(String(describing: error), privacy: .public)")
            do {
                return try AppDatabase.inMemory()
            } catch {
                fatalError("In-memory database failed to open: \(error)")
            }
        }
    }

    private static func fallbackContentPaths() -> ContentPaths {
        liveLog.error("App Group unavailable: article files fall back to Application Support")
        return ContentPaths(
            root: URL.applicationSupportDirectory.appending(path: "Content", directoryHint: .isDirectory))
    }
}
