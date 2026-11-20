import SrokaCore
import Testing

@testable import AppNavigation

@MainActor
struct AppRouterTests {
    private func signedInRouter() -> AppRouter {
        AppRouter(session: .signedIn(email: "reader@example.com"))
    }

    // MARK: Tabs

    @Test func `A new router starts on My List with no paths`() {
        let router = signedInRouter()
        #expect(router.selectedTab == .myList)
        #expect(router.presentedReaderItemId == nil)
        #expect(router.sheet == nil)
    }

    @Test(arguments: AppTab.allCases)
    func `Selecting a tab shows it and leaves the other stacks alone`(tab: AppTab) {
        let router = signedInRouter()
        router.open(itemId: "first")
        router.select(tab)
        #expect(router.selectedTab == tab)
        #expect(router.readerItemId(in: .myList) == "first")
    }

    @Test func `Re-tapping a tab pops it to its root`() {
        let router = signedInRouter()
        router.open(itemId: "first")
        router.popToRoot()
        #expect(router.presentedReaderItemId == nil)
    }

    // MARK: Opening items

    /// The Tags tab pushes a tag's item list itself (`navigationDestination(item:)`, not part of `paths`); the
    /// reader opened from that list goes on the same tab's typed path, and leaving it returns to the list.
    @Test func `A reader opened from a tag's items lives on the Tags path and closes back to it`() {
        let router = signedInRouter()
        router.select(.tags)
        router.open(itemId: "tagged-1")
        #expect(router[path: .tags] == [ReaderRoute(itemId: "tagged-1")])
        #expect(router.readerItemId(in: .tags) == "tagged-1")
        #expect(router[path: .myList].isEmpty)

        router.closeReader()
        #expect(router[path: .tags].isEmpty)
        #expect(router.selectedTab == .tags)
    }

    @Test func `Archive and next from a tag's reader stays on the Tags path`() {
        let router = signedInRouter()
        router.select(.tags)
        router.open(itemId: "tagged-1")
        router.readerArchivedAndOpenNext(archivedId: "tagged-1", nextId: "tagged-2")
        #expect(router[path: .tags] == [ReaderRoute(itemId: "tagged-2")])
        router.closeReader()
        #expect(router[path: .tags].isEmpty)
    }

    @Test(arguments: AppTab.allCases)
    func `Opening an item from a tab pushes the reader on that tab`(tab: AppTab) {
        let router = signedInRouter()
        router.select(tab)
        router.open(itemId: "item-1")
        #expect(router.readerItemId(in: tab) == "item-1")
        #expect(router.presentedReaderItemId == "item-1")
        for other in AppTab.allCases where other != tab {
            #expect(router.readerItemId(in: other) == nil)
        }
    }

