import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Testing

@testable import SettingsFeature

@MainActor
struct ImportViewModelTests {
    private func harness(activeImport: ImportJob? = nil) -> (ImportViewModel, Fakes, TestClock<Duration>) {
        let fakes = Fakes()
        fakes.dataTransfer.active.send(activeImport)
        let clock = TestClock()
        let model = withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
            $0.date = .constant(Fixtures.now)
        } operation: {
            ImportViewModel()
        }
        return (model, fakes, clock)
    }

    private func job(
        _ status: JobStatus,
        total: Int? = nil,
        done: Int = 0,
        skipped: Int = 0,
        error: String? = nil,
        updatedAt: Date = Fixtures.now
    ) -> ImportJob {
        ImportJob(
            id: "job-1",
            status: status,
            format: .pocketCsv,
            total: total,
            done: done,
            skipped: skipped,
            error: error,
            createdAt: Fixtures.now,
            updatedAt: updatedAt
        )
    }

    private func pick(_ model: ImportViewModel, name: String = "ril_export.csv") {
        model.fileImported(.success(URL(filePath: "/tmp/\(name)")))
    }

    private func observing(_ model: ImportViewModel, _ body: () async -> Void) async {
        let task = Task { await model.task() }
        await settle()
        await body()
        task.cancel()
    }

    // MARK: Format

    @Test(
        arguments: [
            (ImportSource.pocket, "ril_export.csv", ImportFormat.pocketCsv),
            (.pocket, "part_000000.csv", .pocketCsv),
            (.pocket, "ril_export.html", .pocketHtml),
            (.pocket, "RIL_EXPORT.HTM", .pocketHtml),
            (.instapaper, "instapaper-export.csv", .instapaperCsv),
            (.browser, "bookmarks.html", .netscapeHtml),
        ]
    )
    func `Source and file name pick the server format`(source: ImportSource, name: String, expected: ImportFormat) {
        #expect(ImportViewModel.resolveFormat(source: source, fileName: name) == expected)
    }

    // MARK: Picking and starting

    @Test func `Nothing can be imported before a file is chosen`() {
        let (model, _, _) = harness()
        #expect(!model.hasFile)
        #expect(!model.canImport)
    }

    @Test func `Choosing a file shows its name and size`() {
        let (model, _, _) = harness()
        pick(model, name: "ril_export.csv")
        #expect(model.fileName == "ril_export.csv")
        #expect(model.fileSizeBytes == 4096)
        #expect(model.canImport)
    }

    @Test func `A cancelled picker keeps the current file`() {
        let (model, _, _) = harness()
        pick(model)
        model.fileImported(.failure(CocoaError(.userCancelled)))
        #expect(model.fileName == "ril_export.csv")
    }

    @Test func `Importing starts a job with the resolved format`() async {
        let (model, fakes, _) = harness()
        model.sourceSelected(.browser)
        pick(model, name: "bookmarks.html")
        await observing(model) {
            await model.importTapped()
            #expect(fakes.dataTransfer.calls.calls.contains("startImport"))
            #expect(fakes.dataTransfer.active.value?.format == .netscapeHtml)
            #expect(model.error == nil)
            #expect(!model.isUploading)
        }
    }

    @Test(
        arguments: [
            ImportError.tooLarge, .rateLimited, .badFile, .unavailable, .network, .signedOut, .unknown,
        ]
    )
    func `Each start failure is shown`(error: ImportError) async {
        let (model, fakes, _) = harness()
        fakes.dataTransfer.importFailure.send(error)
        pick(model)
        await model.importTapped()
        #expect(model.error == error)
        #expect(model.errorMessage != nil)
        #expect(model.canImport)
    }

    @Test func `A file over 20 MiB is refused before uploading`() async {
        let (model, fakes, _) = harness()
        fakes.dataTransfer.pickedFileSizeBytes.send(Limits.maxImportBytes + 1)
        pick(model)
        await model.importTapped()
        #expect(model.error == .tooLarge)
        #expect(!fakes.dataTransfer.calls.calls.contains("startImport"))
    }

    @Test func `A file of exactly 20 MiB is uploaded`() async {
        let (model, fakes, _) = harness()
        fakes.dataTransfer.pickedFileSizeBytes.send(Limits.maxImportBytes)
        pick(model)
        await model.importTapped()
        #expect(model.error == nil)
        #expect(fakes.dataTransfer.calls.calls.contains("startImport"))
    }

    @Test func `Changing the source clears a shown error`() async {
        let (model, fakes, _) = harness()
        fakes.dataTransfer.importFailure.send(.badFile)
        pick(model)
        await model.importTapped()
        #expect(model.error == .badFile)
        model.sourceSelected(.instapaper)
        #expect(model.error == nil)
    }

    // MARK: Job tracking

    @Test func `An unfinished job is tracked and locks the form`() async {
        let (model, fakes, _) = harness(activeImport: job(.running, total: 100, done: 10))
        await observing(model) {
            #expect(model.isJobRunning)
            #expect(!model.canChangeSource)
            #expect(fakes.dataTransfer.calls.calls == ["resumeTracking"])
            model.sourceSelected(.instapaper)
            #expect(model.source == .pocket)
        }
    }

    @Test func `Progress updates resume tracking only once per job`() async {
        let (model, fakes, _) = harness(activeImport: job(.queued))
        await observing(model) {
            fakes.dataTransfer.active.send(job(.running, total: 100, done: 20))
            await settle()
            fakes.dataTransfer.active.send(job(.running, total: 100, done: 60))
            await settle()
            #expect(fakes.dataTransfer.calls.calls == ["resumeTracking"])
            #expect(model.job?.done == 60)
        }
    }

    @Test func `A finished job reports imported links without the skipped ones`() async {
        let (model, _, _) = harness(activeImport: job(.done, total: 120, done: 120, skipped: 20))
        await observing(model) {
            #expect(!model.isJobRunning)
            #expect(model.importedCount == 100)
            #expect(model.job?.skipped == 20)
        }
    }

    @Test func `Done dismisses the job and resets the form`() async {
        let (model, fakes, _) = harness(activeImport: job(.done, total: 5, done: 5))
        pick(model)
        await observing(model) {
            await model.doneTapped()
            await settle()
            #expect(model.job == nil)
            #expect(!model.hasFile)
            #expect(fakes.dataTransfer.active.value == nil)
        }
    }

    @Test(
        arguments: [
            ("lost", "The server lost track of this import. Try importing the file again."),
            ("too_many_rows", "The file has too many links (the limit is 50,000)."),
            ("zip_too_large", "The ZIP file is too large or could not be opened."),
            ("bad_zip", "The ZIP file is too large or could not be opened."),
            ("missing_url_column", "The file has no URL column. Check that you picked the right source."),
            ("no_csv_in_zip", "The ZIP file does not contain a CSV file."),
            ("whatever", "The server could not import this file."),
        ]
    )
    func `Failed jobs give a plain reason`(code: String, sentence: String) {
        #expect(String(localized: ImportViewModel.jobMessage(for: code)) == sentence)
    }

    @Test func `A job with no update for ten minutes can be dismissed`() async {
        let old = Fixtures.now.addingTimeInterval(-ImportViewModel.staleJobSeconds - 1)
        let (model, _, _) = harness(activeImport: job(.running, updatedAt: old))
        await observing(model) {
            #expect(model.isJobStale)
        }
        let (fresh, _, _) = harness(activeImport: job(.running))
        await observing(fresh) {
            #expect(!fresh.isJobStale)
        }
    }
}

