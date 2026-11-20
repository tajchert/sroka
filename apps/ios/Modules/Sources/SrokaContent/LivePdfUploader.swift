import Foundation
import OSLog
import SrokaCore
import SrokaNetwork
import Synchronization

/// Live `PdfUploader` (Android `PdfUploaderImpl.kt`, `PdfUploadProcessor.kt`, `PdfUploadWorker.kt`).
///
/// `enqueue` copies each file into `pdf-uploads/{id}.pdf` (size cap, `%PDF-` sniff) with a `{id}.json` sidecar,
/// so pending uploads survive a relaunch (`resumePendingUploads()`). Uploads run one at a time from the file:
/// permanent errors (413, 415, 409 `storage_full`, other 4xx, missing or oversized file) fail at once; transient
/// ones (I/O, 408, 429, 5xx) retry with exponential backoff from 30 s, at most 15 attempts; a 401 calls
/// `onUnauthorized` and leaves the upload queued until `resumePendingUploads()` runs after sign-in. After a
/// success the first page goes up as a thumbnail (when the server has no lead image), the copy is deleted and a
/// sync is requested.
public final class LivePdfUploader: PdfUploader, Sendable {
    public static let maxAttempts = 15
    public static let firstBackoff: Duration = .seconds(30)
    public static let maxBackoff: Duration = .seconds(60 * 60)

    /// How one failed attempt is handled.
    enum Classification: Sendable, Equatable {
        case permanent(PdfUploadError)
        case transient(PdfUploadError)
        case unauthorized
    }

    enum CopyResult: Sendable, Equatable {
        case copied(Int64)
        case failed(PdfUploadError)
    }

    struct Metadata: Codable, Sendable {
        var id: String
        var fileName: String
        var sizeBytes: Int64
        var attempts: Int
        var tags: [String]
        /// `owner()` when the file was queued; nil in sidecars written before it was recorded.
        var owner: String?
    }

    private let api: any SrokaAPI
    private let paths: ContentPaths
    private let syncController: any SyncController
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let renderThumbnail: @Sendable (URL) -> Data?
    private let onUnauthorized: @Sendable () async -> Void
    private let owner: @Sendable () -> String?
    /// Uploads run one at a time.
    private let lane = KeyedLock()
    var laneForTests: KeyedLock { lane }
    private let list = Broadcast<[PdfUpload]>([])
    private struct Running {
        /// Bumped by `cancelAll`; an `enqueue` that was copying meanwhile must not start its upload.
        var generation = 0
        var tasks: [String: Task<Void, Never>] = [:]
    }

    private let running = Mutex(Running())
    private let log = Logger(subsystem: "app.sroka", category: "pdf-upload")

    public init(
        api: any SrokaAPI,
        paths: ContentPaths,
        syncController: any SyncController,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        renderThumbnail: @escaping @Sendable (URL) -> Data? = { PdfThumbnailRenderer.render($0) },
        onUnauthorized: @escaping @Sendable () async -> Void = {},
        owner: @escaping @Sendable () -> String? = { nil }
    ) {
        self.api = api
        self.paths = paths
        self.syncController = syncController
        self.sleep = sleep
        self.now = now
        self.renderThumbnail = renderThumbnail
        self.onUnauthorized = onUnauthorized
        self.owner = owner
        try? paths.prepare(paths.pdfUploads)
    }

    // MARK: PdfUploader

    public var uploads: AsyncStream<[PdfUpload]> { list.stream() }

    public func enqueue(_ fileURLs: [URL]) async -> [PdfUpload] {
        var result: [PdfUpload] = []
        // Once per call: a sign-out during the first copy must also stop the later files.
        let generation = running.withLock { $0.generation }
        for url in fileURLs {
            var upload = admit(url)
            if upload.state == .queued {
                if !start(upload, generation: generation) {
                    // Signed out while copying: the wipe already ran, drop the late copy.
                    deleteFiles(upload.id)
                    upload.state = .failed(.unknown)
                }
            } else {
                list.update { $0.append(upload) }
            }
            result.append(upload)
        }
        return result
    }

    public func cancel(id: String) async {
        guard list.value.contains(where: { $0.id == id && $0.isActive }) else { return }
        let task = running.withLock { $0.tasks.removeValue(forKey: id) }
        task?.cancel()
        deleteFiles(id)
        list.update { $0.removeAll { $0.id == id } }
    }

