import Foundation
import SrokaCore
import Synchronization

// Repository decorators that report D15 events. Only `TelemetryEvent` values leave this file, and those carry enums
// only: never ids, URLs, titles, tag names, file names or emails. Android: TelemetryDecorators.kt, ConsentApplier.kt.

/// Forwards to `wrapped` only what the user agreed to: events only after analytics was explicitly allowed (not asked
/// = off), non-fatals only while crash reports are on. Wrap the app's telemetry in this before handing it to the
/// decorators and the view models.
public final class ConsentGatedTelemetry: Telemetry {
    private let wrapped: any Telemetry
    private let consent: @Sendable () -> Consent

    /// `consent` is read on every call; pass `{ preferencesStore.consent }`.
    public init(_ wrapped: any Telemetry, consent: @escaping @Sendable () -> Consent) {
        self.wrapped = wrapped
        self.consent = consent
    }

    public var isAvailable: Bool { wrapped.isAvailable }

    public func logEvent(_ event: TelemetryEvent) {
        guard consent().analyticsEnabled else { return }
        wrapped.logEvent(event)
    }

    public func setAnalyticsEnabled(_ enabled: Bool) { wrapped.setAnalyticsEnabled(enabled) }
    public func setCrashReportingEnabled(_ enabled: Bool) { wrapped.setCrashReportingEnabled(enabled) }

    public func recordNonFatal(_ error: any Error) {
        guard consent().crashReports else { return }
        wrapped.recordNonFatal(error)
    }
}

/// Applies stored consent to the SDK at start and on every change. Call `start()` once at launch.
public final class ConsentApplier: Sendable {
    private let consent: any ConsentRepository
    private let telemetry: any Telemetry
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(consent: any ConsentRepository, telemetry: any Telemetry) {
        self.consent = consent
        self.telemetry = telemetry
    }

    public func start() {
        task.withLock { task in
            guard task == nil else { return }
            let stream = consent.consent
            let telemetry = telemetry
            task = Task {
                var last: Consent?
                for await value in stream where value != last {
                    last = value
                    telemetry.setAnalyticsEnabled(value.analyticsEnabled)
                    telemetry.setCrashReportingEnabled(value.crashReports)
                }
            }
        }
    }

    public func stop() {
        task.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    deinit { task.withLock { $0?.cancel() } }
}

/// Reports save_item, archive/unarchive, favorite, delete and add_tag for user-initiated changes.
public final class TelemetryLibraryRepository: LibraryRepository {
    private let delegate: any LibraryRepository
    private let telemetry: any Telemetry

    public init(_ delegate: any LibraryRepository, telemetry: any Telemetry) {
        self.delegate = delegate
        self.telemetry = telemetry
    }

    public func save(url: String, title: String?, tags: [String], source: SaveSource) async -> SaveResult {
        let result = await delegate.save(url: url, title: title, tags: tags, source: source)
        if case .saved(_, let alreadySaved) = result, !alreadySaved {
            let origin: TelemetrySource =
                switch source {
                case .share: .share
                case .manual: .webAdd
                case .drag: .drag
                }
            telemetry.logEvent(.saveItem(source: origin, kind: .article))
        }
        return result
    }

    public func setStatus(id: String, status: ItemStatus) async {
        await delegate.setStatus(id: id, status: status)
        telemetry.logEvent(status == .archived ? .archiveItem : .unarchiveItem)
    }

    public func setFavorite(id: String, favorite: Bool) async {
        await delegate.setFavorite(id: id, favorite: favorite)
        telemetry.logEvent(.favoriteItem(on: favorite))
    }

    public func delete(id: String) async {
        await delegate.delete(id: id)
        telemetry.logEvent(.deleteItem)
    }

    public func setTags(id: String, names: [String]) async {
        let before = await firstValue(of: delegate.observeItem(id: id))??.tags ?? []
        await delegate.setTags(id: id, names: names)
        if names.contains(where: { !before.contains($0) }) { telemetry.logEvent(.addTag) }
    }

    // MARK: Forwarded unchanged

    public func observeItems(_ query: ItemQuery, limit: Int) -> AsyncStream<ItemPage> {
        delegate.observeItems(query, limit: limit)
    }
    public func observeSearch(_ query: String, scope: SearchScope, limit: Int) -> AsyncStream<SearchPage> {
        delegate.observeSearch(query, scope: scope, limit: limit)
    }
    public func observeSearchCount(_ query: String, scope: SearchScope) -> AsyncStream<Int> {
        delegate.observeSearchCount(query, scope: scope)
    }
    public func observeContinueReading(limit: Int) -> AsyncStream<[ItemSummary]> {
        delegate.observeContinueReading(limit: limit)
    }
    public func observeItem(id: String) -> AsyncStream<Item?> { delegate.observeItem(id: id) }
    public func observeNextUnread(excludeId: String?) -> AsyncStream<ItemSummary?> {
        delegate.observeNextUnread(excludeId: excludeId)
    }
    public func observeNextReadable(excludeId: String?) -> AsyncStream<ItemSummary?> {
        delegate.observeNextReadable(excludeId: excludeId)
    }
    public func observeCounts() -> AsyncStream<LibraryCounts> { delegate.observeCounts() }
    public func setProgress(id: String, progress: Double, anchor: Int?) async {
        await delegate.setProgress(id: id, progress: progress, anchor: anchor)
    }
    public func setTitle(id: String, title: String?) async { await delegate.setTitle(id: id, title: title) }
    public func refresh(id: String) async { await delegate.refresh(id: id) }
}

/// Reports save_item {pdf} for each PDF accepted for upload.
public final class TelemetryPdfUploader: PdfUploader {
    private let delegate: any PdfUploader
    private let telemetry: any Telemetry

    public init(_ delegate: any PdfUploader, telemetry: any Telemetry) {
        self.delegate = delegate
        self.telemetry = telemetry
    }

    public var uploads: AsyncStream<[PdfUpload]> { delegate.uploads }

    public func enqueue(_ fileURLs: [URL]) async -> [PdfUpload] {
        let uploads = await delegate.enqueue(fileURLs)
        for upload in uploads {
            if case .failed = upload.state { continue }
            telemetry.logEvent(.saveItem(source: .pdf, kind: .pdf))
        }
        return uploads
    }

    public func cancel(id: String) async { await delegate.cancel(id: id) }
    public func clearFinished() { delegate.clearFinished() }
}

/// Reports import_start and export.
public final class TelemetryDataTransferRepository: DataTransferRepository {
    private let delegate: any DataTransferRepository
    private let telemetry: any Telemetry

    public init(_ delegate: any DataTransferRepository, telemetry: any Telemetry) {
        self.delegate = delegate
        self.telemetry = telemetry
    }

    public func startImport(fileURL: URL, format: ImportFormat) async -> ImportStartResult {
        let result = await delegate.startImport(fileURL: fileURL, format: format)
        if case .started = result { telemetry.logEvent(.importStart()) }
        return result
    }

    public func export(format: ExportFormat) async -> ExportResult {
        let result = await delegate.export(format: format)
        if case .ready = result { telemetry.logEvent(.export(format: format)) }
        return result
    }

    public func activeImport() -> AsyncStream<ImportJob?> { delegate.activeImport() }
    public func resumeTracking(jobId: String) { delegate.resumeTracking(jobId: jobId) }
    public func dismissImport() async { await delegate.dismissImport() }
    public func fileInfo(_ fileURL: URL) -> PickedFile? { delegate.fileInfo(fileURL) }
}
