import GRDB

/// The outbox of un-pushed changes (A7; Android `dao/PendingOpDao.kt`).
public enum PendingOpDao {
    /// Wire op types whose older un-sent ops of the same item are superseded on enqueue.
    public static let coalescingTypes: Set<String> = [
        "item.setProgress", "item.setStatus", "item.setFavorite", "item.setTitle",
    ]

    /// Appends `op`. For `coalescingTypes` it first deletes older queued ops with the same item and
    /// type; other types (add, tag, delete, refresh, tag-level ops) never coalesce. An op whose
    /// `op_id` is already queued is ignored. Returns the new `local_seq`, or nil when ignored.
    @discardableResult
    public static func enqueue(_ db: Database, _ op: PendingOpRecord) throws -> Int64? {
        // A retry of an already queued op must not coalesce it away (or any sibling) first.
        let queued = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM pending_ops WHERE op_id = ?)", arguments: [op.opId])
        if queued == true { return nil }
        if let itemId = op.itemId, coalescingTypes.contains(op.type) {
            try db.execute(sql: "DELETE FROM pending_ops WHERE item_id = ? AND type = ?", arguments: [itemId, op.type])
        }
        var row = op
        row.localSeq = nil
        try row.insert(db, onConflict: .ignore)
        return db.changesCount > 0 ? db.lastInsertedRowID : nil
    }

    /// Oldest-first batch for push.
    public static func batch(_ db: Database, limit: Int) throws -> [PendingOpRecord] {
        try PendingOpRecord.fetchAll(
            db, sql: "SELECT * FROM pending_ops ORDER BY local_seq LIMIT ?", arguments: [limit])
    }

    /// Every queued op, in `local_seq` order.
    public static func all(_ db: Database) throws -> [PendingOpRecord] {
        try batch(db, limit: -1)
    }

    /// Queued ops of `itemIds`, in `local_seq` order.
    public static func forItems(_ db: Database, _ itemIds: [String]) throws -> [PendingOpRecord] {
        try chunked(itemIds).flatMap { chunk in
            try PendingOpRecord.fetchAll(
                db,
                sql: "SELECT * FROM pending_ops WHERE item_id IN (\(placeholders(chunk.count))) ORDER BY local_seq",
                arguments: StatementArguments(chunk)
            )
        }
        .sorted { ($0.localSeq ?? 0) < ($1.localSeq ?? 0) }
    }

    /// Ops of `itemIds` plus every tag-level op (`item_id IS NULL`), in `local_seq` order.
    public static func forItemsOrGlobal(_ db: Database, _ itemIds: [String]) throws -> [PendingOpRecord] {
        try (forItems(db, itemIds) + globalOps(db)).sorted { ($0.localSeq ?? 0) < ($1.localSeq ?? 0) }
    }

    /// Tag-level ops (`tag.rename`, `tag.delete`), in `local_seq` order.
    public static func globalOps(_ db: Database) throws -> [PendingOpRecord] {
        try PendingOpRecord.fetchAll(db, sql: "SELECT * FROM pending_ops WHERE item_id IS NULL ORDER BY local_seq")
    }

    public static func forItem(_ db: Database, _ itemId: String) throws -> [PendingOpRecord] {
        try PendingOpRecord.fetchAll(
            db,
            sql: "SELECT * FROM pending_ops WHERE item_id = ? ORDER BY local_seq",
            arguments: [itemId]
        )
    }

    public static func delete(_ db: Database, opIds: [String]) throws {
        for chunk in chunked(opIds) {
            try db.execute(
                sql: "DELETE FROM pending_ops WHERE op_id IN (\(placeholders(chunk.count)))",
                arguments: StatementArguments(chunk)
            )
        }
    }

    public static func deleteForItem(_ db: Database, _ itemId: String) throws {
        try db.execute(sql: "DELETE FROM pending_ops WHERE item_id = ?", arguments: [itemId])
    }

    /// Counts one more attempt on each op and records `error` (e.g. `http_500`).
    public static func markAttempted(_ db: Database, opIds: [String], error: String?) throws {
        for chunk in chunked(opIds) {
            try db.execute(
                sql: """
                    UPDATE pending_ops SET attempts = attempts + 1, last_error = ?
                    WHERE op_id IN (\(placeholders(chunk.count)))
                    """,
                arguments: StatementArguments([error]) + StatementArguments(chunk)
            )
        }
    }

    public static func count(_ db: Database) throws -> Int {
        try PendingOpRecord.fetchCount(db)
    }

    /// Points every queued op of `fromId` at `toId` (alias or re-key, A8.1). The payload is rewritten
    /// by `rewritePayload`, which must re-encode the op canonically (never string replacement).
    public static func retargetItem(
        _ db: Database,
        from fromId: String,
        to toId: String,
        rewritePayload: (PendingOpRecord) throws -> String
    ) throws {
        for var op in try forItem(db, fromId) {
            op.payload = try rewritePayload(op)
            op.itemId = toId
            try op.update(db)
        }
    }

    /// Gives a queued op a new id (the server already acknowledged the old one) and its re-encoded payload.
    public static func replaceOpId(_ db: Database, from oldId: String, to newId: String, payload: String) throws {
        try db.execute(
            sql: "UPDATE pending_ops SET op_id = ?, payload = ? WHERE op_id = ?",
            arguments: [newId, payload, oldId]
        )
    }

    public static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_ops")
    }
}

/// The single `sync_state` row (Android `dao/SyncStateDao.kt`).
public enum SyncStateDao {
    /// The stored state, or the defaults when no row exists.
    public static func get(_ db: Database) throws -> SyncStateRecord {
        try SyncStateRecord.fetchOne(db, key: 1) ?? SyncStateRecord()
    }

    public static func set(_ db: Database, _ state: SyncStateRecord) throws {
        var row = state
        row.id = 1
        try row.upsert(db)
    }

    /// Read-modify-write of the row.
    public static func update(_ db: Database, _ transform: (inout SyncStateRecord) -> Void) throws {
        var state = try get(db)
        transform(&state)
        try set(db, state)
    }

    public static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM sync_state")
    }
}
