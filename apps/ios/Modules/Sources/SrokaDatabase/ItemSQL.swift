import GRDB
import SrokaCore

// SQL shared by the list, detail and search queries (Android `dao/ItemSql.kt`).

enum ItemSQL {
    static let rowColumns = """
        SELECT i.id AS id, i.title AS title, i.url AS url, substr(i.excerpt, 1, 200) AS excerpt,
          i.reading_minutes AS reading_minutes, i.status AS status, i.is_favorite AS is_favorite,
          i.progress AS progress, i.parse_status AS parse_status, i.saved_at AS saved_at,
          i.content_id AS content_id, cf.content_id AS file_content_id, cf.state AS file_state,
          cf.thumb_path AS thumb_path,
          (SELECT group_concat(name, char(31)) FROM
             (SELECT name FROM item_tags WHERE item_id = i.id ORDER BY name_key)) AS tags,
          (SELECT po.type FROM pending_ops po WHERE po.item_id = i.id AND po.type != 'item.setProgress'
             ORDER BY po.local_seq DESC LIMIT 1) AS pending_type,
          i.kind AS kind, i.file_size AS file_size, i.parse_error AS parse_error
        """

    static let listFrom = "FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id"

    static let detailSelect = """
        SELECT i.*, cf.content_id AS file_content_id, cf.state AS file_state, cf.thumb_path AS thumb_path,
          (SELECT group_concat(name, char(31)) FROM
             (SELECT name FROM item_tags WHERE item_id = i.id ORDER BY name_key)) AS tags
        FROM items i LEFT JOIN content_files cf ON cf.item_id = i.id
        """

    static let orderNewest = "ORDER BY i.saved_at DESC, i.id DESC"
    static let orderOldest = "ORDER BY i.saved_at ASC, i.id ASC"
    static let orderShortest = "ORDER BY (i.word_count IS NULL), i.word_count ASC, i.saved_at DESC, i.id DESC"
    static let orderLongest = "ORDER BY (i.word_count IS NULL), i.word_count DESC, i.saved_at DESC, i.id DESC"

    /// "Continue reading" progress window (proposal 08).
    static let continueFrom = 0.05
    static let continueTo = 0.95

    /// Private-use markers `snippet()` / `highlight()` wrap around matched terms.
    static let highlightStart: Character = "\u{E000}"
    static let highlightEnd: Character = "\u{E001}"

    /// `items_fts` column order: title 0, excerpt 1, site_name 2, tags 3, body 4.
    static let ftsBodyColumn = 4

    /// Search hit columns: list row, a 12-token body snippet, and whether a metadata column (title,
    /// excerpt, site, tags) matched, from `highlight()` on those short columns. FTS5 has no `offsets()`.
    static let searchColumns = """
        \(rowColumns),
          snippet(items_fts, \(ftsBodyColumn), char(57344), char(57345), '…', 12) AS snippet,
          (instr(highlight(items_fts, 0, char(57344), char(57345)), char(57344)) > 0
            OR instr(highlight(items_fts, 1, char(57344), char(57345)), char(57344)) > 0
            OR instr(highlight(items_fts, 2, char(57344), char(57345)), char(57344)) > 0
            OR instr(highlight(items_fts, 3, char(57344), char(57345)), char(57344)) > 0) AS in_meta
        """

    static let searchFrom = """
        FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid
        LEFT JOIN content_files cf ON cf.item_id = i.id
        """

    static func order(_ sort: LibrarySortOrder) -> String {
        switch sort {
        case .newest: orderNewest
        case .oldest: orderOldest
        case .shortest: orderShortest
        case .longest: orderLongest
        }
    }

    static func scopeFilter(_ scope: SearchScope) -> String {
        switch scope {
        case .all: ""
        case .archive: " AND i.status = 'ARCHIVED'"
        case .favorites: " AND i.is_favorite = 1"
        }
    }

    /// The library list statement for `query`, without LIMIT. Each filter adds one concrete AND
    /// condition (never an OR'ed "parameter is null" filter, which forces a full scan), so SQLite
    /// can plan with the status / favorite / tag indexes or let the FTS match drive. Tab literals
    /// are inlined; user input is bound.
    static func list(_ query: ItemQuery) -> (sql: String, arguments: StatementArguments) {
        let match = query.search.flatMap(FtsQuery.build)
        let key = query.tag.map(tagKey)
        var arguments: [(any DatabaseValueConvertible)?] = []
        var conditions: [String] = []
        let from: String
        if match != nil {
            from =
                "FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid"
                + (key != nil ? " JOIN item_tags t ON t.item_id = i.id" : "")
        } else if key != nil {
            // Driven by the item_tags(name_key) index.
            from = "FROM item_tags t JOIN items i ON i.id = t.item_id"
        } else {
            from = "FROM items i"
        }
        if let match {
            conditions.append("items_fts MATCH ?")
            arguments.append(match)
        }
        if let key {
            conditions.append("t.name_key = ?")
            arguments.append(key)
        }
        switch query.tab {
        case .myList: conditions.append("i.status = 'UNREAD'")
        case .archive: conditions.append("i.status = 'ARCHIVED'")
        case .favorites: conditions.append("i.is_favorite = 1")
        case nil: break
        }
        if query.favoritesOnly, query.tab != .favorites { conditions.append("i.is_favorite = 1") }
        if let minutes = query.maxReadingMinutes {
            conditions.append("i.reading_minutes IS NOT NULL AND i.reading_minutes <= ?")
            arguments.append(minutes)
        }
        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = [rowColumns, from, "LEFT JOIN content_files cf ON cf.item_id = i.id", whereSQL, order(query.sort)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (sql, StatementArguments(arguments))
    }
}
