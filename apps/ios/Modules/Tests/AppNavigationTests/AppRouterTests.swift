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

    /// The router owns the Tags stack: a tag's item list is a route, and the reader opened from it goes on top.
    @Test func `Tags root to tag items to reader and back goes through the tag's items`() {
        let router = signedInRouter()
        router.select(.tags)
        router.openTagItems("birds")
        #expect(router[path: .tags] == [.tagItems(tag: "birds")])
        #expect(router.presentedReaderItemId == nil)

        router.open(itemId: "tagged-1")
        #expect(router[path: .tags] == [.tagItems(tag: "birds"), .reader(itemId: "tagged-1")])
        #expect(router.readerItemId(in: .tags) == "tagged-1")
        #expect(router[path: .myList].isEmpty)

        router.closeReader()
        #expect(router[path: .tags] == [.tagItems(tag: "birds")])
        // Back from the list (the stack's own pop) lands on the Tags root.
        router[path: .tags].removeLast()
        #expect(router[path: .tags].isEmpty)
        #expect(router.selectedTab == .tags)
    }

    @Test func `Closing a screen that is not a reader leaves the stack alone`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.closeReader()
        #expect(router[path: .tags] == [.tagItems(tag: "birds")])
    }

    @Test func `Opening a tag selects the Tags tab and a second tap does not stack lists`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        #expect(router.selectedTab == .tags)
        router.openTagItems("science")
        #expect(router[path: .tags] == [.tagItems(tag: "science")])
        router.openTagItems("")
        #expect(router[path: .tags] == [.tagItems(tag: "science")])
    }

    @Test func `Up next from a tag's reader replaces the reader and keeps the list below`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.open(itemId: "a")
        router.openNext(itemId: "b", in: .tags)
        #expect(router[path: .tags] == [.tagItems(tag: "birds"), .reader(itemId: "b")])
    }

    @Test func `Archive and next from a tag's reader stays on top of the tag's items`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.open(itemId: "tagged-1")
        router.readerArchivedAndOpenNext(archivedId: "tagged-1", nextId: "tagged-2")
        #expect(router[path: .tags] == [.tagItems(tag: "birds"), .reader(itemId: "tagged-2")])
        router.closeReader()
        #expect(router[path: .tags] == [.tagItems(tag: "birds")])
    }

    @Test func `Archiving in a tag's reader returns to the tag's items and offers undo`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.open(itemId: "a")
        router.readerArchived(itemId: "a")
        #expect(router[path: .tags] == [.tagItems(tag: "birds")])
        #expect(router.toast?.kind == .archived(itemId: "a"))
    }

    @Test func `Deleting in a tag's reader returns to the tag's items`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.open(itemId: "a")
        router.itemDeleted("a")
        #expect(router[path: .tags] == [.tagItems(tag: "birds")])
    }

    @Test func `A tag that is renamed or deleted drops its list and leaves no dead screen`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.tagGone("birds")
        #expect(router[path: .tags].isEmpty)

        router.tagGone("birds")
        #expect(router[path: .tags].isEmpty)
    }

    @Test func `A tag that goes away under an open reader keeps the reader and drops only the list`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.open(itemId: "a")
        router.tagGone("birds")
        #expect(router[path: .tags] == [.reader(itemId: "a")])
        router.tagGone("other")
        #expect(router[path: .tags] == [.reader(itemId: "a")])
    }

    @Test func `The content column's path hides the reader and popping it also closes the reader`() {
        let router = signedInRouter()
        router.openTagItems("birds")
        router.open(itemId: "a")
        #expect(router[listPath: .tags] == [.tagItems(tag: "birds")])
        // Setting the same list keeps the reader (the column re-renders without a pop).
        router[listPath: .tags] = [.tagItems(tag: "birds")]
        #expect(router.readerItemId(in: .tags) == "a")
        // Back in the column pops the list and the reader detail with it.
        router[listPath: .tags] = []
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
        #expect(router.paths[.myList] == [.reader(itemId: "b")])
    }

    @Test func `Up next replaces the reader on the same tab`() {
        let router = signedInRouter()
        router.select(.tags)
        router.open(itemId: "a")
        router.openNext(itemId: "b", in: .tags)
        #expect(router.paths[.tags] == [.reader(itemId: "b")])
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
        #expect(router.paths[.archive] == [.reader(itemId: "b")])
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

    @Test func `Another account arriving without a sign-out in between starts on a fresh shell`() {
        let router = signedInRouter()
        router.select(.archive)
        router.open(itemId: "a")
        router.presentTagEditor(itemId: "a")
        router.readerArchived(itemId: "a")
        router.sessionChanged(.signedIn(email: "other@example.com"))
        #expect(router.selectedTab == .myList)
        #expect(router.paths.isEmpty)
        #expect(router.sheet == nil)
        #expect(router.toast == nil)
    }

    @Test func `Leaving an account changes the generation the shell models are keyed by, expiry does not`() {
        let router = signedInRouter()
        let first = router.accountGeneration
        router.sessionChanged(.expired(email: "reader@example.com"))
        router.sessionChanged(.signedIn(email: "Reader@example.com"))
        #expect(router.accountGeneration == first)
        router.sessionChanged(.signedIn(email: "other@example.com"))
        let second = router.accountGeneration
        #expect(second != first)
        // A sign-out delivered between two accounts: the next account still gets fresh models.
        router.sessionChanged(.signedOut)
        router.sessionChanged(.signedIn(email: "third@example.com"))
        #expect(router.accountGeneration != second)
    }

    @Test func `The same account signing in again keeps its place`() {
        let router = signedInRouter()
        router.select(.archive)
        router.open(itemId: "a")
        router.sessionChanged(.expired(email: "reader@example.com"))
        router.presentSignInAgain()
        router.sessionChanged(.signedIn(email: "Reader@example.com"))
        #expect(router.selectedTab == .archive)
        #expect(router.presentedReaderItemId == "a")
        #expect(!router.isSignInAgainPresented)
    }

    @Test func `A deep link to an item that is not there closes back to the screen below`() {
        let router = signedInRouter()
        router.openTagItems("work")
        router.open(itemId: "gone")
        // The reader reports a missing item with its close intent (ReaderView, `.missing`).
        router.closeReader(in: .tags)
        #expect(router.presentedReaderItemId == nil)
        #expect(router[path: .tags] == [.tagItems(tag: "work")])
        #expect(router.pendingItemId == nil)
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
