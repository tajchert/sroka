import Clocks
import SrokaCore
import SrokaTesting
import Testing

@testable import ReaderFeature

@MainActor
struct ReaderProgressTests {
    private func openedShortNews() async -> ReaderHarness {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        _ = await h.until { h.model.readyDocument != nil }
        return h
    }

    @Test func `The first position is written at once`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        h.model.readingPositionReported(ProgressReport(progress: 0.1, anchor: 3))
        await h.model.writesSettled()
        #expect(h.item(Fixtures.shortNews.id)?.progress == 0.1)
        #expect(h.item(Fixtures.shortNews.id)?.progressAnchor == 3)
        #expect(h.model.progress == 0.1)
    }

    @Test func `Positions within two seconds are held back and written one second after scrolling stops`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        let id = Fixtures.shortNews.id
        h.model.readingPositionReported(ProgressReport(progress: 0.1, anchor: 3))
        await h.model.writesSettled()

        h.now.advance(0.5)
        h.model.readingPositionReported(ProgressReport(progress: 0.2, anchor: 5))
        await h.model.writesSettled()
        #expect(h.item(id)?.progress == 0.1)
        #expect(h.model.progress == 0.2)  // the screen follows the scroll, only the write waits

        await h.idle()
        await h.clock.advance(by: .milliseconds(900))
        await h.idle()
        #expect(h.item(id)?.progress == 0.1)
        await h.clock.advance(by: .milliseconds(200))
        #expect(await h.until { h.item(id)?.progress == 0.2 })
        #expect(h.item(id)?.progressAnchor == 5)
    }

    @Test func `A newer position restarts the debounce and only the last one is written`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        let id = Fixtures.shortNews.id
        h.model.readingPositionReported(ProgressReport(progress: 0.1, anchor: 1))
        await h.model.writesSettled()
        h.now.advance(0.3)
        h.model.readingPositionReported(ProgressReport(progress: 0.2, anchor: 2))
        await h.idle()
        await h.clock.advance(by: .milliseconds(600))
        h.now.advance(0.3)
        h.model.readingPositionReported(ProgressReport(progress: 0.3, anchor: 3))
        await h.idle()
        await h.clock.advance(by: .milliseconds(600))
        await h.idle()
        #expect(h.item(id)?.progress == 0.1)
        await h.clock.advance(by: .milliseconds(500))
        #expect(await h.until { h.item(id)?.progress == 0.3 })
    }

    @Test func `A position more than two seconds after the last write is written at once`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        h.model.readingPositionReported(ProgressReport(progress: 0.1, anchor: 3))
        await h.model.writesSettled()
        h.now.advance(2.5)
        h.model.readingPositionReported(ProgressReport(progress: 0.4, anchor: 9))
        await h.model.writesSettled()
        #expect(h.item(Fixtures.shortNews.id)?.progress == 0.4)
    }

    @Test func `Leaving the reader writes the position that was still waiting`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        let id = Fixtures.shortNews.id
        h.model.readingPositionReported(ProgressReport(progress: 0.1, anchor: 3))
        await h.model.writesSettled()
        h.now.advance(0.2)
        h.model.readingPositionReported(ProgressReport(progress: 0.5, anchor: 8))
        await h.model.writesSettled()
        #expect(h.item(id)?.progress == 0.1)
        h.model.readerLeft()
        await h.model.writesSettled()
        #expect(h.item(id)?.progress == 0.5)
        #expect(h.item(id)?.progressAnchor == 8)
    }

    @Test func `Leaving without scrolling still bumps the last-read time`() async {
        let h = ReaderHarness(itemId: Fixtures.longRead.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        #expect(h.item(Fixtures.longRead.id)?.lastReadAt != Fixtures.now)
        h.model.readerLeft()
        await h.model.writesSettled()
        let item = h.item(Fixtures.longRead.id)
        #expect(item?.lastReadAt == Fixtures.now)
        #expect(item?.progress == Fixtures.longRead.progress)
        #expect(item?.progressAnchor == Fixtures.longRead.progressAnchor)
    }

    @Test func `Leaving twice does not write twice`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        h.model.readingPositionReported(ProgressReport(progress: 0.3, anchor: 4))
        await h.model.writesSettled()
        h.model.readerLeft()
        await h.model.writesSettled()
        let after = h.item(Fixtures.shortNews.id)?.lastReadAt
        h.now.advance(30)
        h.model.readerLeft()
        await h.model.writesSettled()
        #expect(h.item(Fixtures.shortNews.id)?.lastReadAt == after)
    }

    @Test func `Positions are ignored before the article is shown`() async {
        let item = makeItem(id: "pending-1", contentId: nil, parseStatus: .pending)
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .parsePending })
        h.model.readingPositionReported(ProgressReport(progress: 0.7, anchor: 2))
        await h.model.writesSettled()
        #expect(h.item(item.id)?.progress == 0)
    }

    @Test func `Opening restores the saved position`() async {
        let h = ReaderHarness(itemId: Fixtures.longRead.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        let restore = h.model.restorePoint()
        #expect(restore.anchor == Fixtures.longRead.progressAnchor)
        #expect(restore.progress == Fixtures.longRead.progress)
        h.model.readingPositionReported(ProgressReport(progress: 0.8, anchor: 40))
        #expect(h.model.restorePoint() == RestorePoint(anchor: 40, progress: 0.8))
    }

    @Test func `A PDF page turn is written at once with the page as anchor`() async {
        let h = ReaderHarness(itemId: Fixtures.pdf.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.pdfFile != nil })
        h.model.pdfPageChanged(page: 2, pageCount: 10)
        await h.model.writesSettled()
        #expect(h.item(Fixtures.pdf.id)?.progress == 0.3)
        #expect(h.item(Fixtures.pdf.id)?.progressAnchor == 2)
        h.model.pdfPageChanged(page: 9, pageCount: 10)
        await h.model.writesSettled()
        #expect(h.item(Fixtures.pdf.id)?.progress == 1)
        #expect(h.item(Fixtures.pdf.id)?.progressAnchor == 9)
    }

    @Test func `Progress writes keep their order`() async {
        let h = await openedShortNews()
        defer { h.stop() }
        for step in 1...5 {
            h.now.advance(3)
            h.model.readingPositionReported(ProgressReport(progress: Double(step) / 10, anchor: step))
        }
        await h.model.writesSettled()
        #expect(h.item(Fixtures.shortNews.id)?.progress == 0.5)
        #expect(h.item(Fixtures.shortNews.id)?.progressAnchor == 5)
    }
}

