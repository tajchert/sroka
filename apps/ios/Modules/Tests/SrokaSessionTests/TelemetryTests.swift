import Foundation
import SrokaCore
import SrokaTesting
import Synchronization
import Testing

@testable import SrokaSession

struct TelemetryTests {
    private struct Boom: Error {}

    /// Every parameter value is one of a small set of enum words: no "@", "/", ":" or ".".
    private func expectEnumOnly(_ events: [TelemetryEvent]) {
        for event in events {
            for (key, value) in event.parameters {
                #expect(
                    value.range(of: "^[a-z_]+$", options: .regularExpression) != nil,
                    "\(event.name).\(key) = \(value)")
            }
        }
    }

    @Test func `Library decorator reports user changes with enum parameters only`() async throws {
        let telemetry = RecordingTelemetry()
        let fake = FakeLibraryRepository()
        let repo = TelemetryLibraryRepository(fake, telemetry: telemetry)
        let id = Fixtures.longRead.id

        _ = await repo.save(url: "https://new.example.com/a", title: "Secret title", tags: ["private"], source: .share)
        _ = await repo.save(url: "https://new.example.com/b", title: nil, tags: [], source: .manual)
        _ = await repo.save(url: "https://new.example.com/c", title: nil, tags: [], source: .drag)
        // Saving an existing URL again is not a new save.
        _ = await repo.save(url: "https://new.example.com/a", title: nil, tags: [], source: .share)
        await repo.setStatus(id: id, status: .archived)
        await repo.setStatus(id: id, status: .unread)
        await repo.setFavorite(id: id, favorite: true)
        await repo.setFavorite(id: id, favorite: false)
        await repo.setTags(id: id, names: Fixtures.longRead.tags + ["new-one"])
        await repo.setTags(id: id, names: ["new-one"])  // Removing only: no add_tag.
        await repo.delete(id: id)

        let events = telemetry.logged
        #expect(
            events == [
                .saveItem(source: .share, kind: .article), .saveItem(source: .webAdd, kind: .article),
                .saveItem(source: .drag, kind: .article), .archiveItem, .unarchiveItem, .favoriteItem(on: true),
                .favoriteItem(on: false), .addTag, .deleteItem,
            ])
        expectEnumOnly(events)
    }

    @Test func `PDF decorator reports each accepted file`() async {
        let telemetry = RecordingTelemetry()
        let uploader = TelemetryPdfUploader(FakePdfUploader(), telemetry: telemetry)
        let tmp = FileManager.default.temporaryDirectory
        _ = await uploader.enqueue([
            tmp.appending(path: "a.pdf"), tmp.appending(path: "notes.txt"), tmp.appending(path: "b.PDF"),
        ])
        #expect(telemetry.logged == [.saveItem(source: .pdf, kind: .pdf), .saveItem(source: .pdf, kind: .pdf)])
        expectEnumOnly(telemetry.logged)
    }

    @Test func `Transfer decorator reports started imports and ready exports only`() async {
        let telemetry = RecordingTelemetry()
        let fake = FakeDataTransferRepository()
        let repo = TelemetryDataTransferRepository(fake, telemetry: telemetry)
        let file = FileManager.default.temporaryDirectory.appending(path: "user@example.com.csv")
        _ = await repo.startImport(fileURL: file, format: .pocketCsv)
        _ = await repo.export(format: .json)
        fake.importFailure.send(.tooLarge)
        fake.exportResult.send(.failed(.network))
        _ = await repo.startImport(fileURL: file, format: .pocketCsv)
        _ = await repo.export(format: .csv)
        #expect(telemetry.logged == [.importStart(source: .import), .export(format: .json)])
        expectEnumOnly(telemetry.logged)
    }

    @Test(arguments: [Consent(analytics: nil, crashReports: true), Consent(analytics: false, crashReports: true)])
    func `Nothing is sent while analytics is not asked or refused`(consent: Consent) async {
        let sink = RecordingTelemetry()
        let gated = ConsentGatedTelemetry(sink, consent: { consent })
        let repo = TelemetryLibraryRepository(FakeLibraryRepository(), telemetry: gated)
        _ = await repo.save(url: "https://x.example.com", title: nil, tags: [], source: .share)
        await repo.delete(id: Fixtures.longRead.id)
        gated.logEvent(.login)
        #expect(sink.logged.isEmpty)
    }

    @Test func `Events flow once analytics is allowed, and stop when it is withdrawn`() {
        let sink = RecordingTelemetry()
        let consent = Mutex(Consent(analytics: true, crashReports: true))
        let gated = ConsentGatedTelemetry(sink, consent: { consent.withLock { $0 } })
        gated.logEvent(.login)
        consent.withLock { $0.analytics = false }
        gated.logEvent(.deleteItem)
        #expect(sink.logged == [.login])
    }

    @Test func `Non-fatals follow the crash report switch`() {
        let sink = RecordingTelemetry()
        let consent = Mutex(Consent(analytics: nil, crashReports: true))
        let gated = ConsentGatedTelemetry(sink, consent: { consent.withLock { $0 } })
        gated.recordNonFatal(Boom())
        consent.withLock { $0.crashReports = false }
        gated.recordNonFatal(Boom())
        #expect(sink.nonFatals.withLock { $0 } == 1)
    }

    @Test func `Consent applier pushes stored consent to the SDK and every change`() async throws {
        let sink = RecordingTelemetry()
        let consent = FakeConsentRepository()
        let applier = ConsentApplier(consent: consent, telemetry: sink)
        applier.start()
        await settle()
        #expect(sink.analytics.withLock { $0 } == [false])
        #expect(sink.crash.withLock { $0 } == [true])
        await consent.setAnalytics(true)
        await settle()
        #expect(sink.analytics.withLock { $0 } == [false, true])
        applier.stop()
        await consent.setCrashReports(false)
        await settle()
        #expect(sink.crash.withLock { $0 } == [true, true])
    }
}
