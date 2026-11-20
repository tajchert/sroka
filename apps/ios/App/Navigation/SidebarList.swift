import AppNavigation
import Dependencies
import LibraryFeature
import Observation
import SrokaCore
import SwiftUI

/// One selectable row of the iPad sidebar. Favorites and a tag are filters on My List, not destinations of their own.
enum SidebarItem: Hashable {
    case tab(AppTab)
    case favorites
    case tag(String)

    /// The row that matches the router and My List's filters. Filters the sidebar cannot express (Under 10 min, a
    /// combination) leave plain My List selected.
    @MainActor
    static func current(router: AppRouter, myList: LibraryViewModel) -> SidebarItem {
        guard router.selectedTab == .myList else { return .tab(router.selectedTab) }
        let filters = myList.activeFilters
        if filters == ListFilters(favoritesOnly: true) { return .favorites }
        if let tag = filters.tag, filters == ListFilters(tag: tag) { return .tag(tag) }
        return .tab(.myList)
    }

    /// Selects the row: My List with the matching filter, or the tab.
    @MainActor
    func apply(router: AppRouter, myList: LibraryViewModel) {
        switch self {
        case .tab(let tab):
            router.select(tab)
            if tab == .myList { myList.activeFilters = ListFilters() }
        case .favorites:
            router.select(.myList)
            myList.activeFilters = ListFilters(favoritesOnly: true)
        case .tag(let name):
            router.select(.myList)
            myList.activeFilters = ListFilters(tag: name)
        }
    }
}

/// The tags with their item counts, for the sidebar's "Tags" section.
@Observable @MainActor
final class SidebarTags {
    private(set) var tags: [TagCount] = []
    @ObservationIgnored @Dependency(\.tagRepository) private var repository

    func observe() async {
        for await tags in repository.observeTags() {
            self.tags = tags.filter { $0.count > 0 }
        }
    }
}

/// My List, Archive, Favorites and Search, then the tag list (design: "the tab bar's content in list form, with
/// the tag list underneath"). "All Tags" keeps the Tags tab (rename, delete) reachable.
struct SidebarList: View {
    @Bindable var router: AppRouter
    let models: ShellModels
    @State private var sidebarTags = SidebarTags()

    var body: some View {
        List(selection: selection) {
            Section {
                row(.tab(.myList), title: String(localized: AppTab.myList.title), image: "bookmark")
                row(.tab(.archive), title: String(localized: AppTab.archive.title), image: "archivebox")
                row(.favorites, title: String(localized: "Favorites"), image: "star")
                row(.tab(.search), title: String(localized: AppTab.search.title), image: "magnifyingglass")
            }
            Section(String(localized: "Tags")) {
                row(.tab(.tags), title: String(localized: "All Tags"), image: "tag")
                ForEach(sidebarTags.tags) { tag in
                    row(.tag(tag.name), title: tag.name, image: "tag", count: tag.count)
                }
            }
        }
        .navigationTitle("Sroka")
        .task { await sidebarTags.observe() }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem.current(router: router, myList: models.myList) },
            set: { $0?.apply(router: router, myList: models.myList) })
    }

    private func row(_ item: SidebarItem, title: String, image: String, count: Int? = nil) -> some View {
        Label(title, systemImage: image)
            .badge(count ?? 0)
            .tag(item)
            .accessibilityIdentifier("sidebar.\(title)")
    }
}
