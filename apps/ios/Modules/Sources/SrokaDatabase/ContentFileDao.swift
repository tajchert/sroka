import GRDB

/// Downloaded-package bookkeeping and download selection (A9; Android `dao/ContentFileDao.kt`).
public enum ContentFileDao {
    /// Download attempts after which a FAILED row is no longer eligible.
    public static let maxAttempts = 5
    /// Thumbnail fetch attempts after which a missing thumbnail is no longer retried.
    public static let maxThumbAttempts = 3

    /// Rows eligible for download: live items with content, unread or favorite, whose row is
    /// missing, stale (another content id), QUEUED, or FAILED with fewer than `maxAttempts`
    /// attempts. DOWNLOADING rows are excluded (see `resetDownloading`).
    static let eligibleWhere = """
        FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
        WHERE i.content_id IS NOT NULL AND (i.status = 'UNREAD' OR i.is_favorite = 1)
          AND (cf.item_id IS NULL OR cf.content_id != i.content_id OR cf.state = 'QUEUED'
               OR (cf.state = 'FAILED' AND cf.attempts < ?))
        """

    public static func upsert(_ db: Database, _ file: ContentFileRecord) throws {
        try file.upsert(db)
    }

    public static func get(_ db: Database, itemId: String) throws -> ContentFileRecord? {
        try ContentFileRecord.fetchOne(db, key: itemId)
    }

    public static func all(_ db: Database) throws -> [ContentFileRecord] {
        try ContentFileRecord.fetchAll(db)
    }

    public static func delete(_ db: Database, itemId: String) throws {
        try db.execute(sql: "DELETE FROM content_files WHERE item_id = ?", arguments: [itemId])
    }

    public static func delete(_ db: Database, itemIds: [String]) throws {
        for chunk in chunked(itemIds) {
            try db.execute(
                sql: "DELETE FROM content_files WHERE item_id IN (\(placeholders(chunk.count)))",
                arguments: StatementArguments(chunk)
            )
        }
    }

    public static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM content_files")
    }

    /// Items to download, newest saved first, at most `limit` (negative = all).
    public static func eligibleForDownload(
        _ db: Database,
        maxAttempts: Int = maxAttempts,
        limit: Int = -1
    ) throws -> [EligibleDownloadRow] {
        try EligibleDownloadRow.fetchAll(
            db,
            sql: """
                SELECT i.id AS item_id, i.content_id AS content_id \(eligibleWhere)
                ORDER BY i.saved_at DESC, i.id DESC LIMIT ?
                """,
            arguments: [maxAttempts, limit]
        )
    }

    public static func eligibleCount(_ db: Database, maxAttempts: Int = maxAttempts) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) \(eligibleWhere)", arguments: [maxAttempts]) ?? 0
    }

    /// Current packages that still lack their thumbnail (a DOWNLOADED row is otherwise never
    /// retried), capped by `thumb_attempts`.
    public static func thumbsToRetry(_ db: Database, maxAttempts: Int = maxThumbAttempts) throws
        -> [EligibleDownloadRow]
    {
        try EligibleDownloadRow.fetchAll(
            db,
            sql: """
                SELECT i.id AS item_id, i.content_id AS content_id
                FROM items i JOIN content_files cf ON cf.item_id = i.id
                WHERE cf.state = 'DOWNLOADED' AND cf.content_id = i.content_id AND cf.thumb_path IS NULL
                  AND i.lead_image_key IS NOT NULL AND cf.thumb_attempts < ?
                ORDER BY i.saved_at DESC, i.id DESC
                """,
            arguments: [maxAttempts]
        )
    }

    /// Items with a current (not stale) downloaded package.
    public static func downloadedCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM content_files cf JOIN items i ON i.id = cf.item_id
                WHERE cf.state = 'DOWNLOADED' AND cf.content_id = i.content_id
                """
        ) ?? 0
    }

    /// Item ids of every DOWNLOADED row (launch recovery checks their files exist).
    public static func downloadedItemIds(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT item_id FROM content_files WHERE state = 'DOWNLOADED'")
    }

    /// Launch recovery: a process that died leaves DOWNLOADING rows; queue them again (once per launch).
    public static func resetDownloading(_ db: Database) throws {
        try db.execute(sql: "UPDATE content_files SET state = 'QUEUED' WHERE state = 'DOWNLOADING'")
    }

    /// Marks the row of `itemId` downloaded, only if the item still exists with `contentId` and its
    /// row is still DOWNLOADING for that version (a "Remove downloaded articles" or item delete in
    /// the meantime removed the row). Returns whether the row was committed.
    @discardableResult
    public static func commitDownloaded(
        _ db: Database,
        itemId: String,
        contentId: String,
        bytes: Int64,
        downloadedAt: Int64
    ) throws -> Bool {
        try db.execute(
            sql: """
                UPDATE content_files SET state = 'DOWNLOADED', bytes = ?, downloaded_at = ?, error = NULL
                WHERE item_id = ? AND content_id = ? AND state = 'DOWNLOADING'
                  AND EXISTS (SELECT 1 FROM items i WHERE i.id = content_files.item_id AND i.content_id = ?)
                """,
            arguments: [bytes, downloadedAt, itemId, contentId, contentId]
        )
        return db.changesCount > 0
    }

    public static func totalBytes(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM content_files WHERE state = 'DOWNLOADED'") ?? 0
    }

    public static func thumbPaths(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT thumb_path FROM content_files WHERE thumb_path IS NOT NULL")
    }

    /// Downloaded packages of archived, non-favorite items archived before `archivedBefore` that
    /// were neither downloaded nor read since then (A9 eviction). Without the last two checks,
    /// opening an old archived article would download it and the next sync would delete it again.
    public static func evictionCandidates(_ db: Database, archivedBefore: Int64, limit: Int = 500) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT cf.item_id FROM content_files cf JOIN items i ON i.id = cf.item_id
                WHERE cf.state = 'DOWNLOADED' AND i.status = 'ARCHIVED' AND i.is_favorite = 0
                  AND i.archived_at IS NOT NULL AND i.archived_at < ?
                  AND (cf.downloaded_at IS NULL OR cf.downloaded_at < ?)
                  AND (i.last_read_at IS NULL OR i.last_read_at < ?)
                LIMIT ?
                """,
            arguments: [archivedBefore, archivedBefore, archivedBefore, limit]
        )
    }
}

/// Whole-database maintenance (Android `dao/MaintenanceDao.kt`).
public enum MaintenanceDao {
    /// Sign-out: removes every row of every table, including the FTS index. Keeps the schema.
    public static func wipeAll(_ db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM items_fts;
                DELETE FROM content_files;
                DELETE FROM item_tags;
                DELETE FROM tags;
                DELETE FROM items;
                DELETE FROM pending_ops;
                DELETE FROM sync_state;
                """
        )
    }
}
