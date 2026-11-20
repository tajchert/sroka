import Foundation
import SrokaCore

/// In-memory `ContentStore`: offline state comes from the library items; downloaded articles get a real
/// unpacked `SamplePackage` (article.html, images, and a PDF for PDF items) under this instance's own
/// temporary `articlesDirectory()`, so the reader's scheme handler has files to serve.
public final class FakeContentStore: ContentStore {
    public let library: FakeLibraryRepository
    public let downloadResult: FakeSubject<DownloadResult>
    public let usageBytes: FakeSubject<Int64>
    public let calls = CallRecorder<String>()
    private let directory = URL(filePath: NSTemporaryDirectory())
        .appending(path: "sroka-fake-articles-\(UUID().uuidString)", directoryHint: .isDirectory)

    public init(
        library: FakeLibraryRepository,
        downloadResult: DownloadResult = .downloaded,
        usageBytes: Int64 = 12_400_000
    ) {
        self.library = library
        self.downloadResult = FakeSubject(downloadResult)
        self.usageBytes = FakeSubject(usageBytes)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    public func observeOffline(itemId: String) -> AsyncStream<OfflineState> {
        library.items.stream { items in items.first { $0.id == itemId }?.offline ?? .none }
    }

    public func articleHtml(itemId: String) async -> String? {
        guard let item = library.item(id: itemId), item.offline == .downloaded, item.kind == .article else {
            return nil
        }
        return try? SamplePackage.install(itemId: itemId, title: item.displayTitle, in: directory)
    }

    public func articlesDirectory() -> URL { directory }

    public func downloadNow(itemId: String) async -> DownloadResult {
        calls.record("downloadNow")
        let result = downloadResult.value
        if result == .downloaded {
            library.items.update { items in
                guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
                items[index].offline = .downloaded
            }
        }
        return result
    }

    public func pdfFile(itemId: String) async -> URL? {
        guard let item = library.item(id: itemId), item.kind == .pdf, item.offline == .downloaded else { return nil }
        return try? SamplePackage.installPdf(itemId: itemId, in: directory)
    }

    public func storageUsageBytes() async -> Int64 { usageBytes.value }

    public func clearDownloads() async {
        calls.record("clearDownloads")
        usageBytes.send(0)
        library.items.update { items in
            for index in items.indices where items[index].offline == .downloaded {
                items[index].offline = .availableRemote
            }
        }
    }
}

/// In-memory `PdfUploader`: files ending in `.pdf` are queued; anything else fails as `.notPdf`.
public final class FakePdfUploader: PdfUploader {
    public let state: FakeSubject<[PdfUpload]>

    public init(uploads: [PdfUpload] = []) {
        state = FakeSubject(uploads)
    }

    public var uploads: AsyncStream<[PdfUpload]> { state.stream() }

    public func enqueue(_ fileURLs: [URL]) async -> [PdfUpload] {
        let start = state.value.count
        let entries = fileURLs.enumerated().map { offset, url in
            PdfUpload(
                id: "fake-upload-\(start + offset + 1)",
                fileName: url.lastPathComponent,
                sizeBytes: 1_048_576,
                state: url.pathExtension.lowercased() == "pdf" ? .queued : .failed(.notPdf)
            )
        }
        state.update { $0.append(contentsOf: entries) }
        return entries
    }

    public func cancel(id: String) async {
        state.update { uploads in uploads.removeAll { $0.id == id && $0.isActive } }
    }

    public func clearFinished() {
        state.update { uploads in uploads.removeAll { !$0.isActive } }
    }
}

/// `SyncController` that records calls. `fetchNewArticles` reports `fetchCompleted(0)` on the
/// connected status fake, like an up-to-date library.
public final class FakeSyncController: SyncController {
    public enum Call: Sendable, Hashable {
        case requestSync
        case fetchNewArticles
        case downloadItemNow(String)
    }

    public let calls = CallRecorder<Call>()
    public let status: FakeSyncStatusRepository?

    public init(status: FakeSyncStatusRepository? = nil) {
        self.status = status
    }

    public func requestSync() { calls.record(.requestSync) }

    public func fetchNewArticles() {
        calls.record(.fetchNewArticles)
        status?.eventSubject.send(.fetchCompleted(newlyDownloaded: 0))
    }

    public func downloadItemNow(itemId: String) { calls.record(.downloadItemNow(itemId)) }
}

/// In-memory `SyncStatusRepository`.
public final class FakeSyncStatusRepository: SyncStatusRepository {
    public let state: FakeSubject<SyncStatus>
    public let eventSubject = FakeEvents<SyncEvent>()

    public init(status: SyncStatus = Fixtures.syncStatus) {
        state = FakeSubject(status)
    }

    public var status: AsyncStream<SyncStatus> { state.stream() }
    public var events: AsyncStream<SyncEvent> { eventSubject.stream() }
}

/// `Telemetry` that records events (tests assert D15-safe events were logged).
public final class RecordingTelemetry: Telemetry {
    public let events = CallRecorder<TelemetryEvent>()
    public let available: Bool

    public init(isAvailable: Bool = true) {
        available = isAvailable
    }

    public var isAvailable: Bool { available }
    public func logEvent(_ event: TelemetryEvent) { events.record(event) }
    public func setAnalyticsEnabled(_ enabled: Bool) {}
    public func setCrashReportingEnabled(_ enabled: Bool) {}
    public func recordNonFatal(_ error: any Error) {}
}
