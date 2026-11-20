import XCTest

/// Shared helpers for the live-backend journeys (`SrokaJourneyTests`). The journeys run the Dev app WITHOUT the
/// `-UITests` fakes against a local `wrangler dev`; `scripts/journey.sh` provides the environment:
///
/// - `SROKA_DEV_LOG`: the wrangler dev log (the sign-in code is logged as `[sroka] OTP for <email>: <code>`).
/// - `SROKA_SERVER_URL`: server the app talks to (empty = the Dev build default). Set through "Self-hosting?".
/// - `SROKA_NET_CONTROL`: file the API proxy watches; "down" makes the proxy refuse connections, anything else is up.
/// - `SROKA_JOURNEY_EMAIL`: the account used by every journey of one run.
/// - `SROKA_SHOTS_DIR`: where screenshots are written as PNG (also attached to the result bundle).
enum Journey {
    static let env = ProcessInfo.processInfo.environment
    static let devLog = env["SROKA_DEV_LOG"] ?? ""
    static let serverURL = env["SROKA_SERVER_URL"] ?? ""
    static let netControl = env["SROKA_NET_CONTROL"] ?? ""
    static let shotsDir = env["SROKA_SHOTS_DIR"] ?? ""
    static let email: String = {
        if let email = env["SROKA_JOURNEY_EMAIL"], !email.isEmpty { return email }
        return "journey-\(Int(Date().timeIntervalSince1970))@example.com"
    }()

    /// A public page the local parser can fetch (the same one `scripts/e2e-local.sh` saves).
    static let articleURL = value("SROKA_ARTICLE_URL") ?? "https://en.wikipedia.org/wiki/Eurasian_magpie"
    /// Title the parser gives that page.
    static let articleTitle = value("SROKA_ARTICLE_TITLE") ?? "Eurasian magpie"
    /// A word from the article body that is not in the title.
    static let articleWord = value("SROKA_ARTICLE_WORD") ?? "omnivorous"

    /// An environment value; empty counts as unset (the script passes empty strings through).
    static func value(_ name: String) -> String? {
        guard let value = env[name], !value.isEmpty else { return nil }
        return value
    }

    // MARK: Sign-in code from the wrangler log

    static func otpCount(for email: String) -> Int {
        otpLines(for: email).count
    }

    private static func otpLines(for email: String) -> [Substring] {
        guard let text = try? String(contentsOfFile: devLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").filter { $0.contains("[sroka] OTP for \(email): ") }
    }

    /// The newest code logged after `previousCount` codes for `email` existed; polls up to `timeout` seconds.
    static func waitForOtp(for email: String, after previousCount: Int, timeout: TimeInterval = 30) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = otpLines(for: email)
            if lines.count > previousCount, let line = lines.last,
                let range = line.range(of: #": \d{6}"#, options: .regularExpression)
            {
                return String(line[range].dropFirst(2))
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    // MARK: Network switch (the proxy in `scripts/journey-proxy.mjs`)

    static func setNetwork(up: Bool) {
        guard !netControl.isEmpty else { return }
        try? (up ? "up" : "down").write(toFile: netControl, atomically: true, encoding: .utf8)
    }
}

extension XCTestCase {
    /// A fresh launch of the live Dev app (no `-UITests`). Sign-in, consent and onboarding are the journeys' business.
    @MainActor
    func launchApp(terminateFirst: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if terminateFirst, app.state != .notRunning { app.terminate() }
        app.launch()
        return app
    }

    /// Screenshot of the whole screen as an attachment and, when `SROKA_SHOTS_DIR` is set, as a PNG file.
    @MainActor
    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !Journey.shotsDir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: Journey.shotsDir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(Journey.shotsDir)/\(name).png"))
    }

    /// Fails with the accessibility tree when `element` does not show up: the tree is what the next edit needs.
    @MainActor
    @discardableResult
    func expect(
        _ element: XCUIElement, _ what: String, timeout: TimeInterval = 15,
        app: XCUIApplication = XCUIApplication(), file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            shot("FAIL-\(what.replacingOccurrences(of: " ", with: "-"))")
            XCTFail("Missing: \(what)\n\(app.debugDescription)", file: file, line: line)
        }
        return element
    }
}

/// Screen-level steps shared by the journeys.
@MainActor
struct Screens {
    let app: XCUIApplication
    let test: XCTestCase

    var myListTab: XCUIElement { app.tabBars.buttons["My List"] }

    /// Dismisses the first-run consent prompt when it shows (it covers the library).
    func dismissConsentIfShown() {
        let decline = app.buttons["consent.decline"]
        if decline.waitForExistence(timeout: 3) { decline.tap() }
    }

    /// Signs in with email + code unless the app already shows the library. Returns once the tab bar is up.
    func ensureSignedIn() {
        if myListTab.waitForExistence(timeout: 6) {
            dismissConsentIfShown()
            return
        }
        signIn()
    }

