import Clocks
import Foundation
import SrokaCore
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSession

struct TransferTests {
    struct Setup {
        let h: Harness
        let tracker: ImportTracker
        let repo: LiveDataTransferRepository
        let finished: Locked<[ImportJob]>

        init(defaults: UserDefaults? = nil, clock: any Clock<Duration> = TestClock()) throws {
            h = try Harness(defaults: defaults)
            let finished = Locked<[ImportJob]>([])
            self.finished = finished
            tracker = ImportTracker(
                api: h.api, store: h.jobs, sessionStore: h.sessionStore, clock: clock,
                onFinished: { job in finished.withLock { $0.append(job) } })
            repo = LiveDataTransferRepository(
                api: h.api, jobs: h.jobs, tracker: tracker, sessionStore: h.sessionStore,
                cachesDirectory: h.cachesDirectory)
        }
    }

    private func tempFile(_ name: String, bytes: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sroka-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test func `Import uploads a copy, stores the job and starts polling`() async throws {
        let s = try Setup()
        let file = try tempFile("pocket.csv", bytes: 10)
        let seen = Mutex<(String, String, Int)?>(nil)
        s.h.api.configure {
            $0.createImport = { url, name, mime, _ in
                let size = (try? Data(contentsOf: url).count) ?? -1
                seen.withLock { $0 = (name, mime, size) }
                return jobDto()
            }
            $0.importJob = { _ in jobDto(status: "running") }
        }
        let result = await s.repo.startImport(fileURL: file, format: .pocketCsv)
        guard case .started(let job) = result else {
            Issue.record("not started: \(result)")
            return
        }
        #expect(job.id == "job1")
        #expect(seen.withLock { $0 }! == ("pocket.csv", "text/csv", 10))
        #expect(s.h.jobs.current?.id == "job1")
        #expect(s.tracker.isTracking)
        // The temporary copy is gone.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: s.repo.importsDirectory.path)) ?? []
        #expect(leftovers.isEmpty)
        s.tracker.stop()
    }

    @Test func `Files over 20 MiB are refused without uploading`() async throws {
        let s = try Setup()
        let file = try tempFile("big.csv", bytes: Int(Limits.maxImportBytes) + 1)
        #expect(await s.repo.startImport(fileURL: file, format: .pocketCsv) == .failed(.tooLarge))
        #expect(!s.h.api.recorded.contains("createImport"))
    }

    @Test func `Empty or unreadable files are bad files`() async throws {
        let s = try Setup()
        let empty = try tempFile("empty.csv", bytes: 0)
        #expect(await s.repo.startImport(fileURL: empty, format: .pocketCsv) == .failed(.badFile))
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).csv")
        #expect(await s.repo.startImport(fileURL: missing, format: .pocketCsv) == .failed(.badFile))
    }

    @Test(arguments: [
        (httpError(401), ImportError.signedOut),
        (httpError(413), .tooLarge),
        (httpError(429), .rateLimited),
        (httpError(400), .badFile),
        (httpError(415), .badFile),
        (httpError(503, code: "workflow_unavailable"), .unavailable),
        (httpError(418), .unknown),
        (ApiError.transport(.notConnectedToInternet), .network),
    ])
    func `Import errors map as on Android`(error: ApiError, expected: ImportError) async throws {
        let s = try Setup()
        _ = await s.h.signIn("a@b.co")
        let file = try tempFile("x.html", bytes: 5)
        s.h.api.configure { $0.createImport = { _, _, _, _ in throw error } }
        #expect(await s.repo.startImport(fileURL: file, format: .netscapeHtml) == .failed(expected))
        #expect(s.h.jobs.current == nil)
        #expect((s.h.sessionStore.current?.expired == true) == (expected == .signedOut))
    }

    @Test func `Polling every 3 s mirrors progress until done, then reports it once`() async throws {
        let clock = ImmediateClock()
        let start = clock.now
        let s = try Setup(clock: clock)
        s.h.jobs.set(jobDto().importJob(fallbackFormat: .pocketCsv))
        let answers = Mutex([
            jobDto(status: "running", done: 1, total: 3), jobDto(status: "running", done: 2, total: 3),
            jobDto(status: "done", done: 3, total: 3),
        ])
        s.h.api.configure { $0.importJob = { _ in answers.withLock { $0.removeFirst() } } }
        var seen: [Int] = []
        let stream = s.h.jobs.stream()
        s.tracker.track(jobId: "job1")
        for await job in stream {
            if let job, seen.last != job.done { seen.append(job.done) }
            if job?.status == .done { break }
        }
        // The stream keeps only the newest value, so a fast reader may skip steps but never goes backwards.
        #expect(seen == seen.sorted() && seen.last == 3)
        #expect(answers.withLock { $0.isEmpty })
        // Polls at 0, 3 and 6 s.
        #expect(start.duration(to: clock.now) == .seconds(6))
        while s.tracker.isTracking { await Task.yield() }
        #expect(s.finished.withLock { $0.map(\.id) } == ["job1"])
    }

