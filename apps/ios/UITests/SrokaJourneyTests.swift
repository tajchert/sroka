import XCTest

/// End-to-end journeys of the live Dev app against the local backend. Run with `scripts/journey.sh`.
/// The tests share one account and one install, so they run in order (the letters in the names); each one tolerates
/// being run alone by signing in and saving the journey article when they are missing.
@MainActor
final class SrokaJourneyTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        Journey.setNetwork(up: true)
    }

    // MARK: a. Sign in on a fresh install -> empty library

    func testA_SignInShowsEmptyLibrary() {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        expect(app.textFields["auth.emailField"], "sign-in screen on a fresh install", timeout: 20, app: app)
        shot("a1-sign-in")
        screens.signIn()
        expect(app.navigationBars["My List"].firstMatch, "My List title", app: app)
        shot("a2-empty-library")
        screens.openTab("Archive")
        expect(app.navigationBars["Archive"].firstMatch, "Archive title", app: app)
        shot("a3-archive-empty")
        screens.openTab("My List")
        XCTAssertFalse(screens.row(containing: Journey.articleTitle).exists, "a new account has no articles")
    }

    // MARK: b. Save a link, parse, read, scroll, leave and reopen at the saved position

    func testB_SaveReadScrollResume() {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureSignedIn()
        screens.saveLink(Journey.articleURL)
        shot("b1-saved-row")
        let row = screens.waitForArticleRow()
        shot("b2-parsed-row")
        row.tap()

        let web = expect(app.webViews.firstMatch, "reader web view", timeout: 40, app: app)
        let body = web.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", Journey.articleWord))
        expect(body.firstMatch, "article text with '\(Journey.articleWord)'", timeout: 40, app: app)
        shot("b3-reader-top")
        // The header (title, meta line) rests below the floating back and Aa buttons, sharp, at the top of the page.
        XCTAssertGreaterThan(
            screens.titleTop(in: web), screens.topControlsBottom(),
            "the article header starts below the floating top controls")
        // The same page in the dark theme (chosen in the reader's own appearance sheet, restored below).
        screens.chooseReaderTheme("Dark")
        shot("b3-reader-top-dark")
        screens.chooseReaderTheme("Auto")

        for _ in 0..<4 { web.swipeUp() }
        let progress = screens.readingProgress()
        XCTAssertGreaterThan(progress, 0, "scrolling moves the reading progress")
        shot("b4-reader-scrolled")

        screens.closeReader()
        XCTAssertTrue(screens.waitForArticleRow().exists)
        // A restart in between proves the position is stored, not just remembered by a live view model.
        let app2 = launchApp()
        let screens2 = Screens(app: app2, test: self)
        screens2.ensureSignedIn()
        screens2.waitForArticleRow().tap()
        let web2 = expect(app2.webViews.firstMatch, "reader web view after reopening", timeout: 40, app: app2)
        shot("b5a-reader-reopening")  // as early as the reader is there: the page may still be loading
        // b5 is taken once the notice is on screen and article text is hittable, never before.
        let toast = expect(
            app2.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Resumed at")).firstMatch,
            "'Resumed at N%' toast after reopening", timeout: 20, app: app2)
        XCTAssertTrue(toast.isHittable, "the resume notice is on screen")
        usleep(300_000)  // the toast has finished sliding in
        shot("b5-reader-resumed")
        // The text query is slow (the toast stays about 6 s), so it follows the shot; nothing scrolls in between.
        XCTAssertGreaterThan(
            screens2.visibleBodyTexts(in: web2), 0,
            "article text is on screen when the resume notice shows, not only in the DOM")
        XCTAssertGreaterThan(screens2.readingProgress(), 0, "the progress line starts where the reader left")
    }

    // MARK: c. Favorite, tag, archive with undo, archive, find in Archive, move back

    func testC_FavoriteTagArchive() {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureArticle()

        screens.rowMenu("Add to favorites")
        screens.openTab("My List")
        screens.rowMenu("Remove from favorites", cancel: true)  // the star is now on
        shot("c1-favorited")

        screens.rowMenu("Edit tags")
        let field = expect(app.textFields["tagEditor.field"], "tag editor field", app: app)
        field.tap()
        field.typeText("journey\n")
        shot("c2-tag-editor")
        app.buttons["Save"].firstMatch.tap()
        expect(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "journey")).firstMatch,
            "tag chip 'journey' on the row or filter strip", app: app)
        shot("c3-tagged")

        screens.rowMenu("Archive")
        let undo = expect(app.buttons["Undo"], "Undo on the archive toast", timeout: 8, app: app)
        shot("c4-archive-toast")
        undo.tap()
        XCTAssertTrue(screens.waitForArticleRow().exists, "Undo brings the row back")

        screens.rowMenu("Archive")
        expect(app.buttons["Undo"], "archive toast again", timeout: 8, app: app)
        XCTAssertTrue(
            waitForDisappearance(of: screens.row(containing: Journey.articleTitle)), "archived row leaves My List")
        screens.openTab("Archive")
        screens.waitForArticleRow()
        shot("c5-archive-tab")
        screens.rowMenu("Move to My List")
        screens.openTab("My List")
        screens.waitForArticleRow()
    }

    // MARK: d. Search by a word from the text; Tags tab opens the item

    func testD_SearchAndTags() {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureArticle()

        screens.openTab("Search")
        let field = expect(app.searchFields.firstMatch, "search field", app: app)
        field.tap()
        field.typeText(Journey.articleWord)
        screens.waitForArticleRow(timeout: 20)
        shot("d1-search-result")
        // The keyboard covers the tab bar: submit the search to dismiss it.
        if app.keyboards.count > 0 { app.keyboards.buttons["Search"].firstMatch.tap() }

        screens.openTab("Tags")
        let tag = expect(
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "journey")).firstMatch,
            "tag 'journey' in the Tags tab", app: app)
        shot("d2-tags-tab")
        tag.tap()
        screens.waitForArticleRow().tap()
        expect(app.webViews.firstMatch, "reader opened from the tag's item list", timeout: 40, app: app)
        shot("d3-reader-from-tag")
    }

    // MARK: e. Offline: a downloaded article opens, a new save waits and syncs when the server is back

    func testE_Offline() throws {
        try XCTSkipIf(Journey.netControl.isEmpty || Journey.serverURL.isEmpty, "needs the proxy (run without --direct)")
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureArticle()
        // Make sure the article is on the device before the network goes away.
        screens.waitForArticleRow().tap()
        expect(app.webViews.firstMatch, "reader while online", timeout: 40, app: app)
        screens.closeReader()

        Journey.setNetwork(up: false)
        let offline = launchApp()
        let offlineScreens = Screens(app: offline, test: self)
        expect(offlineScreens.myListTab, "library while offline", timeout: 20, app: offline)
        offlineScreens.waitForArticleRow().tap()
        let web = expect(offline.webViews.firstMatch, "downloaded article offline", timeout: 20, app: offline)
        expect(
            web.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", Journey.articleWord)).firstMatch,
            "article text offline", app: offline)
        shot("e1-reader-offline")
        offlineScreens.closeReader()

        offlineScreens.saveLink("https://blog.cloudflare.com/sqlite-in-durable-objects/")
        let waiting = expect(
            offline.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "waiting to sync")).firstMatch,
            "'waiting to sync' for the offline save", timeout: 15, app: offline)
        _ = waiting
        shot("e2-waiting-to-sync")

        Journey.setNetwork(up: true)
        let second = offlineScreens.row(containing: "Zero-latency SQLite")
        expect(second, "offline save synced and parsed", timeout: 120, app: offline)
        shot("e3-synced")
    }

    // MARK: f. Settings: appearance persists across relaunch, sign out, sign in again shows the server's library

    func testF_SettingsAndSignOut() {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureArticle()
        screens.openSettings()
        screens.chooseTheme("Dark")
        shot("f1-theme-dark")
        app.buttons["settings.doneButton"].tap()

        let relaunched = launchApp()
        let relaunchedScreens = Screens(app: relaunched, test: self)
        relaunchedScreens.ensureSignedIn()
        relaunchedScreens.openSettings()
        let picker = relaunchedScreens.themePicker()
        expect(picker, "Theme picker", app: relaunched)
        XCTAssertTrue(
            (picker.value as? String) == "Dark" || picker.label.contains("Dark"),
            "theme stays Dark after relaunch (value: \(String(describing: picker.value)), label: \(picker.label))")
        shot("f2-theme-after-relaunch")
        relaunchedScreens.chooseTheme("System")

        relaunched.swipeUp()
        relaunched.buttons["settings.signOut"].tap()
        // A confirmation dialog: its button has the same label as the row, but not the row's identifier.
        let confirm = relaunched.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Sign out", "settings.signOut")
        ).firstMatch
        expect(confirm, "sign-out confirmation", app: relaunched)
        shot("f3-sign-out-confirm")
        confirm.tap()
        expect(relaunched.textFields["auth.emailField"], "sign-in screen after sign out", timeout: 20, app: relaunched)
        shot("f4-signed-out")

        relaunchedScreens.signIn()
        relaunchedScreens.waitForArticleRow(timeout: 60)
        shot("f5-signed-in-again")
    }

    // MARK: g. Deep link opens the reader

    func testG_DeepLink() async throws {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureArticle()
        let id = try await JourneyAPI.itemId(urlContaining: Journey.articleURL)
        app.terminate()
        let link = try XCTUnwrap(URL(string: "sroka-dev://item/\(id)"))
        let opened = XCUIApplication()
        opened.open(link)
        let web = expect(opened.webViews.firstMatch, "reader opened by sroka-dev://item/<id>", timeout: 40, app: opened)
        _ = web
        shot("g1-deep-link-reader")
    }

    // MARK: h. Delete (runs last: it removes the journey article)

    func testH_ArchiveAndDelete() {
        let app = launchApp()
        let screens = Screens(app: app, test: self)
        screens.ensureArticle()
        screens.rowMenu("Archive")
        screens.openTab("Archive")
        screens.waitForArticleRow()
        screens.rowMenu("Delete")
        let confirm = app.alerts.buttons["Delete"].firstMatch
        expect(confirm, "delete confirmation", app: app)
        shot("h1-delete-confirm")
        confirm.tap()
        XCTAssertTrue(waitForDisappearance(of: screens.row(containing: Journey.articleTitle)), "deleted row is gone")
        shot("h2-deleted")
    }
}
