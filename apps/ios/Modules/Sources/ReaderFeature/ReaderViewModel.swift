import Dependencies
import Foundation
import Observation
import SrokaCore

/// State and content resolution of one open item (article or PDF). Port of Android's `ReaderViewModel`:
/// item + offline state decide which package to show; a download runs once per retry attempt and outlives
/// re-resolution; progress, actions and refresh live in `ReaderViewModel+Actions.swift`.
@Observable @MainActor
public final class ReaderViewModel {
    public let itemId: String
    /// Theme, font, size and spacing; shared with the appearance sheet.
    public let appearance: ReaderAppearanceModel
    /// Handled by the app root (see ``ReaderIntent``).
    public var onIntent: (ReaderIntent) -> Void

    // MARK: Observable state

    public internal(set) var item: Item?
    var state: ReaderState = .loading
    /// Live reading progress, 0...1.
    var progress = 0.0
    /// True while the article is scrolled to its very end.
    var atEnd = false
    /// The user dismissed the end-of-article card with "Keep".
    var isEndCardKept = false
    /// True while sync reports no network; Refresh is disabled then.
    var isOffline = false
    /// The last non-pending parse status was `partial`: the header shows the partial-copy warning.
    var settledPartial = false
    /// What the end-of-article card offers as "Up next".
    var endNext: ItemSummary?
    var toast: ReaderToast?
    /// False 5 minutes after the last interaction so a forgotten reader lets the screen time out.
    var keepAwake = true
    /// Bumped by "Start over": the view scrolls the web view to the top.
    var scrollToTopRequest = 0
    var refreshPhase = RefreshPhase.none

    // Presentation
    var isAppearancePresented = false
    var isDeleteConfirmationPresented = false

    var isRefreshing: Bool { refreshPhase != .none }
    var isPdf: Bool { item?.kind == .pdf }

    // MARK: Dependencies

    @ObservationIgnored @Dependency(\.libraryRepository) var library
    @ObservationIgnored @Dependency(\.contentStore) var content
    @ObservationIgnored @Dependency(\.syncStatusRepository) var syncStatus
    @ObservationIgnored @Dependency(\.syncController) var syncController
    @ObservationIgnored @Dependency(\.telemetry) var telemetry
    @ObservationIgnored @Dependency(\.date) var date
    @ObservationIgnored @Dependency(\.continuousClock) var clock

    // MARK: Internal bookkeeping (not observed)

    enum RefreshPhase: Sendable { case none, requested, pending }

    struct SourceKey: Equatable {
        var missing: Bool
        var parse: ParseStatus
        var hasContent: Bool
        var offline: OfflineState
        var pdf = false
    }

    @ObservationIgnored var latestItem: Item?
    @ObservationIgnored var receivedItem = false
    @ObservationIgnored var receivedOffline = false
    @ObservationIgnored var offlineState = OfflineState.none
    @ObservationIgnored var currentKey: SourceKey?
    @ObservationIgnored var resolvedAttempt = -1
    @ObservationIgnored var retryAttempt = 0
    @ObservationIgnored var autoDownloadedAttempt = -1
    @ObservationIgnored var vmDownload: ReaderState?
    @ObservationIgnored var inDownloadMode = false
    @ObservationIgnored var resolveTask: Task<Void, Never>?
    @ObservationIgnored var downloadTask: Task<Void, Never>?
    @ObservationIgnored var openLogged = false
    @ObservationIgnored var lastParseStatus: ParseStatus?
    @ObservationIgnored var resumeAnnounced = false
    @ObservationIgnored var isLeaving = false

    // Progress
    @ObservationIgnored var isReady = false
    @ObservationIgnored var reported: ProgressReport?
    @ObservationIgnored var lastSavedAt: Date?
    @ObservationIgnored var unsaved = false
    @ObservationIgnored var trailingSave: Task<Void, Never>?
    @ObservationIgnored var lastWrite: Task<Void, Never>?

