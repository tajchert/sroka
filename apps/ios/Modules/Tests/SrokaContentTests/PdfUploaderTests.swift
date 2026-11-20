import Foundation
import SrokaCore
import SrokaNetwork
import SrokaTesting
import Synchronization
import Testing

@testable import SrokaContent

private let pdfData = Data("%PDF-1.4\n".utf8) + Data(repeating: 66, count: 4_000)

struct PdfUploadClassificationTests {
    @Test func `Permanent and transient errors are told apart`() {
        #expect(LivePdfUploader.classify(httpError(413)) == .permanent(.tooLarge))
        #expect(LivePdfUploader.classify(httpError(415)) == .permanent(.notPdf))
        #expect(LivePdfUploader.classify(httpError(409, "storage_full")) == .permanent(.storageFull))
        #expect(LivePdfUploader.classify(httpError(409, "conflict")) == .permanent(.unknown))
        #expect(LivePdfUploader.classify(httpError(400)) == .permanent(.unknown))
        #expect(LivePdfUploader.classify(ApiError.invalidRequest) == .permanent(.unknown))
        #expect(LivePdfUploader.classify(httpError(401)) == .unauthorized)
        #expect(LivePdfUploader.classify(httpError(408)) == .transient(.unknown))
        #expect(LivePdfUploader.classify(httpError(429)) == .transient(.unknown))
        #expect(LivePdfUploader.classify(httpError(503)) == .transient(.unknown))
        #expect(LivePdfUploader.classify(ApiError.transport(.networkConnectionLost)) == .transient(.network))
        #expect(LivePdfUploader.classify(CocoaError(.fileReadUnknown)) == .transient(.network))
    }

    @Test func `Backoff doubles from 30 seconds and is capped`() {
        #expect(LivePdfUploader.backoff(attempt: 1) == .seconds(30))
        #expect(LivePdfUploader.backoff(attempt: 2) == .seconds(60))
        #expect(LivePdfUploader.backoff(attempt: 4) == .seconds(240))
        #expect(LivePdfUploader.backoff(attempt: 14) == .seconds(3_600))
    }

    @Test func `File names are cleaned`() {
        #expect(LivePdfUploader.cleanPdfName("  report.pdf ") == "report.pdf")
        #expect(LivePdfUploader.cleanPdfName("") == "document.pdf")
        let long = LivePdfUploader.cleanPdfName(String(repeating: "x", count: 300) + ".pdf")
        #expect(long.count == 255)
        #expect(long.hasSuffix(".pdf"))
    }
}

struct PdfUploaderTests {
    let dir: TempDir
    let paths: ContentPaths
    let api = FakeAPI()
    let sync = FakeSyncController()

    init() throws {
        dir = try TempDir()
        paths = ContentPaths(root: dir.url.appending(path: "Content", directoryHint: .isDirectory))
    }

