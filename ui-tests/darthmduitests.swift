import XCTest

@MainActor
final class DarthMDUITests: XCTestCase {
    func testLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testMenusAndSplitControlAreReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        app.activate()
        app.typeKey("n", modifierFlags: .command)
        let splitButton = app.buttons["Toggle Split"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5))

        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        XCTAssertTrue(app.menuItems["Open…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        splitButton.click()
        XCTAssertTrue(
            app.textViews.element(boundBy: 1).waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.textViews.count, 2)
    }
}
