import Clocks
import Dependencies
import Foundation
import GRDB
import ShareFeature
import SrokaContent
import SrokaCore
import SrokaDatabase
import SrokaLive
import SrokaNetwork
import SrokaSession
import SrokaSync
import Synchronization
import Testing

@testable import SrokaShareLive

struct ShareStartupTests {
    let group = AppGroupFixture()

    func decision(_ url: URL?, open: (URL) throws -> AppDatabase = AppDatabase.openForExtension(at:)) -> ShareStartup? {
        if case .failed(let startup) = ShareGraph.startup(databaseURL: url, open: open) { return startup }
        return nil
    }

    @Test func `No App Group container is unavailable`() {
        #expect(decision(nil) == .unavailable)
    }

    @Test func `The app never opened: needs the app, and the extension creates no file`() {
        #expect(decision(group.databaseURL) == .needsApp)
        #expect(!FileManager.default.fileExists(atPath: group.databaseURL.path))
    }

    @Test func `An unmigrated file needs the app`() throws {
        try FileManager.default.createDirectory(
            at: group.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: group.databaseURL.path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE unrelated (id INTEGER)") }
        try queue.close()
        #expect(decision(group.databaseURL) == .needsApp)
    }

    @Test func `A schema written by a newer app needs the app`() {
        #expect(decision(group.databaseURL) { _ in throw DatabaseOpenError.supersededSchema } == .needsApp)
    }

    @Test func `Other open failures are unavailable`() {
        #expect(decision(group.databaseURL) { _ in throw DatabaseOpenError.coordinationFailed } == .unavailable)
    }

    @Test func `A database the app migrated is ready`() throws {
        try group.appOpened()
        #expect(decision(group.databaseURL) == nil)
    }
}

@MainActor
struct ShareGraphTests {
    let group = AppGroupFixture()
    let api = ShareFakeAPI()

    func model(_ graph: ShareGraph) -> ShareViewModel {
        withDependencies {
            graph.install(into: &$0)
            $0.continuousClock = TestClock()
        } operation: {
            ShareViewModel(startup: .ready, pushOnce: { await graph.pushOnce() })
        }
    }

    @Test func `A shared link is committed locally before the one push sends it`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        let group = group
        api.onPush { payloads in
            // At push time the item is already in the shared file (as another process sees it).
            let reader = try AppDatabase.openForExtension(at: group.databaseURL)
            let items = try await reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") }
            #expect(items == 1)
            return pushAnswer(payloads)
        }

        let model = model(graph)
        await model.start(.link(url: "https://example.com/article", title: nil))

        guard case .saved = model.state.phase else {
            Issue.record("not saved: \(model.state.phase)")
            return
        }
        #expect(api.events == ["push"])
        #expect(api.pushed.compactMap(type) == [WireOp.Kind.add.rawValue])
        #expect(try await group.queuedOps().isEmpty)
    }

    @Test func `A failed push is not an error and leaves the op queued for the app`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        api.onPush { _ in throw ApiError.transport(.notConnectedToInternet) }

        let model = model(graph)
        await model.start(.link(url: "https://example.com/offline", title: nil))