    private func makeUploader(render: @escaping @Sendable (URL) -> Data? = { _ in Data(repeating: 9, count: 100) })
        -> LivePdfUploader
    {
        LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: render,
            owner: { "owner-a" })
    }

    private func source(_ name: String, _ data: Data = pdfData) throws -> URL {
        let url = dir.file(name)
        try data.write(to: url)
        return url
    }

    /// Waits until no upload is active and returns the list.
    private func settled(_ uploader: LivePdfUploader) async -> [PdfUpload] {
        for await list in uploader.uploads where !list.contains(where: \.isActive) { return list }
        return []
    }

    private func current(_ uploader: LivePdfUploader) async -> [PdfUpload] {
        for await list in uploader.uploads { return list }
        return []
    }

    private func pendingFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.pdfUploads.path)) ?? []).sorted()
    }

    @Test func `The upload and its preview both use the API bound for the upload's owner`() async throws {
        defer { dir.cleanUp() }
        let bound = FakeAPI()
        bound.setUploads(.success(uploadResponse(itemId: "item1")))
        api.setUploads(.success(uploadResponse(itemId: "wrong")))
        let owners = Mutex<[String?]>([])
        let uploader = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in },
            renderThumbnail: { _ in Data(repeating: 9, count: 100) }, owner: { "owner-a" },
            boundAPI: { owner in
                owners.withLock { $0.append(owner) }
                return bound
            })

        _ = await uploader.enqueue([try source("a.pdf")])
        _ = await settled(uploader)

        #expect(owners.withLock { $0 } == ["owner-a"])
        #expect(bound.uploadCalls == 1)
        #expect(bound.thumbnailUploads.count == 1)
        #expect(api.uploadCalls == 0)
        #expect(api.thumbnailUploads.isEmpty)
    }

    @Test func `Without a credential snapshot for its owner the upload waits, queued`() async throws {
        defer { dir.cleanUp() }
        let uploader = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            owner: { "owner-a" }, boundAPI: { _ in nil })

        let queued = await uploader.enqueue([try source("a.pdf")])
        for await list in uploader.uploads where list.first?.state == .queued { break }
        try await Task.sleep(for: .milliseconds(50))

        #expect(api.uploadCalls == 0)
        #expect(pendingFiles() == ["\(queued[0].id).json", "\(queued[0].id).pdf"])
    }

    @Test func `An upload the other process holds is neither sent nor deleted until its claim expires`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.success(uploadResponse(itemId: "item1", leadImageKey: "img/x.webp")))
        // The share extension queued it and is sending it now: queue files plus its claim.
        let id = "0190a1b2-share"
        try paths.prepare(paths.pdfUploads)
        try pdfData.write(to: paths.pdfUploads.appending(path: "\(id).pdf"))
        let meta = LivePdfUploader.Metadata(
            id: id, fileName: "a.pdf", sizeBytes: Int64(pdfData.count), attempts: 0, tags: [], owner: "owner-a")
        try JSONEncoder().encode(meta).write(to: paths.pdfUploads.appending(path: "\(id).json"))
        let extensionSide = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            owner: { "owner-a" }, claimToken: "extension")
        #expect(extensionSide.claim(id))

        let app = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            owner: { "owner-a" }, claimToken: "app")
        app.resumePendingUploads()
        try await Task.sleep(for: .milliseconds(100))
        #expect(api.uploadCalls == 0)
        #expect(pendingFiles() == ["\(id).claim", "\(id).json", "\(id).pdf"])

        // The extension was killed: its claim stops being renewed and expires.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * LivePdfUploader.claimLease)],
            ofItemAtPath: paths.pdfUploads.appending(path: "\(id).claim").path)
        app.resumePendingUploads()
        _ = await settled(app)
        #expect(api.uploadCalls == 1)
        #expect(pendingFiles().isEmpty)
    }

    @Test func `A file is owned by the account signed in when it was shared, and an ownerless one is dropped`()
        async throws
    {
        defer { dir.cleanUp() }
        api.setUploads(.success(uploadResponse(itemId: "item1", leadImageKey: "img/x.webp")))
        // The account switches while the file is copied: once the copy is in the queue, another account is current.
        let queue = paths.pdfUploads
        let uploader = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            owner: {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? []
                return names.contains { $0.hasSuffix(".pdf") } ? "owner-b" : "owner-a"
            })

        let queued = await uploader.enqueue([try source("a.pdf")])
        #expect(await settled(uploader).first?.state == .failed(.unknown))
        #expect(queued.count == 1)
        #expect(api.uploadCalls == 0)
        #expect(pendingFiles().isEmpty)

        // A sidecar without an owner is never sent, under any account.
        let id = "0190a1b2-ownerless"
        try pdfData.write(to: queue.appending(path: "\(id).pdf"))
        let meta = LivePdfUploader.Metadata(
            id: id, fileName: "a.pdf", sizeBytes: Int64(pdfData.count), attempts: 0, tags: [], owner: nil)
        try JSONEncoder().encode(meta).write(to: queue.appending(path: "\(id).json"))
        let next = makeUploader()
        next.resumePendingUploads()
        _ = await settled(next)
        #expect(api.uploadCalls == 0)
        #expect(pendingFiles().isEmpty)
    }

    @Test func `A request that reports no progress keeps its claim past the lease`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.success(uploadResponse(itemId: "item1", leadImageKey: "img/x.webp")))
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        api.onUpload.withLock {
            $0 = {
                started.continuation.yield()
                for await _ in gate.stream {}
            }
        }
        let clock = Mutex(Date())
        let uploader = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, now: { clock.withLock { $0 } },
            renderThumbnail: { _ in nil }, owner: { "owner-a" }, claimToken: "app",
            claimRenewal: .milliseconds(20))
        let id = try #require(await uploader.enqueue([try source("a.pdf")]).first?.id)
        for await _ in started.stream { break }

        // The request outlives the lease without a progress callback.
        clock.withLock { $0 = $0.addingTimeInterval(2 * LivePdfUploader.claimLease) }
        let claimFile = paths.pdfUploads.appending(path: "\(id).claim")
        let leaseStart = clock.withLock { $0 }.addingTimeInterval(-LivePdfUploader.claimLease)
        for _ in 0..<100 {
            let modified = (try? claimFile.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > leaseStart { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let other = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, now: { clock.withLock { $0 } },
            renderThumbnail: { _ in nil }, owner: { "owner-a" }, claimToken: "extension")
        #expect(other.claim(id) == false)

        gate.continuation.finish()
        #expect(await settled(uploader).first?.state == .done(itemId: "item1", duplicate: false))
        #expect(pendingFiles().isEmpty)
    }

    @Test func `A row queued behind the other process goes once that process finishes it`() async throws {
        defer { dir.cleanUp() }
        let id = "0190a1b2-share"
        try paths.prepare(paths.pdfUploads)
        try pdfData.write(to: paths.pdfUploads.appending(path: "\(id).pdf"))
        let meta = LivePdfUploader.Metadata(
            id: id, fileName: "a.pdf", sizeBytes: Int64(pdfData.count), attempts: 0, tags: [], owner: "owner-a")
        try JSONEncoder().encode(meta).write(to: paths.pdfUploads.appending(path: "\(id).json"))
        let extensionSide = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            owner: { "owner-a" }, claimToken: "extension")
        #expect(extensionSide.claim(id))

        let app = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            owner: { "owner-a" }, claimToken: "app")
        app.resumePendingUploads()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await current(app).map(\.state) == [.queued])

        // The extension sent it and removed the queue files.
        for name in pendingFiles() { try FileManager.default.removeItem(at: paths.pdfUploads.appending(path: name)) }
        app.resumePendingUploads()
        #expect(await current(app).isEmpty)
        #expect(api.uploadCalls == 0)
    }

    @Test func `A successful upload sends a preview, cleans up and requests a sync`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.success(uploadResponse(itemId: "item1")))
        let uploader = makeUploader()

        let queued = await uploader.enqueue([try source("Report.pdf")])
        #expect(queued.map(\.fileName) == ["Report.pdf"])
        #expect(queued.first?.sizeBytes == Int64(pdfData.count))

        let list = await settled(uploader)
        #expect(list.first?.state == .done(itemId: "item1", duplicate: false))
        #expect(api.thumbnailUploads.map(\.0) == ["item1"])
        #expect(api.thumbnailUploads.first?.2 == "image/jpeg")
        #expect(sync.calls.calls == [.requestSync])
        #expect(pendingFiles().isEmpty)
    }

    @Test func `A duplicate with a lead image skips the preview`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.success(uploadResponse(itemId: "item1", created: false, leadImageKey: "thumb.jpg")))
        let uploader = makeUploader()
        _ = await uploader.enqueue([try source("a.pdf")])
        #expect(await settled(uploader).first?.state == .done(itemId: "item1", duplicate: true))
        #expect(api.thumbnailUploads.isEmpty)
    }

    @Test func `Files that fail the client checks are rejected up front`() async throws {
        defer { dir.cleanUp() }
        let uploader = makeUploader()
        let result = await uploader.enqueue([
            try source("page.pdf", Data("<html></html>".utf8)),
            try source("empty.pdf", Data()),
            dir.file("missing.pdf"),
        ])
        #expect(result.map(\.state) == [.failed(.notPdf), .failed(.notPdf), .failed(.unknown)])
        #expect(api.uploadCalls == 0)
        #expect(pendingFiles().isEmpty)
    }

    @Test func `Copying stops above the size cap`() throws {
        defer { dir.cleanUp() }
        let big = try source("big.pdf", pdfData + Data(count: 10_000))
        let dest = dir.file("copy.pdf")
        #expect(LivePdfUploader.copyPdf(from: big, to: dest, cap: 5_000) == .failed(.tooLarge))
        #expect(LivePdfUploader.copyPdf(from: big, to: dest, cap: 50_000) == .copied(Int64(pdfData.count + 10_000)))
    }

    @Test func `A permanent server error fails at once`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.failure(httpError(415)))
        let uploader = makeUploader()
        _ = await uploader.enqueue([try source("a.pdf")])
        #expect(await settled(uploader).first?.state == .failed(.notPdf))
        #expect(api.uploadCalls == 1)
        #expect(pendingFiles().isEmpty)
        #expect(sync.calls.calls.isEmpty)
    }

    @Test func `Transient errors retry until success`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(
            .failure(.transport(.timedOut)), .failure(httpError(503)), .success(uploadResponse(itemId: "item1")))
        let uploader = makeUploader()
        _ = await uploader.enqueue([try source("a.pdf")])
        #expect(await settled(uploader).first?.state == .done(itemId: "item1", duplicate: false))
        #expect(api.uploadCalls == 3)
    }

    @Test func `Transient errors give up after the attempt cap`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.failure(.transport(.notConnectedToInternet)))
        let uploader = makeUploader()
        _ = await uploader.enqueue([try source("a.pdf")])
        #expect(await settled(uploader).first?.state == .failed(.network))
        #expect(api.uploadCalls == LivePdfUploader.maxAttempts)
        #expect(pendingFiles().isEmpty)
    }

    @Test func `An expired session pauses the upload until resumed`() async throws {
        defer { dir.cleanUp() }
        api.setUploads(.failure(httpError(401)), .success(uploadResponse(itemId: "item1")))
        let expired = CallRecorder<Bool>()
        let uploader = LivePdfUploader(
            api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: { _ in nil },
            onUnauthorized: { expired.record(true) }, owner: { "owner-a" })
        _ = await uploader.enqueue([try source("a.pdf")])
        for await _ in uploader.uploads where !expired.calls.isEmpty { break }
        #expect(pendingFiles().count == 2)

        // A new process (or sign-in) picks the file up again.
        let next = makeUploader()
        next.resumePendingUploads()
        #expect(await settled(next).first?.state == .done(itemId: "item1", duplicate: false))
        #expect(pendingFiles().isEmpty)
    }

    @Test func `Cancel removes the upload and its copy`() async throws {
        defer { dir.cleanUp() }
        let gate = AsyncStream<Void>.makeStream()
        api.setUploads(.success(uploadResponse(itemId: "item1")))
        let uploader = makeUploader()
        // Hold the upload lane so the item stays queued.
        let blocker = Task { await uploader.laneForTests.withLock("upload") { for await _ in gate.stream {} } }
        let queued = await uploader.enqueue([try source("a.pdf")])
        await uploader.cancel(id: try #require(queued.first?.id))
        gate.continuation.finish()
        await blocker.value
        #expect(pendingFiles().isEmpty)
        #expect(await settled(uploader).isEmpty)
        #expect(api.uploadCalls == 0)
    }

    @Test func `Clear finished keeps active uploads`() async throws {
        defer { dir.cleanUp() }
        let uploader = makeUploader()
        _ = await uploader.enqueue([try source("bad.pdf", Data("nope".utf8))])
        uploader.clearFinished()
        #expect(await settled(uploader).isEmpty)
    }
}
