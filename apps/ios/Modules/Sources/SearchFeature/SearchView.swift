import SrokaCore
import SrokaDesign
import SwiftUI

/// The Search tab: `.searchable` field with the All / Archive / Favorites scopes and the results.
///
/// Host it in the tab with the search role and give it its own `NavigationStack`:
///
/// ```swift
/// Tab(role: .search) {
///     NavigationStack { SearchView(model: searchModel) }
/// }
/// ```
/// `model.onIntent` asks the app root to open the reader. On a regular-width window (iPad) the
/// field sits at the top of the list column instead of the bottom glass field.
public struct SearchView: View {
    @Bindable private var model: SearchViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(model: SearchViewModel) {
        self.model = model
    }

    public var body: some View {
        SearchResultsContent(
            phase: model.phase,
            results: model.results,
            resultCount: model.resultCount,
            query: model.query,
            onOpen: { model.resultTapped($0) },
            onAppear: { model.resultAppeared($0) }
        )
        .searchable(
            text: $model.query,
            placement: horizontalSizeClass == .regular ? .navigationBarDrawer(displayMode: .always) : .automatic,
            prompt: Text("Search saved articles", bundle: #bundle)
        )
        .searchScopes($model.scope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.immediately)
    }
}

extension SearchScope {
    var title: LocalizedStringResource {
        switch self {
        case .all: LocalizedStringResource("All", bundle: #bundle)
        case .archive: LocalizedStringResource("Archive", bundle: #bundle)
        case .favorites: LocalizedStringResource("Favorites", bundle: #bundle)
        }
    }
}

/// Title, count line and results (or the idle / empty message) without any view model.
/// The owner provides the `NavigationStack` and the search field.
struct SearchResultsContent: View {
    let phase: SearchPhase
    let results: [SearchResult]
    let resultCount: Int?
    let query: String
    var onOpen: (SearchResult) -> Void = { _ in }
    var onAppear: (SearchResult) -> Void = { _ in }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                SearchMessage(
                    title: Text("Search the articles saved on this phone", bundle: #bundle),
                    message: nil
                )
            case .empty:
                SearchMessage(
                    title: Text("No results", bundle: #bundle),
                    message: Text("Try different words", bundle: #bundle)
                )
            case .searching, .results:
                SearchResultsList(
                    results: results, resultCount: phase == .results ? resultCount : nil, query: query,
                    onOpen: onOpen, onAppear: onAppear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SrokaColor.background)
        .navigationTitle(Text("Search", bundle: #bundle))
    }
}

/// "3 results, searched on this phone" and the rows.
struct SearchResultsList: View {
    let results: [SearchResult]
    let resultCount: Int?
    let query: String
    let onOpen: (SearchResult) -> Void
    let onAppear: (SearchResult) -> Void

    var body: some View {
        List {
            SearchCountLine(count: resultCount)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(SrokaColor.background)
            ForEach(results) { result in
                SearchResultRow(result: result, query: query)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(result) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(SrokaColor.background)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                    .onAppear { onAppear(result) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct SearchCountLine: View {
    let count: Int?

    var body: some View {
        Group {
            if let count {
                Text("\(count) results, searched on this phone", bundle: #bundle)
            } else {
                Text("Results, searched on this phone", bundle: #bundle)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(SrokaColor.primary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One hit: thumbnail, title with the matched words marked, "site · In title / In text" and the
/// snippet with the matched words marked.
struct SearchResultRow: View {
    let result: SearchResult
    let query: String

    var body: some View {
        let summary = result.summary
        let archived = summary.status == .archived
        let label = String(localized: SearchHighlight.matchLabel(result.matchIn, archived: archived))
        let title = marked(
            summary.displayTitle,
            SearchHighlight.titleRanges(title: summary.displayTitle, query: query, matchIn: result.matchIn))
        HStack(alignment: .top, spacing: 12) {
            ItemThumbnail(summary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.rowTitle)
                    .foregroundStyle(SrokaColor.onSurface)
                    .lineLimit(2)
                Text(verbatim: "\(summary.domain) · \(label)")
                    .font(.rowMeta)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                    .lineLimit(2)
                if let snippet = result.snippet {
                    Text(
                        marked(snippet, SearchHighlight.snippetRanges(snippet: snippet, highlights: result.highlights))
                    )
                    .font(.subheadline)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                    .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: [summary.displayTitle, summary.domain, label, result.snippet].compactMap { $0 }.joined(
                    separator: ", "))
        )
        .accessibilityAddTraits(.isButton)
    }

    /// `text` with `ranges` on the highlight colours.
    private func marked(_ text: String, _ ranges: [Range<String.Index>]) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                let upper = AttributedString.Index(range.upperBound, within: attributed), lower < upper
            else { continue }
            attributed[lower..<upper].backgroundColor = SrokaColor.tertiaryContainer
            attributed[lower..<upper].foregroundColor = SrokaColor.onTertiaryContainer
        }
        return attributed
    }
}

/// Idle and "No results" states.
struct SearchMessage: View {
    let title: Text
    let message: Text?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
                .accessibilityHidden(true)
            title
                .font(.headline)
                .foregroundStyle(SrokaColor.onSurface)
                .multilineTextAlignment(.center)
            if let message {
                message
                    .font(.subheadline)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}
