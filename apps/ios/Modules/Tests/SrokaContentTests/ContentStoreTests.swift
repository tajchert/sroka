import Foundation
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaContent

private let day: Int64 = 24 * 60 * 60 * 1000
private let pdfBytes = Data("%PDF-1.7\n".utf8) + Data(repeating: 65, count: 2_000)

struct DownloadPipelineTests {
    @Test func `A download installs the package, indexes the body and commits once`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1", leadImageKey: "img/lead.webp"))
        try h.servePackage("item1")
        h.api.serve("https://content.test/item1/img/lead.webp", .data(Data(repeating: 1, count: 50)))

        #expect(await h.store.fetch(itemId: "item1") == .downloaded)

        let row = try #require(try h.database.row("item1"))
        #expect(row.state == .downloaded)
        #expect(row.contentId == "c1")
        #expect(row.attempts == 0)
        #expect(row.bytes > 0)
        #expect(row.downloadedAt == h.nowMs)
        #expect(row.thumbPath == "thumbs/item1.webp")
        #expect(ContentPaths.isFile(h.paths.thumb("item1")))
        #expect(try h.database.ftsBody("item1") == "Hello & welcome")
        #expect(await h.store.articleHtml(itemId: "item1")?.contains("Hello") == true)
        #expect(!h.api.downloads.contains { !$0.hasPrefix("https://content.test/") })
        // The package zip is gone once installed.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.paths.downloads.path)) ?? []).isEmpty)
    }

    @Test func `An already current package is not fetched again`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)
        let calls = h.api.contentUrlCalls.count
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)
        #expect(h.api.contentUrlCalls.count == calls)
    }

    @Test func `A stale content id downloads the new version`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1", contentId: "c1"))
        try h.servePackage("item1", validPackage(html: "<p>old</p>"))
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)

        try h.database.insert(item("item1", contentId: "c2"))
        try h.servePackage("item1", validPackage(html: "<p>new</p>"))
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)

        #expect(try h.database.row("item1")?.contentId == "c2")
        #expect(await h.store.articleHtml(itemId: "item1") == "<p>new</p>")
        #expect(try h.database.ftsBody("item1") == "new")
    }

    @Test func `Not parsed yet is not an attempt`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        h.api.setUrls("item1", .failure(httpError(409, "not_parsed")))
        #expect(await h.store.fetch(itemId: "item1") == .notReady)
        #expect(try h.database.row("item1") == nil)
    }

    @Test func `Low storage is not an attempt and touches no network`() async throws {
        let h = try Harness(freeBytes: LiveContentStore.minFreeBytes - 1)
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        #expect(await h.store.fetch(itemId: "item1") == .failed(.server))
        #expect(await h.store.download(itemId: "item1", api: h.api) == .storageFull)
        #expect(try h.database.row("item1") == nil)
        #expect(h.api.contentUrlCalls.isEmpty)
    }

    @Test func `A network error is not an attempt`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        h.api.setUrls("item1", .success(contentUrls("item1")))
        h.api.serve("https://content.test/item1/package.zip", .error(.transport(.notConnectedToInternet)))
        #expect(await h.store.fetch(itemId: "item1") == .failed(.network))
        #expect(try h.database.row("item1") == nil)
    }

    @Test func `Server errors count attempts until the cap`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        h.api.setUrls("item1", .failure(httpError(500)))
        for expected in 1...ContentFileDao.maxAttempts {
            #expect(await h.store.fetch(itemId: "item1") == .failed(.server))
            #expect(try h.database.row("item1")?.attempts == expected)
        }
        #expect(try h.database.row("item1")?.state == .failed)
        #expect(await h.store.eligibleCount() == 0)
    }

    @Test func `A hostile package fails and counts an attempt`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        var entries = validPackage()
        entries.append(.file("../escape.html", Data("x".utf8)))
        try h.servePackage("item1", entries)
        #expect(await h.store.fetch(itemId: "item1") == .failed(.server))
        let row = try #require(try h.database.row("item1"))
        #expect(row.state == .failed)
        #expect(row.attempts == 1)
        #expect(row.error == "unsafe_path")
        #expect(!ContentPaths.isFile(h.paths.articleHtml("item1")))
    }

    @Test func `A package over the size cap is aborted`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        h.api.setUrls("item1", .success(contentUrls("item1")))
        h.api.serve("https://content.test/item1/package.zip", .progress(PackageInstaller.maxTotalBytes + 1))
        #expect(await h.store.fetch(itemId: "item1") == .failed(.server))
        #expect(try h.database.row("item1")?.error == "too_large")
        #expect(try h.database.row("item1")?.attempts == 1)
    }

    @Test func `An item without content is not ready`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1", contentId: nil))
        #expect(await h.store.fetch(itemId: "item1") == .notReady)
        #expect(h.api.contentUrlCalls.isEmpty)
    }

    @Test func `A failed thumbnail counts its own attempts, a blip does not`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1", leadImageKey: "img/lead.webp"))
        try h.servePackage("item1")
        h.api.serve(
            "https://content.test/item1/img/lead.webp", .error(.transport(.timedOut)), .error(httpError(404)))
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)
        #expect(try h.database.row("item1")?.thumbAttempts == 0)
        // Already downloaded: only the thumbnail is retried.
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)
        #expect(try h.database.row("item1")?.thumbAttempts == 1)
        #expect(try h.database.row("item1")?.state == .downloaded)
        #expect(h.api.downloads.filter { $0.hasSuffix("package.zip") }.count == 1)
    }
}

