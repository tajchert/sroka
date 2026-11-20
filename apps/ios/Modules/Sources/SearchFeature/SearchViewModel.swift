import Dependencies
import Foundation
import Observation
import SrokaCore

/// What the results area shows.
public enum SearchPhase: Sendable, Hashable {
    /// Blank query: "Search the articles saved on this phone".
    case idle
    /// A query is typed but its first page has not arrived.
    case searching
    case results
    /// "No results".
    case empty
}

/// Model of the Search tab: local full-text search over the library, debounced, with the scopes
/// All / Archive / Favorites. The query and scope live here, not in the view, so rotating or
/// switching between the phone and iPad layout never loses them.
@MainActor
@Observable
public final class SearchViewModel {
    @ObservationIgnored @Dependency(\.libraryRepository) private var library
    @ObservationIgnored @Dependency(\.telemetry) private var telemetry
    @ObservationIgnored @Dependency(\.continuousClock) private var clock

    /// Typing pause before a query is searched.
    static let debounce: Duration = .milliseconds(250)

    /// The text field's content.
    public var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }

    /// The selected scope; changing it searches at once.
    public var scope: SearchScope = .all {
        didSet { if scope != oldValue { restart() } }
    }

    public private(set) var results: [SearchResult] = []
    /// Total hits; nil while unknown.
    public private(set) var resultCount: Int?
    public private(set) var hasMore = false

    @ObservationIgnored public var onIntent: @MainActor (SearchIntent) -> Void

    /// The trimmed query that is being searched (after the debounce).
    private var activeQuery = ""
    private var isLoaded = false
    private var listLimit = Limits.listPageSize
    private var hasLoggedUsage = false

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?

    /// - Parameter scope: the scope to preselect (the app root may pass the tab the search came from).
    public init(scope: SearchScope = .all, onIntent: @escaping @MainActor (SearchIntent) -> Void = { _ in }) {
        self.scope = scope
        self.onIntent = onIntent
    }

    isolated deinit {
        debounceTask?.cancel()
        resultsTask?.cancel()
        countTask?.cancel()
    }

    /// What to show now: idle for a blank field, "searching" until the page of the current
    /// query arrives, then results or the no-results message.
    public var phase: SearchPhase {
        if trimmed(query).isEmpty { return .idle }
        if !isLoaded { return .searching }
        return results.isEmpty ? .empty : .results
    }

    // MARK: Intents

    public func resultTapped(_ result: SearchResult) {
        onIntent(.openItem(id: result.summary.id))
    }

    public func clearTapped() {
        query = ""
    }

    /// Grows the page when the user scrolls near the end of a full page.
    public func resultAppeared(_ result: SearchResult) {
        guard hasMore, results.count >= listLimit, results.suffix(10).contains(where: { $0.id == result.id }) else {
            return
        }
        listLimit += Limits.listPageSize
        observeResults()
    }

    // MARK: Pipeline

    private func queryChanged() {
        // One search_used per search session; never the text itself.
        if !hasLoggedUsage, !trimmed(query).isEmpty {
            hasLoggedUsage = true
            telemetry.logEvent(.searchUsed)
        }
        debounceTask?.cancel()
        let text = trimmed(query)
        if text.isEmpty {
            activate(text)
            return
        }
        debounceTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            activate(text)
        }
    }

    /// Searches `text` unless it is already what is searched.
    private func activate(_ text: String) {
        guard text != activeQuery else { return }
        activeQuery = text
        restart()
    }

    private func restart() {
        resultsTask?.cancel()
        countTask?.cancel()
        listLimit = Limits.listPageSize
        results = []
        resultCount = nil
        hasMore = false
        isLoaded = false
        guard !activeQuery.isEmpty else { return }
        observeResults()
        let count = library.observeSearchCount(activeQuery, scope: scope)
        countTask = Task { [weak self] in
            for await count in count {
                guard let self else { return }
                resultCount = count
            }
        }
    }

    private func observeResults() {
        resultsTask?.cancel()
        let stream = library.observeSearch(activeQuery, scope: scope, limit: listLimit)
        resultsTask = Task { [weak self] in
            for await page in stream {
                guard let self else { return }
                results = page.results
                hasMore = page.hasMore
                isLoaded = true
            }
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
