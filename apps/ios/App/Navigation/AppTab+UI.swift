import AppNavigation
import LibraryFeature
import SearchFeature
import SwiftUI
import TagsFeature

extension AppTab {
    var title: LocalizedStringResource {
        switch self {
        case .myList: "My List"
        case .archive: "Archive"
        case .tags: "Tags"
        case .search: "Search"
        }
    }

    /// Outline symbols; the tab bar and the sidebar fill the selected one themselves.
    var systemImage: String {
        switch self {
        case .myList: "bookmark"
        case .archive: "archivebox"
        case .tags: "tag"
        case .search: "magnifyingglass"
        }
    }
}

extension AppRouter {
    /// The sidebar `List` selects an optional value; clearing it (which a list can do) keeps the current tab.
    var sidebarSelection: AppTab? {
        get { selectedTab }
        set { if let newValue { selectedTab = newValue } }
    }
}

/// The root screen of a tab: the feature's own view, which expects a `NavigationStack` around it.
struct TabRoot: View {
    let tab: AppTab
    let models: ShellModels

    var body: some View {
        switch tab {
        case .myList: LibraryView(model: models.myList)
        case .archive: LibraryView(model: models.archive)
        case .tags: TagsView(model: models.tags)
        case .search: SearchView(model: models.search)
        }
    }
}