struct PdfDownloadTests {
    private func pdfItem(_ h: Harness) throws {
        try h.database.insert(item("doc1", kind: .pdf))
    }

    @Test func `A PDF is stored as document pdf without an FTS body`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try pdfItem(h)
        h.api.setUrls("doc1", .success(contentUrls("doc1", documentUrl: "https://content.test/doc1/document.pdf")))
        h.api.serve("https://content.test/doc1/document.pdf", .data(pdfBytes))

        #expect(await h.store.fetch(itemId: "doc1") == .downloaded)
        let file = try #require(await h.store.pdfFile(itemId: "doc1"))
        #expect(file.lastPathComponent == "document.pdf")
        #expect(try Data(contentsOf: file) == pdfBytes)
        #expect(try h.database.row("doc1")?.bytes == Int64(pdfBytes.count))
        #expect(try h.database.ftsBody("doc1") ?? "" == "")
        #expect(h.api.downloads.allSatisfy { !$0.hasSuffix("package.zip") })
    }

    @Test func `A file without the PDF header is rejected`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try pdfItem(h)
        h.api.setUrls("doc1", .success(contentUrls("doc1", documentUrl: "https://content.test/doc1/document.pdf")))
        h.api.serve("https://content.test/doc1/document.pdf", .data(Data("<html>login</html>".utf8)))
        #expect(await h.store.fetch(itemId: "doc1") == .failed(.server))
        #expect(try h.database.row("doc1")?.error == "not_pdf")
        #expect(await h.store.pdfFile(itemId: "doc1") == nil)
    }

    @Test func `The header is found anywhere in the first KiB only`() throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let early = dir.file("early")
        try (Data(repeating: 32, count: 1_000) + Data("%PDF-1.4".utf8)).write(to: early)
        let late = dir.file("late")
        try (Data(repeating: 32, count: 1_100) + Data("%PDF-1.4".utf8)).write(to: late)
        #expect(LiveContentStore.looksLikePdf(early))
        #expect(!LiveContentStore.looksLikePdf(late))
    }

    @Test func `An expired signed URL is refreshed once`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try pdfItem(h)
        h.api.setUrls(
            "doc1",
            .success(contentUrls("doc1", documentUrl: "https://content.test/doc1/old.pdf")),
            .success(contentUrls("doc1", documentUrl: "https://content.test/doc1/new.pdf")))
        h.api.serve("https://content.test/doc1/old.pdf", .error(httpError(403)))
        h.api.serve("https://content.test/doc1/new.pdf", .data(pdfBytes))
        #expect(await h.store.fetch(itemId: "doc1") == .downloaded)
        #expect(h.api.contentUrlCalls == ["doc1", "doc1"])
    }

    @Test func `A second rejection fails without a third request`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try pdfItem(h)
        h.api.setUrls("doc1", .success(contentUrls("doc1", documentUrl: "https://content.test/doc1/document.pdf")))
        h.api.serve("https://content.test/doc1/document.pdf", .error(httpError(410)))
        #expect(await h.store.fetch(itemId: "doc1") == .failed(.server))
        #expect(h.api.contentUrlCalls.count == 2)
        #expect(try h.database.row("doc1")?.attempts == 1)
    }

    @Test func `A PDF without a document URL fails`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try pdfItem(h)
        h.api.setUrls("doc1", .success(contentUrls("doc1")))
        #expect(await h.store.fetch(itemId: "doc1") == .failed(.server))
        #expect(try h.database.row("doc1")?.error == "no_document_url")
    }
}