@MainActor
struct ExportViewModelTests {
    private func harness() -> (ExportViewModel, Fakes) {
        let fakes = Fakes()
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ExportViewModel()
        }
        return (model, fakes)
    }

    @Test func `JSON is the default format and CSV can be chosen`() {
        let (model, _) = harness()
        #expect(model.format == .json)
        model.formatSelected(.csv)
        #expect(model.format == .csv)
    }

    @Test func `Exporting builds the file and shows its size`() async {
        let (model, fakes) = harness()
        await model.exportTapped()
        #expect(fakes.dataTransfer.calls.calls == ["export"])
        #expect(model.ready?.fileName == "sroka-export.csv")
        #expect(model.ready?.bytes == 2048)
        #expect(model.error == nil)
        #expect(!model.isExporting)
    }

    @Test func `Choosing another format drops the built file`() async {
        let (model, _) = harness()
        await model.exportTapped()
        #expect(model.ready != nil)
        model.formatSelected(.csv)
        #expect(model.ready == nil)
    }

    @Test(arguments: [ExportError.network, .signedOut, .server])
    func `Each export failure is shown`(error: ExportError) async {
        let (model, fakes) = harness()
        fakes.dataTransfer.exportResult.send(.failed(error))
        await model.exportTapped()
        #expect(model.error == error)
        #expect(model.errorMessage != nil)
        #expect(model.ready == nil)
    }

    @Test func `Save opens the file exporter only when a file is ready`() async {
        let (model, _) = harness()
        model.saveTapped()
        #expect(!model.isSavingFile)
        await model.exportTapped()
        model.saveTapped()
        #expect(model.isSavingFile)
    }

    @Test func `Saved and failed saves are reported, a cancel is silent`() async {
        let (model, _) = harness()
        await model.exportTapped()
        model.fileSaved(.success(URL(filePath: "/tmp/x.csv")))
        #expect(model.saveMessage != nil)
        let (other, _) = harness()
        await other.exportTapped()
        other.fileSaved(.failure(CocoaError(.userCancelled)))
        #expect(other.saveMessage == nil)
        other.fileSaved(.failure(CocoaError(.fileWriteNoPermission)))
        #expect(other.saveMessage != nil)
    }
}

@MainActor
struct ConsentPromptViewModelTests {
    private func harness(telemetryAvailable: Bool = true, consent: Consent = Consent()) -> (
        ConsentPromptViewModel, Fakes
    ) {
        var fakes = Fakes()
        fakes.telemetry = RecordingTelemetry(isAvailable: telemetryAvailable)
        fakes.consent.state.send(consent)
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ConsentPromptViewModel()
        }
        return (model, fakes)
    }

    private func observing(_ model: ConsentPromptViewModel, _ body: () async -> Void) async {
        let task = Task { await model.task() }
        await settle()
        await body()
        task.cancel()
    }

    @Test func `The prompt shows until the user decides`() async {
        let (model, _) = harness()
        await observing(model) {
            #expect(model.isPending)
        }
    }

    @Test func `Allow records yes and hides the prompt`() async {
        let (model, fakes) = harness()
        await observing(model) {
            await model.allowTapped()
            await settle()
            #expect(fakes.consent.state.value.analytics == true)
            #expect(!model.isPending)
        }
    }

    @Test func `No thanks records no and hides the prompt`() async {
        let (model, fakes) = harness()
        await observing(model) {
            await model.declineTapped()
            await settle()
            #expect(fakes.consent.state.value.analytics == false)
            #expect(!model.isPending)
        }
    }

    @Test func `An earlier decision means no prompt`() async {
        let (model, _) = harness(consent: Consent(analytics: false))
        await observing(model) {
            #expect(!model.isPending)
        }
    }

    @Test func `Builds without telemetry never prompt`() async {
        let (model, _) = harness(telemetryAvailable: false)
        await observing(model) {
            #expect(!model.isPending)
        }
    }
}
