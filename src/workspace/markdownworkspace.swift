import AppKit
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var isSplit = false
    @Published var sourceMode = false
    @Published var fontSize: CGFloat = 14
    @Published private(set) var activePaneID: UUID

    let primaryPane: EditorPaneModel
    let secondaryPane: EditorPaneModel

    init() {
        let latexRenderer = AdaptiveLatexRenderer(
            updateNotification: Notification.Name(
                "DarthScriptum.LatexRendererDidUpdate.\(UUID().uuidString)"
            )
        )
        let mermaidRenderer = MermaidRenderer(
            updateNotification: Notification.Name(
                "DarthScriptum.MermaidRendererDidUpdate.\(UUID().uuidString)"
            )
        )
        let imageProvider = MarkdownImageProvider(documentURL: nil)
        let primaryPane = EditorPaneModel(
            latexRenderer: latexRenderer,
            mermaidRenderer: mermaidRenderer,
            imageProvider: imageProvider
        )
        self.primaryPane = primaryPane
        secondaryPane = EditorPaneModel(
            latexRenderer: latexRenderer,
            mermaidRenderer: mermaidRenderer,
            imageProvider: imageProvider
        )
        activePaneID = primaryPane.id
    }

    var activePane: EditorPaneModel {
        if isSplit, activePaneID == secondaryPane.id {
            return secondaryPane
        }
        return primaryPane
    }

    func toggleSplit() {
        isSplit.toggle()
        if !isSplit {
            activePaneID = primaryPane.id
        }
    }

    func splitRight() {
        isSplit = true
        activePaneID = secondaryPane.id
    }

    func activate(_ pane: EditorPaneModel) {
        guard pane.id == primaryPane.id
                || isSplit && pane.id == secondaryPane.id else {
            return
        }
        guard activePaneID != pane.id else { return }
        activePaneID = pane.id
    }

    func activatePane(with identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier else { return }
        if identifier.rawValue.hasSuffix(primaryPane.id.uuidString) {
            activate(primaryPane)
        } else if identifier.rawValue.hasSuffix(secondaryPane.id.uuidString) {
            activate(secondaryPane)
        }
    }

    func toggleSourceMode() {
        sourceMode.toggle()
    }

    func zoom(by delta: CGFloat) {
        fontSize = min(max(fontSize + delta, 10), 32)
    }

    func resetZoom() {
        fontSize = 14
    }
}

struct MarkdownWorkspace: View {
    @ObservedObject var syncCoordinator: DocumentSyncCoordinator
    @ObservedObject var model: WorkspaceModel
    let fileName: String

    var body: some View {
        ZStack {
            MaterialView()
                .ignoresSafeArea()
            Color(nsColor: AppTheme.background)
                .opacity(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                        ? 1
                        : AppTheme.backgroundOverlayOpacity
                )
                .ignoresSafeArea()
            VStack(spacing: 0) {
                editorSurface
                Divider().overlay(Color(nsColor: AppTheme.separator))
                statusBar
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder
    private var editorSurface: some View {
        if model.isSplit {
            HSplitView {
                editor(pane: model.primaryPane)
                editor(pane: model.secondaryPane)
            }
        } else {
            editor(pane: model.primaryPane)
        }
    }

    private func editor(pane: EditorPaneModel) -> some View {
        LivePreviewTextView(
            sourceBuffer: syncCoordinator.sourceBuffer,
            pane: pane,
            sourceMode: model.sourceMode,
            fontSize: model.fontSize,
            newlineStyle: syncCoordinator.format.dominantNewline,
            documentURL: syncCoordinator.fileURL,
            onBecameActive: {
                model.activate(pane)
            }
        )
        .id(pane.id)
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(syncCoordinator.fileURL?.lastPathComponent ?? fileName)
                .lineLimit(1)
            if let statusPresentation {
                Label(
                    statusPresentation.message,
                    systemImage: statusPresentation.systemImage
                )
                    .foregroundStyle(statusColor(for: statusPresentation.tone))
                    .accessibilityLabel(
                        "Synchronization status: \(statusPresentation.message)"
                    )
                if let action = statusPresentation.primaryAction {
                    Button(action.label) {
                        performStatusAction(action)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.accent))
                    .accessibilityLabel(action.label)
                }
                if statusPresentation.offersLocalRevisionRestore {
                    Button("Restore Local Revision") {
                        syncCoordinator.restoreLatestRecovery()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.accent))
                    .accessibilityLabel("Restore Local Revision")
                }
                if statusPresentation.offersRawRecoveryDiscard {
                    Button("Discard Raw Recovery & Resume") {
                        syncCoordinator.resumeSynchronization()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.failure))
                    .accessibilityLabel(
                        "Discard Raw Recovery and Resume Synchronization"
                    )
                }
            }
            Spacer()
            PanePositionStatus(pane: model.activePane)
                .id(model.activePaneID)
            Text(syncCoordinator.format.encoding.displayName)
            Text(syncCoordinator.format.dominantNewline.rawValue.uppercased())
            Button {
                model.toggleSourceMode()
            } label: {
                Image(
                    systemName: model.sourceMode
                        ? "eye"
                        : "chevron.left.forwardslash.chevron.right"
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: AppTheme.accent))
            .help(model.sourceMode ? "Use Live Preview" : "Use Source Mode")
            .accessibilityLabel("Toggle Source Mode")
            Button {
                model.toggleSplit()
            } label: {
                Image(systemName: model.isSplit ? "rectangle" : "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: AppTheme.accent))
            .help(model.isSplit ? "Close Split" : "Split Editor")
            .accessibilityLabel("Toggle Split")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(nsColor: AppTheme.mutedForeground))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Color(nsColor: AppTheme.background)
                .opacity(AppTheme.statusBarOverlayOpacity)
        )
    }

