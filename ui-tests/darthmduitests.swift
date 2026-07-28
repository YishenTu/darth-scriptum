import XCTest

@MainActor
final class DarthMDUITests: XCTestCase {
    private static let editorLaunchArguments = [
        "-ApplePersistenceIgnoreState", "YES",
        "--skip-opening-untitled-document"
    ]

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.editorLaunchArguments
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        app.activate()

        let fileMenu = app.menuBars.menuBarItems["File"]
        guard fileMenu.waitForExistence(timeout: 5) else {
            XCTFail("File menu did not become available")
            return app
        }
        fileMenu.click()

        let newItem = app.menuItems["New"]
        guard newItem.waitForExistence(timeout: 5) else {
            XCTFail("New menu item did not become available")
            return app
        }
        newItem.click()

        XCTAssertTrue(
            app.textViews.element(boundBy: 0).waitForExistence(timeout: 5)
        )
        return app
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testMenusAndSplitControlAreReachable() {
        let app = launchEditor()

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

    func testKeyboardShortcutsOpenTabAndSplitRight() {
        let app = launchEditor()

        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(
            app.textViews.element(boundBy: 1).waitForExistence(timeout: 5)
        )

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(
            app.textViews.element(boundBy: 0).waitForExistence(timeout: 5)
        )
    }

    func testNumberShortcutsSelectTabs() {
        let app = launchEditor()
        defer {
            for number in ["1", "2", "3"] {
                app.typeKey(number, modifierFlags: .command)
                let activeEditor = app.textViews.firstMatch
                if activeEditor.waitForExistence(timeout: 2) {
                    activeEditor.click()
                    app.typeKey("a", modifierFlags: .command)
                    app.typeKey(.delete, modifierFlags: [])
                }
            }
        }

        var activeEditor = app.textViews.firstMatch
        XCTAssertTrue(activeEditor.waitForExistence(timeout: 5))
        activeEditor.click()
        activeEditor.typeText("first")

        app.typeKey("t", modifierFlags: .command)
        activeEditor = app.textViews.firstMatch
        XCTAssertTrue(activeEditor.waitForExistence(timeout: 5))
        activeEditor.click()
        activeEditor.typeText("second")

        app.typeKey("t", modifierFlags: .command)
        activeEditor = app.textViews.firstMatch
        XCTAssertTrue(activeEditor.waitForExistence(timeout: 5))
        activeEditor.click()
        activeEditor.typeText("third")

        for (number, expectedText) in [
            ("1", "first"),
            ("2", "second"),
            ("3", "third")
        ] {
            app.typeKey(number, modifierFlags: .command)
            activeEditor = app.textViews.firstMatch
            XCTAssertTrue(activeEditor.waitForExistence(timeout: 5))
            XCTAssertEqual(
                (activeEditor.value as? String)?.lowercased(),
                expectedText
            )
        }
    }
}
