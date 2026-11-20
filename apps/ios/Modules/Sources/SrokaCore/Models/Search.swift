/// Which items a search covers (R8). `.all` = every live item, any status.
public enum SearchScope: String, Sendable, Hashable, CaseIterable {
    case all
    case archive
    case favorites
}

/// Where the query matched.
public enum MatchIn: String, Sendable, Hashable {
    case title
    case text
    case both
}

/// One search hit. `snippet` is plain text around the body match (markers stripped), nil when the
/// body did not match; `highlights` are the matched ranges (UTF-16 offsets) inside `snippet`.
public struct SearchResult: Sendable, Hashable, Identifiable {
    public var summary: ItemSummary
    public var matchIn: MatchIn
    public var snippet: String?
    public var highlights: [Range<Int>]
    public var id: String { summary.id }

    public init(summary: ItemSummary, matchIn: MatchIn, snippet: String? = nil, highlights: [Range<Int>] = []) {
        self.summary = summary
        self.matchIn = matchIn
        self.snippet = snippet
        self.highlights = highlights
    }
}

/// One observed window of search results (see `ItemPage`).
public struct SearchPage: Sendable, Hashable {
    public var results: [SearchResult]
    public var hasMore: Bool

    public init(results: [SearchResult], hasMore: Bool) {
        self.results = results
        self.hasMore = hasMore
    }

    public static let empty = SearchPage(results: [], hasMore: false)
}
