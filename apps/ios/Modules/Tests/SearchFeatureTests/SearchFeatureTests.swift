import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Testing

@testable import SearchFeature

@MainActor
struct SearchViewModelTests {
    let fakes: Fakes
    let clock = TestClock<Duration>()
    let intents = IntentLog()

    final class IntentLog {
        var values: [SearchIntent] = []
    }

    init(items: [Item] = Fixtures.items) {
        fakes = Fakes(items: items)
    }

    func makeModel(scope: SearchScope = .all) -> SearchViewModel {
        let fakes = fakes
        let clock = clock
        let log = intents
        return withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
        } operation: {
            SearchViewModel(scope: scope) { log.values.append($0) }
        }
    }

    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    /// Lets the debounce task reach its sleep, then advances the clock.
    func advance(_ duration: Duration) async {
        for _ in 0..<20 { await Task.yield() }
        await clock.advance(by: duration)
    }

    // MARK: Debounce

    @Test func `A blank query shows the idle state and searches nothing`() async {
        let model = makeModel()
        #expect(model.phase == .idle)
        model.query = "   "
        #expect(model.phase == .idle)
        #expect(model.results.isEmpty)
    }

    @Test func `A query is searched after a 250 ms pause`() async {
        let model = makeModel()
        model.query = "magpie"
        #expect(model.phase == .searching)
        await advance(.milliseconds(100))
        #expect(model.results.isEmpty)
        await advance(.milliseconds(150))
        await until { model.phase == .results }
        #expect(model.results.map(\.id) == ["a2-short-news"])
        await until { model.resultCount != nil }
        #expect(model.resultCount == 1)
    }

    @Test func `Typing again restarts the pause`() async {
        let model = makeModel()
        model.query = "mag"
        await advance(.milliseconds(200))
        model.query = "magpie"
        await advance(.milliseconds(200))
        #expect(model.results.isEmpty)
        #expect(model.phase == .searching)
        await advance(.milliseconds(50))
        await until { model.phase == .results }
        #expect(model.results.map(\.id) == ["a2-short-news"])
    }

    @Test func `Clearing the field goes back to idle at once`() async {
        let model = makeModel()
        model.query = "magpie"
        await advance(.milliseconds(250))
        await until { model.phase == .results }
        model.clearTapped()
        #expect(model.phase == .idle)
        #expect(model.results.isEmpty)
        #expect(model.resultCount == nil)
    }

    @Test func `A query that matches nothing shows no results`() async {
        let model = makeModel()
        model.query = "zzzz"
        await advance(.milliseconds(250))
        await until { model.phase == .empty }
        #expect(model.phase == .empty)
        await until { model.resultCount != nil }
        #expect(model.resultCount == 0)
    }

    // MARK: Scopes

    @Test func `The scope narrows the results at once, without waiting`() async {
        let model = makeModel()
        model.query = "sroka"
        await advance(.milliseconds(250))
        await until { model.phase == .results }
        #expect(model.results.map(\.id) == ["a7-archived-fav"])
        model.query = "magpie"
        await advance(.milliseconds(250))
        await until { model.results.map(\.id) == ["a2-short-news"] }
        model.scope = .archive
        await until { model.phase == .empty }
        #expect(model.results.isEmpty)
        model.scope = .favorites
        await until { model.phase == .results }
        #expect(model.results.map(\.id) == ["a2-short-news"])
    }

    @Test func `The search can start in the scope of the tab it came from`() async {
        let model = makeModel(scope: .archive)
        #expect(model.scope == .archive)
        model.query = "flour"
        await advance(.milliseconds(250))
        await until { model.phase == .results }
        #expect(model.results.map(\.id) == ["a6-archived"])
        #expect(model.results.first?.matchIn == .text)
    }

    // MARK: Labels, intents, telemetry

    @Test func `A hit in both title and text is labelled Title and text`() async {
        let model = makeModel()
        model.query = "magpie"
        await advance(.milliseconds(250))
        await until { model.phase == .results }
        #expect(model.results.first?.matchIn == .both)
    }

    @Test func `Match labels use Android's words, archived ones are prefixed`() {
        func label(_ matchIn: MatchIn, _ archived: Bool) -> String {
            String(localized: SearchHighlight.matchLabel(matchIn, archived: archived))
        }
        #expect(label(.title, false) == "In title")
        #expect(label(.text, false) == "In text")
        #expect(label(.both, false) == "Title and text")
        #expect(label(.title, true) == "Archive · in title")
        #expect(label(.text, true) == "Archive · in text")
        #expect(label(.both, true) == "Archive · title and text")
    }

    @Test func `Tapping a result asks the app to open the article`() async throws {
        let model = makeModel()
        model.query = "magpie"
        await advance(.milliseconds(250))
        await until { model.phase == .results }
        model.resultTapped(try #require(model.results.first))
        #expect(intents.values == [.openItem(id: "a2-short-news")])
    }

    @Test func `Search use is counted once per session and never with the text`() async {
        let model = makeModel()
        model.query = "m"
        model.query = "ma"
        model.clearTapped()
        model.query = "mag"
        let used = fakes.telemetry.events.calls.filter { if case .searchUsed = $0 { true } else { false } }
        #expect(used.count == 1)
    }

    // MARK: Paging

    @Test func `More results load when the end of a full page appears`() async throws {
        let bed = SearchViewModelTests(items: Fixtures.manyItems(120))
        let model = bed.makeModel()
        model.query = "bulk"
        await bed.advance(.milliseconds(250))
        await bed.until { model.phase == .results }
        #expect(model.results.count == Limits.listPageSize)
        #expect(model.hasMore)
        await bed.until { model.resultCount == 120 }
        #expect(model.resultCount == 120)
        model.resultAppeared(try #require(model.results.last))
        await bed.until { model.results.count == Limits.listPageSize * 2 }
        #expect(model.results.count == Limits.listPageSize * 2)
    }
}

struct SearchHighlightTests {
    func pieces(_ text: String, _ ranges: [Range<String.Index>]) -> [String] {
        ranges.map { String(text[$0]) }
    }

    @Test func `Snippet highlights are UTF-16 offsets, clamped to the text`() {
        let snippet = "héllo 🐦 magpie"
        let start = snippet.utf16.count - 6
        let ranges = SearchHighlight.snippetRanges(
            snippet: snippet, highlights: [start..<(start + 6), -3..<1, (start + 3)..<500, 4..<4])
        #expect(pieces(snippet, ranges) == ["magpie", "h", "pie"])
    }

    @Test func `Title words that start with a query term are marked`() {
        let title = "Why magpies are not thieves"
        let ranges = SearchHighlight.titleRanges(title: title, query: "MAGPIE", matchIn: .title)
        #expect(pieces(title, ranges) == ["magpie"])
    }

    @Test func `A term inside a word is not marked, a prefix is`() {
        let title = "Magpies and sharpies"
        #expect(SearchHighlight.titleRanges(title: title, query: "pie", matchIn: .title).isEmpty)
        #expect(
            pieces(title, SearchHighlight.titleRanges(title: title, query: "mag sh", matchIn: .both)) == ["Mag", "sh"])
    }

    @Test func `Accents and case do not matter`() {
        let title = "Żółw i Sroka zwyczajna"
        let ranges = SearchHighlight.titleRanges(title: title, query: "sroka", matchIn: .title)
        #expect(pieces(title, ranges) == ["Sroka"])
        #expect(
            pieces("Café au lait", SearchHighlight.titleRanges(title: "Café au lait", query: "cafe", matchIn: .title))
                == ["Café"])
    }

    @Test func `A text-only hit leaves the title unmarked`() {
        #expect(SearchHighlight.titleRanges(title: "Magpies", query: "magpie", matchIn: .text).isEmpty)
    }

    @Test func `Query terms are runs of letters and digits, at most eight`() {
        #expect(SearchHighlight.terms(of: "  foo-bar, baz42 ") == ["foo", "bar", "baz42"])
        #expect(SearchHighlight.terms(of: "a b c d e f g h i j").count == 8)
        #expect(SearchHighlight.terms(of: "!!!").isEmpty)
    }
}
