import Dependencies
import Foundation

/// Online-only import/export (RULINGS R11); an explicit exception to "network only in the sync and
/// content engines". Android: DataTransferRepository.kt.
public protocol DataTransferRepository: Sendable {
    /// Copies the picked file at `fileURL` (security-scoped, from the document picker), uploads it,
    /// stores the job as active and starts progress polling.
    func startImport(fileURL: URL, format: ImportFormat) async -> ImportStartResult

    /// The last started import, kept up to date by progress polling; nil when none (or dismissed).
    func activeImport() -> AsyncStream<ImportJob?>

    /// Makes sure progress polling runs for an unfinished job (no-op while one is running).
    func resumeTracking(jobId: String)

    /// Forget the active job once the UI has shown it finished.
    func dismissImport() async

    /// Downloads the export into the caches `exports/` directory (older exports are deleted first).
    func export(format: ExportFormat) async -> ExportResult

    /// Name and size of a picked document, or nil when it cannot be read.
    func fileInfo(_ fileURL: URL) -> PickedFile?
}

/// Why an import could not be started; mapped to strings in the UI.
public enum ImportError: String, Sendable, Hashable {
    /// Over `Limits.maxImportBytes` (client check or 413).
    case tooLarge
    /// 429: daily import limit reached.
    case rateLimited
    /// Unreadable or empty file, or the server rejected it (400/415).
    case badFile
    /// 5xx, e.g. 503 `workflow_unavailable`.
    case unavailable
    case network
    case signedOut
    case unknown
}

public enum ImportStartResult: Sendable, Hashable {
    case started(ImportJob)
    case failed(ImportError)
}

public enum ExportError: String, Sendable, Hashable {
    case network
    case signedOut
    case server
}

public enum ExportResult: Sendable, Hashable {
    /// `fileURL` is a local file ready for the share sheet / file exporter.
    case ready(fileURL: URL, fileName: String, bytes: Int64)
    case failed(ExportError)
}

/// Display name and size (bytes, nil when unknown) of a picked document.
public struct PickedFile: Sendable, Hashable {
    public var name: String
    public var sizeBytes: Int64?

    public init(name: String, sizeBytes: Int64?) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

private struct UnimplementedDataTransferRepository: DataTransferRepository {
    private func fail(_ method: String) {
        reportUnimplemented("DataTransferRepository.\(method)", key: "dataTransferRepository")
    }

    func startImport(fileURL: URL, format: ImportFormat) async -> ImportStartResult {
        fail("startImport")
        return .failed(.unknown)
    }
    func activeImport() -> AsyncStream<ImportJob?> {
        fail("activeImport")
        return .finished
    }
    func resumeTracking(jobId: String) { fail("resumeTracking") }
    func dismissImport() async { fail("dismissImport") }
    func export(format: ExportFormat) async -> ExportResult {
        fail("export")
        return .failed(.server)
    }
    func fileInfo(_ fileURL: URL) -> PickedFile? {
        fail("fileInfo")
        return nil
    }
}

private enum DataTransferRepositoryKey: TestDependencyKey {
    static let testValue: any DataTransferRepository = UnimplementedDataTransferRepository()
}

extension DependencyValues {
    public var dataTransferRepository: any DataTransferRepository {
        get { self[DataTransferRepositoryKey.self] }
        set { self[DataTransferRepositoryKey.self] = newValue }
    }
}
