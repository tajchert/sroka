import Dependencies
import Foundation
import Observation
import SrokaCore

/// URL asked to be shared (drives the share sheet).
public struct ShareRequest: Identifiable, Sendable, Hashable {
    public let url: URL
    public var id: URL { url }
}

/// Screen model of My List and Archive (one type, two destinations chosen by `scope`).
///
/// It owns the paged item stream, filters, sort, status card, row actions with undo, the add
/// link or PDF flow and drops. Other features' screens are requested through `onIntent`.
/// Attach with `.task { model.start() }` (observation runs until `stop()` or deinit).
@MainActor
@Observable
public final class LibraryViewModel {
    @ObservationIgnored @Dependency(\.libraryRepository) private var library
    @ObservationIgnored @Dependency(\.tagRepository) private var tagRepository
    @ObservationIgnored @Dependency(\.settingsRepository) private var settings
    @ObservationIgnored @Dependency(\.syncStatusRepository) private var syncStatusRepository
    @ObservationIgnored @Dependency(\.syncController) private var syncController
    @ObservationIgnored @Dependency(\.authRepository) private var authRepository
    @ObservationIgnored @Dependency(\.accountRepository) private var accountRepository
    @ObservationIgnored @Dependency(\.pdfUploader) private var pdfUploader
    @ObservationIgnored @Dependency(\.continuousClock) private var clock

    /// Chrome Web Store page of the extension (onboarding step "Save from Chrome").
    public static let extensionURL = URL(
        string: "https://chromewebstore.google.com/detail/mgeodllnkiehnjbdogljfjgdbadjdblh"
    )!

    /// Rows shown at most in "under 10 min" (Android: `maxReadingMinutes = 9`).
    static let underTenMaxMinutes = 9
    static let toastDuration: Duration = .seconds(4)
    static let maxTagChips = 5

    public let scope: LibraryScope
    /// Everything the stateless list content renders.
    public private(set) var state: LibraryListState

    /// The toast on screen (one at a time, 4 s, announced by the view).
    public private(set) var toast: LibraryToast?

    public var isAddSheetPresented = false
    /// Text of the add sheet's link field; editing clears the validation error.
    public var addLinkText = "" {
        didSet { if addLinkText != oldValue { isAddLinkInvalid = false } }
    }
    public private(set) var isAddLinkInvalid = false
    public var isFileImporterPresented = false
    /// True while a drag hovers over the list (shows "Drop to save").
    public var isDropTargeted = false

    public var isConfirmingDelete = false
    public private(set) var itemPendingDeletion: ItemSummary?
    public var shareRequest: ShareRequest?

    /// Bumped when a new save should scroll the list to its top (newest-first sort).
    public private(set) var scrollToTopCount = 0
    /// Haptic triggers (`sensoryFeedback`): success on save, warning on delete.
    public private(set) var successFeedbackCount = 0
    public private(set) var warningFeedbackCount = 0

    @ObservationIgnored public var onIntent: @MainActor (LibraryIntent) -> Void

    // MARK: Inputs

    private var listLimit = Limits.listPageSize
    private var filters = ListFilters() {
        didSet { filtersChanged() }
    }
    private var allContinueReading: [ItemSummary] = []
    private var tagCounts: [TagCount] = []
    private var session: SessionState = .signedOut
    private var syncStatus = SyncStatus()
    private var hintShown = true
    private var lastQuery: ItemQuery?
    private var lastLimit = 0

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var itemsTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var toastCounter = 0
    @ObservationIgnored private var uploadStates: [String: PdfUploadState]?

    public init(scope: LibraryScope = .myList, onIntent: @escaping @MainActor (LibraryIntent) -> Void = { _ in }) {
        self.scope = scope
        self.onIntent = onIntent
        state = LibraryListState(scope: scope, isLoaded: false)
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        itemsTask?.cancel()
        toastTask?.cancel()
    }

    // MARK: Observation

