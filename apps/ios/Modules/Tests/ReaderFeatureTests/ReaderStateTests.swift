import Foundation
import SrokaCore
import SrokaTesting
import Testing

@testable import ReaderFeature

@MainActor
struct ReaderStateTests {
    @Test func `A downloaded article opens from its unpacked package`() async throws {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        let document = try #require(h.model.readyDocument)
        #expect(document.itemId == Fixtures.shortNews.id)
        #expect(document.html.contains("<img"))
        let package = document.articlesDirectory.appending(path: document.itemId, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "img/hero.svg").path))
    }

    @Test func `An article that is still parsing shows the preparing state`() async {
        let h = ReaderHarness(itemId: Fixtures.pendingParse.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .parsePending })
    }

    @Test func `A failed parse keeps the server reason for the plain wording`() async {
        let item = makeItem(id: "failed-1", contentId: nil, parseStatus: .failed, parseError: "http_404")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .parseFailed(error: "http_404") })
    }

    @Test func `A package that is not on the device is downloaded once and then shown`() async {
        let item = makeItem(id: "remote-1")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        #expect(h.fakes.content.calls.calls == ["downloadNow"])
    }

    @Test(arguments: [
        (RemoteFailure.network, NotDownloadedReason.offline),
        (.unauthorized, .signIn),
        (.rateLimited, .error),
        (.server, .error),
    ])
    func `A failed download explains why the article is not saved`(
        failure: RemoteFailure, reason: NotDownloadedReason
    ) async {
        let item = makeItem(id: "remote-2")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.fakes.content.downloadResult.send(.failed(failure))
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .notDownloaded(reason) })
    }

    @Test func `A full device shows the storage reason with its code`() async {
        let item = makeItem(id: "remote-5")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.fakes.content.downloadResult.send(.storageFull(code: "free_space 0"))
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .notDownloaded(.storage, code: "free_space 0") })
    }

    @Test func `A failed download carries its code to the error screen`() async {
        let item = makeItem(id: "remote-6")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.fakes.content.downloadResult.send(.failed(.server, code: "http_403"))
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .notDownloaded(.error, code: "http_403") })
    }

    @Test func `The server not having parsed yet shows the preparing state`() async {
        let item = makeItem(id: "remote-3")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.fakes.content.downloadResult.send(.notReady)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .parsePending })
    }

    @Test func `Try again downloads once more and shows the article`() async {
        let item = makeItem(id: "remote-4")
        let h = ReaderHarness(itemId: item.id, items: [item])
        h.fakes.content.downloadResult.send(.failed(.network))
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.state == .notDownloaded(.offline) })
        h.fakes.content.downloadResult.send(.downloaded)
        h.model.retryTapped()
        #expect(await h.until { h.model.readyDocument != nil })
        #expect(h.fakes.content.calls.calls == ["downloadNow", "downloadNow"])
    }

    @Test func `A PDF opens in the native viewer`() async throws {
        let h = ReaderHarness(itemId: Fixtures.pdf.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.pdfFile != nil })
        #expect(h.model.pdfFile?.lastPathComponent == "document.pdf")
        #expect(h.model.isPdf)
    }

    @Test func `An unknown or malformed item id shows nothing to read`() async {
        let unknown = ReaderHarness(itemId: "does-not-exist")
        unknown.start()
        defer { unknown.stop() }
        #expect(await unknown.until { unknown.model.state == .missing })

        let malformed = ReaderHarness(itemId: "../etc/passwd")
        #expect(malformed.model.state == .missing)
    }

    @Test func `Deleting the item underneath the reader ends in the missing state`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        await h.fakes.library.delete(id: Fixtures.shortNews.id)
        #expect(await h.until { h.model.state == .missing })
    }

    @Test func `The web process being terminated shows its state and reloading recovers`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        h.model.webProcessTerminated()
        #expect(h.model.state == .rendererGone)
        h.model.reloadTapped()
        #expect(await h.until { h.model.readyDocument != nil })
    }

    @Test func `Opening an article logs one enum-only open event`() async {
        let h = ReaderHarness(itemId: Fixtures.shortNews.id)
        h.start()
        defer { h.stop() }
        #expect(await h.until { h.model.readyDocument != nil })
        #expect(h.fakes.telemetry.events.calls == [.openItem(kind: .article)])
    }
}
