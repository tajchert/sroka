import Foundation
import SrokaCore
import Synchronization
import Testing

@testable import SrokaNetwork

struct TransferTests {
    // MARK: PDF upload

    @Test func `PDF upload streams the file with the encoded query`() async throws {
        let bytes = Data("%PDF-1.7\nbody bytes".utf8)
        let file = try temporaryFile(bytes, name: "up.pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = Harness { _ in
            .json(
                #"{"item":{"id":"i1","url":"https://sroka.app/pdf/abc","kind":"pdf","fileName":"a+b & c.pdf"},"created":false}"#,
                status: 202)
        }
        let progress = Mutex<[Int64]>([])
        let response = try await harness.api.uploadPdf(
            file: file, fileName: "a+b & c/é.pdf", tags: ["to read", "x&y", "żółw"], source: .share,
            onProgress: { done, _ in progress.withLock { $0.append(done) } })
        #expect(response.created == false && response.item.kindValue == .pdf)

        let request = harness.last
        #expect(request.method == "POST" && request.path == "/v1/items/pdf")
        #expect(
            request.query
                == "name=a%2Bb%20%26%20c%2F%C3%A9.pdf&source=share&tag=to%20read&tag=x%26y&tag=%C5%BC%C3%B3%C5%82w")
        #expect(request.header("Content-Type") == "application/pdf")
        #expect(request.header("Transfer-Encoding") == nil)
        #expect(request.body == bytes)
        #expect(request.header("Authorization") == "Bearer \(Harness.token)")
        // The query round-trips through a standards parser to exactly what was given.
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "tag" }.compactMap(\.value) == ["to read", "x&y", "żółw"])
        #expect(items.first { $0.name == "name" }?.value == "a+b & c/é.pdf")
    }

    @Test func `PDF upload failures carry the status for the UI mapping`() async throws {
        let file = try temporaryFile(Data("%PDF-".utf8), name: "fail.pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        func upload(_ status: Int, _ body: String) async -> PdfUploadError? {
            let harness = Harness { _ in .json(body, status: status) }
            return await apiError {
                try await harness.api.uploadPdf(
                    file: file, fileName: "a.pdf", tags: [], source: .share, onProgress: nil)
            }?.pdfUploadError
        }
        #expect(await upload(413, #"{"error":"payload_too_large"}"#) == .tooLarge)
        #expect(await upload(415, #"{"error":"unsupported_media_type"}"#) == .notPdf)
        #expect(await upload(409, #"{"error":"storage_full"}"#) == .storageFull)
        #expect(await upload(401, #"{"error":"unauthorized"}"#) == .auth)
        #expect(await upload(500, "") == .unknown)
    }

    @Test func `An unknown source is sent as api`() async throws {
        let file = try temporaryFile(Data("%PDF-".utf8), name: "src.pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = Harness.always()
        _ = try? await harness.api.uploadPdf(file: file, fileName: "a.pdf", tags: [], source: .unknown, onProgress: nil)
        #expect(harness.last.query == "name=a.pdf&source=api")
        _ = try? await harness.api.uploadPdf(
            file: file, fileName: "a.pdf", tags: [], source: .extensionSource, onProgress: nil)
        #expect(harness.last.query == "name=a.pdf&source=extension")
    }

    // MARK: Imports

    @Test func `Import posts multipart with the format field and the file`() async throws {
        let csv = Data("url,title\nhttps://a.b/,\"Ünï\"\n".utf8)
        let file = try temporaryFile(csv, name: "pocket.csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = Harness { _ in
            .json(
                #"{"job":{"id":"j1","kind":"import","status":"queued","format":"pocket_csv","done":0,"skipped":0,"createdAt":1000,"updatedAt":1000}}"#,
                status: 202)
        }
        let job = try await harness.api.createImport(
            source: file, fileName: "my \"export\".csv", mimeType: "text/csv", format: .pocketCsv)
        #expect(job.id == "j1" && job.importJob(fallbackFormat: .netscapeHtml).status == .queued)

        let request = harness.last
        #expect(request.method == "POST" && request.path == "/v1/imports")
        let contentType = try #require(request.header("Content-Type"))
        let boundary = try #require(contentType.split(separator: "boundary=").last.map(String.init))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let text = request.bodyText
        #expect(text.hasPrefix("--\(boundary)\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"format\"\r\n\r\npocket_csv\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"my %22export%22.csv\"\r\nContent-Type: text/csv\r\n\r\n"))
        #expect(text.contains(String(decoding: csv, as: UTF8.self)))
        #expect(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        #expect(request.header("Authorization") == "Bearer \(Harness.token)")
    }

    @Test func `Import status polls the job envelope`() async throws {
        let harness = Harness { _ in
            .json(
                #"{"job":{"id":"j9","status":"running","format":"instapaper_csv","total":50,"done":10,"skipped":2,"createdAt":1,"updatedAt":2}}"#
            )
        }
        let job = try await harness.api.importJob(id: "j9")
        #expect(harness.last.path == "/v1/imports/j9")
        #expect(job.total == 50 && job.done == 10 && job.skipped == 2)
    }

    @Test func `An unreadable import source is refused locally`() async {
        let harness = Harness.always()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID())")
        #expect(
            await apiError {
                try await harness.api.createImport(
                    source: missing, fileName: "a.csv", mimeType: "text/csv", format: .pocketCsv)
            } == .invalidRequest)
        #expect(harness.requests.isEmpty)
    }

    // MARK: Exports

    @Test func `Export streams to the destination and names it from Content-Disposition`() async throws {
        let payload = Data("url,title\nhttps://a.b/,A\n".utf8)
        let harness = Harness { _ in
            StubResponse(
                status: 200, headers: ["Content-Disposition": #"attachment; filename="sroka-export-2026-11-20.csv""#],
                body: payload)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("nested/out.csv")
        let file = try await harness.api.export(format: .csv, to: destination)
        #expect(file == ExportFile(fileName: "sroka-export-2026-11-20.csv", bytes: Int64(payload.count)))
        #expect(try Data(contentsOf: destination) == payload)
        #expect(harness.last.path == "/v1/exports" && harness.last.query == "format=csv")
        #expect(harness.last.header("Authorization") == "Bearer \(Harness.token)")
    }

    @Test func `Export replaces an existing file and keeps nothing on failure`() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.json")
        try Data("old".utf8).write(to: destination)
        let failing = Harness { _ in .json(#"{"error":"rate_limited"}"#, status: 429, headers: ["Retry-After": "60"]) }
        let error = await apiError { try await failing.api.export(format: .json, to: destination) }
        #expect(error?.status == 429 && error?.retryAfter == 60 && error?.remoteFailure == .rateLimited)
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        let ok = Harness { _ in StubResponse(body: Data("{}".utf8)) }
        _ = try await ok.api.export(format: .json, to: destination)
        #expect(try Data(contentsOf: destination) == Data("{}".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["out.json"])
    }

    @Test func `Export file names are reduced to a bare name with a dated fallback`() {
        let day = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func name(_ header: String?) -> String {
            exportFileName(header: header, format: .json, today: day, calendar: calendar)
        }
        #expect(name(#"attachment; filename="a.json""#) == "a.json")
        #expect(name("attachment; filename=plain.json; size=3") == "plain.json")
        #expect(name("attachment; filename*=UTF-8''sroka%20%C5%BC%C3%B3%C5%82w.json") == "sroka żółw.json")
        #expect(name(#"attachment; filename="fallback.json"; filename*=UTF-8''better.json"#) == "better.json")
        #expect(name(#"attachment; filename="../../etc/passwd""#) == "passwd")
        #expect(name(#"attachment; filename="..\..\win.json""#) == "win.json")
        #expect(name(#"attachment; filename="..""#) == "sroka-export-2026-09-21.json")
        #expect(name(#"attachment; filename="""#) == "sroka-export-2026-09-21.json")
        #expect(name("attachment") == "sroka-export-2026-09-21.json")
        #expect(name(nil) == "sroka-export-2026-09-21.json")
    }

    // MARK: Content-host downloads

    @Test func `Downloads from the content host send no auth or device header`() async throws {
        let payload = Data(repeating: 7, count: 100_000)
        let harness = Harness { _ in StubResponse(body: payload) }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("a/package.zip")
        let progress = Mutex<[(Int64, Int64)]>([])
        let url = try #require(URL(string: "https://\(harness.host)/c/abc/package.zip?exp=1&sig=xyz%3D"))
        try await harness.api.download(
            from: url, to: destination,
            onProgress: { done, total in
                progress.withLock { $0.append((done, total)) }
            })
        #expect(try Data(contentsOf: destination) == payload)
        let request = harness.last
        #expect(request.method == "GET" && request.path == "/c/abc/package.zip" && request.query == "exp=1&sig=xyz%3D")
        #expect(request.header("Authorization") == nil)
        #expect(request.header("X-Sroka-Device") == nil)
        #expect(request.header("Origin") == nil)
        #expect(request.header("Cookie") == nil)
        #expect(request.header("User-Agent") == Harness.userAgent)
        #expect(progress.withLock { $0.last?.0 } == Int64(payload.count))
    }

    @Test func `A failed download leaves nothing behind and reports the status`() async throws {
        let harness = Harness { _ in .json(#"{"error":"forbidden"}"#, status: 403) }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("x.bin")
        let url = try #require(URL(string: "https://\(harness.host)/c/x"))
        let error = await apiError { try await harness.api.download(from: url, to: destination, onProgress: nil) }
        #expect(error?.status == 403 && error?.remoteFailure == .server)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func `Only http and https urls can be downloaded`() async {
        let harness = Harness.always()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("never")
        for text in ["file:///etc/passwd", "ftp://x.y/z", "https:///nohost"] {
            let url = URL(string: text)!
            #expect(
                await apiError { try await harness.api.download(from: url, to: destination, onProgress: nil) }
                    == .invalidRequest, "\(text)")
        }
        #expect(harness.requests.isEmpty)
    }

    @Test func `A cancelled download throws CancellationError`() async throws {
        let harness = Harness { _ in StubResponse(hang: true) }
        let api = harness.api
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID())")
        let url = try #require(URL(string: "https://\(harness.host)/slow"))
        let task = Task { try await api.download(from: url, to: destination, onProgress: nil) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
