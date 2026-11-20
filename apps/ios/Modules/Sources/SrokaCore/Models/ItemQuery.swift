/// What a library list shows. Every set filter narrows the list (AND):
/// - `tab`: My List (unread), Archive or Favorites (any status); nil = every live item (tag pages).
/// - `tag`: items carrying this tag (case-insensitive, by `tagKey`).
/// - `favoritesOnly`: favorite items only.
/// - `maxReadingMinutes`: items with a known reading time of at most this many minutes.
/// - `search`: local full-text search.
public struct ItemQuery: Sendable, Hashable {
    public var tab: LibraryTab?
    public var tag: String?
    public var search: String?
    public var sort: LibrarySortOrder
    public var favoritesOnly: Bool
    public var maxReadingMinutes: Int?

    public init(
        tab: LibraryTab?,
        tag: String? = nil,
        search: String? = nil,
        sort: LibrarySortOrder = .newest,
        favoritesOnly: Bool = false,
        maxReadingMinutes: Int? = nil
    ) {
        self.tab = tab
        self.tag = tag
        self.search = search
        self.sort = sort
        self.favoritesOnly = favoritesOnly
        self.maxReadingMinutes = maxReadingMinutes
    }
}

/// One observed window of a list: the first `limit` rows (keyset paging underneath).
/// The list grows `limit` by `Limits.listPageSize` as the user scrolls near the end.
public struct ItemPage: Sendable, Hashable {
    public var items: [ItemSummary]
    /// More rows exist beyond `items`.
    public var hasMore: Bool

    public init(items: [ItemSummary], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public static let empty = ItemPage(items: [], hasMore: false)
}

/// Tag name with the number of live items carrying it.
public struct TagCount: Sendable, Hashable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { tagKey(name) }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// Badge counts for the library tabs.
public struct LibraryCounts: Sendable, Hashable {
    public var unread: Int
    public var archived: Int
    public var favorites: Int

    public init(unread: Int = 0, archived: Int = 0, favorites: Int = 0) {
        self.unread = unread
        self.archived = archived
        self.favorites = favorites
    }
}
