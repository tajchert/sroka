import GRDB
import SrokaCore

/// Items, their tags and the FTS index (Android `dao/ItemDao.kt`). Every function takes a GRDB
/// `Database`, so callers combine several in one transaction (`writer.write { db in … }`), e.g. an
/// item change plus a `PendingOpDao.enqueue` (A7). Every function that changes an item or its tags
/// keeps `items_fts` in step. Callers must run writes inside a write transaction.
public enum ItemDao {
    // MARK: Lists

    /// The first `limit` rows of the library list for `query` (tab, tag, favorites and reading-time
    /// filters AND-combined, optional FTS search, sort), and whether more rows exist.
    public static func page(_ db: Database, query: ItemQuery, limit: Int) throws -> ItemPage {
        let rows = try summaryRows(db, query: query, limit: limit + 1)
        return ItemPage(items: rows.prefix(limit).map { $0.toSummary() }, hasMore: rows.count > limit)
    }

    /// The raw rows of the library list for `query`, at most `limit` (negative = no limit).
    public static func summaryRows(_ db: Database, query: ItemQuery, limit: Int) throws -> [ItemSummaryRow] {
        if let search = query.search, FtsQuery.build(search) == nil { return [] }
        let built = ItemSQL.list(query)
        return try ItemSummaryRow.fetchAll(db, sql: built.sql + " LIMIT \(limit)", arguments: built.arguments)
    }

    /// "Continue reading": unread items read between 5 % and 95 %, most recently read first.
    public static func continueReading(_ db: Database, limit: Int) throws -> [ItemSummaryRow] {
        try ItemSummaryRow.fetchAll(
            db,
            sql: """
                \(ItemSQL.rowColumns) \(ItemSQL.listFrom) WHERE i.status = 'UNREAD'
                AND i.progress >= \(ItemSQL.continueFrom) AND i.progress <= \(ItemSQL.continueTo)
                ORDER BY i.last_read_at DESC, i.id DESC LIMIT ?
                """,
            arguments: [limit]
        )
    }

    /// The newest unread row whose id is not `excludeId` (nil excludes nothing).
    public static func nextUnread(_ db: Database, excludeId: String?) throws -> ItemSummaryRow? {
        try ItemSummaryRow.fetchOne(
            db,
            sql: """
                \(ItemSQL.rowColumns) \(ItemSQL.listFrom) WHERE i.status = 'UNREAD'
                AND (? IS NULL OR i.id != ?) \(ItemSQL.orderNewest) LIMIT 1
                """,
            arguments: [excludeId, excludeId]
        )
    }

    /// Like `nextUnread`, limited to rows that open as readable: a PDF, or an article whose parse
    /// status is OK or PARTIAL (the reader's "Up next").
    public static func nextReadable(_ db: Database, excludeId: String?) throws -> ItemSummaryRow? {
        try ItemSummaryRow.fetchOne(
            db,
            sql: """
                \(ItemSQL.rowColumns) \(ItemSQL.listFrom) WHERE i.status = 'UNREAD'
                AND (? IS NULL OR i.id != ?) AND (i.kind = 'PDF' OR i.parse_status IN ('OK', 'PARTIAL'))
                \(ItemSQL.orderNewest) LIMIT 1
                """,
            arguments: [excludeId, excludeId]
        )
    }

    // MARK: Single items and counts

    public static func detail(_ db: Database, id: String) throws -> ItemDetailRow? {
        try ItemDetailRow.fetchOne(db, sql: "\(ItemSQL.detailSelect) WHERE i.id = ?", arguments: [id])
    }

    public static func item(_ db: Database, id: String) throws -> ItemRecord? {
        try ItemRecord.fetchOne(db, key: id)
    }

    /// A live item with this canonical URL (re-adding a saved URL, A7).
    public static func item(_ db: Database, canonicalUrl: String) throws -> ItemRecord? {
        try ItemRecord.fetchOne(
            db, sql: "SELECT * FROM items WHERE canonical_url = ? LIMIT 1", arguments: [canonicalUrl])
    }