    public func clearFinished() {
        list.update { $0.removeAll { !$0.isActive } }
    }

    // MARK: Entry points

    /// Picks up uploads left in `pdf-uploads/` by an earlier process or paused by an expired session. Call at
    /// launch, after sign-in and when the app returns to the foreground.
    public func resumePendingUploads() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.pdfUploads.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let meta = readMetadata(id), ownedByCurrentAccount(meta) else {
                deleteFiles(id)
                continue
            }
            if running.withLock({ $0.tasks[id] != nil }) { continue }
            _ = start(PdfUpload(id: id, fileName: meta.fileName, sizeBytes: meta.sizeBytes, state: .queued))
        }
    }

    /// Sign-out: stops every upload and forgets them (the content store's wipe deletes the files).
    public func cancelAll() {
        let tasks = running.withLock { running in
            running.generation += 1
            defer { running.tasks.removeAll() }
            // Cleared under the same lock, so no upload can be published in between.
            list.update { $0.removeAll() }
            return Array(running.tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    // MARK: Admission

    private func admit(_ source: URL) -> PdfUpload {
        let id = UUIDv7.next(at: now())
        let fileName = Self.cleanPdfName(source.lastPathComponent)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let declared = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        func failed(_ error: PdfUploadError, size: Int64 = declared) -> PdfUpload {
            PdfUpload(id: id, fileName: fileName, sizeBytes: size, state: .failed(error))
        }
        if declared > Limits.maxPdfBytes { return failed(.tooLarge) }
        guard let dest = paths.pdfUpload(id), let metaURL = paths.pdfUploadMetadata(id) else { return failed(.unknown) }
        try? paths.prepare(paths.pdfUploads)
        let copied: Int64
        switch Self.copyPdf(from: source, to: dest, cap: Limits.maxPdfBytes) {
        case .copied(let size): copied = size
        case .failed(let error):
            paths.removeIfPresent(dest)
            return failed(error)
        }
        let meta = Metadata(id: id, fileName: fileName, sizeBytes: copied, attempts: 0, tags: [], owner: owner())
        do {
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        } catch {
            paths.removeIfPresent(dest)
            return failed(.storageFull, size: copied)
        }
        return PdfUpload(id: id, fileName: fileName, sizeBytes: copied, state: .queued)
    }

    /// Streams `source` to `dest`, failing above `cap` bytes or without `%PDF-` in the first KiB.
    static func copyPdf(from source: URL, to dest: URL, cap: Int64) -> CopyResult {
        guard let input = try? FileHandle(forReadingFrom: source) else { return .failed(.unknown) }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
            let output = try? FileHandle(forWritingTo: dest)
        else { return .failed(.storageFull) }
        defer { try? output.close() }
        var total: Int64 = 0
        var head = Data()
        while true {
            let chunk: Data
            do {
                guard let next = try input.read(upToCount: 64 * 1024), !next.isEmpty else { break }
                chunk = next
            } catch {
                return .failed(.unknown)
            }
            if head.count < LiveContentStore.pdfSniffBytes {
                head.append(chunk.prefix(LiveContentStore.pdfSniffBytes - head.count))
            }
            total += Int64(chunk.count)
            if total > cap { return .failed(.tooLarge) }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                return .failed(.storageFull)
            }
        }
        guard total > 0, head.range(of: Data("%PDF-".utf8)) != nil else { return .failed(.notPdf) }
        return .copied(total)
    }

    /// Last path component, trimmed; "document.pdf" when empty; at most 255 characters keeping ".pdf".
    static func cleanPdfName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "/" { return "document.pdf" }
        if name.count > Limits.maxFileNameLength { return String(name.prefix(Limits.maxFileNameLength - 4)) + ".pdf" }
        return name
    }

    // MARK: Processing

    /// Publishes `upload` (or marks a known entry queued) and starts its task, unless `cancelAll` ran since
    /// `generation` was read. Lock order: `running`, then the list.
    private func start(_ upload: PdfUpload, generation: Int? = nil) -> Bool {
        let id = upload.id
        return running.withLock { running in
            if let generation, generation != running.generation { return false }
            guard running.tasks[id] == nil else { return true }
            list.update { uploads in
                if let index = uploads.firstIndex(where: { $0.id == id }) {
                    uploads[index].state = .queued
                } else {
                    uploads.append(upload)
                }
            }
            running.tasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.lane.withLock("upload") { await self.process(id) }
                self.running.withLock { _ = $0.tasks.removeValue(forKey: id) }
            }
            return true
        }
    }

    private func process(_ id: String) async {
        while !Task.isCancelled {
            guard var meta = readMetadata(id), let file = paths.pdfUpload(id) else {
                finish(id, .failed(.unknown))
                return
            }
            // Queued for another account (the share extension raced a sign-out): never upload it under this one.
            guard ownedByCurrentAccount(meta) else {
                finish(id, .failed(.unknown))
                return
            }
            let size = ContentPaths.fileSize(file)
            guard ContentPaths.isFile(file), size > 0 else {
                finish(id, .failed(.unknown))
                return
            }
            if size > Limits.maxPdfBytes {
                finish(id, .failed(.tooLarge))
                return
            }
            setState(id, .uploading(progress: 0))
            let classification: Classification
            do {
                let response = try await api.uploadPdf(
                    file: file, fileName: meta.fileName, tags: meta.tags, source: .share
                ) { [weak self] sent, total in
                    guard total > 0 else { return }
                    self?.setState(id, .uploading(progress: min(1, Double(sent) / Double(total))))
                }
                if response.item.leadImageKey == nil { await uploadPreview(itemId: response.item.id, file: file) }
                finish(id, .done(itemId: response.item.id, duplicate: !response.created))
                syncController.requestSync()
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                classification = Self.classify(error)
            }
            switch classification {
            case .permanent(let reason):
                log.notice("pdf upload failed permanently: \(reason.rawValue, privacy: .public)")
                finish(id, .failed(reason))
                return
            case .unauthorized:
                // Paused until the user signs in again (`resumePendingUploads`).
                await onUnauthorized()
                setState(id, .queued)
                return
            case .transient(let reason):
                meta.attempts += 1
                writeMetadata(meta)
                if meta.attempts >= Self.maxAttempts {
                    finish(id, .failed(reason))
                    return
                }
                setState(id, .queued)
                do {
                    try await sleep(Self.backoff(attempt: meta.attempts))
                } catch {
                    return
                }
            }
        }
    }

    /// 30 s, 60 s, 120 s, … capped at an hour.
    static func backoff(attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt - 1, 0), 16)
        return min(firstBackoff * factor, maxBackoff)
    }

    static func classify(_ error: any Error) -> Classification {
        guard let error = error as? ApiError else { return .transient(.network) }
        switch error {
        case .transport: return .transient(.network)
        case .malformedResponse: return .transient(.unknown)
        case .invalidRequest: return .permanent(.unknown)
        case .http(let status, _, _, _):
            switch status {
            case 401: return .unauthorized
            case 408, 429, 500...: return .transient(.unknown)
            default: return .permanent(error.pdfUploadError)
            }
        }
    }

    /// Best effort: an upload is done even when its preview is not.
    private func uploadPreview(itemId: String, file: URL) async {
        guard let data = renderThumbnail(file), !data.isEmpty, data.count <= Limits.maxThumbnailBytes else { return }
        do {
            _ = try await api.uploadThumbnail(itemId: itemId, data: data, contentType: PdfThumbnailRenderer.contentType)
        } catch {
            log.notice("pdf preview upload failed")
        }
    }

    // MARK: State

    private func finish(_ id: String, _ state: PdfUploadState) {
        deleteFiles(id)
        setState(id, state)
    }

    private func setState(_ id: String, _ state: PdfUploadState) {
        list.update { uploads in
            guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
            uploads[index].state = state
        }
    }

    private func deleteFiles(_ id: String) {
        if let file = paths.pdfUpload(id) { paths.removeIfPresent(file) }
        if let meta = paths.pdfUploadMetadata(id) { paths.removeIfPresent(meta) }
    }

    /// A sidecar without an owner predates the field and stays uploadable.
    private func ownedByCurrentAccount(_ meta: Metadata) -> Bool {
        guard let queuedBy = meta.owner else { return true }
        return queuedBy == owner()
    }

    private func readMetadata(_ id: String) -> Metadata? {
        guard let url = paths.pdfUploadMetadata(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func writeMetadata(_ meta: Metadata) {
        guard let url = paths.pdfUploadMetadata(meta.id), let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
