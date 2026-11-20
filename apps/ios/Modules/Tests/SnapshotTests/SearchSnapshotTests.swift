import SnapshotTesting
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import Testing

@testable import SearchFeature

/// Search tab on the iPhone 18 Pro. References live in `__Snapshots__/SearchSnapshotTests`; valid
/// only on the iPhone 18 Pro / iOS 27.2 simulator. The `.searchable` field is system chrome that
/// renders outside the content in a bare hosting controller, so these show the content only.
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct SearchSnapshotTests {
    init() {
        _ = SrokaFont.registerFonts()
    }

    private func check(
        _ view: some View,
        style: UIUserInterfaceStyle = .light,
        category: UIContentSizeCategory? = nil,
        name: String,
        line: UInt = #line
    ) {
        var traits = [UITraitCollection(userInterfaceStyle: style)]
        if let category { traits.append(UITraitCollection(preferredContentSizeCategory: category)) }
        let controller = UIHostingController(rootView: view)
        assertSnapshot(
            of: controller,
            as: .wait(
                for: 1,
                on: .image(
                    on: LibrarySnapshotTests.phone, precision: 0.99, perceptualPrecision: 0.98,
                    traits: UITraitCollection(traitsFrom: traits))),
            named: nil,
            testName: name,
            line: line
        )
    }

    /// A hit whose snippet has `mark` highlighted (UTF-16 offsets, like the database returns).
    private func hit(_ summary: ItemSummary, _ matchIn: MatchIn, snippet: String? = nil, mark: String? = nil)
        -> SearchResult
    {
        var highlights: [Range<Int>] = []
        if let snippet, let mark, let range = snippet.range(of: mark) {
            let start = snippet.utf16.distance(from: snippet.startIndex, to: range.lowerBound)
            highlights = [start..<(start + mark.utf16.count)]
        }
        return SearchResult(summary: summary, matchIn: matchIn, snippet: snippet, highlights: highlights)
    }

    /// The three hits of the plan's mock-up for "magpie".
    private var magpieHits: [SearchResult] {
        var wiki = Fixtures.shortNews.summary
        wiki.displayTitle = "Eurasian magpie"
        wiki.domain = "en.wikipedia.org"
        var mirror = Fixtures.archived.summary
        mirror.displayTitle = "Mirror test"
        mirror.domain = "en.wikipedia.org"
        var thieves = Fixtures.longRead.summary
        thieves.displayTitle = "Why magpies are not thieves"
        thieves.domain = "birdguides.com"
        return [
            hit(
                wiki, .both, snippet: "…the magpie is one of the few animals known to recognise itself…",
                mark: "magpie"),
            hit(
                mirror, .text, snippet: "…European magpies removed a mark placed on their feathers…",
                mark: "magpie"),
            hit(thieves, .title),
        ]
    }

    private func screen(_ phase: SearchPhase, results: [SearchResult] = [], count: Int? = nil, query: String)
        -> some View
    {
        NavigationStack {
            SearchResultsContent(phase: phase, results: results, resultCount: count, query: query)
        }
    }

    @Test func resultsLight() {
        check(screen(.results, results: magpieHits, count: 3, query: "magpie"), name: "results-light")
    }

    @Test func resultsDark() {
        check(
            screen(.results, results: magpieHits, count: 3, query: "magpie"), style: .dark, name: "results-dark")
    }

    @Test func resultsLargeDynamicType() {
        check(
            screen(.results, results: magpieHits, count: 3, query: "magpie"), category: .accessibilityLarge,
            name: "results-ax-large")
    }

    @Test func resultsSearching() {
        check(screen(.searching, query: "magpie"), name: "results-searching")
    }

    @Test func emptyLight() {
        check(screen(.empty, count: 0, query: "zzzz"), name: "empty-light")
    }

    @Test func emptyDark() {
        check(screen(.empty, count: 0, query: "zzzz"), style: .dark, name: "empty-dark")
    }

    @Test func emptyLargeDynamicType() {
        check(screen(.empty, count: 0, query: "zzzz"), category: .accessibilityLarge, name: "empty-ax-large")
    }

    @Test func idleLight() {
        check(screen(.idle, query: ""), name: "idle-light")
    }
}