    /// Starts observing the repositories. Idempotent; the view calls it from `.task`.
    public func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            observe(settings.preferences) { $0.apply($1) },
            observe(tagRepository.observeTags()) { model, tags in
                model.tagCounts = tags
                model.recomputeTagChips()
            },
            observe(library.observeContinueReading()) { model, items in
                model.allContinueReading = items
                model.recomputeContinueReading()
            },
            observe(syncStatusRepository.status) { model, status in
                model.syncStatus = status
                model.recomputeStatusCard()
            },
            observe(syncStatusRepository.events) { $0.handle($1) },
            observe(authRepository.session) { model, session in
                model.session = session
                model.state.avatarLetter = Self.avatarLetter(for: session)
                model.recomputeStatusCard()
            },
            observe(pdfUploader.uploads) { $0.apply(uploads: $1) },
        ]
        if scope == .myList {
            tasks.append(
                Task { [weak self] in
                    guard let self else { return }
                    let clients = await accountRepository.connectedClients()
                    state.extensionConnected = clients?.extensionClient ?? false
                })
        }
        restartItems()
    }

    /// Stops observing (the view disappeared for good).
    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
        itemsTask?.cancel()
        itemsTask = nil
        lastQuery = nil
    }

    private func observe<Element: Sendable>(
        _ stream: AsyncStream<Element>,
        _ apply: @escaping @MainActor (LibraryViewModel, Element) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                apply(self, element)
            }
        }
    }

    private var query: ItemQuery {
        ItemQuery(
            tab: scope.tab,
            tag: filters.tag,
            sort: state.sortOrder,
            favoritesOnly: filters.favoritesOnly,
            maxReadingMinutes: filters.underTenMinutes ? Self.underTenMaxMinutes : nil
        )
    }

    /// Re-subscribes to the item stream when the query or the paging limit changed.
    private func restartItems() {
        let query = query
        guard query != lastQuery || listLimit != lastLimit else { return }
        lastQuery = query
        lastLimit = listLimit
        itemsTask?.cancel()
        itemsTask = observe(library.observeItems(query, limit: listLimit)) { model, page in
            model.state.items = page.items
            model.state.hasMore = page.hasMore
            model.state.isLoaded = true
            model.recomputeEmptyState()
            model.recomputePeek()
        }
    }

    private func apply(_ preferences: UserPreferences) {
        state.swipeLeftAction = preferences.swipeLeftAction
        state.swipeRightAction = preferences.swipeRightAction
        hintShown = preferences.swipeHintShown
        if state.sortOrder != preferences.sortOrder {
            state.sortOrder = preferences.sortOrder
            listLimit = Limits.listPageSize
            restartItems()
        }
        recomputePeek()
    }

    // MARK: Recomputing stored state

    private func filtersChanged() {
        state.filters = filters
        listLimit = Limits.listPageSize
        recomputeTagChips()
        recomputeContinueReading()
        recomputeEmptyState()
        restartItems()
    }

    /// Selected tag first, then the five most-used tags (Android `tagChips`).
    private func recomputeTagChips() {
        let top =
            tagCounts
            .filter { $0.count > 0 }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(Self.maxTagChips)
            .map(\.name)
        var chips: [String] = []
        if let selected = filters.tag { chips.append(selected) }
        chips.append(contentsOf: top.filter { $0 != filters.tag })
        state.tagChips = chips
    }

    /// Only on an unfiltered My List.
    private func recomputeContinueReading() {
        state.continueReading = scope == .myList && !filters.isActive ? allContinueReading : []
    }

    private func recomputeEmptyState() {
        guard state.isLoaded, state.items.isEmpty else {
            state.emptyState = nil
            return
        }
        if filters.isActive {
            state.emptyState = .noMatches
        } else {
            state.emptyState = scope == .archive ? .archiveEmpty : .onboarding
        }
    }

    /// One card at a time: sign in > resync > offline > downloading.
    private func recomputeStatusCard() {
        var needsSignIn = false
        if case .expired = session { needsSignIn = true }
        if case .error(.auth) = syncStatus.phase { needsSignIn = true }
        if needsSignIn {
            state.statusCard = .signInAgain
            return
        }
        switch syncStatus.phase {
        case .resyncing(let fraction):
            state.statusCard = .resyncing(fraction: fraction)
        case .offline:
            state.statusCard = .offline(pendingChanges: syncStatus.pendingOps)
        case .downloading(let done, let total, _) where total > 0 && done < total:
            state.statusCard = .downloading(done: done, total: total)
        default:
            state.statusCard = nil
        }
    }

    /// The first row peeks at the first configured swipe action until the hint was shown.
    private func recomputePeek() {
        guard !hintShown, !state.items.isEmpty else {
            state.peekEdge = nil
            return
        }
        if state.swipeLeftAction != .none {
            state.peekEdge = .trailing
        } else if state.swipeRightAction != .none {
            state.peekEdge = .leading
        } else {
            state.peekEdge = nil
        }
    }

    static func avatarLetter(for session: SessionState) -> String {
        guard let email = session.email, let first = email.first(where: { $0.isLetter || $0.isNumber }) else {
            return "?"
        }
        return String(first).uppercased()
    }

    // MARK: Header and filters

    public func avatarTapped() { onIntent(.openSettings) }
    public func signInTapped() { onIntent(.signInAgain) }

    public func sortChosen(_ order: LibrarySortOrder) async {
        guard order != state.sortOrder else { return }
        state.sortOrder = order
        listLimit = Limits.listPageSize
        restartItems()
        await settings.setSortOrder(order)
    }

    public func favoritesFilterTapped() { filters.favoritesOnly.toggle() }
    public func underTenFilterTapped() { filters.underTenMinutes.toggle() }
    public func tagChipTapped(_ name: String) { filters.tag = filters.tag == name ? nil : name }
    public func clearFiltersTapped() { filters = ListFilters() }

    /// Pull to refresh: fetch new articles; the outcome arrives as a toast.
    public func refresh() async {
        syncController.fetchNewArticles()
        try? await clock.sleep(for: .milliseconds(500))
    }

    /// Grows the page when the user scrolls near the end of a full page.
    public func itemAppeared(_ item: ItemSummary) {
        guard state.hasMore, state.items.count >= listLimit,
            state.items.suffix(10).contains(where: { $0.id == item.id })
        else { return }
        listLimit += Limits.listPageSize
        restartItems()
    }

    // MARK: Row actions

    public func itemTapped(_ item: ItemSummary) { onIntent(.openItem(id: item.id)) }

    /// Runs the action configured for the edge the row was swiped from.
    public func swiped(_ edge: SwipeEdge, item: ItemSummary) async {
        switch state.action(for: edge) {
        case .archive: await archiveTapped(item)
        case .favorite: await favoriteTapped(item)
        case .tags: editTagsTapped(item)
        case .none: break
        }
    }

    /// Archive, or move back to My List when the item is archived.
    public func archiveTapped(_ item: ItemSummary) async {
        let target: ItemStatus = item.status == .archived ? .unread : .archived
        await library.setStatus(id: item.id, status: target)
        let offline = syncStatus.phase == .offline
        showToast(
            target == .archived
                ? LibraryStrings.archived(offline: offline) : LibraryStrings.unarchived(offline: offline),
            action: .undo(.status(id: item.id, previous: item.status))
        )
    }

    public func favoriteTapped(_ item: ItemSummary) async {
        let target = !item.isFavorite
        await library.setFavorite(id: item.id, favorite: target)
        showToast(
            target ? LibraryStrings.addedToFavorites : LibraryStrings.removedFromFavorites,
            action: .undo(.favorite(id: item.id, previous: item.isFavorite))
        )
    }

    public func editTagsTapped(_ item: ItemSummary) { onIntent(.editTags(id: item.id)) }

    public func shareLinkTapped(_ item: ItemSummary) async {
        guard let url = await originalURL(of: item) else { return }
        shareRequest = ShareRequest(url: url)
    }

    public func openOriginalTapped(_ item: ItemSummary) async {
        guard let url = await originalURL(of: item) else { return }
        onIntent(.openURL(url))
    }

    public func refreshArticleTapped(_ item: ItemSummary) async {
        await library.refresh(id: item.id)
        showToast(LibraryStrings.refreshing)
    }

    public func deleteTapped(_ item: ItemSummary) {
        itemPendingDeletion = item
        isConfirmingDelete = true
    }

    public func cancelDeleteTapped() {
        isConfirmingDelete = false
        itemPendingDeletion = nil
    }

    public func confirmDeleteTapped() async {
        guard let item = itemPendingDeletion else { return }
        isConfirmingDelete = false
        itemPendingDeletion = nil
        await library.delete(id: item.id)
        warningFeedbackCount += 1
        showToast(LibraryStrings.articleDeleted)
    }

    private func originalURL(of item: ItemSummary) async -> URL? {
        for await full in library.observeItem(id: item.id) {
            return full.flatMap { URL(string: $0.url) }
        }
        return nil
    }

    // MARK: Swipe hint

    /// The peek animation ran (or was skipped for Reduce Motion): never show it again.
    public func swipeHintFinished() async {
        guard !hintShown else { return }
        hintShown = true
        state.peekEdge = nil
        await settings.setSwipeHintShown()
    }

    // MARK: Toast

    public func toastActionTapped() async {
        guard let toast, let action = toast.action else { return }
        dismissToast()
        switch action {
        case .undo(let undo): await perform(undo)
        case .open(let id): onIntent(.openItem(id: id))
        }
    }

    public func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    private func perform(_ undo: UndoAction) async {
        switch undo {
        case .status(let id, let previous): await library.setStatus(id: id, status: previous)
        case .favorite(let id, let previous): await library.setFavorite(id: id, favorite: previous)
        case .deleteSaved(let ids):
            for id in ids { await library.delete(id: id) }
        }
    }

    private func showToast(_ message: LocalizedStringResource, action: LibraryToast.Action? = nil) {
        toastCounter += 1
        let toast = LibraryToast(id: toastCounter, message: message, action: action)
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.toastDuration)
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }

    // MARK: Add link or PDF

    public func addButtonTapped() {
        addLinkText = ""
        isAddSheetPresented = true
    }

    public func cancelAddTapped() {
        isAddSheetPresented = false
        addLinkText = ""
    }

    /// Fills the field from the clipboard (system paste button: no permission prompt).
    public func pasted(_ strings: [String]) {
        guard let text = strings.first else { return }
        addLinkText = LinkExtraction.link(from: text) ?? text
    }

    /// Onboarding chip "Save link from clipboard": saves the pasted link without the sheet.
    public func saveClipboardLinkTapped(_ strings: [String]) async {
        guard let link = strings.lazy.compactMap({ LinkExtraction.link(from: $0) }).first else {
            showToast(LibraryStrings.noLinkFound)
            return
        }
        await save(link: link)
    }

    public func saveLinkTapped() async {
        guard let link = LinkExtraction.link(from: addLinkText) else {
            isAddLinkInvalid = true
            return
        }
        if await save(link: link) {
            isAddSheetPresented = false
            addLinkText = ""
        }
    }

    @discardableResult
    private func save(link: String) async -> Bool {
        switch await library.save(url: link, title: nil, tags: [], source: .manual) {
        case .saved(_, let alreadySaved):
            successFeedbackCount += 1
            showToast(alreadySaved ? LibraryStrings.alreadySavedMoved : LibraryStrings.saved)
            requestScrollToTop()
            return true
        case .invalidUrl:
            isAddLinkInvalid = true
            return false
        }
    }

    private func requestScrollToTop() {
        if state.sortOrder == .newest { scrollToTopCount += 1 }
    }

    public func choosePdfTapped() { isFileImporterPresented = true }

    /// Files from `fileImporter`; the uploader enforces the 50 MiB cap and the `%PDF-` sniff and
    /// reports failures as upload cards.
    public func pdfFilesPicked(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessed { url.stopAccessingSecurityScopedResource() }
        }
        let queued = await pdfUploader.enqueue(urls)
        isAddSheetPresented = false
        showToast(queued.count == 1 ? LibraryStrings.uploadingPdf : LibraryStrings.uploadingPdfs(queued.count))
    }

    public func dismissUploadCardTapped() { pdfUploader.clearFinished() }

    // MARK: Drops

    /// Text dropped onto the list: every link found in it.
    public func textDropped(_ strings: [String]) async {
        let urls = strings.compactMap { LinkExtraction.firstURL(in: $0) }.compactMap { URL(string: $0) }
        await linksDropped(urls)
    }

    public func linksDropped(_ urls: [URL]) async {
        var seen = Set<String>()
        let links = urls.map(\.absoluteString).filter { LinkExtraction.isHTTPURL($0) && seen.insert($0).inserted }
        guard !links.isEmpty else {
            showToast(LibraryStrings.noLinkFound)
            return
        }
        var created: [String] = []
        var duplicates: [String] = []
        for link in links {
            if case .saved(let id, let already) = await library.save(url: link, title: nil, tags: [], source: .drag) {
                if already { duplicates.append(id) } else { created.append(id) }
            }
        }
        if !created.isEmpty {
            successFeedbackCount += 1
            showToast(
                created.count == 1 ? LibraryStrings.savedToSroka : LibraryStrings.savedLinks(created.count),
                action: .undo(.deleteSaved(ids: created))
            )
            requestScrollToTop()
        } else if let first = duplicates.first {
            showToast(LibraryStrings.alreadyInSroka, action: .open(itemId: first))
        }
    }

    // MARK: Onboarding

    public func chromeStepTapped() { onIntent(.openURL(Self.extensionURL)) }
    public func pasteLinkStepTapped() { addButtonTapped() }

    // MARK: Events

    private func handle(_ event: SyncEvent) {
        switch event {
        case .fetchCompleted(let count):
            showToast(count > 0 ? LibraryStrings.readyOffline(count) : LibraryStrings.upToDate)
        case .fetchFailed(let kind):
            showToast(LibraryStrings.fetchFailed(kind))
        }
    }

    private func apply(uploads: [PdfUpload]) {
        defer { uploadStates = Dictionary(uniqueKeysWithValues: uploads.map { ($0.id, $0.state) }) }
        state.uploadCard = Self.uploadCard(for: uploads)
        guard let previous = uploadStates else { return }
        for upload in uploads {
            guard let before = previous[upload.id], Self.isActive(before) else { continue }
            switch upload.state {
            case .done(_, let duplicate):
                showToast(duplicate ? LibraryStrings.alreadyInSroka : LibraryStrings.pdfAdded)
            case .failed(let error):
                showToast(LibraryStrings.pdfFailed(error))
            case .queued, .uploading: break
            }
        }
    }

    private static func isActive(_ state: PdfUploadState) -> Bool {
        switch state {
        case .queued, .uploading: true
        case .failed, .done: false
        }
    }

    static func uploadCard(for uploads: [PdfUpload]) -> UploadCardKind? {
        let active = uploads.filter(\.isActive)
        if !active.isEmpty {
            let total = active.reduce(0.0) { sum, upload in
                if case .uploading(let progress) = upload.state { sum + progress } else { sum }
            }
            return .uploading(count: active.count, progress: total / Double(active.count))
        }
        let failed = uploads.compactMap { upload -> (String, PdfUploadError)? in
            if case .failed(let error) = upload.state { (upload.fileName, error) } else { nil }
        }
        guard let first = failed.first else { return nil }
        return .failed(fileName: first.0, error: first.1, others: failed.count - 1)
    }
}
