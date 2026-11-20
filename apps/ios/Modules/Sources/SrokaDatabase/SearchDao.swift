import Foundation
import GRDB
import SrokaCore

/// Local full-text search over `items_fts` (R8; Android `ItemDao.search*` and `SearchMapping.kt`).
public enum SearchDao {
    /// The first `limit` hits for `query` in `scope`, newest first. A blank or symbol-only query
    /// yields an empty page.
    public static func page(_ db: Database, query: String, scope: SearchScope, limit: Int) throws -> SearchPage {
        let rows = try hits(db, query: query, scope: scope, limit: limit + 1)
        return SearchPage(results: rows.prefix(limit).map { $0.toSearchResult() }, hasMore: rows.count > limit)
    }

    /// Raw hits, at most `limit` (negative = no limit).
    public static func hits(_ db: Database, query: String, scope: SearchScope, limit: Int) throws -> [SearchRow] {
        guard let match = FtsQuery.build(query) else { return [] }
        return try SearchRow.fetchAll(
            db,
            sql: """
                \(ItemSQL.searchColumns) \(ItemSQL.searchFrom)
                WHERE items_fts MATCH ?\(ItemSQL.scopeFilter(scope)) \(ItemSQL.orderNewest) LIMIT \(limit)
                """,
            arguments: [match]
        )
    }

    /// Total hits `page` would return without a limit (0 for a blank query).
    public static func count(_ db: Database, query: String, scope: SearchScope) throws -> Int {
        guard let match = FtsQuery.build(query) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid
                WHERE items_fts MATCH ?\(ItemSQL.scopeFilter(scope))
                """,
            arguments: [match]
        ) ?? 0
    }
}

/// A search hit: the list row, the raw body snippet (with private-use match markers) and whether a
/// metadata column (title, excerpt, site name, tags) matched.
public struct SearchRow: Sendable, Hashable, FetchableRecord {
    public var row: ItemSummaryRow
    public var snippet: String?
    public var inMeta: Bool

    public init(row: Row) {
        self.row = ItemSummaryRow(row: row)
        snippet = row["snippet"]
        inMeta = row["in_meta"] ?? false
    }

    /// The body matched when `snippet()` marked a term in it.
    public var inBody: Bool { snippet?.contains(ItemSQL.highlightStart) ?? false }

    /// Mapping as on Android: any non-body match counts as "title"; a hit with no detected column
    /// also counts as "title".
    public func toSearchResult() -> SearchResult {
        let body = inBody
        let meta = inMeta || !body
        let parsed = body ? parseSnippet(snippet) : nil
        let matchIn: MatchIn =
            if body && meta {
                .both
            } else if body {
                .text
            } else {
                .title
            }
        return SearchResult(
            summary: row.toSummary(),
            matchIn: matchIn,
            snippet: parsed?.text,
            highlights: parsed?.ranges ?? []
        )
    }
}

/// Strips the private-use markers of a `snippet()` and returns the clean text with the marked ranges
/// (UTF-16 offsets into the clean text). Nil when `raw` is nil or blank.
public func parseSnippet(_ raw: String?) -> (text: String, ranges: [Range<Int>])? {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var out = ""
    var length = 0
    var ranges: [Range<Int>] = []
    var start: Int?
    for character in raw {
        switch character {
        case ItemSQL.highlightStart:
            start = length
        case ItemSQL.highlightEnd:
            if let begin = start, length > begin { ranges.append(begin..<length) }
            start = nil
        default:
            out.append(character)
            length += character.utf16.count
        }
    }
    return (out, ranges)
}
