import Dependencies
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI

extension SearchResult {
    /// Sample hits: both columns, archived text-only, title-only.
    static var previewResults: [SearchResult] {
        let long = Fixtures.longRead.summary
        let archived = Fixtures.archived.summary
        let short = Fixtures.shortNews.summary
        let snippet = "…one of the few animals known to recognise itself in a mirror…"
        let word = "recognise"
        let start = snippet.utf16.distance(from: snippet.startIndex, to: snippet.range(of: word)!.lowerBound)
        return [
            SearchResult(
                summary: long, matchIn: .both, snippet: snippet, highlights: [start..<(start + word.utf16.count)]),
            SearchResult(
                summary: archived, matchIn: .text, snippet: snippet, highlights: [start..<(start + word.utf16.count)]),
            SearchResult(summary: short, matchIn: .title),
        ]
    }
}

#Preview("Results") {
    let _ = SrokaFont.registerFonts()
    NavigationStack {
        SearchResultsContent(
            phase: .results, results: SearchResult.previewResults, resultCount: 3, query: "the")
    }
}

#Preview("Idle") {
    NavigationStack {
        SearchResultsContent(phase: .idle, results: [], resultCount: nil, query: "")
    }
}

#Preview("No results") {
    NavigationStack {
        SearchResultsContent(phase: .empty, results: [], resultCount: 0, query: "zzz")
    }
}

#Preview("Live with fakes") {
    let fakes = Fakes()
    let model = withDependencies {
        $0.useFakes(fakes)
    } operation: {
        SearchViewModel()
    }
    NavigationStack { SearchView(model: model) }
}