    public static func counts(_ db: Database) throws -> LibraryCounts {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(CASE WHEN status = 'UNREAD' THEN 1 ELSE 0 END), 0) AS unread,
                  COALESCE(SUM(CASE WHEN status = 'ARCHIVED' THEN 1 ELSE 0 END), 0) AS archived,
                  COALESCE(SUM(is_favorite), 0) AS favorites FROM items
                """
        )
        guard let row else { return LibraryCounts() }
        return LibraryCounts(unread: row["unread"], archived: row["archived"], favorites: row["favorites"])
    }

    /// Tag names of `itemId` as stored, sorted by key.
    public static func tagNames(_ db: Database, itemId: String) throws -> [String] {
        try String.fetchAll(
            db, sql: "SELECT name FROM item_tags WHERE item_id = ? ORDER BY name_key", arguments: [itemId])
    }

    public static func itemIds(_ db: Database, withTagKey nameKey: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT item_id FROM item_tags WHERE name_key = ?", arguments: [nameKey])
    }

    /// The subset of `ids` that exist locally.
    public static func existingIds(_ db: Database, _ ids: [String]) throws -> [String] {
        try chunked(ids).flatMap { chunk in
            try String.fetchAll(
                db, sql: "SELECT id FROM items WHERE id IN (\(placeholders(chunk.count)))",
                arguments: StatementArguments(chunk))
        }
    }

    // MARK: Writes

    /// Inserts or updates `item`, preserving its `fts_rowid` and its child rows (tags, content
    /// file), and refreshes its FTS metadata (a downloaded body is kept). `item.ftsRowId` is ignored.
    public static func upsert(_ db: Database, _ item: ItemRecord) throws {
        let old = try self.item(db, id: item.id)
        var row = item
        row.ftsRowId = try old?.ftsRowId ?? nextFtsRowId(db)
        try row.upsert(db)
        if old == nil || old!.indexedFieldsDiffer(from: item) { try refreshFts(db, itemId: item.id) }
    }

    /// `upsert` plus a full replacement of the item's tags, with one FTS write.
    public static func upsert(_ db: Database, _ item: ItemRecord, tags: [String]) throws {
        let old = try self.item(db, id: item.id)
        var row = item
        row.ftsRowId = try old?.ftsRowId ?? nextFtsRowId(db)
        try row.upsert(db)
        let wanted = cleanTagRows(itemId: item.id, names: tags)
        let current = try tagNames(db, itemId: item.id)
        let tagsChanged = old == nil || wanted.sorted { $0.nameKey < $1.nameKey }.map(\.name) != current
        if tagsChanged {
            try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ?", arguments: [item.id])
            for tag in wanted { try tag.insert(db, onConflict: .ignore) }
        }
        if old == nil || tagsChanged || old!.indexedFieldsDiffer(from: item) {
            try refreshFts(db, itemId: item.id)
        }
    }

    /// Replaces the tags of `itemId`: names are trimmed, normalized and de-duplicated by key (first
    /// spelling wins). No-op for an unknown item.
    public static func replaceTags(_ db: Database, itemId: String, names: [String]) throws {
        guard try item(db, id: itemId) != nil else { return }
        try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ?", arguments: [itemId])
        for tag in cleanTagRows(itemId: itemId, names: names) { try tag.insert(db, onConflict: .ignore) }
        try refreshFts(db, itemId: itemId)
    }

    /// Deletes the item (its tags and content file row cascade) and its FTS row.
    public static func delete(_ db: Database, id: String) throws {
        if let rowId = try ftsRowId(db, itemId: id) {
            try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [rowId])
        }
        try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
    }

    public static func delete(_ db: Database, ids: [String]) throws {
        for id in ids { try delete(db, id: id) }
    }

    /// Re-keys item `fromId` to `toId` (server alias, or a fresh id after a tombstone rejection).
    /// The row keeps its FTS rowid; its tags follow through `ON UPDATE CASCADE`; its content file row
    /// is dropped (the new id has no package yet). Returns false (and changes nothing) when `fromId`
    /// does not exist or `toId` already does. Queued ops are not touched: see
    /// `PendingOpDao.retargetItem`.
    @discardableResult
    public static func rekey(_ db: Database, from fromId: String, to toId: String) throws -> Bool {
        guard try item(db, id: fromId) != nil, try item(db, id: toId) == nil else { return false }
        try db.execute(sql: "DELETE FROM content_files WHERE item_id = ?", arguments: [fromId])
        try db.execute(sql: "UPDATE items SET id = ? WHERE id = ?", arguments: [toId, fromId])
        return true
    }

    public static func setTitle(_ db: Database, id: String, title: String?) throws {
        try db.execute(sql: "UPDATE items SET title = ? WHERE id = ?", arguments: [title, id])
        try refreshFts(db, itemId: id)
    }

    /// Sets the searchable plain-text article body (empty clears it); called when a package is installed.
    public static func setFtsBody(_ db: Database, itemId: String, body: String) throws {
        guard let rowId = try ftsRowId(db, itemId: itemId) else { return }
        if try ftsBody(db, rowId: rowId) == nil { try refreshFts(db, itemId: itemId) }
        try db.execute(sql: "UPDATE items_fts SET body = ? WHERE rowid = ?", arguments: [body, rowId])
    }

    /// Renames the tag with key `fromKey` to `toName` on every item (merging with an existing tag of
    /// the same key) and drops the server tag row of `fromKey`.
    public static func renameTag(_ db: Database, fromKey: String, toName: String) throws {
        for id in try itemIds(db, withTagKey: fromKey) {
            let names = try tagNames(db, itemId: id).filter { tagKey($0) != fromKey } + [toName]
            try replaceTags(db, itemId: id, names: names)
        }
        try TagDao.deleteRow(db, nameKey: fromKey)
    }

    /// Removes the tag with key `nameKey` from every item and drops its server tag row.
    public static func deleteTag(_ db: Database, nameKey: String) throws {
        for id in try itemIds(db, withTagKey: nameKey) {
            try replaceTags(db, itemId: id, names: try tagNames(db, itemId: id).filter { tagKey($0) != nameKey })
        }
        try TagDao.deleteRow(db, nameKey: nameKey)
    }

    public static func setStatus(_ db: Database, id: String, status: ItemStatus, archivedAt: Int64?) throws {
        try db.execute(
            sql: "UPDATE items SET status = ?, archived_at = ? WHERE id = ?",
            arguments: [DbEnum.literal(status), archivedAt, id]
        )
    }

    public static func setFavorite(_ db: Database, id: String, favorite: Bool) throws {
        try db.execute(sql: "UPDATE items SET is_favorite = ? WHERE id = ?", arguments: [favorite, id])
    }

    public static func setProgress(_ db: Database, id: String, progress: Double, anchor: Int?, readAt: Int64) throws {
        try db.execute(
            sql: "UPDATE items SET progress = ?, progress_anchor = ?, last_read_at = ? WHERE id = ?",
            arguments: [progress, anchor, readAt, id]
        )
    }

    /// Sets the parse status and clears the parse error (local `item.refresh`).
    public static func setParseStatus(_ db: Database, id: String, parseStatus: ParseStatus) throws {
        try db.execute(
            sql: "UPDATE items SET parse_status = ?, parse_error = NULL WHERE id = ?",
            arguments: [DbEnum.literal(parseStatus), id]
        )
    }

    // MARK: Resync (A8.3)

    public static func markAllForResync(_ db: Database) throws {
        try db.execute(sql: "UPDATE items SET resync_mark = 1")
    }

    /// Deletes items still marked after a full pull that have no pending ops; returns their ids so
    /// the caller can remove their files.
    public static func deleteStaleMarked(_ db: Database) throws -> [String] {
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM items WHERE resync_mark = 1
                AND NOT EXISTS (SELECT 1 FROM pending_ops p WHERE p.item_id = items.id)
                """
        )
        try delete(db, ids: ids)
        return ids
    }

    public static func clearResyncMarks(_ db: Database) throws {
        try db.execute(sql: "UPDATE items SET resync_mark = 0")
    }

    // MARK: FTS internals

    static func ftsRowId(_ db: Database, itemId: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT fts_rowid FROM items WHERE id = ?", arguments: [itemId])
    }

    static func nextFtsRowId(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(fts_rowid), 0) + 1 FROM items") ?? 1
    }

    static func ftsBody(_ db: Database, rowId: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT body FROM items_fts WHERE rowid = ?", arguments: [rowId])
    }

    /// Rewrites the item's FTS row from the item and its tags, keeping a stored body. Leaves the row
    /// alone when nothing indexed changed (re-tokenizing a long body is expensive).
    static func refreshFts(_ db: Database, itemId: String) throws {
        guard let item = try item(db, id: itemId) else { return }
        let title = item.title ?? ""
        let excerpt = item.excerpt ?? ""
        let siteName = item.siteName ?? ""
        let tags = try tagNames(db, itemId: itemId).joined(separator: " ")
        let current = try Row.fetchOne(
            db,
            sql: "SELECT title, excerpt, site_name, tags, body FROM items_fts WHERE rowid = ?",
            arguments: [item.ftsRowId]
        )
        if let current, current["title"] == title, current["excerpt"] == excerpt,
            current["site_name"] == siteName, current["tags"] == tags
        {
            return
        }
        let body: String = current?["body"] ?? ""
        try db.execute(sql: "DELETE FROM items_fts WHERE rowid = ?", arguments: [item.ftsRowId])
        try db.execute(
            sql: "INSERT INTO items_fts(rowid, title, excerpt, site_name, tags, body) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [item.ftsRowId, title, excerpt, siteName, tags, body]
        )
    }

    /// Tag rows for `names` as stored: trimmed, normalized, de-duplicated by key (first wins).
    static func cleanTagRows(itemId: String, names: [String]) -> [ItemTagRecord] {
        var seen = Set<String>()
        var rows: [ItemTagRecord] = []
        for name in names {
            let normalized = normalizeTagName(name)
            guard !normalized.isEmpty else { continue }
            let key = tagKey(normalized)
            guard seen.insert(key).inserted else { continue }
            rows.append(ItemTagRecord(itemId: itemId, nameKey: key, name: normalized))
        }
        return rows
    }
}

extension ItemRecord {
    fileprivate func indexedFieldsDiffer(from other: ItemRecord) -> Bool {
        title != other.title || excerpt != other.excerpt || siteName != other.siteName
    }
}

/// Max bound variables per chunked `IN (…)` statement.
let sqlChunk = 500

func chunked<T>(_ values: [T]) -> [ArraySlice<T>] {
    stride(from: 0, to: values.count, by: sqlChunk).map { values[$0..<min($0 + sqlChunk, values.count)] }
}

func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