    private var statusPresentation: SynchronizationStatusPresentation? {
        let snapshot = syncCoordinator.statusSnapshot
        return snapshot.presentedState.flatMap {
            SynchronizationStatusPresentation.make(
                for: $0,
                failureRequiresSaveAs: snapshot.failureRequiresSaveAs,
                recoveryMigrationIsPending:
                    snapshot.recoveryMigrationIsPending,
                rawRecoveryURL: snapshot.rawRecoveryURL,
                hasLocalRecovery: snapshot.hasLocalRecovery
            )
        }
    }

    private func statusColor(
        for tone: SynchronizationStatusPresentation.Tone
    ) -> Color {
        switch tone {
        case .failure:
            Color(nsColor: AppTheme.failure)
        case .accent:
            Color(nsColor: AppTheme.accent)
        }
    }

    private func performStatusAction(
        _ action: SynchronizationStatusPresentation.Action
    ) {
        switch action {
        case .restoreLocalRevision:
            syncCoordinator.restoreLatestRecovery()
        case .saveAs:
            NSApp.sendAction(
                #selector(NSDocument.saveAs(_:)),
                to: nil,
                from: nil
            )
        case .retrySynchronization:
            syncCoordinator.retrySynchronization()
        case .retryRecoveryMigration:
            syncCoordinator.retryRecoveryMigration()
        case let .showRecoveryFile(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct SynchronizationStatusPresentation: Equatable {
    enum Tone: Equatable {
        case accent
        case failure
    }

    enum Action: Equatable {
        case restoreLocalRevision
        case saveAs
        case retrySynchronization
        case retryRecoveryMigration
        case showRecoveryFile(URL)

        var label: String {
            switch self {
            case .restoreLocalRevision: "Restore Local Revision"
            case .saveAs: "Save As…"
            case .retrySynchronization: "Retry"
            case .retryRecoveryMigration: "Retry Recovery Migration"
            case .showRecoveryFile: "Show Recovery File"
            }
        }
    }

    let message: String
    let systemImage: String
    let tone: Tone
    let primaryAction: Action?
    let offersLocalRevisionRestore: Bool
    let offersRawRecoveryDiscard: Bool

    static func make(
        for state: SynchronizationState,
        failureRequiresSaveAs: Bool = false,
        recoveryMigrationIsPending: Bool = false,
        rawRecoveryURL: URL? = nil,
        hasLocalRecovery: Bool = false
    ) -> SynchronizationStatusPresentation? {
        guard let message = message(for: state) else { return nil }
        let systemImage: String
        let tone: Tone
        let primaryAction: Action?
        switch state {
        case .recoveredConflict:
            systemImage = "arrow.triangle.branch"
            tone = .accent
            primaryAction = .restoreLocalRevision
        case .readOnly, .missing:
            systemImage = "exclamationmark.triangle.fill"
            tone = .failure
            primaryAction = .saveAs
        case .failed:
            systemImage = "exclamationmark.triangle.fill"
            tone = .failure
            primaryAction = failureRequiresSaveAs
                ? .saveAs
                : .retrySynchronization
        case .limitedSyncSafety:
            systemImage = "arrow.triangle.branch"
            tone = .accent
            primaryAction = nil
        case .synchronizationPaused:
            systemImage = "exclamationmark.triangle.fill"
            tone = .failure
            if recoveryMigrationIsPending {
                primaryAction = .retryRecoveryMigration
            } else if let rawRecoveryURL {
                primaryAction = .showRecoveryFile(rawRecoveryURL)
            } else {
                primaryAction = .saveAs
            }
        case .idle,
             .waitingToWrite,
             .writing,
             .checkingExternalChange,
             .reloading,
             .merging:
            return nil
        }
        return SynchronizationStatusPresentation(
            message: message,
            systemImage: systemImage,
            tone: tone,
            primaryAction: primaryAction,
            offersLocalRevisionRestore:
                state == .synchronizationPaused && hasLocalRecovery,
            offersRawRecoveryDiscard:
                state == .synchronizationPaused && rawRecoveryURL != nil
        )
    }

    static func message(for state: SynchronizationState) -> String? {
        switch state {
        case .idle,
             .waitingToWrite,
             .writing,
             .checkingExternalChange,
             .reloading,
             .merging:
            nil
        case .recoveredConflict: "Disk version shown · local revision recoverable"
        case .readOnly: "Read only"
        case .missing: "File missing"
        case let .failed(message): message
        case .limitedSyncSafety: "Limited sync safety"
        case .synchronizationPaused: "Synchronization paused"
        }
    }
}

private struct PanePositionStatus: View {
    @ObservedObject var pane: EditorPaneModel

    var body: some View {
        if pane.isPositionPending {
            Text("Indexing")
        } else {
            Text("Ln \(pane.line), Col \(pane.column)")
        }
    }
}

private extension TextEncoding {
    var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8WithBOM: "UTF-8 BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        }
    }
}

enum TabShortcutPolicy {
    static let lastTabShortcut = 9
    private static let directShortcutRange = 1...8

    static func selectionIndex(
        for shortcutNumber: Int,
        tabCount: Int
    ) -> Int? {
        guard tabCount > 0 else { return nil }
        if shortcutNumber == lastTabShortcut {
            return tabCount - 1
        }
        guard directShortcutRange.contains(shortcutNumber),
              shortcutNumber <= tabCount else {
            return nil
        }
        return shortcutNumber - 1
    }

    static func displayNumber(
        forTabAt index: Int,
        tabCount: Int
    ) -> Int? {
        guard tabCount > 1, index >= 0, index < tabCount else {
            return nil
        }
        if index < directShortcutRange.upperBound {
            return index + 1
        }
        return index == tabCount - 1 ? lastTabShortcut : nil
    }
}

@MainActor
enum TabShortcutPresentation {
    private static let labelIdentifier = NSUserInterfaceItemIdentifier(
        "DarthScriptum.TabShortcut"
    )

    static func update(windows: [NSWindow]) {
        for (index, window) in windows.enumerated() {
            guard let number = TabShortcutPolicy.displayNumber(
                forTabAt: index,
                tabCount: windows.count
            ) else {
                if window.tab.accessoryView != nil {
                    window.tab.accessoryView = nil
                }
                continue
            }
            let label = shortcutLabel(for: window)
            let title = "⌘\(number)"
            if label.stringValue != title {
                label.stringValue = title
                label.setAccessibilityLabel("Command-\(number)")
            }
            if window.tab.accessoryView !== label {
                window.tab.accessoryView = label
            }
        }
    }

    private static func shortcutLabel(for window: NSWindow) -> NSTextField {
        if let label = window.tab.accessoryView as? NSTextField,
           label.identifier == labelIdentifier {
            return label
        }
        let label = NSTextField(labelWithString: "")
        label.identifier = labelIdentifier
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(
            ofSize: 10,
            weight: .medium
        )
        label.textColor = .tertiaryLabelColor
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 24),
            label.heightAnchor.constraint(equalToConstant: 16)
        ])
        return label
    }
}

@MainActor
final class MarkdownWindowController: NSWindowController, NSWindowDelegate {
    private final class WeakOwner {
        weak var value: MarkdownWindowController?

        init(_ value: MarkdownWindowController) {
            self.value = value
        }
    }

    private static var observationOwners: [
        ObjectIdentifier: WeakOwner
    ] = [:]

    let workspaceModel: WorkspaceModel
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabWindowsObservation: NSKeyValueObservation?

    init(document: MarkdownDocument) {
        let displayName = document.displayName ?? "Untitled"
        workspaceModel = WorkspaceModel()
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
        let targetIndex = (
            currentIndex + relativeOffset + textViews.count
        ) % textViews.count
        focus(textViews[targetIndex])
    }

    private func focus(_ pane: EditorPaneModel) {
        guard let textView = descendantTextViews(in: window?.contentView)
            .first(where: {
                $0.identifier?.rawValue.hasSuffix(pane.id.uuidString) == true
            }) else {
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
           previousOwner !== self {
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
              ) else {
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