        guard case .saved = model.state.phase else {
            Issue.record("not saved: \(model.state.phase)")
            return
        }
        #expect(api.events == ["push"])
        #expect(try await group.queuedOps().map(\.type) == [WireOp.Kind.add.rawValue])
    }

    @Test func `A slow push gives up after the timeout and keeps the op`() async throws {
        try group.appOpened()
        let gate = Gate()
        let graph = try group.graph(api: api, clock: ImmediateClock())
        api.onPush { payloads in
            await gate.wait()
            throw CancellationError()
        }
        let saved = await graph.library.save(url: "https://example.com/slow", title: nil, tags: [], source: .share)
        guard case .saved = saved else {
            Issue.record("not saved")
            return
        }

        await graph.pushOnce()

        #expect(try await group.queuedOps().count == 1)
        gate.open()
    }

    @Test func `A 401 leaves the shared Keychain untouched and the op queued`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        api.onPush { _ in throw ApiError.http(status: 401, code: nil, message: nil, retryAfter: nil) }
        let before = group.secureStore.snapshot

        let model = model(graph)
        await model.start(.link(url: "https://example.com/expired", title: nil))

        #expect(api.events == ["push"])
        #expect(group.secureStore.snapshot == before)
        #expect(try await group.queuedOps().count == 1)
    }

    @Test func `Without the app's device id the link is saved and nothing is sent`() async throws {
        try group.appOpened(deviceId: false)
        let graph = try group.graph(api: api)
        let before = group.secureStore.snapshot

        let model = model(graph)
        await model.start(.link(url: "https://example.com/new-install", title: nil))

        #expect(api.events.isEmpty)
        #expect(group.secureStore.snapshot == before)
        #expect(try await group.queuedOps().count == 1)
    }

    @Test func `After an account switch in the app nothing is pushed with the old token`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        api.onPush { pushAnswer($0) }
        let saved = await graph.library.save(url: "https://example.com/a", title: nil, tags: [], source: .share)
        guard case .saved = saved else {
            Issue.record("not saved")
            return
        }
        // The app signs out and another account signs in while the sheet stays open.
        try group.appSwitched(signedInAs: "other-token")

        await graph.pushOnce()

        #expect(api.events.isEmpty)
        #expect(try await group.queuedOps().count == 1)
    }

    @Test func `Signed out: nothing is saved and nothing is sent`() async throws {
        try group.appOpened(signedIn: false)
        let graph = try group.graph(api: api)

        let model = model(graph)
        await model.start(.link(url: "https://example.com/article", title: nil))

        #expect(model.state.phase == .needsSignIn)
        #expect(api.events.isEmpty)
        #expect(try await group.queuedOps().isEmpty)
    }

    @Test func `A shared PDF waits in the App Group queue and the app picks it up`() async throws {
        try group.appOpened()
        let gate = Gate()
        let graph = try group.graph(api: api)
        api.onUpload { _, _ in
            // The extension is killed mid-upload.
            await gate.wait()
            throw CancellationError()
        }
        let source = group.root.appending(path: "Report.pdf")
        try Data("%PDF-1.7\n1 0 obj\n".utf8).write(to: source)

        let uploads = await graph.uploader.enqueue([source])
        let id = try #require(uploads.first?.id)
        let queued = try FileManager.default.contentsOfDirectory(atPath: group.paths.pdfUploads.path)
        #expect(Set(queued) == ["\(id).pdf", "\(id).json"])

        // The app (another process: its own uploader over the same App Group) resumes it.
        let appAPI = ShareFakeAPI()
        let appStarted = Gate()
        appAPI.onUpload { _, _ in
            appStarted.open()
            throw ApiError.http(status: 400, code: nil, message: nil, retryAfter: nil)
        }
        let owner = try #require(SessionStore(store: group.secureStore).current?.ownerKey)
        let appUploader = LivePdfUploader(
            api: appAPI, paths: group.paths, syncController: ShareSyncController(), renderThumbnail: { _ in nil },
            owner: { owner })
        appUploader.resumePendingUploads()
        await appStarted.wait()
        #expect(appAPI.events == ["upload:Report.pdf"])
        gate.open()
    }

    @Test func `Install points every service the sheet and tag editor use at the graph`() throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        var values = DependencyValues()
        graph.install(into: &values)
        #expect(values.appEnvironment == group.environment)
        #expect(values.libraryRepository is LiveLibraryRepository)
        #expect(values.tagRepository is LiveTagRepository)
        #expect(values.pdfUploader is SharePdfUploader)
    }

    @Test func `A share after the app signed out is refused and leaves no row`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        try group.appSwitched()

        let saved = await graph.library.save(url: "https://example.com/late", title: nil, tags: [], source: .share)

        if case .saved = saved { Issue.record("saved for a signed-out account") }
        #expect(try await group.queuedOps().isEmpty)
        #expect(try await group.itemCount() == 0)
    }

    @Test func `A commit is rolled back when the account goes inside its transaction`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        let group = group
        await #expect(throws: ShareAccountGone.self) {
            try await graph.database.write { db in
                try db.execute(
                    sql: "INSERT INTO pending_ops (op_id, type, payload, created_at) VALUES ('x', 'item.add', '{}', 0)")
                // The app's sign-out lands after the gate admitted the write, before it commits.
                try group.appSwitched(signedInAs: "other-token")
            }
        }
        #expect(try await group.queuedOps().isEmpty)
    }

    @Test func `After an account switch the API sends nothing, not even without a token`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        let account = group.account()
        let preferences = PreferencesStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        preferences.accountServer = AppGroupFixture.server
        let provider = ShareApiSessionProvider(
            base: LiveApiSessionProvider(
                sessionStore: SessionStore(store: group.secureStore), preferences: preferences,
                defaultServerUrl: AppGroupFixture.server),
            account: account)
        #expect(await provider.endpoint() == ApiEndpoint(baseUrl: URL(string: AppGroupFixture.server)!, token: "token"))

        try group.appSwitched(signedInAs: "other-token")

        #expect(await provider.endpoint() == ApiEndpoint(baseUrl: ShareApiSessionProvider.refused, token: nil))
        await #expect(throws: ApiError.invalidRequest) {
            _ = try await HTTPSrokaAPI(provider: provider, identity: ClientIdentity(appVersion: "1")).push(payloads: [])
        }
        await #expect(throws: ApiError.http(status: 401, code: nil, message: nil, retryAfter: nil)) {
            _ = try await ShareAPI(base: api, account: account, endpointUsable: { true }).push(payloads: ["{}"])
        }
        await graph.pushOnce()
        #expect(api.events.isEmpty)
    }

    @Test func `A PDF queued after the app signed out is removed and never uploaded`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        let source = group.root.appending(path: "Late.pdf")
        try Data("%PDF-1.7\n1 0 obj\n".utf8).write(to: source)
        try group.appSwitched()

        let uploads = await graph.uploader.enqueue([source])

        #expect(uploads.count == 1)
        #expect(uploads.allSatisfy { !$0.isActive })
        let left = (try? FileManager.default.contentsOfDirectory(atPath: group.paths.pdfUploads.path)) ?? []
        #expect(left.isEmpty)
        #expect(api.events.isEmpty)
    }

    @Test func `A PDF a stale sheet queued is deleted, not uploaded, by the next account's app`() async throws {
        try group.appOpened()
        let gate = Gate()
        let graph = try group.graph(api: api)
        api.onUpload { _, _ in
            await gate.wait()
            throw CancellationError()
        }
        let source = group.root.appending(path: "Stale.pdf")
        try Data("%PDF-1.7\n1 0 obj\n".utf8).write(to: source)
        // The sheet published the file just before the app's wipe, then was suspended.
        _ = await graph.uploader.enqueue([source])
        try group.appSwitched(signedInAs: "other-token")

        let appAPI = ShareFakeAPI()
        let newOwner = try #require(SessionStore(store: group.secureStore).current?.ownerKey)
        let appUploader = LivePdfUploader(
            api: appAPI, paths: group.paths, syncController: ShareSyncController(), renderThumbnail: { _ in nil },
            owner: { newOwner })
        appUploader.resumePendingUploads()

        let left = (try? FileManager.default.contentsOfDirectory(atPath: group.paths.pdfUploads.path)) ?? []
        #expect(left.isEmpty)
        #expect(appAPI.events.isEmpty)
        gate.open()
    }

    @Test func `With the account marker cleared nothing is written, even if the Keychain item survived`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        // The wipe could not delete the Keychain item but cleared the marker.
        group.marker.withLock { $0 = nil }

        let saved = await graph.library.save(url: "https://example.com/kept", title: nil, tags: [], source: .share)

        if case .saved = saved { Issue.record("saved without an account marker") }
        #expect(try await group.queuedOps().isEmpty)
    }

    @Test func `A refused endpoint pauses requests with a 401 instead of failing the PDF`() async throws {
        try group.appOpened()
        let account = group.account()
        let refused = ShareAPI(base: api, account: account, endpointUsable: { false })
        await #expect(throws: ApiError.http(status: 401, code: nil, message: nil, retryAfter: nil)) {
            _ = try await refused.uploadPdf(
                file: group.root, fileName: "a.pdf", tags: [], source: .share, onProgress: nil)
        }
        #expect(api.events.isEmpty)
    }

    @Test func `Closing waits for a push the timeout cancelled`() async throws {
        try group.appOpened()
        let release = Gate()
        let pushing = Gate()
        let clock = TestClock()
        let graph = try group.graph(api: api, clock: clock)
        api.onPush { payloads in
            pushing.open()
            await release.wait()
            return pushAnswer(payloads)
        }
        _ = await graph.library.save(url: "https://example.com/slow", title: nil, tags: [], source: .share)
        let push = Task { await graph.pushOnce() }
        await pushing.wait()
        // The timeout fires only once the push is inside the API.
        await clock.advance(by: ShareGraph.pushTimeout)
        await push.value
        let closed = Mutex(false)
        let closing = Task {
            await graph.closeWrites()
            closed.withLock { $0 = true }
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(closed.withLock { $0 } == false)
        release.open()
        await closing.value
        #expect(closed.withLock { $0 })
    }

    @Test func `A wipe that could not clear the marker or the Keychain still refuses the share`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        // Another process: its cached marker and the Keychain item survive; only the epoch file changed.
        try WipeEpoch.bump(at: try #require(WipeEpoch.url(besideDatabaseAt: group.databaseURL)))

        let saved = await graph.library.save(url: "https://example.com/late", title: nil, tags: [], source: .share)

        if case .saved = saved { Issue.record("saved after a wipe started") }
        #expect(try await group.queuedOps().isEmpty)
        #expect(try await group.itemCount() == 0)
    }

    @Test func `The app's wipe replaces the epoch before it clears anything`() async throws {
        try group.appOpened()
        let graph = try group.graph(api: api)
        let defaults = try #require(UserDefaults(suiteName: "share-wipe-\(UUID().uuidString)"))
        let preferences = PreferencesStore(defaults: defaults)
        let wiper = LocalDataWiper.databaseOnly(
            try AppDatabase.openShared(at: group.databaseURL), sessionStore: SessionStore(store: InMemorySecureStore()),
            preferences: preferences, importJobs: ImportJobStore(preferences: preferences))
        #expect(await wiper.wipe())

        #expect(graph.account.isCurrent == false)
    }

    @Test func `A PDF published without its sidecar is swept once it is old`() async throws {
        try group.appOpened()
        let uploads = group.paths.pdfUploads
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let old = uploads.appending(path: "orphan-old.pdf")
        let fresh = uploads.appending(path: "orphan-new.pdf")
        try Data("%PDF-1.7".utf8).write(to: old)
        try Data("%PDF-1.7".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * LivePdfUploader.orphanAge)], ofItemAtPath: old.path)

        let appUploader = LivePdfUploader(
            api: ShareFakeAPI(), paths: group.paths, syncController: ShareSyncController(),
            renderThumbnail: { _ in nil })
        appUploader.resumePendingUploads()

        #expect(FileManager.default.fileExists(atPath: old.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func `A request refused while it is built pauses with a 401`() async throws {
        try group.appOpened()
        // The fake throws invalidRequest, as HTTPSrokaAPI does when the endpoint is refused after the preflight.
        let shareAPI = ShareAPI(base: api, account: group.account(), endpointUsable: { true })
        await #expect(throws: ApiError.http(status: 401, code: nil, message: nil, retryAfter: nil)) {
            _ = try await shareAPI.uploadPdf(
                file: group.root, fileName: "a.pdf", tags: [], source: .share, onProgress: nil)
        }
    }

    @Test func `Closing waits for a running write and refuses new ones`() async throws {
        try group.appOpened()
        let gate = ShareWriteGate(account: group.account())
        let release = Gate()
        let entered = Gate()
        let committed = Mutex(false)
        let write = Task {
            try await gate.admit {
                entered.open()
                await release.wait()
                committed.withLock { $0 = true }
            }
        }
        await entered.wait()
        let closing = Task { await gate.closeAndDrain() }
        release.open()
        await closing.value
        #expect(committed.withLock { $0 })
        try await write.value
        await #expect(throws: ShareWriteGate.Closed.self) { try await gate.admit {} }
    }
}