    func signIn() {
        let emailField = app.textFields["auth.emailField"]
        test.expect(emailField, "sign-in email field", timeout: 20, app: app)
        if !Journey.serverURL.isEmpty { setCustomServer(Journey.serverURL) }
        emailField.tap()
        emailField.typeText(Journey.email)
        let before = Journey.otpCount(for: Journey.email)
        app.buttons["auth.sendCodeButton"].tap()
        let codeField = app.textFields["auth.codeField"]
        test.expect(codeField, "code field after send", app: app)
        guard let code = Journey.waitForOtp(for: Journey.email, after: before) else {
            XCTFail("No sign-in code logged in \(Journey.devLog) for the journey account")
            return
        }
        codeField.typeText(code)
        test.expect(myListTab, "My List tab after sign-in", timeout: 30, app: app)
        dismissConsentIfShown()
    }

    func setCustomServer(_ url: String) {
        let button = app.buttons["auth.selfHostingButton"]
        // Already pointing there ("Self-hosting? · localhost:8788").
        if let host = URL(string: url)?.host, button.label.contains(host) {
            let port = URL(string: url)?.port.map(String.init) ?? ""
            if port.isEmpty || button.label.contains(port) { return }
        }
        button.tap()
        let field = app.textFields["auth.serverField"]
        test.expect(field, "self-hosting server field", app: app)
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != "https://" {
            field.press(forDuration: 1.0)
            if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(url)
        app.buttons["auth.serverSaveButton"].tap()
    }

    /// The first list row whose accessibility label contains `text`.
    func row(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ AND traits != 0", text)).firstMatch
    }

    func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        test.expect(tab, "tab \(name)", app: app)
        tab.tap()
    }

    /// Add link sheet: type the URL and save.
    func saveLink(_ url: String) {
        let plus = app.buttons["Add link or PDF"].firstMatch
        test.expect(plus, "Add link button", app: app)
        plus.tap()
        let field = app.textFields["Link"].firstMatch
        test.expect(field, "Link field of the add sheet", app: app)
        // The sheet focuses its field itself; tapping again while it animates in can drop the keystrokes.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        if !app.keyboards.firstMatch.exists { field.tap() }
        field.typeText(url)
        let typed = (field.value as? String) ?? ""
        XCTAssertTrue(typed.contains(url), "typed link is in the field (field value: '\(typed)')")
        app.buttons["Save"].firstMatch.tap()
    }

    /// The row of the journey article once the parser has given it its real title (the pending row shows the host).
    @discardableResult
    func waitForArticleRow(timeout: TimeInterval = 120) -> XCUIElement {
        let row = row(containing: Journey.articleTitle)
        // No nudge: the app polls for the parse result by itself while it is active.
        test.expect(row, "row '\(Journey.articleTitle)' (saved and parsed)", timeout: timeout, app: app)
        return row
    }

    /// Signs in and makes sure My List holds the journey article (saves it when missing).
    func ensureArticle() {
        ensureSignedIn()
        openTab("My List")
        if row(containing: Journey.articleTitle).waitForExistence(timeout: 8) { return }
        saveLink(Journey.articleURL)
        waitForArticleRow()
    }

    /// Long-press the article's row and tap `title` in the context menu (or only check it is offered).
    func rowMenu(_ title: String, cancel: Bool = false) {
        let row = waitForArticleRow(timeout: 30)
        row.press(forDuration: 1.2)
        let entry = app.buttons[title].firstMatch
        test.expect(entry, "context menu entry '\(title)'", timeout: 8, app: app)
        if cancel {
            app.tap()
        } else {
            entry.tap()
        }
    }

    /// Reading progress in percent from the reader's progress line ("N percent").
    func readingProgress() -> Int {
        let line = app.descendants(matching: .any)["Reading progress"].firstMatch
        test.expect(line, "reading progress line", app: app)
        let value = (line.value as? String) ?? ""
        return Int(value.split(separator: " ").first ?? "") ?? -1
    }