@MainActor
struct ReaderResumeTests {
    @Test func `An article opened part-way offers to start over`() async {
        let h = ReaderHarness(itemId: Fixtures.longRead.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.toast == .resumed(percent: 42) })
    }

    @Test func `An article opened at the top shows no resume notice`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        await h.idle()
        #expect(h.model.toast == nil)
    }

    @Test func `A tiny saved position is not announced`() async {
        var item = makeItem(id: "tiny-1", offline: .downloaded)
        item.progress = 0.02
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        await h.idle()
        #expect(h.model.toast == nil)
    }

    @Test func `The resume notice goes away after a few seconds`() async {
        let h = ReaderHarness(itemId: Fixtures.longRead.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.toast != nil })
        await h.idle()
        await h.clock.advance(by: .seconds(7))
        #expect(await h.until { h.model.toast == nil })
    }

    @Test func `Start over resets the position and scrolls to the top`() async {
        let h = ReaderHarness(itemId: Fixtures.longRead.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.toast != nil })
        h.model.startOverTapped()
        await h.model.writesSettled()
        #expect(h.model.toast == nil)
        #expect(h.model.progress == 0)
        #expect(h.model.scrollToTopRequest == 1)
        #expect(h.item(Fixtures.longRead.id)?.progress == 0)
        #expect(h.item(Fixtures.longRead.id)?.progressAnchor == nil)
        #expect(h.model.restorePoint() == RestorePoint(anchor: nil, progress: 0))
    }

    @Test func `The screen is kept awake until five minutes without interaction`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        #expect(h.model.keepAwake)
        await h.idle()
        await h.clock.advance(by: .seconds(299))
        #expect(h.model.keepAwake)
        await h.clock.advance(by: .seconds(2))
        #expect(await h.until { !h.model.keepAwake })
        h.model.readingPositionReported(ProgressReport(progress: 0.1, anchor: 1))
        #expect(h.model.keepAwake)
    }
}
