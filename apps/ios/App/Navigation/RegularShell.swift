import AppNavigation
import ReaderFeature
import SwiftUI

/// Regular width (iPad, wide windows): sidebar with the four destinations, the selected destination's list in the
/// content column and the reader in the detail column. Reads the same router state as `CompactShell`, so a reader
/// open on a phone-sized window is still open after the window grows.
struct RegularShell: View {
    @Bindable var router: AppRouter
    let models: ShellModels

    var body: some View {
        NavigationSplitView {
            SidebarList(router: router)
        } content: {
            NavigationStack {
                TabRoot(tab: router.selectedTab, models: models)
            }
            .id(router.selectedTab)
        } detail: {
            NavigationStack {
                RegularDetail(router: router, models: models)
            }
        }
        .background { ShellShortcuts(router: router, models: models) }
    }
}

private struct SidebarList: View {
    @Bindable var router: AppRouter

    var body: some View {
        List(AppTab.allCases, selection: $router.sidebarSelection) { tab in
            Label(String(localized: tab.title), systemImage: tab.systemImage)
        }
        .navigationTitle("Sroka")
    }
}

/// The reader of the selected destination, or an invitation to pick something.
private struct RegularDetail: View {
    let router: AppRouter
    let models: ShellModels

    var body: some View {
        if let itemId = router.presentedReaderItemId {
            ReaderView(itemId: itemId) { models.intents.handle($0, in: router.selectedTab) }
                .id(itemId)
        } else {
            ContentUnavailableView {
                Label(String(localized: "Pick something to read"), systemImage: "book")
            } description: {
                Text("Choose an article from the list.")
            }
        }
    }
}

/// Keyboard shortcuts the design lists for iPad: ⌘N add a link, ⌘F search, ⌘R fetch new articles. They need no
/// visible control, so they live in zero-size buttons behind the shell.
private struct ShellShortcuts: View {
    let router: AppRouter
    let models: ShellModels

    var body: some View {
        ZStack {
            Button(String(localized: "Add link or PDF")) {
                router.select(.myList)
                models.myList.addButtonTapped()
            }
            .keyboardShortcut("n")
            Button(String(localized: "Search")) { router.select(.search) }
                .keyboardShortcut("f")
            Button(String(localized: "Fetch new articles")) {
                Task { await refreshCurrentList() }
            }
            .keyboardShortcut("r")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func refreshCurrentList() async {
        switch router.selectedTab {
        case .archive: await models.archive.refresh()
        case .myList, .tags, .search: await models.myList.refresh()
        }
    }
}