    /// Number of article text blocks whose frame is on the screen right now (the web view also lists off-screen text).
    func visibleBodyTexts(in web: XCUIElement) -> Int {
        let screen = app.windows.firstMatch.frame
        let texts = web.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".{40,}"))
        var count = 0
        for index in 0..<min(texts.count, 80) {
            let frame = texts.element(boundBy: index).frame
            if frame.height > 0, frame.intersects(screen.insetBy(dx: 0, dy: 100)) { count += 1 }
        }
        return count
    }

    func closeReader() {
        let back = app.navigationBars.buttons.firstMatch
        // The chrome hides while reading (after scrolling): a tap on the page brings it back.
        if !back.waitForExistence(timeout: 2) || !back.isHittable { app.webViews.firstMatch.tap() }
        test.expect(back, "reader back button", app: app)
        back.tap()
    }

    /// Top edge (screen points) of the article title in the page header.
    func titleTop(in web: XCUIElement) -> CGFloat {
        let title = web.staticTexts.matching(NSPredicate(format: "label == %@", Journey.articleTitle)).firstMatch
        test.expect(title, "article title in the page header", app: app)
        return title.frame.minY
    }

    /// Bottom edge (screen points) of the floating back / Aa / more buttons.
    func topControlsBottom() -> CGFloat {
        let buttons = app.navigationBars.buttons
        var bottom: CGFloat = 0
        for index in 0..<buttons.count { bottom = max(bottom, buttons.element(boundBy: index).frame.maxY) }
        return bottom
    }

    /// The reader's own appearance sheet (Aa): pick a theme swatch by its label, then close the sheet.
    func chooseReaderTheme(_ name: String) {
        let aa = app.buttons["Appearance"].firstMatch
        if !aa.isHittable { app.webViews.firstMatch.tap() }  // the chrome is hidden: a tap on the page shows it
        test.expect(aa, "Aa (appearance) button", app: app)
        aa.tap()
        let swatch = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        test.expect(swatch, "theme swatch \(name)", app: app)
        swatch.tap()
        // Drag the fitted sheet down by its title (the sheet starts about half way down the screen).
        let title = app.staticTexts["Appearance"].firstMatch
        let from =
            title.exists
            ? title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
        XCTAssertTrue(test.waitForDisappearance(of: swatch), "the appearance sheet closes")
    }

    func openSettings() {
        let avatar = app.buttons["Settings"].firstMatch
        test.expect(avatar, "Settings (avatar) button", app: app)
        avatar.tap()
        test.expect(app.buttons["settings.doneButton"], "Settings sheet", app: app)
    }

    /// The Theme row of Settings (a menu picker whose label also carries the current value, e.g. "Theme, System").
    func themePicker() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Theme")).firstMatch
    }

    /// Theme picker (menu style): open it and choose `name`.
    func chooseTheme(_ name: String) {
        let picker = themePicker()
        test.expect(picker, "Theme picker", app: app)
        picker.tap()
        let option = app.buttons[name].firstMatch
        test.expect(option, "theme option \(name)", app: app)
        option.tap()
    }
}

extension XCTestCase {
    /// True once `element` no longer exists within `timeout` seconds.
    @MainActor
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}

/// Talks to the API as the journey account to learn ids the UI does not show (a second session of the same user).
enum JourneyAPI {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static var base: String { Journey.serverURL.isEmpty ? "http://localhost:8787" : Journey.serverURL }

    private static func send(
        _ method: String, _ path: String, body: [String: Any]? = nil, token: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: base + path) else { throw Failure(description: "bad URL \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("http://localhost:8787", forHTTPHeaderField: "Origin")
        request.setValue("XXXX.DUMMY.TOKEN.XXXX", forHTTPHeaderField: "x-turnstile-token")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    static func token() async throws -> String {
        for _ in 0..<4 {
            let before = Journey.otpCount(for: Journey.email)
            let (_, sent) = try await send(
                "POST", "/api/auth/email-otp/send-verification-otp",
                body: ["email": Journey.email, "type": "sign-in"])
            if sent.statusCode == 429 {
                try await Task.sleep(for: .seconds(20))
                continue
            }
            guard sent.statusCode == 200 else { throw Failure(description: "send OTP: HTTP \(sent.statusCode)") }
            guard let otp = Journey.waitForOtp(for: Journey.email, after: before) else {
                throw Failure(description: "no OTP in the dev log")
            }
            let (_, signed) = try await send(
                "POST", "/api/auth/sign-in/email-otp", body: ["email": Journey.email, "otp": otp])
            guard signed.statusCode == 200, let token = signed.value(forHTTPHeaderField: "set-auth-token") else {
                throw Failure(description: "sign-in: HTTP \(signed.statusCode)")
            }
            return token
        }
        throw Failure(description: "rate limited")
    }

    /// Id of the journey account's item whose canonical URL contains `fragment` (the part after the host is enough).
    static func itemId(urlContaining fragment: String) async throws -> String {
        let token = try await token()
        let (data, response) = try await send("GET", "/v1/items?state=all&limit=100", token: token)
        guard response.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["items"] as? [[String: Any]]
        else { throw Failure(description: "list items: HTTP \(response.statusCode)") }
        let tail = fragment.split(separator: "/").last.map(String.init) ?? fragment
        guard let item = items.first(where: { ($0["canonicalUrl"] as? String)?.contains(tail) == true }),
            let id = item["id"] as? String
        else { throw Failure(description: "no item matching \(tail) among \(items.count)") }
        return id
    }
}
