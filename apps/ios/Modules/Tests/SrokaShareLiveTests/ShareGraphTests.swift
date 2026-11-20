import Clocks
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
        let appUploader = LivePdfUploader(
            api: appAPI, paths: group.paths, syncController: ShareSyncController(), renderThumbnail: { _ in nil })
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
        #expect(values.pdfUploader is LivePdfUploader)
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

    @Test func `Without a team prefix the default Keychain group is used`() throws {
        #expect(try #require(ShareConfiguration(infoDictionary: info)).keychainAccessGroup == nil)
        var unexpanded = info
        unexpanded["AppIdentifierPrefix"] = "$(AppIdentifierPrefix)"
        #expect(try #require(ShareConfiguration(infoDictionary: unexpanded)).keychainAccessGroup == nil)
    }
}
