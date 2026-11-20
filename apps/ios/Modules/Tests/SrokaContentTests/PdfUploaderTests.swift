import Foundation
import SrokaCore
import SrokaNetwork
import SrokaTesting
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
        LivePdfUploader(api: api, paths: paths, syncController: sync, sleep: { _ in }, renderThumbnail: render)
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

    private func pendingFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.pdfUploads.path)) ?? []).sorted()
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
            onUnauthorized: { expired.record(true) })
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
