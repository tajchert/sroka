import XCTest

final class SrokaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsMyList() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITests"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["My List"].waitForExistence(timeout: 10))
    }
}
