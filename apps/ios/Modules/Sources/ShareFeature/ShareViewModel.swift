import Dependencies
import Foundation
import Observation
import SrokaCore

/// Model of the save sheet shown by the share extension (Android: `SaveSheetViewModel` and
/// `PdfShareViewModel`). It saves through `LibraryRepository` (so it works offline and a duplicate
/// moves back to My List) or hands PDFs to `PdfUploader`, then offers Tags, Favorite and Open.
///
/// The sheet dismisses itself 4 s after it shows, unless the user touched it; `state.countdown`
/// drives the line that counts this down. The extension host calls `start(_:)` once with the
/// extracted input and handles `onIntent`.
@MainActor
@Observable
public final class ShareViewModel {
    @ObservationIgnored @Dependency(\.libraryRepository) private var library
    @ObservationIgnored @Dependency(\.tagRepository) private var tagRepository
    @ObservationIgnored @Dependency(\.authRepository) private var authRepository
    @ObservationIgnored @Dependency(\.pdfUploader) private var pdfUploader
    @ObservationIgnored @Dependency(\.appEnvironment) private var environment
    @ObservationIgnored @Dependency(\.continuousClock) private var clock

    /// How long the link sheet stays without a touch (Kotlin: `AUTO_DISMISS_MS`; the docs say otherwise).
    static let autoDismiss: Duration = .seconds(4)
    /// PDF sheet: waiting for the server's answer, then after the answer (Kotlin `PdfShareHost`).
    static let pdfQueuedDismiss: Duration = .seconds(8)
    static let pdfAnsweredDismiss: Duration = .milliseconds(2500)
    static let recentTagsLimit = 20

    public private(set) var state: ShareSheetState
    /// Recently used tag names, newest first (suggestions in the tag editor).
    public private(set) var recentTags: [String] = []
    /// The tag editor request on screen; the view presents the injected editor for it.
    public var tagEditor: ShareTagEditorRequest?

    @ObservationIgnored public var onIntent: @MainActor (ShareIntent) -> Void

    @ObservationIgnored private let startup: ShareStartup
    @ObservationIgnored private let pushOnce: @Sendable () async -> Void
    @ObservationIgnored private var started = false
    @ObservationIgnored private var interacted = false
    @ObservationIgnored private var timerRun = 0
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var changedSincePush = false
    /// Edits still writing; `finish` waits for them, so the host never completes (and suspends the database)
    /// under a pending write.
    @ObservationIgnored private var pendingEdits: [Task<Void, Never>] = []
    @ObservationIgnored private var finished = false

    /// - Parameters:
    ///   - startup: result of opening the extension's storage (`needsApp` shows "Open Sroka to finish updating").
    ///   - pushOnce: one bounded `sync/push`, called after a link is saved and once more before the sheet
    ///     closes if favorite or tags changed afterwards. The live one has a short timeout and never throws.
    ///   - onIntent: dismiss or open-the-app requests for the extension host.
    public init(
        startup: ShareStartup = .ready,
        pushOnce: @escaping @Sendable () async -> Void = {},
        onIntent: @escaping @MainActor (ShareIntent) -> Void = { _ in }
    ) {
        self.startup = startup
        self.pushOnce = pushOnce
        self.onIntent = onIntent
        state = ShareSheetState()
    }

    isolated deinit {
        timerTask?.cancel()
        pushTask?.cancel()
        for task in observers { task.cancel() }
    }

    // MARK: Start

    /// Saves what was shared, once (a second call is ignored). A link returns after the first push finished;
    /// PDFs return once queued (the outcome arrives on `state`).
    public func start(_ input: SharedInput) async {
        guard !started else { return }
        started = true
        switch startup {
        case .needsApp: return show(.needsApp)
        case .unavailable: return show(.error)
        case .ready: break
        }
        var session = SessionState.signedOut
        for await current in authRepository.session {
            session = current
            break
        }
        if session == .signedOut { return show(.needsSignIn) }

        switch input {
        case .link(let url, let title):
            await saveLink(url, title: title)
        case .nothing:
            show(.noLink)
            armTimer(Self.autoDismiss)
        case .pdfs(let urls):
            await addPdfs(urls)
        case .rejectedPdf(let error):
            show(.pdf(.failed(error)))
        }
    }

    private func show(_ phase: ShareSheetState.Phase) {
        state.phase = phase
    }

    private func saveLink(_ url: String, title: String?) async {
        let result = await library.save(url: url, title: title, tags: [], source: .share)
        guard case .saved(let itemId, let alreadySaved) = result else {
            show(.noLink)
            armTimer(Self.autoDismiss)
            return
        }
        observeItem(itemId)
        observers.append(
            Task { [weak self] in
                guard let stream = self?.tagRepository.observeRecentTags(limit: Self.recentTagsLimit) else { return }
                for await names in stream {
                    guard let self else { return }
                    recentTags = names
                }
            })
        show(.saved(itemId: itemId, alreadySaved: alreadySaved))
        armTimer(Self.autoDismiss)
        let push = pushOnce
        pushTask = Task { await push() }
        await pushTask?.value
    }

