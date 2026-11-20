import SrokaCore
import SrokaDesign
import SwiftUI

/// My List / Archive without any view model: title, toolbar and the list. The container
/// (`LibraryView`) adds toast, sheets and drops. The owner provides the `NavigationStack`.
struct LibraryScreenContent: View {
    let state: LibraryListState
    let actions: LibraryActions
    var clipboardHasLink = false
    var scrollToTopCount = 0

    var body: some View {
        LibraryList(
            state: state, actions: actions, clipboardHasLink: clipboardHasLink, scrollToTopCount: scrollToTopCount
        )
        .background(SrokaColor.background)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AvatarButton(letter: state.avatarLetter, action: actions.avatarTapped)
            }
            ToolbarItem(placement: .topBarTrailing) {
                SortMenu(selection: state.sortOrder, onChoose: actions.sortChosen)
            }
            if state.scope == .myList {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: actions.addTapped) {
                        Image(systemName: "plus")
                    }
                    .toolbarAddStyle()
                    .accessibilityLabel(Text("Add link or PDF", bundle: #bundle))
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch state.scope {
        case .myList: "My List"
        case .archive: "Archive"
        }
    }
}

/// Leading toolbar button with the account's first letter; opens Settings.
struct AvatarButton: View {
    let letter: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SrokaColor.onTertiaryContainer)
                .frame(width: 32, height: 32)
                .background(SrokaColor.tertiaryContainer, in: .circle)
        }
        .accessibilityLabel(Text("Settings", bundle: #bundle))
    }
}

/// Sort menu with the current order checked.
struct SortMenu: View {
    let selection: LibrarySortOrder
    let onChoose: (LibrarySortOrder) -> Void

    var body: some View {
        Menu {
            ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                Button {
                    onChoose(order)
                } label: {
                    if order == selection {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(Text("Sort", bundle: #bundle))
    }
}

extension LibrarySortOrder {
    var title: LocalizedStringResource {
        switch self {
        case .newest: LocalizedStringResource("Newest first", bundle: #bundle)
        case .oldest: LocalizedStringResource("Oldest first", bundle: #bundle)
        case .shortest: LocalizedStringResource("Shortest first", bundle: #bundle)
        case .longest: LocalizedStringResource("Longest first", bundle: #bundle)
        }
    }
}

/// The scrolling list: cards, chips, continue reading, rows or the empty state.
struct LibraryList: View {
    let state: LibraryListState
    let actions: LibraryActions
    let clipboardHasLink: Bool
    let scrollToTopCount: Int

    private static let topID = "library-top"

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear.frame(height: 0).id(Self.topID)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                accessories
                if let empty = state.emptyState {
                    LibraryEmptyView(
                        kind: empty,
                        extensionConnected: state.extensionConnected,
                        clipboardHasLink: clipboardHasLink,
                        actions: actions
                    )
                    .plainRow()
                } else {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        LibraryRow(
                            item: item,
                            state: state,
                            actions: actions,
                            peekEdge: index == 0 ? state.peekEdge : nil
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await actions.refresh() }
            .onChange(of: scrollToTopCount) {
                withAnimation { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    @ViewBuilder private var accessories: some View {
        if let card = state.uploadCard {
            UploadCard(kind: card, onDismiss: actions.dismissUploads).plainRow(top: 4, bottom: 10)
        }
        if let card = state.statusCard {
            SyncStatusCard(kind: card, onSignIn: actions.signInTapped).plainRow(top: 4, bottom: 10)
        }
        if state.emptyState != .onboarding {
            FilterChipRow(state: state, actions: actions).plainRow()
        }
        if !state.continueReading.isEmpty {
            ContinueReadingStrip(items: state.continueReading, onOpen: actions.itemTapped).plainRow(bottom: 8)
        }
    }
}

extension View {
    /// A non-item list row: full width paper, no separator.
    func plainRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(SrokaColor.background)
    }
}
