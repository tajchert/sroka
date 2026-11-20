import AppNavigation
import ReaderFeature
import SwiftUI
import TagsFeature

/// Compact width (iPhone, narrow windows): a tab bar with My List, Archive, Tags and the search tab, each tab with
/// its own `NavigationStack`. The reader is pushed on the tab it was opened from and hides the tab bar.
struct CompactShell: View {
    @Bindable var router: AppRouter
    let models: ShellModels

    var body: some View {
        TabView(selection: $router.selectedTab) {
            ForEach([AppTab.myList, .archive, .tags]) { tab in
                Tab(value: tab) {
                    CompactTabStack(router: router, models: models, tab: tab)
                } label: {
                    Label(String(localized: tab.title), systemImage: tab.systemImage)
                }
            }
            Tab(value: AppTab.search, role: .search) {
                CompactTabStack(router: router, models: models, tab: .search)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// One tab's stack. Its path is the router's path for the tab, so a deep link can push the reader onto it and a
/// reader opened from a tag's items sits on top of that list.
private struct CompactTabStack: View {
    @Bindable var router: AppRouter
    let models: ShellModels
    let tab: AppTab

    var body: some View {
        NavigationStack(path: $router[path: tab]) {
            TabRoot(tab: tab, models: models)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .reader(let itemId):
                        ReaderDestination(itemId: itemId, tab: tab, intents: models.intents)
                    case .tagItems(let tag):
                        TagItemsDestination(tag: tag, models: models)
                    }
                }
        }
    }
}

/// A tag's item list as a pushed screen. The model lives in the view's state, so it survives the reader being
/// pushed on top and goes away when the list is popped.
struct TagItemsDestination: View {
    let tag: String
    @State private var model: TagItemsViewModel

    init(tag: String, models: ShellModels) {
        self.tag = tag
        _model = State(initialValue: models.tags.itemsModel(for: tag))
    }

    var body: some View {
        TagItemsView(model: model)
    }
}

/// The reader as a pushed screen. `id` makes "Up next" and "Archive & next" build a fresh reader for the new
/// item instead of reusing the old one's state.
struct ReaderDestination: View {
    let itemId: String
    let tab: AppTab
    let intents: ShellIntents

    var body: some View {
        ReaderView(itemId: itemId) { intents.handle($0, in: tab) }
            .id(itemId)
            .toolbar(.hidden, for: .tabBar)
    }
}
