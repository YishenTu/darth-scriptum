import AppKit
import SwiftUI

@MainActor
final class MarkdownWindowController: NSWindowController, NSWindowDelegate {
    private final class WeakOwner {
        weak var value: MarkdownWindowController?

        init(_ value: MarkdownWindowController) {
            self.value = value
        }
    }

    private static var observationOwners: [ObjectIdentifier: WeakOwner] = [:]

    let workspaceModel: WorkspaceModel
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabWindowsObservation: NSKeyValueObservation?

    init(
        document: MarkdownDocument,
        onOpenMarkdownFile: @escaping (URL) -> Void
    ) {
        let displayName = document.displayName ?? "Untitled"
        workspaceModel = WorkspaceModel(
            onOpenMarkdownFile: onOpenMarkdownFile
        )
        let workspace = MarkdownWorkspace(
            syncCoordinator: document.syncCoordinator,
            model: workspaceModel,
            fileName: displayName
        )
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: workspace)
        )
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 680, height: 440)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .preferred
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        window.setAccessibilityLabel("DarthScriptum — \(displayName)")
    }

    func windowDidResignKey(_ notification: Notification) {
        (document as? MarkdownDocument)?.flushNow()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshTabShortcuts()
    }

    func windowWillClose(_ notification: Notification) {
        stopObservingTabGroup()
    }

    func refreshTabShortcuts() {
        guard let window else { return }
        if window.tabGroup?.selectedWindow === window {
            observeTabGroupIfNeeded(window.tabGroup)
        }
        TabShortcutPresentation.update(
            windows: window.tabGroup?.windows ?? [window]
        )
    }

    func focusNextPane() {
        focusPane(relativeOffset: 1)
    }

    func focusPreviousPane() {
        focusPane(relativeOffset: -1)
    }

    func focusLeftPane() {
        focus(workspaceModel.primaryPane)
    }

    func focusRightPane() {
        guard workspaceModel.isSplit else { return }
        focus(workspaceModel.secondaryPane)
    }

    func splitRight() {
        workspaceModel.splitRight()
        DispatchQueue.main.async { [weak self] in
            self?.focusRightPane()
        }
    }

    private func focusPane(relativeOffset: Int) {
        guard let window else { return }
        let textViews = descendantTextViews(in: window.contentView)
        guard !textViews.isEmpty else { return }
        let current = window.firstResponder as? NSTextView
        let currentIndex = current.flatMap { textViews.firstIndex(of: $0) } ?? 0
        let targetIndex = (currentIndex + relativeOffset + textViews.count) % textViews.count
        focus(textViews[targetIndex])
    }

    private func focus(_ pane: EditorPaneModel) {
        guard
            let textView = descendantTextViews(in: window?.contentView)
                .first(where: {
                    $0.identifier?.rawValue.hasSuffix(pane.id.uuidString) == true
                })
        else {
            return
        }
        focus(textView)
    }

    private func focus(_ textView: NSTextView) {
        window?.makeFirstResponder(textView)
        workspaceModel.activatePane(with: textView.identifier)
    }

    private func observeTabGroupIfNeeded(_ tabGroup: NSWindowTabGroup?) {
        guard let tabGroup else {
            stopObservingTabGroup()
            return
        }
        let key = ObjectIdentifier(tabGroup)
        if let previousOwner = Self.observationOwners[key]?.value,
            previousOwner !== self
        {
            previousOwner.stopObservingTabGroup()
        }
        guard observedTabGroup !== tabGroup else { return }
        stopObservingTabGroup()
        observedTabGroup = tabGroup
        Self.observationOwners[key] = WeakOwner(self)
        tabWindowsObservation = tabGroup.observe(
            \.windows,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshTabShortcuts()
            }
        }
    }

    private func stopObservingTabGroup() {
        if let observedTabGroup {
            let key = ObjectIdentifier(observedTabGroup)
            if Self.observationOwners[key]?.value === self {
                Self.observationOwners[key] = nil
            }
        }
        tabWindowsObservation?.invalidate()
        tabWindowsObservation = nil
        observedTabGroup = nil
    }

    func toggleTaskMarker() {
        guard let textView = window?.firstResponder as? NSTextView,
            let mutation = MarkdownEditingCommands.taskToggle(
                in: textView.string,
                selection: textView.selectedRange()
            )
        else {
            return
        }
        textView.insertText(
            mutation.replacement,
            replacementRange: mutation.range
        )
    }

    private func descendantTextViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] }
            ?? view.subviews.flatMap { descendantTextViews(in: $0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