    private func observeItem(_ id: String) {
        let stream = library.observeItem(id: id)
        observers.append(
            Task { [weak self] in
                for await item in stream {
                    guard let self else { return }
                    state.item = item
                }
            })
    }

    // MARK: PDF

    private func addPdfs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return show(.pdf(.noFile)) }
        show(.pdf(.working))
        let uploads = await pdfUploader.enqueue(urls)
        ShareInputExtractor.discard(urls)
        let failed = uploads.compactMap { upload -> PdfUploadError? in
            if case .failed(let error) = upload.state { error } else { nil }
        }
        if !uploads.isEmpty, failed.count == uploads.count, let first = failed.first {
            return show(.pdf(.failed(first)))
        }
        show(.pdf(.queued(count: uploads.count - failed.count)))
        armTimer(Self.pdfQueuedDismiss)
        let accepted = Set(uploads.filter { !$0.state.isFailed }.map(\.id))
        observers.append(Task { [weak self] in await self?.watchUploads(accepted) })
    }

    /// Moves "Adding PDF" to its outcome once every accepted upload has an answer.
    private func watchUploads(_ ids: Set<String>) async {
        for await uploads in pdfUploader.uploads {
            if finished { return }
            let mine = uploads.filter { ids.contains($0.id) }
            guard mine.count == ids.count, mine.allSatisfy({ !$0.isActive }) else { continue }
            let done = mine.filter { if case .done = $0.state { true } else { false } }
            if done.isEmpty {
                if case .failed(let error)? = mine.first?.state { show(.pdf(.failed(error))) }
                return
            }
            let duplicates = done.contains { if case .done(_, true) = $0.state { true } else { false } }
            show(.pdf(duplicates ? .duplicate : .added(count: done.count)))
            armTimer(Self.pdfAnsweredDismiss)
            return
        }
    }

    // MARK: Auto-dismiss

    private func armTimer(_ duration: Duration) {
        guard !interacted, !finished else { return }
        timerTask?.cancel()
        timerRun += 1
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        state.countdown = .running(seconds: seconds, run: timerRun)
        timerTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: duration) } catch { return }
            guard let self else { return }
            state.countdown = .hidden
            await finish(.dismiss)
        }
    }

    /// Any touch on the sheet keeps it open for good and removes the countdown line.
    public func sheetTouched() {
        interacted = true
        timerTask?.cancel()
        timerTask = nil
        if state.countdown != .hidden { state.countdown = .hidden }
    }

    // MARK: Intentions

    public func tagsButtonTapped() {
        sheetTouched()
        guard case .saved(let itemId, _) = state.phase, let item = state.item else { return }
        tagEditor = ShareTagEditorRequest(itemId: itemId, initialTags: item.tags, suggestions: recentTags)
    }

    /// The tag editor's save: writes the tags and closes the editor.
    public func tagsSaved(itemId: String, names: [String]) async {
        await library.setTags(id: itemId, names: names)
        changedSincePush = true
        tagEditor = nil
    }

    /// An editor that saved the tags itself closed (Save or Cancel): push once more before the sheet goes.
    public func tagEditorFinished() {
        changedSincePush = true
        tagEditor = nil
    }

    public func favoriteButtonTapped() async {
        sheetTouched()
        guard case .saved(let itemId, _) = state.phase, let item = state.item else { return }
        guard !finished else { return }
        changedSincePush = true
        let library = library
        let edit = Task { await library.setFavorite(id: itemId, favorite: !item.isFavorite) }
        pendingEdits.append(edit)
        await edit.value
    }

    /// "Open" and "Continue reading": the app opens at the item's reader.
    public func openButtonTapped() async {
        sheetTouched()
        guard case .saved(let itemId, _) = state.phase, let url = environment.itemURL(id: itemId) else {
            return await finish(.dismiss)
        }
        await finish(.openURL(url))
    }

    public func closeButtonTapped() async {
        sheetTouched()
        await finish(.dismiss)
    }

    /// "Sign in" while signed out: open the app, which shows its sign-in screen.
    public func signInButtonTapped() async {
        sheetTouched()
        guard let url = URL(string: "\(environment.urlScheme)://") else { return await finish(.dismiss) }
        await finish(.openURL(url))
    }

    /// The user swiped the sheet away.
    public func sheetDismissed() async {
        sheetTouched()
        await finish(.dismiss)
    }

    /// Finishes once: waits for the running push, pushes again if favorite or tags changed since,
    /// then asks the host to close.
    private func finish(_ intent: ShareIntent) async {
        guard !finished else { return }
        finished = true
        timerTask?.cancel()
        for edit in pendingEdits { await edit.value }
        await pushTask?.value
        if changedSincePush {
            changedSincePush = false
            await pushOnce()
        }
        onIntent(intent)
    }
}

extension PdfUploadState {
    fileprivate var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}
