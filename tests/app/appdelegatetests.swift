import AppKit
import XCTest

@testable import DarthMD

@MainActor
final class AppDelegateTests: XCTestCase {
    func testFileMenuOmitsSaveAndRetainsSaveAs() {
        let originalMenu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = originalMenu
        }

        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu

        XCTAssertNil(fileMenu?.item(withTitle: "Save / Flush Now"))
        XCTAssertNil(fileMenu?.item(withTitle: "Revert to Saved"))
        XCTAssertNotNil(fileMenu?.item(withTitle: "Save As…"))
        XCTAssertFalse(
            fileMenu?.items.contains {
                $0.keyEquivalent == "s"
                    && $0.keyEquivalentModifierMask == .command
            } ?? true
        )
    }

    func testEditMenuRoutesUndoAndRedoThroughDocumentHistory() {
        let originalMenu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = originalMenu
        }
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
        let undoItem = editMenu?.item(withTitle: "Undo")
        let redoItem = editMenu?.item(withTitle: "Redo")

        XCTAssertTrue(undoItem?.target === delegate)
        XCTAssertEqual(undoItem?.action, Selector(("undoDocument:")))
        XCTAssertTrue(redoItem?.target === delegate)
        XCTAssertEqual(redoItem?.action, Selector(("redoDocument:")))
    }
}
