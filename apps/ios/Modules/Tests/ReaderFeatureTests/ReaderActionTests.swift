import Clocks
import SrokaCore
import SrokaTesting
import Testing

@testable import ReaderFeature

@MainActor
struct ReaderActionTests {
    private func opened(_ id: String, items: [Item] = Fixtures.items) async -> ReaderHarness {
        let h = ReaderHarness(itemId: id, items: items)
        h.start()
        _ = await h.until { h.model.readyDocument != nil && h.model.item != nil }
        return h
    }

    @Test func `The favorite button toggles the favorite`() async {
        let h = await opened(Fixtures.longRead.id)
        defer { h.stop() }
        #expect(h.item(Fixtures.longRead.id)?.isFavorite == false)
        await h.model.favoriteTapped()
        #expect(h.item(Fixtures.longRead.id)?.isFavorite == true)
        #expect(await h.until { h.model.item?.isFavorite == true })
        await h.model.favoriteTapped()
        #expect(h.item(Fixtures.longRead.id)?.isFavorite == false)
    }

    @Test func `Archiving saves the position, archives and leaves`() async {
        let h = await opened(Fixtures.longRead.id)
        defer { h.stop() }
        h.model.readingPositionReported(ProgressReport(progress: 0.6, anchor: 10))
        await h.model.archiveTapped()
        await h.model.writesSettled()
        #expect(h.item(Fixtures.longRead.id)?.status == .archived)
        #expect(h.item(Fixtures.longRead.id)?.progress == 0.6)
        #expect(h.intents.all == [.archived(itemId: Fixtures.longRead.id)])
    }

    @Test func `An archived article moves back to My List and stays open`() async {
        var archived = makeItem(id: "archived-1", offline: .downloaded)
        archived.status = .archived
        let h = await opened(archived.id, items: [archived])
        defer { h.stop() }
        await h.model.archiveTapped()
        #expect(h.item(archived.id)?.status == .unread)
        #expect(h.intents.all.isEmpty)
    }

    @Test func `Archive and next archives and opens the up-next item`() async throws {
        let h = await opened(Fixtures.shortNews.id)
        defer { h.stop() }
        #expect(await h.until { h.model.endNext != nil })
        let next = try #require(h.model.endNext)
        await h.model.archiveAndNextTapped()
        #expect(h.item(Fixtures.shortNews.id)?.status == .archived)
        #expect(h.intents.all == [.archivedAndOpenNext(archivedId: Fixtures.shortNews.id, nextId: next.id)])
    }

    @Test func `Archive and next without a next item just archives and leaves`() async {
        let only = makeItem(id: "only-1", offline: .downloaded)
        let h = await opened(only.id, items: [only])
        defer { h.stop() }
        #expect(h.model.endNext == nil)
        await h.model.archiveAndNextTapped()
        #expect(h.intents.all == [.archived(itemId: only.id)])
    }

    @Test func `The up-next row opens the next item`() async throws {
        let h = await opened(Fixtures.shortNews.id)
        defer { h.stop() }
        #expect(await h.until { h.model.endNext != nil })
        let next = try #require(h.model.endNext)
        h.model.upNextTapped()
        #expect(h.intents.all == [.openItem(next.id)])
    }

    @Test func `Tags and close are handed to the app root`() async {
        let h = await opened(Fixtures.shortNews.id)
        defer { h.stop() }
        h.model.tagsTapped()
        h.model.closeTapped()
        #expect(h.intents.all == [.editTags(itemId: Fixtures.shortNews.id), .close])
    }

    @Test func `Deleting asks first, then removes the item and leaves`() async {
        let h = await opened(Fixtures.shortNews.id)
        defer { h.stop() }
        h.model.deleteTapped()
        #expect(h.model.isDeleteConfirmationPresented)
        await h.model.deleteConfirmed()
        #expect(!h.model.isDeleteConfirmationPresented)
        #expect(h.item(Fixtures.shortNews.id) == nil)
        #expect(h.intents.all == [.deleted(itemId: Fixtures.shortNews.id)])
    }

    @Test func `Nothing is written for an article that was just deleted`() async {
        let h = await opened(Fixtures.shortNews.id)
        defer { h.stop() }
        await h.model.deleteConfirmed()
        h.model.readerLeft()
        await h.model.writesSettled()
        #expect(h.item(Fixtures.shortNews.id) == nil)
    }
}

