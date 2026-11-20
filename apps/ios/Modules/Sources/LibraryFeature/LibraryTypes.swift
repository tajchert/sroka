import Foundation
import SrokaCore

/// What the library asks the app root to do. LibraryFeature never imports the features that own
/// these destinations; the root handles each intent (see the report in docs).
public enum LibraryIntent: Sendable, Hashable {
    /// Open the article or PDF in the reader.
    case openItem(id: String)
    /// Present the tag editor for the item (owned by TagsFeature).
    case editTags(id: String)
    /// Open Settings (avatar button).
    case openSettings
    /// The session expired: present sign-in again.
    case signInAgain
    /// Open a web address (original article, Chrome extension page) in the system browser.
    case openURL(URL)
}

/// The two destinations that share one screen.
public enum LibraryScope: Sendable, Hashable {
    case myList
    case archive

    var tab: LibraryTab {
        switch self {
        case .myList: .myList
        case .archive: .archive
        }
    }
}

/// Chip filters, AND-combined (Android `ListFilters`).
public struct ListFilters: Sendable, Hashable {
    public var favoritesOnly = false
    public var underTenMinutes = false
    public var tag: String?

    public init(favoritesOnly: Bool = false, underTenMinutes: Bool = false, tag: String? = nil) {
        self.favoritesOnly = favoritesOnly
        self.underTenMinutes = underTenMinutes
        self.tag = tag
    }

    public var isActive: Bool { favoritesOnly || underTenMinutes || tag != nil }
}

/// The one sync card shown above the list, by priority (Android `SyncBanner`).
public enum StatusCardKind: Sendable, Hashable {
    case signInAgain
    case resyncing(fraction: Double?)
    case offline(pendingChanges: Int)
    case downloading(done: Int, total: Int)
}

public enum LibraryEmptyState: Sendable, Hashable {
    /// First run: empty My List, no filters.
    case onboarding
    case archiveEmpty
    case noMatches
}

public enum SwipeEdge: Sendable, Hashable {
    case leading
    case trailing
}

/// A PDF upload summarized for the cards above the list.
public enum UploadCardKind: Sendable, Hashable {
    case uploading(count: Int, progress: Double)
    case failed(fileName: String, error: PdfUploadError, others: Int)
}

/// Everything the stateless list content renders. The view model owns one and mutates fields.
public struct LibraryListState: Sendable, Hashable {
    public var scope: LibraryScope = .myList
    public var items: [ItemSummary] = []
    public var hasMore = false
    /// False until the first page arrives, so the empty state never flashes.
    public var isLoaded = false
    public var continueReading: [ItemSummary] = []
    public var sortOrder: LibrarySortOrder = .newest
    public var filters = ListFilters()
    public var tagChips: [String] = []
    public var statusCard: StatusCardKind?
    public var emptyState: LibraryEmptyState?
    public var uploadCard: UploadCardKind?
    public var avatarLetter = "?"
    public var swipeLeftAction: SwipeAction = .archive
    public var swipeRightAction: SwipeAction = .none
    /// Side whose action the first row should peek at (first run only), else nil.
    public var peekEdge: SwipeEdge?
    public var extensionConnected = false

    public init() {}

    public init(
        scope: LibraryScope = .myList,
        items: [ItemSummary] = [],
        hasMore: Bool = false,
        isLoaded: Bool = true,
        continueReading: [ItemSummary] = [],
        sortOrder: LibrarySortOrder = .newest,
        filters: ListFilters = ListFilters(),
        tagChips: [String] = [],
        statusCard: StatusCardKind? = nil,
        emptyState: LibraryEmptyState? = nil,
        uploadCard: UploadCardKind? = nil,
        avatarLetter: String = "?",
        swipeLeftAction: SwipeAction = .archive,
        swipeRightAction: SwipeAction = .none,
        peekEdge: SwipeEdge? = nil,
        extensionConnected: Bool = false
    ) {
        self.scope = scope
        self.items = items
        self.hasMore = hasMore
        self.isLoaded = isLoaded
        self.continueReading = continueReading
        self.sortOrder = sortOrder
        self.filters = filters
        self.tagChips = tagChips
        self.statusCard = statusCard
        self.emptyState = emptyState
        self.uploadCard = uploadCard
        self.avatarLetter = avatarLetter
        self.swipeLeftAction = swipeLeftAction
        self.swipeRightAction = swipeRightAction
        self.peekEdge = peekEdge
        self.extensionConnected = extensionConnected
    }

    /// Swipe action behind each edge. Swiping towards the left edge reveals the trailing actions
    /// and is the "swipe left" preference; the leading edge is "swipe right".
    public func action(for edge: SwipeEdge) -> SwipeAction {
        switch edge {
        case .leading: swipeRightAction
        case .trailing: swipeLeftAction
        }
    }
}

/// The toast on screen. `action` is the single button ("Undo", "Open").
public struct LibraryToast: Identifiable, Sendable {
    public enum Action: Sendable, Hashable {
        case undo(UndoAction)
        case open(itemId: String)

        var title: LocalizedStringResource {
            switch self {
            case .undo: LibraryStrings.undo
            case .open: LibraryStrings.open
            }
        }
    }

    public var id: Int
    public var message: LocalizedStringResource
    public var action: Action?

    public init(id: Int, message: LocalizedStringResource, action: Action? = nil) {
        self.id = id
        self.message = message
        self.action = action
    }
}

/// What Undo reverts.
public enum UndoAction: Sendable, Hashable {
    case status(id: String, previous: ItemStatus)
    case favorite(id: String, previous: Bool)
    /// Items created by a drop.
    case deleteSaved(ids: [String])
}
