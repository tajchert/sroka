import Foundation
import SrokaCore
import SrokaNetwork
import UniformTypeIdentifiers

/// Online-only import and export (RULINGS R11). Android: DataTransferRepositoryImpl.kt.
///
/// Temporary files live in `<caches>/imports` and `<caches>/exports`; both hold the user's library and are deleted by
/// the local wipe (`transferDirectories`).
public final class LiveDataTransferRepository: DataTransferRepository {
    static let downloadName = "download.tmp"

    private let api: any SrokaAPI
    private let jobs: ImportJobStore
    private let tracker: ImportTracker
    private let sessionStore: SessionStore
    private let cachesDirectory: URL

    public init(
        api: any SrokaAPI,
        jobs: ImportJobStore,
        tracker: ImportTracker,
        sessionStore: SessionStore,
        cachesDirectory: URL
    ) {
        self.api = api
        self.jobs = jobs
        self.tracker = tracker
        self.sessionStore = sessionStore
        self.cachesDirectory = cachesDirectory
    }

    public var importsDirectory: URL { cachesDirectory.appending(path: "imports", directoryHint: .isDirectory) }
    public var exportsDirectory: URL { cachesDirectory.appending(path: "exports", directoryHint: .isDirectory) }
    /// What the local wipe must delete.
    public var transferDirectories: [URL] { [importsDirectory, exportsDirectory] }

    public func activeImport() -> AsyncStream<ImportJob?> { jobs.stream() }

    public func resumeTracking(jobId: String) { tracker.track(jobId: jobId) }

    public func dismissImport() async { jobs.clear() }

    public func fileInfo(_ fileURL: URL) -> PickedFile? {
        guard let values = try? fileURL.resourceValues(forKeys: [.nameKey, .fileSizeKey, .isRegularFileKey]),
            values.isRegularFile != false
        else { return nil }
        let name = values.name ?? fileURL.lastPathComponent
        return PickedFile(name: name.isEmpty ? "import" : name, sizeBytes: values.fileSize.map(Int64.init))
    }

    /// Runs detached from the caller: leaving the screen stops the wait, not the upload or storing the job.
    public func startImport(fileURL: URL, format: ImportFormat) async -> ImportStartResult {
        // The copy must happen while the caller still holds the security scope, so it runs before detaching.
        let max = Limits.maxImportBytes
        let info = fileInfo(fileURL)
        if (info?.sizeBytes ?? 0) > max { return .failed(.tooLarge) }
        let name = info?.name ?? "import"
        let directory = importsDirectory
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(.unknown)
        }
        let temp = directory.appending(path: "\(UUID().uuidString)-\(Self.safeName(name))")
        switch Self.copyLimited(from: fileURL, to: temp, max: max) {
        case nil:
            try? fileManager.removeItem(at: temp)
            return .failed(.badFile)
        case let copied? where copied > max:
            try? fileManager.removeItem(at: temp)
            return .failed(.tooLarge)
        case 0:
            try? fileManager.removeItem(at: temp)
            return .failed(.badFile)
        default:
            break
        }
        let mime = Self.mimeType(for: name)
        let generation = jobs.generation
        return await Task {
            defer { try? FileManager.default.removeItem(at: temp) }
            return await upload(temp: temp, name: name, mime: mime, format: format, generation: generation)
        }.value
    }

    private func upload(
        temp: URL, name: String, mime: String, format: ImportFormat, generation: Int
    ) async -> ImportStartResult {
        switch await apiCall({
            try await api.createImport(source: temp, fileName: name, mimeType: mime, format: format)
        })
        {
        case .success(let dto):
            let job = dto.importJob(fallbackFormat: format)
            // Signed out (and wiped) while uploading: do not bring the job back.
            guard jobs.set(job, ifNotClearedSince: generation) else { return .failed(.signedOut) }
            tracker.track(jobId: job.id)
            return .started(job)
        case .failure(let error):
            guard let status = error.status else { return .failed(error == .invalidRequest ? .badFile : .network) }
            switch status {
            case 401:
                sessionStore.markExpired()
                return .failed(.signedOut)
            case 413: return .failed(.tooLarge)
            case 429: return .failed(.rateLimited)
            case 400, 415: return .failed(.badFile)
            case 500...599: return .failed(.unavailable)
            default: return .failed(.unknown)
            }
        }
    }

    public func export(format: ExportFormat) async -> ExportResult {
        // Each export gets its own folder, so cleaning up after one never touches another.
        let directory = exportsDirectory.appending(path: UUID().uuidString)
        let fileManager = FileManager.default
        // Older exports hold the whole library: keep at most the newest one.
        try? fileManager.removeItem(at: exportsDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(.server)
        }
        let temp = directory.appending(path: Self.downloadName)
        let token = sessionStore.token
        switch await apiCall({ try await api.export(format: format, to: temp) }) {
        case .success where sessionStore.token != token:
            // Signed out (and wiped) while downloading: the library copy must not outlive the wipe.
            try? fileManager.removeItem(at: directory)
            return .failed(.signedOut)
        case .success(let file):
            let name = Self.safeExportName(file.fileName, format: format)
            let target = directory.appending(path: name)
            do {
                try? fileManager.removeItem(at: target)
                try fileManager.moveItem(at: temp, to: target)
                return .ready(fileURL: target, fileName: name, bytes: file.bytes)
            } catch {
                try? fileManager.removeItem(at: temp)
                return .failed(.server)
            }
        case .failure(let error):
            try? fileManager.removeItem(at: temp)
            if case .transport = error { return .failed(.network) }
            if error.status == 401 {
                sessionStore.markExpired()
                return .failed(.signedOut)
            }
            return .failed(.server)
        }
    }

    // MARK: Helpers

    /// Bytes copied, or nil when the source is unreadable. Stops once more than `max` bytes were seen.
    static func copyLimited(from source: URL, to destination: URL, max: Int64) -> Int64? {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
            let input = try? FileHandle(forReadingFrom: source),
            let output = try? FileHandle(forWritingTo: destination)
        else { return nil }
        defer {
            try? input.close()
            try? output.close()
        }
        var total: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                total += Int64(chunk.count)
                if total > max { return total }
                try output.write(contentsOf: chunk)
            }
        } catch {
            return nil
        }
        return total
    }

    /// File-system safe tail of a display name (never a path).
    static func safeName(_ name: String) -> String {
        let mapped = String(
            name.unicodeScalars.map { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
                    ? Character(scalar) : "_"
            })
        return String(mapped.suffix(80))
    }

    /// The server's name reduced to one safe path component; the temp name or an empty name gets the default.
    static func safeExportName(_ name: String, format: ExportFormat) -> String {
        let bare = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != "..", clean != downloadName, !clean.hasPrefix(".") else {
            return "sroka-export.\(format.fileExtension)"
        }
        return String(clean.prefix(Limits.maxFileNameLength))
    }

    static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