@MainActor
struct ReaderEndOfArticleTests {
    @Test func `Scrolling to the end shows the end card until Keep`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil && h.model.item != nil })
        #expect(!h.model.isEndCardShown)
        h.model.readingPositionReported(ProgressReport(progress: 1, anchor: 9, atEnd: true))
        #expect(h.model.isEndCardShown)
        h.model.keepTapped()
        #expect(!h.model.isEndCardShown)
    }

    @Test func `Scrolling back up hides the end card`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil && h.model.item != nil })
        h.model.readingPositionReported(ProgressReport(progress: 1, anchor: 9, atEnd: true))
        #expect(h.model.isEndCardShown)
        h.now.advance(3)
        h.model.readingPositionReported(ProgressReport(progress: 0.9, anchor: 8, atEnd: false))
        #expect(!h.model.isEndCardShown)
    }

    @Test func `A partial copy ends without the card and shows the partial warning state`() async {
        var partial = makeItem(id: "partial-1", parseStatus: .partial, parseError: "paywalled", offline: .downloaded)
        partial.progress = 0
        let h = ReaderHarness(itemId: partial.id, items: [partial])
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil && h.model.item != nil })
        #expect(h.model.settledPartial)
        h.model.readingPositionReported(ProgressReport(progress: 1, anchor: 9, atEnd: true))
        #expect(!h.model.endsWithCard)
        #expect(!h.model.isEndCardShown)
    }
}

@MainActor
struct ReaderRefreshTests {
    private func opened(syncStatus: SyncStatus = SyncStatus()) async -> ReaderHarness {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id, syncStatus: syncStatus)
        h.start()
        _ = await h.until { h.model.readyDocument != nil && h.model.item != nil }
        return h
    }

    private func settle(_ h: ReaderHarness, as status: ParseStatus) {
        h.fakes.library.items.update { items in
            guard let index = items.firstIndex(where: { $0.id == Fixtures.shortNews.id }) else { return }
            items[index].parseStatus = status
        }
    }

    @Test func `Refreshing polls for sync every four seconds and announces the result`() async {
        let h = await opened()
        defer { h.stop() }
        await h.model.refreshTapped()
        #expect(h.model.isRefreshing)
        #expect(await h.until { h.model.refreshPhase == .pending })
        await h.idle()
        await h.clock.advance(by: .seconds(4))
        #expect(await h.until { h.fakes.syncController.calls.calls.contains(.requestSync) })
        settle(h, as: .ok)
        #expect(await h.until { h.model.toast == .refreshed })
        #expect(!h.model.isRefreshing)
    }

    @Test func `A refresh that stays partial says so`() async {
        let h = await opened()
        defer { h.stop() }
        await h.model.refreshTapped()
        #expect(await h.until { h.model.refreshPhase == .pending })
        settle(h, as: .partial)
        #expect(await h.until { h.model.toast == .refreshedPartial })
        #expect(h.model.settledPartial)
    }

    @Test func `A refresh that fails says so`() async {
        let h = await opened()
        defer { h.stop() }
        await h.model.refreshTapped()
        #expect(await h.until { h.model.refreshPhase == .pending })
        settle(h, as: .failed)
        #expect(await h.until { h.model.toast == .refreshFailed })
    }

    @Test func `A refresh gives up quietly after ninety seconds`() async {
        let h = await opened()
        defer { h.stop() }
        await h.model.refreshTapped()
        #expect(await h.until { h.model.refreshPhase == .pending })
        // The poll loop registers its next sleep only after the previous one resumed: advance poll by poll.
        for _ in 0..<23 {
            await h.idle()
            await h.clock.advance(by: .seconds(4))
        }
        #expect(await h.until { !h.model.isRefreshing })
        #expect(h.model.toast != .refreshed)
        let syncs = h.fakes.syncController.calls.calls.filter { $0 == .requestSync }.count
        #expect(syncs >= 20)
    }

    @Test func `Refreshing is not possible while offline`() async {
        let h = await opened(syncStatus: SyncStatus(phase: .offline))
        defer { h.stop() }
        #expect(await h.until { h.model.isOffline })
        await h.model.refreshTapped()
        #expect(!h.model.isRefreshing)
        #expect(h.item(Fixtures.shortNews.id)?.parseStatus == .ok)
    }

    @Test func `A second tap while refreshing does nothing`() async {
        let h = await opened()
        defer { h.stop() }
        await h.model.refreshTapped()
        #expect(await h.until { h.model.refreshPhase == .pending })
        await h.model.refreshTapped()
        #expect(h.model.refreshPhase == .pending)
    }

    @Test func `The article stays on screen while it is being refreshed`() async {
        let h = await opened()
        defer { h.stop() }
        await h.model.refreshTapped()
        #expect(await h.until { h.model.refreshPhase == .pending })
        await h.idle()
        #expect(h.model.readyDocument != nil)
    }
}