    @Test func `Opening another item replaces the reader instead of stacking readers`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.open(itemId: "b")
        #expect(router.paths[.myList] == [ReaderRoute(itemId: "b")])
    }

    @Test func `Up next replaces the reader on the same tab`() {
        let router = signedInRouter()
        router.select(.tags)
        router.open(itemId: "a")
        router.openNext(itemId: "b", in: .tags)
        #expect(router.paths[.tags] == [ReaderRoute(itemId: "b")])
    }

    @Test(arguments: ["", "../etc", "has space", String(repeating: "x", count: 65), "a/b"])
    func `Invalid item ids never open a reader`(id: String) {
        let router = signedInRouter()
        router.open(itemId: id)
        router.openNext(itemId: id)
        router.presentTagEditor(itemId: id)
        #expect(router.presentedReaderItemId == nil)
        #expect(router.sheet == nil)
    }

    @Test func `Opening an item closes the open sheet`() {
        let router = signedInRouter()
        router.presentSettings()
        router.open(itemId: "a")
        #expect(router.sheet == nil)
        #expect(router.presentedReaderItemId == "a")
    }

    @Test func `Closing the reader pops it from its tab`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.closeReader()
        #expect(router.presentedReaderItemId == nil)
        router.closeReader()
        #expect(router.presentedReaderItemId == nil)
    }

    // MARK: Deep links

    @Test func `A deep link before the session is known is held and opens once signed in`() {
        let router = AppRouter()
        router.open(itemId: "from-link")
        #expect(router.pendingItemId == "from-link")
        #expect(router.presentedReaderItemId == nil)
        router.sessionChanged(.signedIn(email: "reader@example.com"))
        #expect(router.presentedReaderItemId == "from-link")
        #expect(router.pendingItemId == nil)
    }

    @Test func `A deep link while signed out waits for the next sign-in`() {
        let router = AppRouter(session: .signedOut)
        router.open(itemId: "from-link")
        #expect(router.showsAuth)
        #expect(router.presentedReaderItemId == nil)
        router.sessionChanged(.signedIn(email: "reader@example.com"))
        #expect(router.showsShell)
        #expect(router.presentedReaderItemId == "from-link")
    }

    @Test func `A deep link opens at once when the shell is already on screen`() {
        let router = signedInRouter()
        router.select(.search)
        router.open(itemId: "from-link")
        #expect(router.readerItemId(in: .search) == "from-link")
        #expect(router.pendingItemId == nil)
    }

    @Test func `A held deep link survives a sign-out`() {
        let router = signedInRouter()
        router.sessionChanged(.signedOut)
        router.open(itemId: "from-link")
        router.sessionChanged(.signedOut)
        #expect(router.pendingItemId == "from-link")
    }

    @Test func `An expired session still shows the shell and opens deep links`() {
        let router = AppRouter(session: .expired(email: "reader@example.com"))
        #expect(router.showsShell)
        router.open(itemId: "from-link")
        #expect(router.presentedReaderItemId == "from-link")
    }

    // MARK: Archive

    @Test func `Archiving from the reader pops it and offers undo`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.readerArchived(itemId: "a")
        #expect(router.presentedReaderItemId == nil)
        #expect(router.toast?.kind == .archived(itemId: "a"))
    }

    @Test func `Archive and open next puts the next item in the same place and offers undo`() {
        let router = signedInRouter()
        router.select(.archive)
        router.open(itemId: "a")
        router.readerArchivedAndOpenNext(archivedId: "a", nextId: "b")
        #expect(router.paths[.archive] == [ReaderRoute(itemId: "b")])
        #expect(router.toast?.kind == .archived(itemId: "a"))
    }

    @Test func `Archive and open next with an invalid next id just leaves the reader`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.readerArchivedAndOpenNext(archivedId: "a", nextId: "../bad")
        #expect(router.presentedReaderItemId == nil)
        #expect(router.toast?.kind == .archived(itemId: "a"))
    }

    @Test func `A newer toast is not dismissed by an older toast's timer`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.readerArchived(itemId: "a")
        let first = router.toast?.id ?? -1
        router.open(itemId: "b")
        router.readerArchived(itemId: "b")
        router.dismissToast(id: first)
        #expect(router.toast?.kind == .archived(itemId: "b"))
        router.dismissToast(id: router.toast?.id ?? -1)
        #expect(router.toast == nil)
    }

    // MARK: Delete

    @Test func `Deleting the open item closes its reader`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.itemDeleted("a")
        #expect(router.presentedReaderItemId == nil)
    }

    @Test func `Deleting an item closes readers on other tabs and its tag editor and undo toast`() {
        let router = signedInRouter()
        router.select(.tags)
        router.open(itemId: "a")
        router.select(.myList)
        router.open(itemId: "b")
        router.readerArchived(itemId: "a")
        router.presentTagEditor(itemId: "a")
        router.itemDeleted("a")
        #expect(router.readerItemId(in: .tags) == nil)
        #expect(router.readerItemId(in: .myList) == "b")
        #expect(router.sheet == nil)
        #expect(router.toast == nil)
    }

    @Test func `Deleting another item leaves the open reader alone`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.itemDeleted("other")
        #expect(router.presentedReaderItemId == "a")
    }

    // MARK: Sheets

    @Test func `The tag editor and Settings share one sheet slot`() {
        let router = signedInRouter()
        router.presentTagEditor(itemId: "a")
        #expect(router.sheet == .tagEditor(itemId: "a"))
        router.presentSettings()
        #expect(router.sheet == .settings)
        router.dismissSheet()
        #expect(router.sheet == nil)
    }

    @Test func `The tag editor opens over an open reader without closing it`() {
        let router = signedInRouter()
        router.open(itemId: "a")
        router.presentTagEditor(itemId: "a")
        #expect(router.presentedReaderItemId == "a")
        #expect(router.sheet == .tagEditor(itemId: "a"))
    }

    @Test func `Sign in again is only offered on the shell and ends when signed in`() {
        let signedOut = AppRouter(session: .signedOut)
        signedOut.presentSignInAgain()
        #expect(!signedOut.isSignInAgainPresented)

        let router = AppRouter(session: .expired(email: "reader@example.com"))
        router.presentSignInAgain()
        #expect(router.isSignInAgainPresented)
        router.sessionChanged(.signedIn(email: "reader@example.com"))
        #expect(!router.isSignInAgainPresented)
    }

    // MARK: Sign-out

    @Test func `Signing out resets tabs, paths, sheets, covers and toasts`() {
        let router = signedInRouter()
        router.select(.tags)
        router.open(itemId: "a")
        router.select(.search)
        router.open(itemId: "b")
        router.presentSettings()
        router.readerArchived(itemId: "b")
        router.sessionChanged(.signedOut)
        #expect(router.selectedTab == .myList)
        #expect(router.paths.isEmpty)
        #expect(router.sheet == nil)
        #expect(!router.isSignInAgainPresented)
        #expect(router.toast == nil)
        #expect(router.showsAuth)
        #expect(!router.showsShell)
    }

    @Test func `The next account starts on a fresh shell`() {
        let router = signedInRouter()
        router.select(.archive)
        router.open(itemId: "a")
        router.sessionChanged(.signedOut)
        router.sessionChanged(.signedIn(email: "other@example.com"))
        #expect(router.selectedTab == .myList)
        #expect(router.presentedReaderItemId == nil)
    }

    @Test func `No root is shown until the session is known`() {
        let router = AppRouter()
        #expect(!router.showsShell)
        #expect(!router.showsAuth)
    }
}

struct VersionGateTests {
    @Test func `Only an update requirement blocks`() {
        #expect(!VersionGate.open.isBlocking)
        #expect(VersionGate.updateRequired(storeURL: nil).isBlocking)
    }
}