struct BulkDownloadTests {
    @Test func `Automatic downloads take eligible items newest first`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(
            item("old", savedAt: 1), item("new", savedAt: 4), item("mid", savedAt: 3), item("mid2", savedAt: 2),
            item("gone", status: .archived, savedAt: 4))
        for id in ["old", "new", "mid", "mid2", "gone"] { try h.servePackage(id) }
        let progress = Mutex<[DownloadProgress]>([])

        let result = await h.store.runAutomaticDownloads(policy: .anyNetwork) { value in
            progress.withLock { $0.append(value) }
        }

        #expect(result == DownloadRunResult(downloaded: 4))
        // Three run at once; the oldest starts only when one of the newer three is done.
        #expect(h.api.contentUrlCalls.last == "old")
        #expect(Set(h.api.contentUrlCalls) == ["new", "mid", "mid2", "old"])
        let values = progress.withLock { $0 }
        #expect(values.first == DownloadProgress(done: 0, total: 4, currentTitle: nil))
        #expect(values.map(\.done).max() == 4)
        #expect(try h.database.row("gone") == nil)
    }

    @Test func `Manual policy downloads nothing`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        #expect(await h.store.runAutomaticDownloads(policy: .manual) == DownloadRunResult())
        #expect(h.api.contentUrlCalls.isEmpty)
    }

    @Test func `Wi-Fi only uses the constrained client and download all does not`() async throws {
        let dir = try TempDir()
        defer { dir.cleanUp() }
        let database = try AppDatabase.inMemory()
        let any = FakeAPI()
        let wifi = FakeAPI()
        let store = LiveContentStore(
            database: database, api: any, wifiOnlyAPI: wifi, paths: ContentPaths(root: dir.url), freeBytes: { .max })
        try database.insert(item("item1"))
        _ = await store.runAutomaticDownloads(policy: .wifiOnly)
        #expect(wifi.contentUrlCalls == ["item1"])
        #expect(any.contentUrlCalls.isEmpty)
        _ = await store.downloadAll()
        #expect(any.contentUrlCalls == ["item1"])
        #expect(!LiveContentStore.makeWifiOnlySession().configuration.allowsExpensiveNetworkAccess)
    }

    @Test func `A run stops at the first network failure`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        for index in 0..<10 { try h.database.insert(item("item\(index)", savedAt: Int64(index))) }
        for index in 0..<10 { h.api.setUrls("item\(index)", .failure(.transport(.notConnectedToInternet))) }
        let result = await h.store.downloadAll()
        #expect(result.failure == .network)
        #expect(result.downloaded == 0)
        // At most the first parallel wave went out.
        #expect(h.api.contentUrlCalls.count <= LiveContentStore.parallelDownloads)
    }

    @Test func `A run reports full storage and stops`() async throws {
        let h = try Harness(freeBytes: 0)
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"), item("item2"))
        #expect(await h.store.downloadAll().failure == .storage)
    }

    @Test func `Remove downloads racing a commit wins`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        let store = h.store
        h.api.onDownload.withLock { $0 = { _ in await store.clearDownloads() } }

        #expect(await h.store.fetch(itemId: "item1") == .notReady)

        #expect(try h.database.row("item1") == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(h.paths.articleDir("item1")).path))
        #expect(try h.database.ftsBody("item1") ?? "" == "")
    }

    @Test func `A deleted item does not leave files behind`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        let database = h.database
        h.api.onDownload.withLock {
            $0 = { _ in _ = try? await database.write { db in try ItemDao.delete(db, id: "item1") } }
        }
        #expect(await h.store.fetch(itemId: "item1") == .notReady)
        #expect(try h.database.row("item1") == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(h.paths.articleDir("item1")).path))
    }
}

struct MaintenanceTests {
    @Test func `Eviction drops old archived packages and keeps the FTS body`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        let old = h.nowMs - 40 * day
        let recent = h.nowMs - 5 * day
        try h.database.insert(
            item("evict", status: .archived, archivedAt: old),
            item("fav", status: .archived, favorite: true, archivedAt: old),
            item("read", status: .archived, archivedAt: old, lastReadAt: recent),
            item("fresh", status: .archived, archivedAt: recent))
        for id in ["evict", "fav", "read", "fresh"] {
            try h.servePackage(id)
            #expect(await h.store.fetch(itemId: id) == .downloaded)
        }
        // Pretend they were downloaded long ago (except "fresh", whose archive is recent anyway).
        for id in ["evict", "fav", "read", "fresh"] {
            var row = try #require(try h.database.row(id))
            row.downloadedAt = old
            try h.database.insert(row)
        }

        await h.store.evict()

