import Dependencies
import Foundation
import Observation
import SrokaCore

/// What Undo on the toast reverts.
public enum TagItemsUndo: Sendable, Hashable {
    case status(id: String, previous: ItemStatus)
    case favorite(id: String, previous: Bool)
}

/// The toast on screen (one at a time, 4 s).
public struct TagItemsToast: Identifiable, Sendable {
    public var id: Int
    public var message: LocalizedStringResource
    public var undo: TagItemsUndo?
}

/// URL asked to be shared (drives the share sheet).
public struct TagShareRequest: Identifiable, Sendable, Hashable {
    public let url: URL
    public var id: URL { url }
}

/// One tag's items (My List and Archive together) as a filtered list with the same row actions as
/// the library: swipe on both edges as configured, context menu, Undo toast, delete confirmation.
/// Created by `TagsViewModel.tagTapped`; attach with `.task { model.start() }`.
@MainActor
@Observable
public final class TagItemsViewModel {
    @ObservationIgnored @Dependency(\.libraryRepository) private var library
    @ObservationIgnored @Dependency(\.settingsRepository) private var settings
    @ObservationIgnored @Dependency(\.syncStatusRepository) private var syncStatusRepository
    @ObservationIgnored @Dependency(\.continuousClock) private var clock

    static let toastDuration: Duration = .seconds(4)

    public let tag: String
    public private(set) var items: [ItemSummary] = []
    public private(set) var hasMore = false
    /// False until the first page arrives, so the empty state never flashes.
    public private(set) var isLoaded = false
    public private(set) var swipeLeftAction: SwipeAction = .archive
    public private(set) var swipeRightAction: SwipeAction = .none
    public private(set) var toast: TagItemsToast?

    public var isConfirmingDelete = false
    public private(set) var itemPendingDeletion: ItemSummary?
    public var shareRequest: TagShareRequest?
    /// Haptic trigger (`sensoryFeedback`): warning on delete.
    public private(set) var warningFeedbackCount = 0

    @ObservationIgnored public var onIntent: @MainActor (TagsIntent) -> Void

    private var sortOrder: LibrarySortOrder = .newest
    private var listLimit = Limits.listPageSize
    private var isOffline = false
    private var lastLimit = 0
    private var lastSort: LibrarySortOrder?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var itemsTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var toastCounter = 0

    public init(tag: String, onIntent: @escaping @MainActor (TagsIntent) -> Void = { _ in }) {
        self.tag = tag
        self.onIntent = onIntent
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        itemsTask?.cancel()
        toastTask?.cancel()
    }

    // MARK: Observation

    public func start() {
        guard tasks.isEmpty else { return }
        let preferences = settings.preferences
        let status = syncStatusRepository.status
        tasks = [
            Task { [weak self] in
                for await preferences in preferences {
                    guard let self else { return }
                    apply(preferences)
                }
            },
            Task { [weak self] in
                for await status in status {
                    guard let self else { return }
                    isOffline = status.phase == .offline
                }
            },
        ]
        restartItems()
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
        itemsTask?.cancel()
        itemsTask = nil
        lastSort = nil
    }

    private func apply(_ preferences: UserPreferences) {
        swipeLeftAction = preferences.swipeLeftAction
        swipeRightAction = preferences.swipeRightAction
        if sortOrder != preferences.sortOrder {
            sortOrder = preferences.sortOrder
            listLimit = Limits.listPageSize
            restartItems()
        }
    }

    /// Re-subscribes when the sort order or the paging limit changed.
    private func restartItems() {
        guard sortOrder != lastSort || listLimit != lastLimit else { return }
        lastSort = sortOrder
        lastLimit = listLimit
        itemsTask?.cancel()
        let stream = library.observeItems(ItemQuery(tab: nil, tag: tag, sort: sortOrder), limit: listLimit)
        itemsTask = Task { [weak self] in
            for await page in stream {
                guard let self else { return }
                items = page.items
                hasMore = page.hasMore
                isLoaded = true
            }
        }
    }

    /// Grows the page when the user scrolls near the end of a full page.
    public func itemAppeared(_ item: ItemSummary) {
        guard hasMore, items.count >= listLimit, items.suffix(10).contains(where: { $0.id == item.id }) else {
            return
        }
        listLimit += Limits.listPageSize
        restartItems()
    }

    /// Swipe action behind each edge ("swipe left" reveals the trailing actions).
    public func action(for edge: TagSwipeEdge) -> SwipeAction {
        edge == .leading ? swipeRightAction : swipeLeftAction
    }

    // MARK: Row actions

    public func itemTapped(_ item: ItemSummary) { onIntent(.openItem(id: item.id)) }

    public func swiped(_ edge: TagSwipeEdge, item: ItemSummary) async {
        switch action(for: edge) {
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
        showToast(
            target == .archived
                ? TagsStrings.archived(offline: isOffline) : TagsStrings.unarchived(offline: isOffline),
            undo: .status(id: item.id, previous: item.status)
        )
    }

    public func favoriteTapped(_ item: ItemSummary) async {
        let target = !item.isFavorite
        await library.setFavorite(id: item.id, favorite: target)
        showToast(
            target ? TagsStrings.addedToFavorites : TagsStrings.removedFromFavorites,
            undo: .favorite(id: item.id, previous: item.isFavorite)
        )
    }

    public func editTagsTapped(_ item: ItemSummary) { onIntent(.editTags(id: item.id)) }

    public func shareLinkTapped(_ item: ItemSummary) async {
        guard let url = await originalURL(of: item) else { return }
        shareRequest = TagShareRequest(url: url)
    }

    public func openOriginalTapped(_ item: ItemSummary) async {
        guard let url = await originalURL(of: item) else { return }
        onIntent(.openURL(url))
    }

    public func refreshArticleTapped(_ item: ItemSummary) async {
        await library.refresh(id: item.id)
        showToast(TagsStrings.refreshing)
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
        showToast(TagsStrings.articleDeleted)
    }

    private func originalURL(of item: ItemSummary) async -> URL? {
        for await full in library.observeItem(id: item.id) {
            return full.flatMap { URL(string: $0.url) }
        }
        return nil
    }

    // MARK: Toast

    public func undoTapped() async {
        guard let undo = toast?.undo else { return }
        dismissToast()
        switch undo {
        case .status(let id, let previous): await library.setStatus(id: id, status: previous)
        case .favorite(let id, let previous): await library.setFavorite(id: id, favorite: previous)
        }
    }

    public func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    private func showToast(_ message: LocalizedStringResource, undo: TagItemsUndo? = nil) {
        toastCounter += 1
        let toast = TagItemsToast(id: toastCounter, message: message, undo: undo)
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.toastDuration)
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }
}

/// The edge a row is swiped from.
public enum TagSwipeEdge: Sendable, Hashable {
    case leading
    case trailing
}

/// `navigationDestination(item:)` needs a hashable value; a model is identified by identity.
extension TagItemsViewModel: Hashable {
    public nonisolated static func == (lhs: TagItemsViewModel, rhs: TagItemsViewModel) -> Bool { lhs === rhs }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
