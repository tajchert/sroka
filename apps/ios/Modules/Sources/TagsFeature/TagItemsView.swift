import SrokaCore
import SrokaDesign
import SwiftUI
import UIKit

/// What a row of the tag's items asks for; the container maps these onto the view model.
struct TagItemsActions {
    var itemTapped: (ItemSummary) -> Void = { _ in }
    var itemAppeared: (ItemSummary) -> Void = { _ in }
    var swiped: (TagSwipeEdge, ItemSummary) -> Void = { _, _ in }
    var archive: (ItemSummary) -> Void = { _ in }
    var favorite: (ItemSummary) -> Void = { _ in }
    var editTags: (ItemSummary) -> Void = { _ in }
    var shareLink: (ItemSummary) -> Void = { _ in }
    var openOriginal: (ItemSummary) -> Void = { _ in }
    var refreshArticle: (ItemSummary) -> Void = { _ in }
    var delete: (ItemSummary) -> Void = { _ in }
}

/// One tag's articles (My List and Archive together), pushed from the Tags list. Same row,
/// swipe actions and context menu as My List.
public struct TagItemsView: View {
    @Bindable private var model: TagItemsViewModel

    public init(model: TagItemsViewModel) {
        self.model = model
    }

    public var body: some View {
        TagItemsContent(
            tag: model.tag,
            items: model.isLoaded ? model.items : nil,
            swipeLeftAction: model.swipeLeftAction,
            swipeRightAction: model.swipeRightAction,
            actions: actions
        )
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.snappy, value: model.toast?.id)
        .task { model.start() }
        .onChange(of: model.toast?.id) {
            if let toast = model.toast {
                AccessibilityNotification.Announcement(String(localized: toast.message)).post()
            }
        }
        .sensoryFeedback(.warning, trigger: model.warningFeedbackCount)
        .sheet(item: $model.shareRequest) { request in
            TagShareSheet(url: request.url).presentationDetents([.medium, .large])
        }
        .alert(
            Text("Delete article?", bundle: #bundle),
            isPresented: $model.isConfirmingDelete
        ) {
            Button(role: .cancel) {
                model.cancelDeleteTapped()
            } label: {
                Text("Cancel", bundle: #bundle)
            }
            Button(role: .destructive) {
                Task { await model.confirmDeleteTapped() }
            } label: {
                Text("Delete", bundle: #bundle)
            }
        } message: {
            Text("It will be removed from this device and your account.", bundle: #bundle)
        }
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast = model.toast {
            GlassToast(
                Text(toast.message),
                actionTitle: toast.undo == nil ? nil : Text(TagsStrings.undo),
                action: toast.undo == nil ? nil : { Task { await model.undoTapped() } }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var actions: TagItemsActions {
        TagItemsActions(
            itemTapped: { model.itemTapped($0) },
            itemAppeared: { model.itemAppeared($0) },
            swiped: { edge, item in Task { await model.swiped(edge, item: item) } },
            archive: { item in Task { await model.archiveTapped(item) } },
            favorite: { item in Task { await model.favoriteTapped(item) } },
            editTags: { model.editTagsTapped($0) },
            shareLink: { item in Task { await model.shareLinkTapped(item) } },
            openOriginal: { item in Task { await model.openOriginalTapped(item) } },
            refreshArticle: { item in Task { await model.refreshArticleTapped(item) } },
            delete: { model.deleteTapped($0) }
        )
    }
}

/// The tag's rows without any view model. `items` is nil while loading.
struct TagItemsContent: View {
    let tag: String
    let items: [ItemSummary]?
    let swipeLeftAction: SwipeAction
    let swipeRightAction: SwipeAction
    let actions: TagItemsActions

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    TagItemsEmptyView()
                } else {
                    List(items) { item in
                        TagItemRow(
                            item: item,
                            swipeLeftAction: swipeLeftAction,
                            swipeRightAction: swipeRightAction,
                            actions: actions
                        )
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SrokaColor.background)
        .navigationTitle(Text(verbatim: tag))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TagItemsEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag.slash")
                .font(.largeTitle)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
                .accessibilityHidden(true)
            Text("No articles with this tag", bundle: #bundle)
                .font(.brandHeading(.title3))
                .foregroundStyle(SrokaColor.onSurface)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// A row with swipe actions on both edges, the context menu and VoiceOver actions.
struct TagItemRow: View {
    let item: ItemSummary
    let swipeLeftAction: SwipeAction
    let swipeRightAction: SwipeAction
    let actions: TagItemsActions

    var body: some View {
        ItemRow(item, onRetry: { actions.refreshArticle(item) })
            .onTapGesture { actions.itemTapped(item) }
            .listRowInsets(EdgeInsets())
            .listRowBackground(SrokaColor.background)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { swipeButton(.leading, swipeRightAction) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButton(.trailing, swipeLeftAction) }
            .contextMenu { TagItemMenu(item: item, actions: actions) }
            .accessibilityAction(named: Text(item.archiveTitle)) { actions.archive(item) }
            .accessibilityAction(named: Text(item.favoriteTitle)) { actions.favorite(item) }
            .accessibilityAction(named: Text("Tags", bundle: #bundle)) { actions.editTags(item) }
            .onAppear { actions.itemAppeared(item) }
    }

    @ViewBuilder private func swipeButton(_ edge: TagSwipeEdge, _ action: SwipeAction) -> some View {
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
            .tint(action == .favorite ? SrokaColor.brandYellow : SrokaColor.primary)
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
}

extension ItemSummary {
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
struct TagItemMenu: View {
    let item: ItemSummary
    let actions: TagItemsActions

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

/// System share sheet for a link.
struct TagShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
