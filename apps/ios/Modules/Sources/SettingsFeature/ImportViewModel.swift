import Dependencies
import Foundation
import Observation
import SrokaCore
import UniformTypeIdentifiers

/// Where the file being imported comes from (Android `ImportSource`).
public enum ImportSource: String, Sendable, Hashable, CaseIterable {
    case pocket
    case instapaper
    case browser
}

/// Import of Pocket, Instapaper and browser-bookmark exports (Android `ImportViewModel`). The
/// repository uploads the file and polls the job every 3 s; this model observes the active job.
@Observable @MainActor
public final class ImportViewModel {
    /// A running job with no update for this long is offered a "Dismiss".
    public static let staleJobSeconds: TimeInterval = 10 * 60
    static let staleCheckSeconds = 30

    public private(set) var source: ImportSource = .pocket
    public private(set) var fileName: String?
    public private(set) var fileSizeBytes: Int64?
    public private(set) var error: ImportError?
    public private(set) var isUploading = false
    /// The active (possibly finished) job, if any.
    public private(set) var job: ImportJob?
    public private(set) var isJobStale = false
    /// Presentation state of the system file picker.
    public var isPickingFile = false

    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var trackedJobId: String?
    @ObservationIgnored @Dependency(\.dataTransferRepository) private var transfer
    @ObservationIgnored @Dependency(\.continuousClock) private var clock
    @ObservationIgnored @Dependency(\.date) private var date

    public init() {}

    public var hasFile: Bool { fileName != nil }
    public var isJobRunning: Bool { job.map { !$0.status.isFinished } ?? false }
    public var canImport: Bool { hasFile && !isUploading && !isJobRunning }
    public var canChangeSource: Bool { !isUploading && !isJobRunning }

    /// Observes the active job (resuming polling for an unfinished one) and watches for a stalled
    /// job until cancelled.
    public func task() async {
        let tasks = [
            Task { await observeJob() },
            Task { await watchForStall() },
        ]
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    private func observeJob() async {
        for await value in transfer.activeImport() { jobChanged(value) }
    }

    private func watchForStall() async {
        while !Task.isCancelled {
            updateStale()
            do { try await clock.sleep(for: .seconds(Self.staleCheckSeconds)) } catch { return }
        }
    }

    // MARK: Intentions

    public func sourceSelected(_ source: ImportSource) {
        guard canChangeSource else { return }
        self.source = source
        error = nil
    }

    public func chooseFileTapped() {
        guard canChangeSource else { return }
        isPickingFile = true
    }

    /// Result of the system picker. A cancelled picker keeps the current file.
    public func fileImported(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let info = transfer.fileInfo(url)
        fileURL = url
        fileName = info?.name ?? url.lastPathComponent
        fileSizeBytes = info?.sizeBytes
        error = nil
    }

    public func importTapped() async {
        guard let fileURL, !isUploading, !isJobRunning else { return }
        if (fileSizeBytes ?? 0) > Limits.maxImportBytes {
            error = .tooLarge
            return
        }
        isUploading = true
        error = nil
        let scoped = fileURL.startAccessingSecurityScopedResource()
        let result = await transfer.startImport(
            fileURL: fileURL,
            format: Self.resolveFormat(source: source, fileName: fileName)
        )
        if scoped { fileURL.stopAccessingSecurityScopedResource() }
        isUploading = false
        if case .failed(let reason) = result { error = reason }
    }

    /// "Done" on a finished job (or "Dismiss" on a stalled one): forget it and reset the picker.
    public func doneTapped() async {
        await transfer.dismissImport()
        fileURL = nil
        fileName = nil
        fileSizeBytes = nil
        error = nil
        isJobStale = false
    }

    // MARK: Derived

    /// Maps the source and the picked file name to the server format (RULINGS R11).
    public static func resolveFormat(source: ImportSource, fileName: String?) -> ImportFormat {
        switch source {
        case .pocket:
            let name = (fileName ?? "").lowercased()
            return name.hasSuffix(".html") || name.hasSuffix(".htm") ? .pocketHtml : .pocketCsv
        case .instapaper: return .instapaperCsv
        case .browser: return .netscapeHtml
        }
    }

    /// Types the picker offers; `.data` last because providers often report CSV as generic data.
    public static func allowedContentTypes(for source: ImportSource) -> [UTType] {
        switch source {
        case .pocket: [.commaSeparatedText, .zip, .html, .data]
        case .instapaper: [.commaSeparatedText, .data]
        case .browser: [.html, .data]
        }
    }

    /// Links imported by a finished job (`done` counts skipped ones too).
    public var importedCount: Int { job.map { max($0.done - $0.skipped, 0) } ?? 0 }

    public var errorMessage: LocalizedStringResource? {
        guard let error else { return nil }
        return Self.message(for: error)
    }

    public static func message(for error: ImportError) -> LocalizedStringResource {
        switch error {
        case .tooLarge:
            LocalizedStringResource(
                "That file is larger than 20 MB. Remove unneeded entries and try again.",
                bundle: #bundle
            )
        case .rateLimited:
            LocalizedStringResource("You have reached today’s import limit. Try again tomorrow.", bundle: #bundle)
        case .badFile:
            LocalizedStringResource(
                "Sroka could not read that file. Check that it matches the source you picked.",
                bundle: #bundle
            )
        case .unavailable:
            LocalizedStringResource("Import is unavailable right now. Try again in a little while.", bundle: #bundle)
        case .network:
            LocalizedStringResource("No connection. Check your network and try again.", bundle: #bundle)
        case .signedOut:
            LocalizedStringResource("Your session has expired. Sign in again to import.", bundle: #bundle)
        case .unknown:
            LocalizedStringResource("Something went wrong. Try again.", bundle: #bundle)
        }
    }

    /// Plain reason for a failed job's server code (api.md §11.1); unknown codes get a generic line.
    public static func jobMessage(for code: String?) -> LocalizedStringResource {
        switch code {
        case "lost":
            LocalizedStringResource(
                "The server lost track of this import. Try importing the file again.",
                bundle: #bundle
            )
        case "too_many_rows":
            LocalizedStringResource("The file has too many links (the limit is 50,000).", bundle: #bundle)
        case "zip_too_large", "bad_zip":
            LocalizedStringResource("The ZIP file is too large or could not be opened.", bundle: #bundle)
        case "missing_url_column":
            LocalizedStringResource(
                "The file has no URL column. Check that you picked the right source.",
                bundle: #bundle
            )
        case "no_csv_in_zip":
            LocalizedStringResource("The ZIP file does not contain a CSV file.", bundle: #bundle)
        default:
            LocalizedStringResource("The server could not import this file.", bundle: #bundle)
        }
    }

    // MARK: Private

    private func jobChanged(_ value: ImportJob?) {
        job = value
        updateStale()
        // An unfinished job with no poller (app relaunched, gave up) would stay locked forever.
        guard let value, !value.status.isFinished else {
            trackedJobId = nil
            return
        }
        if trackedJobId != value.id {
            trackedJobId = value.id
            transfer.resumeTracking(jobId: value.id)
        }
    }

    private func updateStale() {
        guard let job, !job.status.isFinished else {
            isJobStale = false
            return
        }
        isJobStale = date.now.timeIntervalSince(job.updatedAt) > Self.staleJobSeconds
    }
}
