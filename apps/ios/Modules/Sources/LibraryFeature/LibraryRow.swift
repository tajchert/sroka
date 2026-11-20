import SrokaCore
import SrokaDesign
import SwiftUI

/// One list row with swipe actions on both edges, the context menu and VoiceOver actions.
struct LibraryRow: View {
    let item: ItemSummary
    let state: LibraryListState
    let actions: LibraryActions
    let peekEdge: SwipeEdge?

    var body: some View {
        ItemRow(item, onRetry: { actions.refreshArticle(item) })
            .modifier(
                SwipePeek(edge: peekEdge, action: peekEdge.map { state.action(for: $0) } ?? .none, item: item) {
                    actions.swipeHintFinished()
                }
            )
            .onTapGesture { actions.itemTapped(item) }
            .listRowInsets(EdgeInsets())
            .listRowBackground(SrokaColor.background)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { swipeButton(.leading) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButton(.trailing) }
            .contextMenu {
                LibraryRowMenu(item: item, actions: actions)
            } preview: {
                ItemPreviewCard(item: item)
            }
            .accessibilityAction(named: Text(item.archiveTitle)) { actions.archive(item) }
            .accessibilityAction(named: Text(item.favoriteTitle)) { actions.favorite(item) }
            .accessibilityAction(named: Text("Tags", bundle: #bundle)) { actions.editTags(item) }
            .onAppear { actions.itemAppeared(item) }
    }

    @ViewBuilder private func swipeButton(_ edge: SwipeEdge) -> some View {
        let action = state.action(for: edge)
        if action != .none {
            Button {
                actions.swiped(edge, item)
            } label: {
                Label {
                    Text(action.title(for: item))
                } icon: {
                    Image(systemName: action.symbol(for: item))
                }
            }
            .tint(action.tint)
        }
    }
}

extension SwipeAction {
    func title(for item: ItemSummary) -> LocalizedStringResource {
        switch self {
        case .archive: item.archiveTitle
        case .favorite: item.favoriteTitle
        case .tags: LocalizedStringResource("Tags", bundle: #bundle)
        case .none: LocalizedStringResource("None", bundle: #bundle)
        }
    }

    func symbol(for item: ItemSummary) -> String {
        switch self {
        case .archive: item.status == .archived ? "tray.and.arrow.up" : "archivebox"
        case .favorite: item.isFavorite ? "star.slash" : "star"
        case .tags: "tag"
        case .none: "circle"
        }
    }

    /// Brand blue for archive and tags, beak yellow for the favorite star.
    var tint: Color {
        self == .favorite ? SrokaColor.brandYellow : SrokaColor.primary
    }
}

extension ItemSummary {
    /// Swipe / accessibility title of the archive action.
    var archiveTitle: LocalizedStringResource {
        status == .archived
            ? LocalizedStringResource("Unarchive", bundle: #bundle)
            : LocalizedStringResource("Archive", bundle: #bundle)
    }

    var favoriteTitle: LocalizedStringResource {
        isFavorite
            ? LocalizedStringResource("Remove favorite", bundle: #bundle)
            : LocalizedStringResource("Favorite", bundle: #bundle)
    }
}

/// The seven context-menu actions in Android's order; Delete sits in its own group.
struct LibraryRowMenu: View {
    let item: ItemSummary
    let actions: LibraryActions

    var body: some View {
        Button {
            actions.favorite(item)
        } label: {
            if item.isFavorite {
                Label(String(localized: "Remove from favorites", bundle: #bundle), systemImage: "star.slash")
            } else {
                Label(String(localized: "Add to favorites", bundle: #bundle), systemImage: "star")
            }
        }
        Button {
            actions.archive(item)
        } label: {
            if item.status == .archived {
                Label(String(localized: "Move to My List", bundle: #bundle), systemImage: "tray.and.arrow.up")
            } else {
                Label(String(localized: "Archive", bundle: #bundle), systemImage: "archivebox")
            }
        }
        Button {
            actions.editTags(item)
        } label: {
            Label(String(localized: "Edit tags", bundle: #bundle), systemImage: "tag")
        }
        Button {
            actions.shareLink(item)
        } label: {
            Label(String(localized: "Share link", bundle: #bundle), systemImage: "square.and.arrow.up")
        }
        Button {
            actions.openOriginal(item)
        } label: {
            Label(String(localized: "Open original", bundle: #bundle), systemImage: "safari")
        }
        Button {
            actions.refreshArticle(item)
        } label: {
            Label(String(localized: "Refresh article", bundle: #bundle), systemImage: "arrow.clockwise")
        }
        Divider()
        Button(role: .destructive) {
            actions.delete(item)
        } label: {
            Label(String(localized: "Delete", bundle: #bundle), systemImage: "trash")
        }
    }
}

/// Context-menu preview: the title, site, excerpt and tags on paper.
struct ItemPreviewCard: View {
    let item: ItemSummary

    var body: some View {
        let presentation = ItemRowPresentation(item)
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTitle).font(.headline).lineLimit(3)
            Text(presentation.metaText).font(.subheadline).foregroundStyle(SrokaColor.onSurfaceVariant)
            if let excerpt = item.excerpt, !excerpt.isEmpty {
                Text(excerpt).font(.callout).lineLimit(5)
            }
            if !item.tags.isEmpty {
                Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.footnote)
                    .foregroundStyle(SrokaColor.primary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(SrokaColor.surfaceContainer)
    }
}

/// First-run hint: the first row slides to reveal the first configured swipe action, then back.
/// Skipped (but counted as shown) with Reduce Motion.
struct SwipePeek: ViewModifier {
    let edge: SwipeEdge?
    let action: SwipeAction
    let item: ItemSummary
    let onFinished: () -> Void

    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: edge == .leading ? .leading : .trailing) {
                if offset != 0 {
                    action.tint
                        .overlay(alignment: edge == .leading ? .leading : .trailing) {
                            Image(systemName: action.symbol(for: item))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                        }
                }
            }
            .task(id: edge) { await peek() }
    }

    private func peek() async {
        guard let edge else { return }
        guard !reduceMotion else {
            onFinished()
            return
        }
        let direction: CGFloat = edge == .trailing ? -1 : 1
        try? await Task.sleep(for: .milliseconds(600))
        withAnimation(.spring(duration: 0.45)) { offset = 72 * direction }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(.spring(duration: 0.45)) { offset = 0 }
        try? await Task.sleep(for: .milliseconds(450))
        onFinished()
    }
}
