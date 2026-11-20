import LibraryFeature
import SearchFeature
import SrokaDesign
import SwiftUI
import TagsFeature

/// Top-level destinations. Selection lives above the layout branch so rotating or resizing keeps it.
enum RootTab: String, Hashable, CaseIterable, Identifiable {
    case myList
    case archive
    case tags
    case search

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .myList: "My List"
        case .archive: "Archive"
        case .tags: "Tags"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .myList: "bookmark"
        case .archive: "archivebox"
        case .tags: "tag"
        case .search: "magnifyingglass"
        }
    }
}

/// Tab bar on compact width; sidebar + detail split on regular width (iPad, wide windows).
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: RootTab = .myList

    var body: some View {
        if sizeClass == .regular {
            RootSplitView(selection: $selection)
        } else {
            RootTabView(selection: $selection)
        }
    }
}

struct RootTabView: View {
    @Binding var selection: RootTab

    var body: some View {
        TabView(selection: $selection) {
            ForEach([RootTab.myList, .archive, .tags]) { tab in
                Tab(value: tab) {
                    NavigationStack { RootDestination(tab: tab) }
                } label: {
                    Label(String(localized: tab.title), systemImage: tab.systemImage)
                }
            }
            Tab(value: RootTab.search, role: .search) {
                NavigationStack { RootDestination(tab: .search) }
            }
        }
    }
}

struct RootSplitView: View {
    @Binding var selection: RootTab

    var body: some View {
        NavigationSplitView {
            List(RootTab.allCases, selection: optionalSelection) { tab in
                Label(String(localized: tab.title), systemImage: tab.systemImage)
            }
            .navigationTitle("Sroka")
        } detail: {
            NavigationStack { RootDestination(tab: selection) }
        }
    }

    private var optionalSelection: Binding<RootTab?> {
        Binding {
            selection
        } set: {
            if let tab = $0 { selection = tab }
        }
    }
}

/// Placeholder screens until the feature streams land.
struct RootDestination: View {
    let tab: RootTab

    var body: some View {
        Group {
            switch tab {
            case .myList: LibraryTab(scope: .myList)
            case .archive: LibraryTab(scope: .archive)
            case .tags: TagsPlaceholderView().navigationTitle(Text(tab.title))
            case .search: SearchPlaceholderView().navigationTitle(Text(tab.title))
            }
        }
    }
}

/// Owns the library view model for one tab. `LibraryIntent`s (open item, edit tags, Settings,
/// sign in, open URL) are handled here once the reader, tags and settings features land.
private struct LibraryTab: View {
    @State private var model: LibraryViewModel

    init(scope: LibraryScope) {
        _model = State(initialValue: LibraryViewModel(scope: scope))
    }

    var body: some View {
        LibraryView(model: model)
    }
}

#Preview {
    RootView()
}
