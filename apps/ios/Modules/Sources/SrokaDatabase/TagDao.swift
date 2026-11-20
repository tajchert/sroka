import GRDB
import SrokaCore

/// Tag reads and the server `tags` mirror. Tag changes on items go through `ItemDao` (`replaceTags`,
/// `renameTag`, `deleteTag`) so the FTS row follows.
public enum TagDao {
    /// Tag names (display form) with live-item counts, including server tags with no items, sorted by key.
    public static func counts(_ db: Database) throws -> [TagCount] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT name, cnt FROM (
                  SELECT MIN(name) AS name, name_key, COUNT(*) AS cnt FROM item_tags GROUP BY name_key
                  UNION ALL
                  SELECT t.name, t.name_key, 0 FROM tags t
                    WHERE NOT EXISTS (SELECT 1 FROM item_tags it WHERE it.name_key = t.name_key)
                ) ORDER BY name_key
                """
        ).map { TagCount(name: $0["name"], count: $0["cnt"]) }
    }

    /// Most recently used tag names (by the newest of the 500 newest items carrying them).
    public static func recent(_ db: Database, limit: Int) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                WITH recent AS (SELECT id, saved_at FROM items ORDER BY saved_at DESC LIMIT 500)
                SELECT MIN(it.name) FROM recent r JOIN item_tags it ON it.item_id = r.id
                GROUP BY it.name_key ORDER BY MAX(r.saved_at) DESC, it.name_key LIMIT ?
                """,
            arguments: [limit]
        )
    }

    /// Inserts or updates server tag rows. A row whose key another id already holds replaces it.
    public static func upsertRows(_ db: Database, _ rows: [TagRecord]) throws {
        for row in rows {
            try db.execute(sql: "DELETE FROM tags WHERE name_key = ? AND id != ?", arguments: [row.nameKey, row.id])
            try row.upsert(db)
        }
    }

    public static func deleteRows(_ db: Database, ids: [String]) throws {
        for chunk in chunked(ids) {
            try db.execute(
                sql: "DELETE FROM tags WHERE id IN (\(placeholders(chunk.count)))",
                arguments: StatementArguments(chunk)
            )
        }
    }

    public static func deleteRow(_ db: Database, nameKey: String) throws {
        try db.execute(sql: "DELETE FROM tags WHERE name_key = ?", arguments: [nameKey])
    }

    public static func allRows(_ db: Database) throws -> [TagRecord] {
        try TagRecord.fetchAll(db)
    }
}
