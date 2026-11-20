import Dependencies

/// The user's library, local-first (DECISIONS A7). Reads come from the database only; every write
/// updates the local rows and queues a sync op in one transaction, then requests a debounced sync.
/// No method waits for the network, so everything works offline. Writes to an unknown/deleted item id
/// are no-ops. Android: core/domain/LibraryRepository.kt.
public protocol LibraryRepository: Sendable {
    /// The first `limit` list rows for `query` (tab or tag filter, optional FTS search, sort).
    /// Replaces Android's paging: the list grows `limit` by `Limits.listPageSize` near the end.
    func observeItems(_ query: ItemQuery, limit: Int) -> AsyncStream<ItemPage>

    /// Full-text search (local FTS only) over `scope`, newest first, first `limit` hits. Blank /
    /// symbol-only `query` yields an empty page. Hits carry a body snippet with match ranges (R8).
    func observeSearch(_ query: String, scope: SearchScope, limit: Int) -> AsyncStream<SearchPage>

    /// Total number of hits `observeSearch` would return (0 for a blank / symbol-only query).
    func observeSearchCount(_ query: String, scope: SearchScope) -> AsyncStream<Int>

    /// "Continue reading": unread items read between 5 % and 95 %, most recently read first.
    func observeContinueReading(limit: Int) -> AsyncStream<[ItemSummary]>

    /// One item with full detail, or nil once it no longer exists locally.
    func observeItem(id: String) -> AsyncStream<Item?>

    /// The newest unread item whose id is not `excludeId` (nil excludes nothing).
    func observeNextUnread(excludeId: String?) -> AsyncStream<ItemSummary?>

    /// The newest unread item other than `excludeId` that opens as readable (a PDF, or an article
    /// whose parse status is ok or partial).
    func observeNextReadable(excludeId: String?) -> AsyncStream<ItemSummary?>

    /// Counts for tab badges / empty states.
    func observeCounts() -> AsyncStream<LibraryCounts>

    /// Saves `url` (extract a URL from free text first with `UrlNormalizer.extractFirstUrl`).
    /// Re-adds an existing item with the same canonical URL instead of duplicating.
    func save(url: String, title: String?, tags: [String], source: SaveSource) async -> SaveResult

    /// Archive (`.archived`) or move back to My List (`.unread`).
    func setStatus(id: String, status: ItemStatus) async

    func setFavorite(id: String, favorite: Bool) async

    /// Reading position: `progress` 0...1 and the block-element `anchor` (A10). Coalesced.
    func setProgress(id: String, progress: Double, anchor: Int?) async

    /// User title; nil or blank clears it (the server falls back to the parsed title).
    func setTitle(id: String, title: String?) async

    /// Replaces the item's tags with `names` (normalized, deduplicated by `tagKey`).
    func setTags(id: String, names: [String]) async

    /// Deletes the item and its downloaded files.
    func delete(id: String) async

    /// Asks the server to parse the article again (parse status becomes pending locally).
    func refresh(id: String) async
}

extension LibraryRepository {
    public func observeContinueReading() -> AsyncStream<[ItemSummary]> {
        observeContinueReading(limit: Limits.continueReadingLimit)
    }

    public func observeNextUnread() -> AsyncStream<ItemSummary?> { observeNextUnread(excludeId: nil) }

    public func save(url: String, source: SaveSource) async -> SaveResult {
        await save(url: url, title: nil, tags: [], source: source)
    }
}

/// Where a save came from; `wire` is the wire `source` (api.md §4.1).
public enum SaveSource: String, Sendable, Hashable, CaseIterable {
    /// iOS share sheet (Share Extension).
    case share
    /// Typed or pasted in the app's "Add link" sheet.
    case manual
    /// Links dropped onto the list (R15.1); sent to the server as a share.
    case drag

    public var wire: String {
        switch self {
        case .share, .drag: "share"
        case .manual: "web"
        }
    }
}

private struct UnimplementedLibraryRepository: LibraryRepository {
    private func fail(_ method: String) { reportUnimplemented("LibraryRepository.\(method)", key: "libraryRepository") }

    func observeItems(_ query: ItemQuery, limit: Int) -> AsyncStream<ItemPage> {
        fail("observeItems")
        return .finished
    }
    func observeSearch(_ query: String, scope: SearchScope, limit: Int) -> AsyncStream<SearchPage> {
        fail("observeSearch")
        return .finished
    }
    func observeSearchCount(_ query: String, scope: SearchScope) -> AsyncStream<Int> {
        fail("observeSearchCount")
        return .finished
    }
    func observeContinueReading(limit: Int) -> AsyncStream<[ItemSummary]> {
        fail("observeContinueReading")
        return .finished
    }
    func observeItem(id: String) -> AsyncStream<Item?> {
        fail("observeItem")
        return .finished
    }
    func observeNextUnread(excludeId: String?) -> AsyncStream<ItemSummary?> {
        fail("observeNextUnread")
        return .finished
    }
    func observeNextReadable(excludeId: String?) -> AsyncStream<ItemSummary?> {
        fail("observeNextReadable")
        return .finished
    }
    func observeCounts() -> AsyncStream<LibraryCounts> {
        fail("observeCounts")
        return .finished
    }
    func save(url: String, title: String?, tags: [String], source: SaveSource) async -> SaveResult {
        fail("save")
        return .invalidUrl
    }
    func setStatus(id: String, status: ItemStatus) async { fail("setStatus") }
    func setFavorite(id: String, favorite: Bool) async { fail("setFavorite") }
    func setProgress(id: String, progress: Double, anchor: Int?) async { fail("setProgress") }
    func setTitle(id: String, title: String?) async { fail("setTitle") }
    func setTags(id: String, names: [String]) async { fail("setTags") }
    func delete(id: String) async { fail("delete") }
    func refresh(id: String) async { fail("refresh") }
}

private enum LibraryRepositoryKey: TestDependencyKey {
    static let testValue: any LibraryRepository = UnimplementedLibraryRepository()
}

extension DependencyValues {
    /// No static live value: the composition roots install the live repository (stream G).
    public var libraryRepository: any LibraryRepository {
        get { self[LibraryRepositoryKey.self] }
        set { self[LibraryRepositoryKey.self] = newValue }
    }
}
