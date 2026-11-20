import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Synchronization
import Testing

@testable import ShareFeature

@MainActor
struct ShareViewModelTests {
    let fakes: Fakes
    let clock = TestClock<Duration>()
    let log = Log()

    /// Intents the extension host would handle and pushes it would send.
    final class Log: Sendable {
        private let intentValues = Mutex<[ShareIntent]>([])
        private let pushCount = Mutex(0)
        var intents: [ShareIntent] { intentValues.withLock { $0 } }
        var pushes: Int { pushCount.withLock { $0 } }
        func record(_ intent: ShareIntent) { intentValues.withLock { $0.append(intent) } }
        func recordPush() { pushCount.withLock { $0 += 1 } }
    }

    init(items: [Item] = Fixtures.items, session: SessionState = .signedIn(email: Fixtures.email)) {
        fakes = Fakes(items: items, session: session)
    }

    func makeModel(startup: ShareStartup = .ready) -> ShareViewModel {
        let fakes = fakes
        let clock = clock
        let log = log
        return withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
        } operation: {
            ShareViewModel(
                startup: startup,
                pushOnce: { log.recordPush() },
                onIntent: { log.record($0) }
            )
        }
    }

    /// Lets observation and timer tasks run until `condition` holds (no sleeping).
    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    func savedModel(url: String = "https://example.com/new", title: String? = nil) async -> ShareViewModel {
        let model = makeModel()
        await model.start(.link(url: url, title: title))
        await until { model.state.item != nil }
        return model
    }

    var savedId: String? { fakes.library.items.value.first?.id }

    // MARK: Saving

    @Test func `A shared link is saved and shows the item`() async {
        let model = await savedModel(title: "Hello")
        guard case .saved(let id, let already) = model.state.phase else {
            Issue.record("expected saved, got \(model.state.phase)")
            return
        }
        #expect(!already)
        #expect(model.state.item?.id == id)
        #expect(model.state.item?.title == "Hello")
        #expect(fakes.library.item(id: id)?.source == .share)
    }

    @Test func `Saving requests one push`() async {
        _ = await savedModel()
        #expect(log.pushes == 1)
    }

    @Test func `Starting twice saves once`() async {
        let model = makeModel()
        let before = fakes.library.items.value.count
        await model.start(.link(url: "https://example.com/new", title: nil))
        await model.start(.link(url: "https://example.com/other", title: nil))
        #expect(fakes.library.items.value.count == before + 1)
    }

    @Test func `An already saved link moves back to My List and shows its progress`() async {
        var archived = Fixtures.longRead
        archived.status = .archived
        let test = ShareViewModelTests(items: [archived])
        let model = test.makeModel()
        await model.start(.link(url: archived.url, title: nil))
        await test.until { model.state.item != nil }
        #expect(model.state.phase == .saved(itemId: archived.id, alreadySaved: true))
        #expect(model.state.item?.progress == 0.42)
        #expect(test.fakes.library.item(id: archived.id)?.status == .unread)
        #expect(test.fakes.library.items.value.count == 1)
    }

    @Test func `Shared text without a link shows no link found`() async {
        let model = makeModel()
        await model.start(.nothing)
        #expect(model.state.phase == .noLink)
        #expect(model.state.countdown == .running(seconds: 4, run: 1))
    }

    @Test func `A link the repository rejects shows no link found`() async {
        let model = makeModel()
        await model.start(.link(url: "ftp://example.com/file", title: nil))
        #expect(model.state.phase == .noLink)
    }

    @Test func `Signed out shows the sign in message and saves nothing`() async {
        let test = ShareViewModelTests(session: .signedOut)
        let model = test.makeModel()
        let before = test.fakes.library.items.value.count
        await model.start(.link(url: "https://example.com/new", title: nil))
        #expect(model.state.phase == .needsSignIn)
        #expect(model.state.countdown == .hidden)
        #expect(test.fakes.library.items.value.count == before)
        #expect(test.log.pushes == 0)
    }

    @Test func `An expired session still saves locally`() async {
        let test = ShareViewModelTests(session: .expired(email: Fixtures.email))
        let model = test.makeModel()
        await model.start(.link(url: "https://example.com/new", title: nil))
        guard case .saved = model.state.phase else {
            Issue.record("expected saved")
            return
        }
    }

    @Test func `Sign in opens the app at its scheme`() async {
        let test = ShareViewModelTests(session: .signedOut)
        let model = test.makeModel()
        await model.start(.nothing)
        await model.signInButtonTapped()
        #expect(test.log.intents == [.openURL(URL(string: "sroka-test://")!)])
    }

    @Test func `A database that needs the app shows the update message and saves nothing`() async {
        let model = makeModel(startup: .needsApp)
        let before = fakes.library.items.value.count
        await model.start(.link(url: "https://example.com/new", title: nil))
        #expect(model.state.phase == .needsApp)
        #expect(fakes.library.items.value.count == before)
        #expect(model.state.countdown == .hidden)
    }

    @Test func `Storage that cannot start shows an error`() async {
        let model = makeModel(startup: .unavailable)
        await model.start(.nothing)
        #expect(model.state.phase == .error)
    }

    // MARK: Auto-dismiss

    @Test func `The sheet dismisses itself after four seconds`() async {
        let model = await savedModel()
        #expect(model.state.countdown == .running(seconds: 4, run: 1))
        await clock.advance(by: .seconds(3))
        await until { !log.intents.isEmpty }
        #expect(log.intents.isEmpty)
        await clock.advance(by: .seconds(1))
        await until { !log.intents.isEmpty }
        #expect(log.intents == [.dismiss])
        #expect(model.state.countdown == .hidden)
    }

    @Test func `A touch stops the countdown for good`() async {
        let model = await savedModel()
        model.sheetTouched()
        #expect(model.state.countdown == .hidden)
        await clock.advance(by: .seconds(30))
        await until { !log.intents.isEmpty }
        #expect(log.intents.isEmpty)
    }

    @Test func `A touch before the PDF answer keeps its timer off`() async {
        let model = makeModel()
        await model.start(.pdfs([URL(fileURLWithPath: "/nonexistent/share-test/a.pdf")]))
        model.sheetTouched()
        fakes.pdfUploader.state.update { $0 = $0.map { upload in finished(upload, duplicate: false) } }
        await until { model.state.phase == .pdf(.added(count: 1)) }
        #expect(model.state.countdown == .hidden)
    }

    // MARK: Favorite and tags

    @Test func `Favorite toggles on the saved item`() async {
        let model = await savedModel()
        let id = savedId ?? ""
        await model.favoriteButtonTapped()
        #expect(fakes.library.item(id: id)?.isFavorite == true)
        await until { model.state.item?.isFavorite == true }
        #expect(model.state.item?.isFavorite == true)
        await model.favoriteButtonTapped()
        #expect(fakes.library.item(id: id)?.isFavorite == false)
    }

    @Test func `Tags opens the editor with the item's tags and recent names`() async {
        let model = await savedModel()
        await until { !model.recentTags.isEmpty }
        model.tagsButtonTapped()
        let request = model.tagEditor
        #expect(request?.itemId == savedId)
        #expect(request?.initialTags == [])
        #expect(request?.suggestions.isEmpty == false)
    }

    @Test func `Saving tags writes them and closes the editor`() async {
        let model = await savedModel()
        let id = savedId ?? ""
        model.tagsButtonTapped()
        await model.tagsSaved(itemId: id, names: ["alpha", "beta"])
        #expect(fakes.library.item(id: id)?.tags == ["alpha", "beta"])
        #expect(model.tagEditor == nil)
        await until { model.state.item?.tags == ["alpha", "beta"] }
        #expect(model.state.item?.tags == ["alpha", "beta"])
    }

    @Test func `Tags and favorite stop the countdown`() async {
        let model = await savedModel()
        model.tagsButtonTapped()
        #expect(model.state.countdown == .hidden)
    }

    // MARK: Push

    @Test func `Closing pushes again only when something changed after the save`() async {
        let model = await savedModel()
        await model.closeButtonTapped()
        #expect(log.pushes == 1)
        #expect(log.intents == [.dismiss])
    }

    @Test func `Closing after a favorite change pushes once more`() async {
        let model = await savedModel()
        await model.favoriteButtonTapped()
        await model.closeButtonTapped()
        #expect(log.pushes == 2)
        #expect(log.intents == [.dismiss])
    }

    @Test func `Swiping away during a favorite write waits for it and pushes it`() async {
        let model = await savedModel()
        let id = savedId ?? ""
        let tap = Task { await model.favoriteButtonTapped() }
        await Task.yield()
        await model.sheetDismissed()
        await tap.value
        #expect(fakes.library.item(id: id)?.isFavorite == true)
        #expect(log.pushes == 2)
        #expect(log.intents == [.dismiss])
    }

    @Test func `An editor that saved tags itself closes and the sheet pushes once more`() async {
        let model = await savedModel()
        model.tagsButtonTapped()
        model.tagEditorFinished()
        #expect(model.tagEditor == nil)
        await model.closeButtonTapped()
        #expect(log.pushes == 2)
    }

    @Test func `Swiping the sheet away completes the request once`() async {
        let model = await savedModel()
        await model.sheetDismissed()
        await model.closeButtonTapped()
        #expect(log.intents == [.dismiss])
    }

    // MARK: Open

    @Test func `Open asks for the item's deep link`() async {
        let model = await savedModel()
        let id = savedId ?? ""
        await model.openButtonTapped()
        #expect(log.intents == [.openURL(URL(string: "sroka-test://item/\(id)")!)])
    }

    // MARK: PDF

    private func finished(_ upload: PdfUpload, duplicate: Bool) -> PdfUpload {
        var copy = upload
        copy.state = .done(itemId: "pdf-item", duplicate: duplicate)
        return copy
    }

    @Test func `A shared PDF is queued and shows adding`() async {
        let model = makeModel()
        await model.start(.pdfs([URL(fileURLWithPath: "/nonexistent/share-test/a.pdf")]))
        #expect(model.state.phase == .pdf(.queued(count: 1)))
        #expect(fakes.pdfUploader.state.value.count == 1)
        #expect(model.state.countdown == .running(seconds: 8, run: 1))
        #expect(log.pushes == 0)
    }

    @Test func `A PDF answered by the server shows added and dismisses sooner`() async {
        let model = makeModel()
        await model.start(.pdfs([URL(fileURLWithPath: "/nonexistent/share-test/a.pdf")]))
        fakes.pdfUploader.state.update { $0 = $0.map { upload in finished(upload, duplicate: false) } }
        await until { model.state.phase == .pdf(.added(count: 1)) }
        #expect(model.state.phase == .pdf(.added(count: 1)))
        #expect(model.state.countdown == .running(seconds: 2.5, run: 2))
        await clock.advance(by: .milliseconds(2500))
        await until { !log.intents.isEmpty }
        #expect(log.intents == [.dismiss])
    }

    @Test func `A PDF that is already in the library shows already in Sroka`() async {
        let model = makeModel()
        await model.start(.pdfs([URL(fileURLWithPath: "/nonexistent/share-test/a.pdf")]))
        fakes.pdfUploader.state.update { $0 = $0.map { upload in finished(upload, duplicate: true) } }
        await until { model.state.phase == .pdf(.duplicate) }
        #expect(model.state.phase == .pdf(.duplicate))
    }

    @Test func `A file the uploader refuses shows its reason and stays open`() async {
        let model = makeModel()
        await model.start(.pdfs([URL(fileURLWithPath: "/nonexistent/share-test/notes.txt")]))
        #expect(model.state.phase == .pdf(.failed(.notPdf)))
        #expect(model.state.countdown == .hidden)
    }

    @Test func `A PDF rejected by the input checks shows its reason`() async {
        let model = makeModel()
        await model.start(.rejectedPdf(.tooLarge))
        #expect(model.state.phase == .pdf(.failed(.tooLarge)))
    }

    @Test func `A share with no PDF file says so`() async {
        let model = makeModel()
        await model.start(.pdfs([]))
        #expect(model.state.phase == .pdf(.noFile))
    }

    @Test func `A signed out PDF share asks to sign in`() async {
        let test = ShareViewModelTests(session: .signedOut)
        let model = test.makeModel()
        await model.start(.pdfs([URL(fileURLWithPath: "/nonexistent/share-test/a.pdf")]))
        #expect(model.state.phase == .needsSignIn)
        #expect(test.fakes.pdfUploader.state.value.isEmpty)
    }
}