        #expect(try h.database.row("evict") == nil)
        #expect(!ContentPaths.isFile(h.paths.articleHtml("evict")))
        #expect(try h.database.ftsBody("evict") == "Hello & welcome")
        for id in ["fav", "read", "fresh"] {
            #expect(try h.database.row(id)?.state == .downloaded, "\(id)")
            #expect(ContentPaths.isFile(h.paths.articleHtml(id)), "\(id)")
        }
    }

    @Test func `Recovery requeues interrupted rows and drops missing packages`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("busy"), item("lost"), item("swap"), item("thumb", leadImageKey: "img/x.webp"))
        try h.database.insert(ContentFileRecord(itemId: "busy", contentId: "c1", state: .downloading))
        try h.database.insert(ContentFileRecord(itemId: "lost", contentId: "c1", state: .downloaded))
        // The installer swaps while the row is DOWNLOADING.
        try h.database.insert(ContentFileRecord(itemId: "swap", contentId: "c1", state: .downloading))
        try h.database.insert(
            ContentFileRecord(
                itemId: "thumb", contentId: "c1", state: .downloaded, thumbPath: "thumbs/thumb.webp", thumbAttempts: 2))
        let fileManager = FileManager.default
        // "swap" crashed between target -> .old and .tmp -> target.
        let old = try #require(h.paths.oldDir("swap"))
        try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("<p>kept</p>".utf8).write(to: old.appending(path: "article.html"))
        let thumbDir = try #require(h.paths.articleDir("thumb"))
        try fileManager.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try Data("<p>t</p>".utf8).write(to: thumbDir.appending(path: "article.html"))
        // Leftovers without a row.
        let orphan = try #require(h.paths.articleDir("orphan"))
        try fileManager.createDirectory(at: orphan, withIntermediateDirectories: true)
        let partial = try #require(h.paths.tmpDir("busy"))
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)

        await h.store.recoverInterrupted()

        #expect(try h.database.row("busy")?.state == .queued)
        #expect(try h.database.row("lost") == nil)
        #expect(try h.database.row("swap")?.state == .queued)
        #expect(await h.store.articleHtml(itemId: "swap") == "<p>kept</p>")
        #expect(try h.database.row("thumb")?.thumbPath == nil)
        #expect(try h.database.row("thumb")?.thumbAttempts == 0)
        #expect(!fileManager.fileExists(atPath: orphan.path))
        #expect(!fileManager.fileExists(atPath: partial.path))
    }

    @Test func `Recovery runs once per launch`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("busy"))
        await h.store.recoverInterrupted()
        try h.database.insert(ContentFileRecord(itemId: "busy", contentId: "c1", state: .downloading))
        await h.store.recoverInterrupted()
        #expect(try h.database.row("busy")?.state == .downloading)
    }

    @Test func `Remove downloaded articles clears files and rows but keeps search`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)
        #expect(await h.store.storageUsageBytes() > 0)
        let pending = h.paths.pdfUploads.appending(path: "keep.pdf")
        try pdfBytes.write(to: pending)

        await h.store.clearDownloads()

        #expect(try h.database.row("item1") == nil)
        #expect(await h.store.articleHtml(itemId: "item1") == nil)
        #expect(await h.store.storageUsageBytes() == 0)
        #expect(try h.database.ftsBody("item1") == "Hello & welcome")
        #expect(ContentPaths.isFile(pending))
        #expect(FileManager.default.fileExists(atPath: h.paths.articles.path))
    }

    @Test func `The wipe removes pending uploads too`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        let pending = h.paths.pdfUploads.appending(path: "x.pdf")
        try pdfBytes.write(to: pending)
        await h.store.removeAllContent()
        #expect(!ContentPaths.isFile(pending))
        #expect(FileManager.default.fileExists(atPath: h.paths.pdfUploads.path))
    }

    @Test func `Deleting files of removed items ignores invalid ids`() async throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        try h.database.insert(item("item1"))
        try h.servePackage("item1")
        #expect(await h.store.fetch(itemId: "item1") == .downloaded)
        h.store.deleteFiles(itemIds: ["item1", "../..", ""])
        #expect(!ContentPaths.isFile(h.paths.articleHtml("item1")))
        #expect(FileManager.default.fileExists(atPath: h.paths.articles.path))
    }

    @Test func `Directories are excluded from backup`() throws {
        let h = try Harness()
        defer { h.dir.cleanUp() }
        for dir in [h.paths.articles, h.paths.thumbs, h.paths.pdfUploads] {
            #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #expect(h.paths.articleDir("a/b") == nil)
        #expect(h.store.articlesDirectory() == h.paths.articles)
    }
}
