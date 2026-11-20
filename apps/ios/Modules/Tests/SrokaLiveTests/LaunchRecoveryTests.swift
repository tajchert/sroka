import Foundation
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import SrokaSession
import Synchronization
import Testing

@testable import SrokaLive

/// A file database (the wipe epoch lives beside it), a signed-in session with one queued op, and the graph's launch
/// recovery over a real `LocalDataWiper`.
@MainActor
private final class LaunchHarness {
    let directory: URL
    let database: AppDatabase
    let sessionStore = SessionStore(store: InMemorySecureStore())
    let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let wipeGuard = WipeGuard()
    let log = StepLog()
    let recovery: LaunchRecovery

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.openShared(at: directory.appending(path: AppDatabase.fileName))
        self.database = database
        try sessionStore.save(token: "t", email: "a@b.co", server: "https://api.example")
        preferences.accountEmail = "a@b.co"
        preferences.accountServer = "https://api.example"
        let log = log
        let wipeGuard = wipeGuard
        let local = LocalDataWiper(
            database: database,
            cancelAllWork: { log.add(wipeGuard.isWiping ? "cancel:guarded" : "cancel:unguarded") },
            clearTables: {
                log.add("tables")
                try await database.write { try MaintenanceDao.wipeAll($0) }
            },
            deleteFiles: {},
            transferDirectories: [],
            sessionStore: sessionStore,
            preferences: preferences,
            importJobs: ImportJobStore(preferences: preferences))
        recovery = LiveGraph.launchRecovery(
            interrupted: { LiveGraph.hasInterruptedWipe(database) },
            serialize: { await $0() },
            wiper: GuardedWiper(local, guard: wipeGuard),
            local: local)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var epochURL: URL { WipeEpoch.url(besideDatabaseAt: directory.appending(path: AppDatabase.fileName))! }