    // Timers
    @ObservationIgnored var idleTask: Task<Void, Never>?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var refreshTimeout: Task<Void, Never>?

    public init(
        itemId: String,
        appearance: ReaderAppearanceModel = ReaderAppearanceModel(),
        onIntent: @escaping (ReaderIntent) -> Void = { _ in }
    ) {
        self.itemId = itemId
        self.appearance = appearance
        self.onIntent = onIntent
        if !isValidItemId(itemId) { state = .missing }
    }

    /// Follows the item, its offline state, sync status, the next readable item and the appearance preferences
    /// until cancelled (run it from the view's `.task`).
    public func observe() async {
        guard isValidItemId(itemId) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followItem() }
            group.addTask { await self.followOffline() }
            group.addTask { await self.followNextReadable() }
            group.addTask { await self.followSyncStatus() }
            group.addTask { await self.appearance.observe() }
        }
    }

    /// Cancels timers and in-flight resolution. The view calls it when it goes away.
    func stop() {
        resolveTask?.cancel()
        trailingSave?.cancel()
        idleTask?.cancel()
        toastTask?.cancel()
        refreshTimeout?.cancel()
        // `observe()` may run again (the view reappears): make it resolve afresh, without reloading an equal state.
        currentKey = nil
        receivedItem = false
        receivedOffline = false
    }

    // MARK: Following

    private func followItem() async {
        for await value in library.observeItem(id: itemId) {
            itemReceived(value)
        }
    }

    private func followOffline() async {
        for await value in content.observeOffline(itemId: itemId) {
            offlineState = value
            receivedOffline = true
            recompute()
        }
    }

    private func followNextReadable() async {
        for await value in library.observeNextReadable(excludeId: itemId) {
            endNext = value
        }
    }

    private func followSyncStatus() async {
        for await value in syncStatus.status {
            isOffline = value.phase == .offline
        }
    }

    func itemReceived(_ value: Item?) {
        latestItem = value
        item = value
        // A refresh passes through `pending`; the header keeps the last settled answer meanwhile.
        if let status = value?.parseStatus, status != .pending { settledPartial = status == .partial }
        receivedItem = true
        if let value, !openLogged {
            openLogged = true
            telemetry.logEvent(.openItem(kind: value.kind))
        }
        parseStatusChanged(value?.parseStatus)
        recompute()
    }

    // MARK: Resolution

    /// Restarts resolution when the inputs that decide what to show change (or a retry was requested).
    func recompute() {
        guard receivedItem, receivedOffline else { return }
        let key: SourceKey
        if let latestItem {
            if latestItem.kind == .pdf {
                // A PDF's state does not depend on parse/offline changes (the download itself flips them):
                // keep its key stable so the in-flight download is never cancelled by its own progress.
                key = SourceKey(missing: false, parse: .ok, hasContent: true, offline: .availableRemote, pdf: true)
            } else {
                key = SourceKey(
                    missing: false, parse: latestItem.parseStatus, hasContent: latestItem.contentId != nil,
                    offline: offlineState)
            }
        } else {
            key = SourceKey(missing: true, parse: .pending, hasContent: false, offline: .none)
        }
        guard key != currentKey || retryAttempt != resolvedAttempt else { return }
        currentKey = key
        resolvedAttempt = retryAttempt
        let attempt = retryAttempt
        resolveTask?.cancel()
        resolveTask = Task { await resolve(key, attempt: attempt) }
    }

    private func resolve(_ key: SourceKey, attempt: Int) async {
        inDownloadMode = false
        switch true {
        case key.missing:
            setState(.missing)
        case key.pdf:
            await resolvePdf()
        case key.offline == .downloaded:
            if let html = await content.articleHtml(itemId: itemId) {
                guard !Task.isCancelled else { return }
                setState(readyState(html))
            } else {
                guard !Task.isCancelled else { return }
                download(key, attempt: attempt)
            }
        case !key.hasContent:
            setState(key.parse == .failed ? .parseFailed(error: latestItem?.parseError) : .parsePending)
        default:
            // Also when DOWNLOADING elsewhere: downloads of one item are serialized, so this waits for the
            // in-flight one (then confirms it) and recovers if that one never finishes.
            download(key, attempt: attempt)
        }
    }

    private func resolvePdf() async {
        if let file = await content.pdfFile(itemId: itemId) {
            guard !Task.isCancelled else { return }
            setState(.pdfReady(file))
            return
        }
        guard !Task.isCancelled else { return }
        setState(.downloading)
        let result = await content.ensurePdfFile(itemId: itemId)
        guard !Task.isCancelled else { return }
        switch result {
        case .ready(let file): setState(.pdfReady(file))
        case .notReady: setState(.parsePending)
        case .failed(let reason): setState(.notDownloaded(Self.reason(for: reason)))
        }
    }

    /// Downloads at most once per retry `attempt`; later keys of the same attempt show the outcome.
    private func download(_ key: SourceKey, attempt: Int) {
        inDownloadMode = true
        if attempt != autoDownloadedAttempt {
            autoDownloadedAttempt = attempt
            vmDownload = .downloading
            setState(.downloading)
            // Unstructured on purpose: re-resolution must not cancel a download in flight.
            downloadTask = Task { [content, itemId] in
                let result = await content.downloadNow(itemId: itemId)
                await self.downloadFinished(result)
            }
        } else {
            setState(vmDownload ?? .notDownloaded(key.offline == .failed ? .error : .offline))
        }
    }

    private func downloadFinished(_ result: DownloadResult) async {
        let mapped = await mapResult(result)
        vmDownload = mapped
        if inDownloadMode { setState(mapped) }
    }

    private func mapResult(_ result: DownloadResult) async -> ReaderState {
        switch result {
        case .downloaded:
            if let html = await content.articleHtml(itemId: itemId) { return readyState(html) }
            return .notDownloaded(.error)
        case .notReady:
            return .parsePending
        case .failed(let reason):
            return .notDownloaded(Self.reason(for: reason))
        }
    }

    private func readyState(_ html: String) -> ReaderState {
        .ready(ReaderDocument(html: html, itemId: itemId, articlesDirectory: content.articlesDirectory()))
    }

    static func reason(for failure: RemoteFailure) -> NotDownloadedReason {
        switch failure {
        case .network: .offline
        case .unauthorized: .signIn
        case .rateLimited, .server: .error
        }
    }

    /// Applies `new` (a no-op when equal, so an identical re-resolution never reloads the web view).
    func setState(_ new: ReaderState) {
        guard new != state else { return }
        state = new
        switch new {
        case .ready, .pdfReady:
            isReady = true
            // A scroll still waiting for its save survives a document replacement (refresh, reload).
            if !unsaved { reported = nil }
            progress = reported?.progress ?? latestItem?.progress ?? 0
            // The held-back save may have fired while the reader was not ready (and exited): write it now.
            if unsaved { saveReported(at: date.now) }
            atEnd = false
            touchActivity()
            if case .ready = new { announceResumeIfNeeded() }
        case .rendererGone:
            break  // keep `isReady`: the position reported so far is still saved on leave
        default:
            isReady = false
        }
    }

    // MARK: Retry

    /// "Try again" on the not-saved screen.
    func retryTapped() {
        retryAttempt += 1
        recompute()
    }

    /// The system killed the web content process: show the "couldn't be displayed" state.
    func webProcessTerminated() {
        guard case .ready = state else { return }
        state = .rendererGone
    }

    /// "Reload" after the web content process was terminated.
    func reloadTapped() {
        guard case .rendererGone = state else { return }
        retryAttempt += 1
        state = .loading
        recompute()
    }

    /// Where the article should open: the latest reported position, else the saved one.
    func restorePoint() -> RestorePoint {
        if let reported { return RestorePoint(anchor: reported.anchor, progress: reported.progress) }
        return RestorePoint(anchor: latestItem?.progressAnchor, progress: latestItem?.progress ?? 0)
    }
}