    @Test func `Polling resumes on the next launch from the stored job id`() async throws {
        let defaults = Harness.freshDefaults()
        do {
            let first = try Setup(defaults: defaults)
            first.h.jobs.set(jobDto(status: "running").importJob(fallbackFormat: .pocketCsv))
        }
        let s = try Setup(defaults: defaults)
        #expect(s.h.jobs.current?.id == "job1")
        s.h.api.configure { $0.importJob = { id in jobDto(id: id, status: "done", done: 4, total: 4) } }
        s.tracker.resumeIfNeeded()
        await settle()
        #expect(s.h.jobs.current?.status == .done)
        #expect(s.finished.withLock { $0.count } == 1)
    }

    @Test func `A finished stored job is not polled again`() async throws {
        let s = try Setup()
        s.h.jobs.set(jobDto(status: "done").importJob(fallbackFormat: .pocketCsv))
        s.tracker.resumeIfNeeded()
        #expect(!s.tracker.isTracking)
    }

    @Test func `A 404 marks the job lost and a 401 stops polling and expires the session`() async throws {
        let s = try Setup()
        s.h.jobs.set(jobDto().importJob(fallbackFormat: .pocketCsv))
        s.h.api.configure { $0.importJob = { _ in throw httpError(404) } }
        #expect(await s.tracker.refresh(jobId: "job1") == .updated(s.h.jobs.current!))
        #expect(s.h.jobs.current?.status == .failed)
        #expect(s.h.jobs.current?.error == ImportTracker.errorLost)

        _ = await s.h.signIn("a@b.co")
        s.h.jobs.set(jobDto().importJob(fallbackFormat: .pocketCsv))
        s.h.api.configure { $0.importJob = { _ in throw httpError(401) } }
        #expect(await s.tracker.refresh(jobId: "job1") == .stop)
        #expect(s.h.sessionStore.current?.expired == true)
    }

    @Test func `Polling stops when the job is dismissed or replaced`() async throws {
        let s = try Setup()
        s.h.api.configure { $0.importJob = { _ in jobDto(status: "running") } }
        #expect(await s.tracker.refresh(jobId: "job1") == .stop)
        s.h.jobs.set(jobDto(id: "job2").importJob(fallbackFormat: .pocketCsv))
        #expect(await s.tracker.refresh(jobId: "job1") == .stop)
    }

    @Test func `Export lands in exports under the Content-Disposition name`() async throws {
        let s = try Setup()
        let old = s.repo.exportsDirectory.appending(path: "old.csv")
        try FileManager.default.createDirectory(at: s.repo.exportsDirectory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old)
        s.h.api.configure {
            $0.export = { _, destination in
                try Data("a,b".utf8).write(to: destination)
                return ExportFile(fileName: "sroka-2026-11-20.csv", bytes: 3)
            }
        }
        let result = await s.repo.export(format: .csv)
        let expected = s.repo.exportsDirectory.appending(path: "sroka-2026-11-20.csv")
        #expect(result == .ready(fileURL: expected, fileName: "sroka-2026-11-20.csv", bytes: 3))
        #expect(try String(contentsOf: expected, encoding: .utf8) == "a,b")
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func `Export names are reduced to one safe component`() {
        #expect(LiveDataTransferRepository.safeExportName("../../etc/passwd", format: .csv) == "passwd")
        #expect(LiveDataTransferRepository.safeExportName("..", format: .json) == "sroka-export.json")
        #expect(LiveDataTransferRepository.safeExportName(".hidden", format: .csv) == "sroka-export.csv")
        #expect(LiveDataTransferRepository.safeExportName("download.tmp", format: .csv) == "sroka-export.csv")
    }

    @Test func `Export errors map to network, signed out and server`() async throws {
        let s = try Setup()
        _ = await s.h.signIn("a@b.co")
        s.h.api.configure { $0.export = { _, _ in throw ApiError.transport(.timedOut) } }
        #expect(await s.repo.export(format: .json) == .failed(.network))
        s.h.api.configure { $0.export = { _, _ in throw httpError(500) } }
        #expect(await s.repo.export(format: .json) == .failed(.server))
        s.h.api.configure { $0.export = { _, _ in throw httpError(401) } }
        #expect(await s.repo.export(format: .json) == .failed(.signedOut))
        #expect(s.h.sessionStore.current?.expired == true)
    }

    @Test func `File info reports the name and size`() throws {
        let s = try Setup()
        let file = try tempFile("ril_export.html", bytes: 123)
        #expect(s.repo.fileInfo(file) == PickedFile(name: "ril_export.html", sizeBytes: 123))
        #expect(s.repo.fileInfo(file.deletingLastPathComponent().appending(path: "nope")) == nil)
    }
}