    func insertOp() async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_ops (op_id, type, payload, created_at)
                    VALUES ('op-1', 'item.add', '{}', 0)
                    """)
        }
    }

    func opCount() async throws -> Int {
        try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_ops") ?? 0 }
    }

    /// The app's launch: the root model and the first activation, both behind launch recovery.
    func launch() async throws -> (model: AppModel, activation: StepLog) {
        let sessionStore = sessionStore
        let recovery = recovery
        let model = AppModel(
            sessionStates: { sessionStore.state }, versionGate: .alwaysSupported(),
            deepLinks: DeepLinkInbox(scheme: "sroka-dev"), ready: { await recovery.ready() })
        let activation = StepLog()
        let lifecycle = AppLifecycle(
            actions: LifecycleActions(
                enterForeground: {}, enterBackground: {}, holdDatabase: { {} }, reloadStores: {},
                notifyExternalChanges: {},
                isSignedIn: { sessionStore.current.map { !$0.expired } ?? false },
                recoverInterrupted: {}, resumePendingUploads: { activation.add("uploads") },
                resumeImport: { activation.add("import") }, requestSync: { activation.add("sync") },
                pendingOpCount: { 0 }, syncNow: { activation.add("syncNow") }, cancelAutomaticDownloads: {},
                setDownloadsForeground: { _ in }, scheduleRefresh: {}, needsBackgroundDownload: { false },
                scheduleDownload: {}, ready: { await recovery.ready() }))
        model.start()
        await lifecycle.activate()
        for _ in 0..<2000 where model.session == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        return (model, activation)
    }
}

@MainActor
struct LaunchRecoveryTests {
    @Test func `An interrupted wipe finishes before the session reaches the root and before any account work`()
        async throws
    {
        let h = try LaunchHarness()
        try await h.insertOp()
        try WipeEpoch.begin(at: h.epochURL)

        let (model, activation) = try await h.launch()

        // The root never saw the old account's session, and activation found nobody signed in.
        #expect(model.session == .signedOut)
        #expect(activation.all.isEmpty)
        #expect(h.log.all.first == "cancel:guarded")
        #expect(try await h.opCount() == 0)
        #expect(h.sessionStore.current == nil)
        #expect(!WipeEpoch.isWiping(WipeEpoch.read(at: h.epochURL)))
        #expect(!h.wipeGuard.isWiping)
    }

    @Test func `With no interrupted wipe nothing is wiped and nothing is written`() async throws {
        let h = try LaunchHarness()
        try await h.insertOp()

        let (model, activation) = try await h.launch()

        #expect(h.log.all.isEmpty)
        #expect(try await h.opCount() == 1)
        #expect(model.session == .signedIn(email: "a@b.co"))
        #expect(activation.all == ["uploads", "import", "sync"])
        #expect(!FileManager.default.fileExists(atPath: h.epochURL.path))
    }

    @Test func `Concurrent callers share one recovery run`() async {
        let runs = Mutex(0)
        let recovery = LaunchRecovery { runs.withLock { $0 += 1 } }
        async let first: Void = recovery.ready()
        async let second: Void = recovery.ready()
        _ = await (first, second)
        await recovery.ready()
        #expect(runs.withLock { $0 } == 1)
    }
}

struct UploadAPITests {
    @Test func `The live uploader gets no API for a PDF another account queued`() async throws {
        let server = "https://api.example"
        let sessionStore = SessionStore(store: InMemorySecureStore())
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try sessionStore.save(token: "t", email: "a@b.co", server: server)
        preferences.accountServer = server
        let provider = LiveApiSessionProvider(
            sessionStore: sessionStore, preferences: preferences, defaultServerUrl: server)
        let api = HTTPSrokaAPI(provider: provider, identity: ClientIdentity(appVersion: "1"))
        let uploadAPI = LiveGraph.uploadAPI(api: api, provider: provider, sessionStore: sessionStore)
        let own = try #require(sessionStore.current?.ownerKey)
        let other = StoredSession(token: "u", email: "c@d.co", expired: false, server: server).ownerKey

        #expect(await uploadAPI(other) == nil)
        #expect(await uploadAPI(own) != nil)
    }
}

/// The App Group suite goes with an uninstall, the Keychain does not.
struct FirstRunTests {
    private let keychain = InMemorySecureStore()
    private let preferences = PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

    /// What a reinstall finds: an earlier install's session and device id in the Keychain.
    private func earlierInstall() throws -> SessionStore {
        let earlier = SessionStore(store: keychain)
        try earlier.save(token: "t", email: "a@b.co", server: "https://api.example")
        _ = earlier.deviceId()
        return SessionStore(store: keychain)
    }

    @Test func `A fresh install starts signed out with a new device id`() throws {
        let sessionStore = try earlierInstall()
        let earlierDevice = try #require(sessionStore.existingDeviceId())
        let fresh = SessionStore(store: keychain)
        LiveGraph.clearEarlierInstall(preferences: preferences, sessionStore: fresh)

        #expect(fresh.current == nil)
        #expect(SessionStore(store: keychain).current == nil)
        #expect(fresh.existingDeviceId() == nil)
        #expect(fresh.deviceId() != earlierDevice)
        #expect(preferences.installMarker)
    }

    @Test func `An app update keeps the session`() throws {
        let sessionStore = try earlierInstall()
        preferences.installMarker = true
        preferences.accountEmail = "a@b.co"
        LiveGraph.clearEarlierInstall(preferences: preferences, sessionStore: sessionStore)

        #expect(sessionStore.current?.email == "a@b.co")
        #expect(SessionStore(store: keychain).current?.token == "t")
    }

    @Test func `An update from a build before the marker keeps the session and sets the marker`() throws {
        let sessionStore = try earlierInstall()
        preferences.accountEmail = "a@b.co"
        LiveGraph.clearEarlierInstall(preferences: preferences, sessionStore: sessionStore)

        #expect(sessionStore.current?.token == "t")
        #expect(preferences.installMarker)
    }

    @Test func `A Keychain that refuses leaves the marker unset for the next launch`() throws {
        let sessionStore = try earlierInstall()
        keychain.setFailure(SecureStoreError(status: -25308))
        LiveGraph.clearEarlierInstall(preferences: preferences, sessionStore: sessionStore)
        #expect(!preferences.installMarker)

        keychain.setFailure(nil)
        LiveGraph.clearEarlierInstall(preferences: preferences, sessionStore: sessionStore)
        #expect(SessionStore(store: keychain).current == nil)
        #expect(preferences.installMarker)
    }

    @Test func `Launch recovery clears an earlier install before anything else`() async throws {
        let log = StepLog()
        let local = LocalDataWiper(
            database: try AppDatabase.inMemory(),
            cancelAllWork: {}, clearTables: {}, deleteFiles: {}, transferDirectories: [],
            sessionStore: SessionStore(store: InMemorySecureStore()), preferences: preferences,
            importJobs: ImportJobStore(preferences: preferences))
        let recovery = LiveGraph.launchRecovery(
            firstRun: { log.add("firstRun") },
            interrupted: {
                log.add("interrupted")
                return false
            },
            serialize: { await $0() },
            wiper: GuardedWiper(local, guard: WipeGuard()),
            local: local)
        await recovery.ready()
        #expect(log.all == ["firstRun", "interrupted"])
    }
}
