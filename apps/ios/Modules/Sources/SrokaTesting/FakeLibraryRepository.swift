import Foundation
import SrokaCore
import Synchronization

/// In-memory `LibraryRepository`: filters, sorts and searches a list of `Item`s. Writes apply
/// immediately and mark the item `pendingChange` like the real outbox would.
public final class FakeLibraryRepository: LibraryRepository {
    /// The whole library; mutate it directly in tests to simulate a sync.
    public let items: FakeSubject<[Item]>
    private let now: @Sendable () -> Date
    private let nextId = Mutex(1)

    public init(items: [Item] = Fixtures.items, now: @escaping @Sendable () -> Date = { Fixtures.now }) {
        self.items = FakeSubject(items)
        self.now = now
    }

    public func item(id: String) -> Item? { items.value.first { $0.id == id } }

    // MARK: Reads

    public func observeItems(_ query: ItemQuery, limit: Int) -> AsyncStream<ItemPage> {
        items.stream { all in
            let rows = Self.filter(all, query).map(\.summary)
            return ItemPage(items: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        }
    }

    public func observeSearch(_ query: String, scope: SearchScope, limit: Int) -> AsyncStream<SearchPage> {
        items.stream { all in
            let hits = Self.search(all, query, scope)
            return SearchPage(results: Array(hits.prefix(limit)), hasMore: hits.count > limit)
        }
    }

    public func observeSearchCount(_ query: String, scope: SearchScope) -> AsyncStream<Int> {
        items.stream { Self.search($0, query, scope).count }
    }

    public func observeContinueReading(limit: Int) -> AsyncStream<[ItemSummary]> {
        items.stream { all in
            let rows =
                all
                .filter { $0.status == .unread && (0.05...0.95).contains($0.progress) }
                .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
            return Array(rows.prefix(limit)).map(\.summary)
        }
    }

    public func observeItem(id: String) -> AsyncStream<Item?> {
        items.stream { all in all.first { $0.id == id } }
    }

    public func observeNextUnread(excludeId: String?) -> AsyncStream<ItemSummary?> {
        items.stream { all in Self.newestUnread(all, excluding: excludeId).first?.summary }
    }

    public func observeNextReadable(excludeId: String?) -> AsyncStream<ItemSummary?> {
        items.stream { all in
            Self.newestUnread(all, excluding: excludeId)
                .first { $0.kind == .pdf || $0.parseStatus.isReadable }?.summary
        }
    }

    public func observeCounts() -> AsyncStream<LibraryCounts> {
        items.stream { all in
            LibraryCounts(
                unread: all.count { $0.status == .unread },
                archived: all.count { $0.status == .archived },
                favorites: all.count(where: \.isFavorite)
            )
        }
    }

    // MARK: Writes

    public func save(url: String, title: String?, tags: [String], source: SaveSource) async -> SaveResult {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UrlNormalizer.hostOf(trimmed) != nil else { return .invalidUrl }
        let date = now()
        if let existing = items.value.first(where: { $0.canonicalUrl == trimmed }) {
            mutate(existing.id) {
                $0.status = .unread
                $0.archivedAt = nil
                $0.savedAt = date
                $0.pendingChange = .save
            }
            return .saved(itemId: existing.id, alreadySaved: true)
        }
        let id = nextId.withLock { counter in
            defer { counter += 1 }
            return "fake-\(counter)"
        }
        let item = Item(
            id: id,
            url: trimmed,
            canonicalUrl: trimmed,
            title: Limits.clampTitle(title),
            parseStatus: .pending,
            savedAt: date,
            source: source == .manual ? .web : .share,
            tags: Self.normalizedTags(tags),
            pendingChange: .save
        )
        items.update { $0.insert(item, at: 0) }
        return .saved(itemId: id, alreadySaved: false)
    }

    public func setStatus(id: String, status: ItemStatus) async {
        let date = now()
        mutate(id) {
            $0.status = status
            $0.archivedAt = status == .archived ? date : nil
            $0.pendingChange = .other
        }
    }

    public func setFavorite(id: String, favorite: Bool) async {
        mutate(id) {
            $0.isFavorite = favorite
            $0.pendingChange = .favorite
        }
    }

    public func setProgress(id: String, progress: Double, anchor: Int?) async {
        let date = now()
        mutate(id) {
            $0.progress = min(max(progress, 0), 1)
            $0.progressAnchor = anchor
            $0.lastReadAt = date
        }
    }

    public func setTitle(id: String, title: String?) async {
        mutate(id) {
            $0.title = Limits.clampTitle(title)
            $0.pendingChange = .other
        }
    }

    public func setTags(id: String, names: [String]) async {
        mutate(id) {
            $0.tags = Self.normalizedTags(names)
            $0.pendingChange = .tags
        }
    }

    public func delete(id: String) async {
        items.update { $0.removeAll { $0.id == id } }
    }

    public func refresh(id: String) async {
        mutate(id) {
            $0.parseStatus = .pending
            $0.parseError = nil
            $0.pendingChange = .other
        }
    }

    // MARK: Helpers

    private func mutate(_ id: String, _ body: (inout Item) -> Void) {
        items.update { all in
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            body(&all[index])
        }
    }

    static func normalizedTags(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return
            names
            .map(normalizeTagName)
            .filter { !$0.isEmpty && $0.count <= Limits.maxTagLength && seen.insert(tagKey($0)).inserted }
            .prefix(Limits.maxTagsPerItem)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func newestUnread(_ all: [Item], excluding excludeId: String?) -> [Item] {
        all.filter { $0.status == .unread && $0.id != excludeId }.sorted { $0.savedAt > $1.savedAt }
    }

    static func filter(_ all: [Item], _ query: ItemQuery) -> [Item] {
        let tagKeyFilter = query.tag.map(tagKey)
        let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = all.filter { item in
            switch query.tab {
            case .myList: if item.status != .unread { return false }
            case .archive: if item.status != .archived { return false }
            case .favorites: if !item.isFavorite { return false }
            case nil: break
            }
            if let tagKeyFilter, !item.tags.contains(where: { tagKey($0) == tagKeyFilter }) { return false }
            if query.favoritesOnly, !item.isFavorite { return false }
            if let max = query.maxReadingMinutes {
                guard let minutes = item.readingMinutes, minutes <= max else { return false }
            }
            if let search, !search.isEmpty, !matches(item, search) { return false }
            return true
        }
        return filtered.sorted { lhs, rhs in
            switch query.sort {
            case .newest: return (lhs.savedAt, lhs.id) > (rhs.savedAt, rhs.id)
            case .oldest: return (lhs.savedAt, lhs.id) < (rhs.savedAt, rhs.id)
            case .shortest: return (lhs.readingMinutes ?? .max, lhs.id) < (rhs.readingMinutes ?? .max, rhs.id)
            case .longest: return (lhs.readingMinutes ?? -1, lhs.id) > (rhs.readingMinutes ?? -1, rhs.id)
            }
        }
    }

    private static func matches(_ item: Item, _ needle: String) -> Bool {
        [item.title, item.excerpt, item.siteName, item.tags.joined(separator: " ")]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(needle) }
    }

    static func search(_ all: [Item], _ query: String, _ scope: SearchScope) -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        return
            all
            .filter { item in
                switch scope {
                case .all: true
                case .archive: item.status == .archived
                case .favorites: item.isFavorite
                }
            }
            .sorted { $0.savedAt > $1.savedAt }
            .compactMap { item in
                let inTitle = item.displayTitle.lowercased().contains(needle)
                let body = item.excerpt ?? ""
                let range = body.lowercased().range(of: needle)
                guard inTitle || range != nil else { return nil }
                let matchIn: MatchIn = inTitle && range != nil ? .both : (inTitle ? .title : .text)
                var highlights: [Range<Int>] = []
                if let range {
                    let start = body.utf16.distance(from: body.startIndex, to: range.lowerBound)
                    highlights = [start..<(start + needle.utf16.count)]
                }
                return SearchResult(
                    summary: item.summary,
                    matchIn: matchIn,
                    snippet: range == nil ? nil : body,
                    highlights: highlights
                )
            }
    }
}
