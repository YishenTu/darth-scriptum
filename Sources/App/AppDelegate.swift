import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var opensSeparately = false
    private var openRecentMenu: NSMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        installMainMenu()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !ProcessInfo.processInfo.arguments.contains(
            "--skip-opening-untitled-document"
        )
    }

    func applicationShouldSaveSecureApplicationState(
        _ app: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(
        _ app: NSApplication
    ) -> Bool {
        false
    }

    @objc private func newWindow(_ sender: Any?) {
        opensSeparately = true
        NSDocumentController.shared.newDocument(sender)
        DispatchQueue.main.async { [weak self] in
            self?.opensSeparately = false
        }
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { _, _, error in
            if let error {
                NSDocumentController.shared.presentError(error)
            }
        }
    }

    @objc private func toggleSourceMode(_ sender: Any?) {
        currentDocument?.markdownWindowController?.workspaceModel.toggleSourceMode()
    }

    @objc private func toggleSplit(_ sender: Any?) {
        currentDocument?.markdownWindowController?.workspaceModel.toggleSplit()
    }

    @objc private func splitRight(_ sender: Any?) {
        currentDocument?.markdownWindowController?.splitRight()
    }

    @objc private func focusPreviousPane(_ sender: Any?) {
        currentDocument?.markdownWindowController?.focusPreviousPane()
    }

    @objc private func focusNextPane(_ sender: Any?) {
        currentDocument?.markdownWindowController?.focusNextPane()
    }

    @objc private func focusLeftPane(_ sender: Any?) {
        currentDocument?.markdownWindowController?.focusLeftPane()
    }

    @objc private func focusRightPane(_ sender: Any?) {
        currentDocument?.markdownWindowController?.focusRightPane()
    }

    @objc private func toggleTaskMarker(_ sender: Any?) {
        currentDocument?.markdownWindowController?.toggleTaskMarker()
    }

    @objc private func undoDocument(_ sender: Any?) {
        currentDocument?.syncCoordinator.sourceBuffer.undo()
    }

    @objc private func redoDocument(_ sender: Any?) {
        currentDocument?.syncCoordinator.sourceBuffer.redo()
    }

    @objc private func zoomIn(_ sender: Any?) {
        currentDocument?.markdownWindowController?.workspaceModel.zoom(by: 1)
    }

    @objc private func zoomOut(_ sender: Any?) {
        currentDocument?.markdownWindowController?.workspaceModel.zoom(by: -1)
    }

    @objc private func actualSize(_ sender: Any?) {
        currentDocument?.markdownWindowController?.workspaceModel.resetZoom()
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        NSApp.keyWindow?.toggleFullScreen(sender)
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        guard let currentWindow = NSApp.keyWindow else { return }
        let windows = currentWindow.tabGroup?.windows ?? [currentWindow]
        guard
            let index = TabShortcutPolicy.selectionIndex(
                for: sender.tag,
                tabCount: windows.count
            )
        else {
            return
        }
        let targetWindow = windows[index]
        if let tabGroup = currentWindow.tabGroup {
            tabGroup.selectedWindow = targetWindow
        }
        targetWindow.makeKeyAndOrderFront(sender)
    }

    @objc private func restoreLocalRevision(_ sender: Any?) {
        currentDocument?.syncCoordinator.restoreLatestRecovery()
    }

    private var currentDocument: MarkdownDocument? {
        NSApp.keyWindow?.windowController?.document as? MarkdownDocument
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()
        let controller = NSDocumentController.shared
        for url in controller.recentDocumentURLs {
            let item = menu.addItem(
                withTitle: url.lastPathComponent,
                action: #selector(openRecentDocument(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
        }
        if !controller.recentDocumentURLs.isEmpty {
            menu.addItem(.separator())
        }
        let clearItem = menu.addItem(
            withTitle: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clearItem.target = controller
        clearItem.isEnabled = !controller.recentDocumentURLs.isEmpty
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(
            title: "DarthScriptum",
            action: nil,
            keyEquivalent: ""
        )
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About DarthScriptum",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(
            withTitle: "Hide DarthScriptum",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        let showAllItem = appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(
            withTitle: "Quit DarthScriptum",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let newItem = fileMenu.addItem(
            withTitle: "New",
            action: #selector(NSDocumentController.newDocument(_:)),
            keyEquivalent: "n"
        )
        newItem.target = NSDocumentController.shared
        let newTabItem = fileMenu.addItem(
            withTitle: "New Tab",
            action: #selector(NSDocumentController.newDocument(_:)),
            keyEquivalent: "t"
        )
        newTabItem.target = NSDocumentController.shared
        let newWindowItem = fileMenu.addItem(
            withTitle: "New Window",
            action: #selector(newWindow(_:)),
            keyEquivalent: "n"
        )
        newWindowItem.keyEquivalentModifierMask = [.command, .option]
        newWindowItem.target = self
        let openItem = fileMenu.addItem(
            withTitle: "Open…",
            action: #selector(NSDocumentController.openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = NSDocumentController.shared
        let recentItem = NSMenuItem(
            title: "Open Recent",
            action: nil,
            keyEquivalent: ""
        )
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        openRecentMenu = recentMenu
        fileMenu.addItem(.separator())
        let saveAsItem = fileMenu.addItem(
            withTitle: "Save As…",
            action: #selector(NSDocument.saveAs(_:)),
            keyEquivalent: "s"
        )
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let undoItem = editMenu.addItem(
            withTitle: "Undo",
            action: #selector(undoDocument(_:)),
            keyEquivalent: "z"
        )
        undoItem.target = self
        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: #selector(redoDocument(_:)),
            keyEquivalent: "Z"
        )
        redoItem.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)
        for (title, tag, key, modifiers) in [
            ("Find…", 1, "f", NSEvent.ModifierFlags.command),
            ("Find Next", 2, "g", NSEvent.ModifierFlags.command),
            ("Find Previous", 3, "g", [.command, .shift]),
            ("Find and Replace…", 12, "f", [.command, .option]),
        ] {
            let item = findMenu.addItem(
                withTitle: title,
                action: #selector(NSTextView.performTextFinderAction(_:)),
                keyEquivalent: key
            )
            item.tag = tag
            item.keyEquivalentModifierMask = modifiers
        }
        editMenu.addItem(.separator())
        let toggleTaskItem = editMenu.addItem(
            withTitle: "Toggle Task Marker",
            action: #selector(toggleTaskMarker(_:)),
            keyEquivalent: "x"
        )
        toggleTaskItem.keyEquivalentModifierMask = [.command, .shift]
        toggleTaskItem.target = self

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let sourceItem = viewMenu.addItem(
            withTitle: "Toggle Source Mode",
            action: #selector(toggleSourceMode(_:)),
            keyEquivalent: "e"
        )
        sourceItem.target = self
        let splitRightItem = viewMenu.addItem(
            withTitle: "Split Right",
            action: #selector(splitRight(_:)),
            keyEquivalent: "d"
        )
        splitRightItem.target = self
        let toggleSplitItem = viewMenu.addItem(
            withTitle: "Toggle Split",
            action: #selector(toggleSplit(_:)),
            keyEquivalent: "\\"
        )
        toggleSplitItem.target = self
        viewMenu.addItem(.separator())
        let previousPaneItem = viewMenu.addItem(
            withTitle: "Focus Previous Pane",
            action: #selector(focusPreviousPane(_:)),
            keyEquivalent: "["
        )
        previousPaneItem.target = self
        let nextPaneItem = viewMenu.addItem(
            withTitle: "Focus Next Pane",
            action: #selector(focusNextPane(_:)),
            keyEquivalent: "]"
        )
        nextPaneItem.target = self
        let leftPaneItem = viewMenu.addItem(
            withTitle: "Focus Left Pane",
            action: #selector(focusLeftPane(_:)),
            keyEquivalent: "1"
        )
        leftPaneItem.keyEquivalentModifierMask = [.control]
        leftPaneItem.target = self
        let rightPaneItem = viewMenu.addItem(
            withTitle: "Focus Right Pane",
            action: #selector(focusRightPane(_:)),
            keyEquivalent: "2"
        )
        rightPaneItem.keyEquivalentModifierMask = [.control]
        rightPaneItem.target = self
        viewMenu.addItem(.separator())
        for (title, action, key) in [
            ("Zoom In", #selector(zoomIn(_:)), "+"),
            ("Zoom Out", #selector(zoomOut(_:)), "-"),
            ("Actual Size", #selector(actualSize(_:)), "0"),
        ] {
            let item = viewMenu.addItem(
                withTitle: title,
                action: action,
                keyEquivalent: key
            )
            item.target = self
        }
        viewMenu.addItem(.separator())
        let restoreItem = viewMenu.addItem(
            withTitle: "Restore Local Revision",
            action: #selector(restoreLocalRevision(_:)),
            keyEquivalent: ""
        )
        restoreItem.target = self

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        let fullScreenItem = windowMenu.addItem(
            withTitle: "Toggle Full Screen",
            action: #selector(toggleFullScreen(_:)),
            keyEquivalent: ""
        )
        fullScreenItem.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Show Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            keyEquivalent: "{"
        )
        windowMenu.addItem(
            withTitle: "Show Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            keyEquivalent: "}"
        )
        windowMenu.addItem(.separator())
        for number in 1...8 {
            let item = windowMenu.addItem(
                withTitle: "Show Tab \(number)",
                action: #selector(selectTab(_:)),
                keyEquivalent: "\(number)"
            )
            item.tag = number
            item.target = self
        }
        let lastTabItem = windowMenu.addItem(
            withTitle: "Show Last Tab",
            action: #selector(selectTab(_:)),
            keyEquivalent: "9"
        )
        lastTabItem.tag = 9
        lastTabItem.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Move Tab to New Window",
            action: #selector(NSWindow.moveTabToNewWindow(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(
            withTitle: "Merge All Windows",
            action: #selector(NSWindow.mergeAllWindows(_:)),
            keyEquivalent: ""
        )
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        fullScreenItem.keyEquivalent = "f"
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
    }
}
