import AppKit
import XCTest

@testable import DarthScriptum

@objc private protocol AppDelegateMenuActions {
    func undoDocument(_ sender: Any?)
    func redoDocument(_ sender: Any?)
    func splitRight(_ sender: Any?)
    func focusPreviousPane(_ sender: Any?)
    func focusNextPane(_ sender: Any?)
    func focusLeftPane(_ sender: Any?)
    func focusRightPane(_ sender: Any?)
    func toggleFullScreen(_ sender: Any?)
    func selectTab(_ sender: NSMenuItem)
}

@MainActor
final class AppDelegateTests: XCTestCase {
    func testFileMenuContainsNativeSaveAsWithoutManualInPlaceSaveCommands() {
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
        let saveAsItem = fileMenu?.item(withTitle: "Save As…")
        XCTAssertNil(saveAsItem?.target)
        assertShortcut(
            saveAsItem,
            key: "s",
            modifiers: [.command, .shift],
            action: #selector(NSDocument.saveAs(_:))
        )
        XCTAssertFalse(
            fileMenu?.items.contains {
                $0.keyEquivalent.lowercased() == "s"
                    && $0.keyEquivalentModifierMask.contains(.command)
                    && !$0.keyEquivalentModifierMask.contains(.shift)
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
        XCTAssertEqual(
            undoItem?.action,
            #selector(AppDelegateMenuActions.undoDocument(_:))
        )
        XCTAssertTrue(redoItem?.target === delegate)
        XCTAssertEqual(
            redoItem?.action,
            #selector(AppDelegateMenuActions.redoDocument(_:))
        )
    }

    func testCommonMacOSKeyboardShortcutsAreInstalled() {
        let originalMenu = NSApp.mainMenu
        defer {
            NSApp.mainMenu = originalMenu
        }
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        let appMenu = NSApp.mainMenu?.item(withTitle: "DarthScriptum")?.submenu
        let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        let windowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu

        assertShortcut(
            appMenu?.item(withTitle: "Hide DarthScriptum"),
            key: "h",
            modifiers: [.command],
            action: #selector(NSApplication.hide(_:))
        )
        assertShortcut(
            appMenu?.item(withTitle: "Hide Others"),
            key: "h",
            modifiers: [.command, .option],
            action: #selector(NSApplication.hideOtherApplications(_:))
        )
        assertShortcut(
            fileMenu?.item(withTitle: "New Tab"),
            key: "t",
            modifiers: [.command],
            action: #selector(NSDocumentController.newDocument(_:))
        )
        assertShortcut(
            viewMenu?.item(withTitle: "Split Right"),
            key: "d",
            modifiers: [.command],
            action: #selector(AppDelegateMenuActions.splitRight(_:))
        )
        assertShortcut(
            viewMenu?.item(withTitle: "Focus Previous Pane"),
            key: "[",
            modifiers: [.command],
            action: #selector(AppDelegateMenuActions.focusPreviousPane(_:))
        )
        assertShortcut(
            viewMenu?.item(withTitle: "Focus Next Pane"),
            key: "]",
            modifiers: [.command],
            action: #selector(AppDelegateMenuActions.focusNextPane(_:))
        )
        assertShortcut(
            viewMenu?.item(withTitle: "Focus Left Pane"),
            key: "1",
            modifiers: [.control],
            action: #selector(AppDelegateMenuActions.focusLeftPane(_:))
        )
        assertShortcut(
            viewMenu?.item(withTitle: "Focus Right Pane"),
            key: "2",
            modifiers: [.control],
            action: #selector(AppDelegateMenuActions.focusRightPane(_:))
        )
        assertShortcut(
            windowMenu?.item(withTitle: "Toggle Full Screen"),
            key: "f",
            modifiers: [.command, .control],
            action: #selector(AppDelegateMenuActions.toggleFullScreen(_:))
        )
        for number in 1...8 {
            let item = windowMenu?.item(withTitle: "Show Tab \(number)")
            assertShortcut(
                item,
                key: "\(number)",
                modifiers: [.command],
                action: #selector(AppDelegateMenuActions.selectTab(_:))
            )
            XCTAssertEqual(item?.tag, number)
        }
        let lastTabItem = windowMenu?.item(withTitle: "Show Last Tab")
        assertShortcut(
            lastTabItem,
            key: "9",
            modifiers: [.command],
            action: #selector(AppDelegateMenuActions.selectTab(_:))
        )
        XCTAssertEqual(lastTabItem?.tag, 9)
    }

    func testOnlyNonemptyUntitledDocumentsRequireSavingOnClose() {
        let document = MarkdownDocument()
        XCTAssertFalse(document.hasUnsavedUntitledContent)

        document.syncCoordinator.sourceBuffer.replace(
            with: "# Draft",
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertTrue(document.hasUnsavedUntitledContent)

        document.syncCoordinator.sourceBuffer.replace(
            with: "",
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertFalse(document.hasUnsavedUntitledContent)
    }

    private func assertShortcut(
        _ item: NSMenuItem?,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        action: Selector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(item?.keyEquivalent, key, file: file, line: line)
        XCTAssertEqual(
            item?.keyEquivalentModifierMask,
            modifiers,
            file: file,
            line: line
        )
        XCTAssertEqual(item?.action, action, file: file, line: line)
    }
}