struct ShareConfigurationTests {
    let info: [String: Any] = [
        "AppEnvironmentName": "Dev", "APIBaseURL": "https://api.example.test", "AppGroupIdentifier": "group.test",
        "KeychainAccessGroup": "app.sroka.dev.session", "URLScheme": "sroka-dev",
        "CFBundleShortVersionString": "1.2.0",
    ]

    @Test func `The shared Keychain group carries the team prefix`() throws {
        var info = info
        info["AppIdentifierPrefix"] = "ABCDE12345."
        let configuration = try #require(ShareConfiguration(infoDictionary: info))
        #expect(configuration.keychainAccessGroup == "ABCDE12345.app.sroka.dev.session")
        #expect(configuration.appVersion == "1.2.0")
    }

    @Test func `The Keychain service is the app's`() {
        #expect(ShareConfiguration.keychainService == LiveConfiguration.keychainService)
    }

    @Test func `Without a team prefix the default Keychain group is used`() throws {
        #expect(try #require(ShareConfiguration(infoDictionary: info)).keychainAccessGroup == nil)
        var unexpanded = info
        unexpanded["AppIdentifierPrefix"] = "$(AppIdentifierPrefix)"
        #expect(try #require(ShareConfiguration(infoDictionary: unexpanded)).keychainAccessGroup == nil)
    }
}

struct WithTimeoutTests {
    @Test func `A cancelled caller returns without waiting for the operation or the timeout`() async {
        let gate = Gate()
        let caller = Task {
            await withTimeout(.seconds(3600), clock: TestClock()) { await gate.wait() }
        }
        caller.cancel()
        await caller.value
        gate.open()
    }

    @Test func `An already cancelled caller does not start the operation`() async {
        let started = Gate()
        let ran = Mutex(false)
        let caller = Task {
            await started.wait()
            await withTimeout(.seconds(1), clock: ImmediateClock()) { ran.withLock { $0 = true } }
        }
        caller.cancel()
        started.open()
        await caller.value
        #expect(ran.withLock { $0 } == false)
    }

    @Test func `A fast operation returns before the timeout`() async {
        let ran = Mutex(false)
        await withTimeout(.seconds(3600), clock: TestClock()) { ran.withLock { $0 = true } }
        #expect(ran.withLock { $0 })
    }
}
