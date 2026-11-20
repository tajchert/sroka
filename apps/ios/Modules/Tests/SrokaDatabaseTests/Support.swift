import GRDB
import SrokaCore

@testable import SrokaDatabase

/// A fresh migrated in-memory database.
func makeDatabase() throws -> AppDatabase {
    try AppDatabase.inMemory()
}

/// An item row with test defaults.
func item(
    _ id: String,
    title: String? = nil,
    excerpt: String? = nil,
    siteName: String? = nil,
    status: ItemStatus = .unread,
    favorite: Bool = false,
    savedAt: Int64 = 1_000,
    archivedAt: Int64? = nil,
    lastReadAt: Int64? = nil,
    words: Int? = nil,
    minutes: Int? = nil,
    progress: Double = 0,
    contentId: String? = nil,
    leadImageKey: String? = nil,
    parseStatus: ParseStatus = .ok,
    kind: ItemKind = .article
) -> ItemRecord {
    ItemRecord(
        id: id,
        url: "https://example.com/\(id)",
        canonicalUrl: "https://example.com/\(id)",
        title: title,
        excerpt: excerpt,
        siteName: siteName,
        leadImageKey: leadImageKey,
        wordCount: words,
        readingMinutes: minutes,
        contentId: contentId,
        parseStatus: parseStatus,
        status: status,
        isFavorite: favorite,
        progress: progress,
        savedAt: savedAt,
        archivedAt: archivedAt,
        lastReadAt: lastReadAt,
        kind: kind
    )
}

func op(_ opId: String, item itemId: String?, type: String, payload: String = "{}") -> PendingOpRecord {
    PendingOpRecord(opId: opId, itemId: itemId, type: type, payload: payload, createdAt: 1)
}

extension AppDatabase {
    /// Synchronous write for tests.
    @discardableResult
    func run<T>(_ updates: (Database) throws -> T) throws -> T {
        try writer.write(updates)
    }

    /// Ids of the list rows for `query`.
    func ids(_ query: ItemQuery, limit: Int = 100) throws -> [String] {
        try writer.read { db in try ItemDao.page(db, query: query, limit: limit).items.map(\.id) }
    }

    func searchIds(_ text: String, scope: SearchScope = .all) throws -> [String] {
        try writer.read { db in try SearchDao.page(db, query: text, scope: scope, limit: 100).results.map(\.id) }
    }
}
