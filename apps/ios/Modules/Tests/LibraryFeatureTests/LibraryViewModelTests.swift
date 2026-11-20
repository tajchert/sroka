import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Testing

@testable import LibraryFeature

@MainActor
struct LibraryViewModelTests {
    let fakes: Fakes
    let clock = TestClock<Duration>()
    var intents: IntentLog

    /// Records the intents the app root would handle.
    final class IntentLog {
        var values: [LibraryIntent] = []
    }

    init(
        items: [Item] = Fixtures.items,
        preferences: UserPreferences = UserPreferences(swipeHintShown: true),
        syncStatus: SyncStatus = Fixtures.syncStatus,
        session: SessionState = .signedIn(email: Fixtures.email)
    ) {
        fakes = Fakes(items: items, session: session, preferences: preferences, syncStatus: syncStatus)
        intents = IntentLog()
    }

    func makeModel(_ scope: LibraryScope = .myList, started: Bool = true) async -> LibraryViewModel {
        let log = intents
        let fakes = fakes
        let clock = clock
        let model = withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
        } operation: {
            LibraryViewModel(scope: scope) { log.values.append($0) }
        }
        if started {
            model.start()
            await until { model.state.isLoaded }
        }
        return model
    }

    /// Lets the observation tasks run until `condition` holds (no sleeping).
    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    func text(_ resource: LocalizedStringResource?) -> String? {
        resource.map { String(localized: $0) }
    }

    func summary(_ item: Item) -> ItemSummary { item.summary }

    // MARK: Lists, filters, sort, paging

    @Test func `My List shows unread items newest first`() async {
        let model = await makeModel()
        #expect(
            model.state.items.map(\.id) == [
                "a3-pending", "a1-long-read", "a2-short-news", "a4-paywalled", "a5-partial", "p1-pdf",
            ])
        #expect(model.state.emptyState == nil)
    }

    @Test func `Archive shows archived items`() async {
        let model = await makeModel(.archive)
        #expect(Set(model.state.items.map(\.id)) == ["a6-archived", "a7-archived-fav"])
        #expect(model.state.continueReading.isEmpty)
    }

    @Test func `Favorites filter keeps only favorites`() async {
        let model = await makeModel()
        model.favoritesFilterTapped()
        await until { model.state.items.count == 1 }
        #expect(model.state.items.map(\.id) == ["a2-short-news"])
        #expect(model.state.filters.favoritesOnly)
        model.favoritesFilterTapped()
        await until { model.state.items.count == 6 }
        #expect(!model.state.filters.isActive)
    }

    @Test func `Under ten minutes keeps articles of at most nine minutes`() async {
        let model = await makeModel()
        model.underTenFilterTapped()
        await until { model.state.items.count == 1 }
        #expect(model.state.items.map(\.id) == ["a2-short-news"])
    }

    @Test func `Filters combine with AND`() async {
        let model = await makeModel()
        model.favoritesFilterTapped()
        model.tagChipTapped("finance")
        await until { model.state.items.isEmpty }
        #expect(model.state.emptyState == .noMatches)
        model.tagChipTapped("finance")
        model.favoritesFilterTapped()
        await until { model.state.items.count == 6 }
        #expect(model.state.emptyState == nil)
    }

    @Test func `Clear filters resets every filter`() async {
        let model = await makeModel()
        model.favoritesFilterTapped()
        model.underTenFilterTapped()
        model.tagChipTapped("birds")
        model.clearFiltersTapped()
        #expect(model.state.filters == ListFilters())
        await until { model.state.items.count == 6 }
    }

    @Test func `Tag chips are the five most used tags with the selected tag first`() async {
        let items = (0..<8).map { index in
            Item(
                id: "t\(index)", url: "https://example.com/\(index)", title: "T\(index)", readingMinutes: 5,
                parseStatus: .ok,
                savedAt: Fixtures.now.addingTimeInterval(Double(-index)),
                tags: (0...index).map { "tag\($0)" }
            )
        }
        let test = LibraryViewModelTests(items: items)
        let model = await test.makeModel()
        await test.until { !model.state.tagChips.isEmpty }
        #expect(model.state.tagChips == ["tag0", "tag1", "tag2", "tag3", "tag4"])
        model.tagChipTapped("tag7")
        #expect(model.state.tagChips == ["tag7", "tag0", "tag1", "tag2", "tag3", "tag4"])
    }

    @Test func `Sorting persists the choice and reorders`() async {
        let model = await makeModel()
        await model.sortChosen(.oldest)
        await until { model.state.items.first?.id == "p1-pdf" }
        #expect(model.state.sortOrder == .oldest)
        #expect(fakes.settings.state.value.sortOrder == .oldest)
        await model.sortChosen(.shortest)
        await until { model.state.items.first?.id == "a2-short-news" }
    }

    @Test func `The stored sort order applies when preferences load`() async {
        let test = LibraryViewModelTests(preferences: UserPreferences(sortOrder: .oldest, swipeHintShown: true))
        let model = await test.makeModel()
        await test.until { model.state.items.first?.id == "p1-pdf" }
        #expect(model.state.sortOrder == .oldest)
    }

    @Test func `The list pages in and grows near the end`() async {
        let test = LibraryViewModelTests(items: Fixtures.manyItems(120))
        let model = await test.makeModel()
        #expect(model.state.items.count == Limits.listPageSize)
        #expect(model.state.hasMore)
        model.itemAppeared(model.state.items[0])
        #expect(model.state.items.count == Limits.listPageSize)
        model.itemAppeared(model.state.items[model.state.items.count - 1])
        await test.until { model.state.items.count == 2 * Limits.listPageSize }
        model.itemAppeared(model.state.items[model.state.items.count - 1])
        await test.until { model.state.items.count == 120 }
        #expect(!model.state.hasMore)
    }

    @Test func `Continue reading shows only on an unfiltered My List`() async {
        let model = await makeModel()
        await until { !model.state.continueReading.isEmpty }
        #expect(model.state.continueReading.map(\.id) == ["a1-long-read"])
        model.favoritesFilterTapped()
        #expect(model.state.continueReading.isEmpty)
        model.favoritesFilterTapped()
        #expect(model.state.continueReading.count == 1)
    }

    // MARK: Empty states and status card

    @Test func `The empty state waits for the first page`() async {
        let test = LibraryViewModelTests(items: [])
        let model = await test.makeModel(started: false)
        #expect(!model.state.isLoaded)
        #expect(model.state.emptyState == nil)
        model.start()
        await test.until { model.state.isLoaded }
        #expect(model.state.emptyState == .onboarding)
    }

    @Test func `An empty Archive says so and a filtered empty list offers to clear`() async {
        let test = LibraryViewModelTests(items: [])
        let archive = await test.makeModel(.archive)
        #expect(archive.state.emptyState == .archiveEmpty)
        let myList = await test.makeModel()
        myList.favoritesFilterTapped()
        await test.until { myList.state.emptyState == .noMatches }
        #expect(myList.state.emptyState == .noMatches)
    }

    @Test func `Onboarding marks Save from Chrome done when the extension is connected`() async {
        let test = LibraryViewModelTests(items: [])
        test.fakes.account.clients.send(ConnectedClients(extensionClient: true, android: false, ios: false))
        let model = await test.makeModel()
        await test.until { model.state.extensionConnected }
        #expect(model.state.extensionConnected)
    }

    @Test func `The sync card follows the priority sign in, resync, offline, downloading`() async {
        let model = await makeModel()
        #expect(model.state.statusCard == nil)

        fakes.syncStatus.state.send(SyncStatus(phase: .downloading(done: 2, total: 5, currentTitle: nil)))
        await until { model.state.statusCard == .downloading(done: 2, total: 5) }

        fakes.syncStatus.state.send(SyncStatus(phase: .downloading(done: 5, total: 5, currentTitle: nil)))
        await until { model.state.statusCard == nil }

        fakes.syncStatus.state.send(SyncStatus(phase: .offline, pendingOps: 2))
        await until { model.state.statusCard == .offline(pendingChanges: 2) }

        fakes.syncStatus.state.send(SyncStatus(phase: .resyncing(fraction: 0.4), pendingOps: 2))
        await until { model.state.statusCard == .resyncing(fraction: 0.4) }

        fakes.syncStatus.state.send(SyncStatus(phase: .error(.auth)))
        await until { model.state.statusCard == .signInAgain }

        fakes.syncStatus.state.send(SyncStatus(phase: .error(.network)))
        await until { model.state.statusCard == nil }
    }

    @Test func `An expired session shows the sign in card above everything`() async {
        let test = LibraryViewModelTests(
            syncStatus: SyncStatus(phase: .offline), session: .expired(email: Fixtures.email))
        let model = await test.makeModel()
        await test.until { model.state.statusCard != nil }
        #expect(model.state.statusCard == .signInAgain)
        model.signInTapped()
        #expect(test.intents.values == [.signInAgain])
    }

    @Test func `The avatar shows the first letter of the account email`() async {
        let model = await makeModel()
        await until { model.state.avatarLetter == "R" }
        #expect(model.state.avatarLetter == "R")
        #expect(LibraryViewModel.avatarLetter(for: .signedIn(email: "_9lives@example.com")) == "9")
        #expect(LibraryViewModel.avatarLetter(for: .signedOut) == "?")
        model.avatarTapped()
        #expect(intents.values == [.openSettings])
    }

    // MARK: Row actions

    @Test func `The swipe preferences decide the action behind each edge`() async {
        let test = LibraryViewModelTests(
            preferences: UserPreferences(swipeLeftAction: .favorite, swipeRightAction: .tags, swipeHintShown: true))
        let model = await test.makeModel()
        await test.until { model.state.swipeLeftAction == .favorite }
        #expect(model.state.action(for: .trailing) == .favorite)
        #expect(model.state.action(for: .leading) == .tags)
        let item = model.state.items[1]
        await model.swiped(.trailing, item: item)
        #expect(test.fakes.library.item(id: item.id)?.isFavorite == !item.isFavorite)
        await model.swiped(.leading, item: item)
        #expect(test.intents.values == [.editTags(id: item.id)])
    }

    @Test func `A swipe with no action does nothing`() async {
        let model = await makeModel()
        let item = model.state.items[0]
        await model.swiped(.leading, item: item)
        #expect(model.toast == nil)
        #expect(fakes.library.item(id: item.id)?.status == .unread)
    }

    @Test func `Archive swipe archives, toasts and undo restores`() async {
        let model = await makeModel()
        let item = model.state.items[1]
        await model.swiped(.trailing, item: item)
        #expect(fakes.library.item(id: item.id)?.status == .archived)
        #expect(text(model.toast?.message) == "Archived")
        await until { model.state.items.count == 5 }
        await model.toastActionTapped()
        #expect(fakes.library.item(id: item.id)?.status == .unread)
        #expect(model.toast == nil)
    }

    @Test func `Archiving an archived item moves it back to My List`() async {
        let model = await makeModel(.archive)
        let item = model.state.items[0]
        await model.archiveTapped(item)
        #expect(fakes.library.item(id: item.id)?.status == .unread)
        #expect(text(model.toast?.message) == "Moved to My List")
    }

    @Test func `Archive toasts say changes sync later while offline`() async {
        let model = await makeModel()
        fakes.syncStatus.state.send(SyncStatus(phase: .offline))
        await until { model.state.statusCard != nil }
        await model.archiveTapped(model.state.items[0])
        #expect(text(model.toast?.message) == "Archived. Syncs when you’re online.")
    }

    @Test func `Favorite toggles with an undo`() async {
        let model = await makeModel()
        let item = model.state.items[1]
        await model.favoriteTapped(item)
        #expect(fakes.library.item(id: item.id)?.isFavorite == true)
        #expect(text(model.toast?.message) == "Added to favorites")
        await model.toastActionTapped()
        #expect(fakes.library.item(id: item.id)?.isFavorite == false)
        let favorite = ItemSummary(
            id: "a2-short-news", displayTitle: "x", domain: "x", isFavorite: true, savedAt: Fixtures.now)
        await model.favoriteTapped(favorite)
        #expect(text(model.toast?.message) == "Removed from favorites")
    }

    @Test func `The toast disappears after four seconds`() async {
        let model = await makeModel()
        await model.favoriteTapped(model.state.items[0])
        #expect(model.toast != nil)
        await clock.advance(by: .seconds(3))
        #expect(model.toast != nil)
        await clock.advance(by: .seconds(1))
        await until { model.toast == nil }
        #expect(model.toast == nil)
    }

    @Test func `A new toast replaces the previous one and restarts the timer`() async {
        let model = await makeModel()
        await model.favoriteTapped(model.state.items[0])
        let first = model.toast?.id
        await clock.advance(by: .seconds(3))
        await model.archiveTapped(model.state.items[1])
        #expect(model.toast?.id != first)
        await clock.advance(by: .seconds(3))
        #expect(model.toast != nil)
    }

    @Test func `Delete asks first, then deletes`() async {
        let model = await makeModel()
        let item = model.state.items[0]
        model.deleteTapped(item)
        #expect(model.isConfirmingDelete)
        #expect(model.itemPendingDeletion == item)
        model.cancelDeleteTapped()
        #expect(fakes.library.item(id: item.id) != nil)
        model.deleteTapped(item)
        await model.confirmDeleteTapped()
        #expect(fakes.library.item(id: item.id) == nil)
        #expect(text(model.toast?.message) == "Article deleted")
        #expect(model.warningFeedbackCount == 1)
    }

    @Test func `Context actions open, tag, share and refresh`() async {
        let model = await makeModel()
        let item = model.state.items[1]
        model.itemTapped(item)
        model.editTagsTapped(item)
        await model.openOriginalTapped(item)
        #expect(
            intents.values == [
                .openItem(id: item.id), .editTags(id: item.id),
                .openURL(URL(string: "https://www.example.com/essays/the-slow-web")!),
            ])
        await model.shareLinkTapped(item)
        #expect(model.shareRequest?.url.absoluteString == "https://www.example.com/essays/the-slow-web")
        await model.refreshArticleTapped(item)
        #expect(text(model.toast?.message) == "Refreshing article")
    }

    @Test func `Pull to refresh fetches new articles`() async {
        let model = await makeModel()
        let refreshing = Task { await model.refresh() }
        await Task.yield()
        await clock.advance(by: .milliseconds(500))
        await refreshing.value
        #expect(fakes.syncController.calls.calls == [.fetchNewArticles])
    }

    @Test func `Fetch results become toasts`() async {
        let model = await makeModel()
        fakes.syncStatus.eventSubject.send(.fetchCompleted(newlyDownloaded: 0))
        await until { model.toast != nil }
        #expect(text(model.toast?.message) == "Library is up to date")
        fakes.syncStatus.eventSubject.send(.fetchCompleted(newlyDownloaded: 3))
        await until { text(model.toast?.message) == "3 articles ready offline" }
        fakes.syncStatus.eventSubject.send(.fetchFailed(.network))
        await until { text(model.toast?.message) == "Couldn’t fetch: no connection" }
        #expect(text(model.toast?.message) == "Couldn’t fetch: no connection")
    }

    // MARK: Swipe hint

    @Test func `The first row peeks at the first configured swipe until the hint was shown`() async {
        let test = LibraryViewModelTests(preferences: UserPreferences(swipeHintShown: false))
        let model = await test.makeModel()
        await test.until { model.state.peekEdge != nil }
        #expect(model.state.peekEdge == .trailing)
        await model.swipeHintFinished()
        #expect(model.state.peekEdge == nil)
        #expect(test.fakes.settings.state.value.swipeHintShown)
    }

    @Test func `The peek falls back to the right swipe and is skipped without actions`() async {
        let right = LibraryViewModelTests(
            preferences: UserPreferences(swipeLeftAction: .none, swipeRightAction: .favorite, swipeHintShown: false))
        let model = await right.makeModel()
        await right.until { model.state.peekEdge != nil }
        #expect(model.state.peekEdge == .leading)

        let none = LibraryViewModelTests(
            preferences: UserPreferences(swipeLeftAction: .none, swipeRightAction: .none, swipeHintShown: false))
        let quiet = await none.makeModel()
        await none.until { quiet.state.swipeLeftAction == .none }
        #expect(quiet.state.peekEdge == nil)
    }

    // MARK: Add link or PDF

    @Test func `Saving a link validates the address`() async {
        let model = await makeModel()
        model.addButtonTapped()
        #expect(model.isAddSheetPresented)
        model.addLinkText = "not a link"
        await model.saveLinkTapped()
        #expect(model.isAddLinkInvalid)
        #expect(model.isAddSheetPresented)
        model.addLinkText = "not a link!"
        #expect(!model.isAddLinkInvalid)
    }

    @Test func `A valid link is saved, the sheet closes and the list scrolls to the top`() async {
        let model = await makeModel()
        model.addButtonTapped()
        model.addLinkText = "  Look: https://example.com/new-story. "
        await model.saveLinkTapped()
        #expect(!model.isAddSheetPresented)
        #expect(text(model.toast?.message) == "Saved")
        #expect(model.scrollToTopCount == 1)
        #expect(model.successFeedbackCount == 1)
        #expect(fakes.library.items.value.contains { $0.url == "https://example.com/new-story" })
    }

    @Test func `A duplicate link moves to My List with its own message`() async {
        let model = await makeModel()
        model.addLinkText = "https://www.example.com/essays/the-slow-web"
        await model.saveLinkTapped()
        #expect(text(model.toast?.message) == "Already saved. Moved to My List.")
        #expect(!model.isAddSheetPresented)
    }

    @Test func `Pasting fills the field with the link in the text`() async {
        let model = await makeModel()
        model.pasted(["See https://example.com/p today"])
        #expect(model.addLinkText == "https://example.com/p")
    }

    @Test func `Saving from the clipboard chip saves without the sheet`() async {
        let model = await makeModel()
        await model.saveClipboardLinkTapped(["nothing here"])
        #expect(text(model.toast?.message) == "Couldn’t find a link to save")
        await model.saveClipboardLinkTapped(["https://example.com/clip"])
        #expect(text(model.toast?.message) == "Saved")
    }

    @Test func `Chosen PDFs go to the uploader`() async {
        let model = await makeModel()
        model.choosePdfTapped()
        #expect(model.isFileImporterPresented)
        await model.pdfFilesPicked(.success([URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")]))
        #expect(fakes.pdfUploader.state.value.map(\.fileName) == ["a.pdf", "b.pdf"])
        #expect(text(model.toast?.message) == "Uploading 2 PDFs")
        await until { model.state.uploadCard != nil }
        #expect(model.state.uploadCard == .uploading(count: 2, progress: 0))
    }

    @Test func `A cancelled file picker does nothing`() async {
        let model = await makeModel()
        await model.pdfFilesPicked(.success([]))
        #expect(fakes.pdfUploader.state.value.isEmpty)
        #expect(model.toast == nil)
    }

    @Test func `A rejected PDF shows a failed card with the reason`() async {
        let model = await makeModel()
        await model.pdfFilesPicked(
            .success([URL(fileURLWithPath: "/tmp/notes.txt"), URL(fileURLWithPath: "/tmp/x.pdf")]))
        fakes.pdfUploader.state.update { $0[1].state = .done(itemId: "n", duplicate: false) }
        await until { model.state.uploadCard == .failed(fileName: "notes.txt", error: .notPdf, others: 0) }
        #expect(model.state.uploadCard == .failed(fileName: "notes.txt", error: .notPdf, others: 0))
        model.dismissUploadCardTapped()
        await until { model.state.uploadCard == nil }
        #expect(fakes.pdfUploader.state.value.isEmpty)
    }

    @Test func `Upload results become toasts`() async {
        let test = LibraryViewModelTests()
        test.fakes.pdfUploader.state.send(Fixtures.uploads)
        let model = await test.makeModel()
        await test.until { model.state.uploadCard != nil }
        test.fakes.pdfUploader.state.update { $0[0].state = .done(itemId: "p9", duplicate: true) }
        await test.until { model.toast != nil }
        #expect(test.text(model.toast?.message) == "Already in Sroka")
        test.fakes.pdfUploader.state.update { $0[1].state = .failed(.tooLarge) }
        await test.until { test.text(model.toast?.message)?.hasPrefix("Couldn’t add PDF.") == true }
        #expect(test.text(model.toast?.message) == "Couldn’t add PDF. Too large. PDFs can be up to 50 MB.")
    }

    // MARK: Drops

    @Test func `Dropping nothing useful says no link was found`() async {
        let model = await makeModel()
        await model.linksDropped([URL(string: "file:///tmp/x")!])
        #expect(text(model.toast?.message) == "Couldn’t find a link to save")
        await model.textDropped(["just words"])
        #expect(text(model.toast?.message) == "Couldn’t find a link to save")
    }

    @Test func `Dropped links are saved with an undo that deletes them`() async {
        let model = await makeModel()
        await model.linksDropped([URL(string: "https://example.com/d1")!])
        #expect(text(model.toast?.message) == "Saved to Sroka")
        await model.toastActionTapped()
        #expect(!fakes.library.items.value.contains { $0.url == "https://example.com/d1" })

        await model.linksDropped([URL(string: "https://example.com/d2")!, URL(string: "https://example.com/d3")!])
        #expect(text(model.toast?.message) == "Saved 2 links")
        #expect(fakes.library.items.value.contains { $0.url == "https://example.com/d3" })
    }

    @Test func `Dropping a saved link offers to open it`() async {
        let model = await makeModel()
        await model.linksDropped([URL(string: "https://www.example.com/essays/the-slow-web")!])
        #expect(text(model.toast?.message) == "Already in Sroka")
        await model.toastActionTapped()
        #expect(intents.values == [.openItem(id: "a1-long-read")])
    }

    // MARK: Onboarding

    @Test func `Onboarding steps open Chrome and the add sheet`() async {
        let model = await makeModel()
        model.chromeStepTapped()
        #expect(intents.values == [.openURL(LibraryViewModel.extensionURL)])
        model.pasteLinkStepTapped()
        #expect(model.isAddSheetPresented)
    }
}
