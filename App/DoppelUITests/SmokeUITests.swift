import XCTest

/// Smoke test: app launches and shows the empty state. Expanded in Milestone 4+.
final class SmokeUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Choose folders to find duplicates"].waitForExistence(timeout: 5))
    }
}
