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
        let primaryPane = EditorPaneModel()
        self.primaryPane = primaryPane
        secondaryPane = EditorPaneModel()
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
            DarthMaterialView()
            Color(nsColor: DarthTheme.background)
                .opacity(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                        ? 1
                        : 0.7
                )
            VStack(spacing: 0) {
                editorSurface
                Divider().overlay(Color(nsColor: DarthTheme.separator))
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
            if let statusText {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                    .accessibilityLabel("Synchronization status: \(statusText)")
                if let statusActionLabel {
                    Button(statusActionLabel) {
                        performStatusAction()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: DarthTheme.accent))
                    .accessibilityLabel(statusActionLabel)
                }
                if syncCoordinator.state == .synchronizationPaused,
                   syncCoordinator.hasLocalRecovery {
                    Button("Restore Local Revision") {
                        syncCoordinator.restoreLatestRecovery()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: DarthTheme.accent))
                    .accessibilityLabel("Restore Local Revision")
                }
                if syncCoordinator.state == .synchronizationPaused,
                   syncCoordinator.latestRawRecoveryURL != nil {
                    Button("Discard Raw Recovery & Resume") {
                        syncCoordinator.resumeSynchronization()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: DarthTheme.failure))
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
                Image(systemName: model.sourceMode ? "textformat.alt" : "textformat")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: DarthTheme.accent))
            .help(model.sourceMode ? "Use Live Preview" : "Use Source Mode")
            .accessibilityLabel("Toggle Source Mode")
            Button {
                model.toggleSplit()
            } label: {
                Image(systemName: model.isSplit ? "rectangle" : "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: DarthTheme.accent))
            .help(model.isSplit ? "Close Split" : "Split Editor")
            .accessibilityLabel("Toggle Split")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(nsColor: DarthTheme.mutedForeground))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color(nsColor: DarthTheme.background).opacity(0.78))
    }

    private var statusText: String? {
        switch syncCoordinator.state {
        case .idle: nil
        case .waitingToWrite, .writing: "Updating file"
        case .checkingExternalChange: "Checking"
        case .reloading: "Reloading"
        case .merging: "Merging"
        case .recoveredConflict: "Disk version shown · local revision recoverable"
        case .readOnly: "Read only"
        case .missing: "File missing"
        case let .failed(message): message
        case .limitedSyncSafety: "Limited sync safety"
        case .synchronizationPaused: "Synchronization paused"
        }
    }

    private var statusIcon: String {
        switch syncCoordinator.state {
        case .failed, .missing, .readOnly, .synchronizationPaused:
            "exclamationmark.triangle.fill"
        case .recoveredConflict, .limitedSyncSafety:
            "arrow.triangle.branch"
        default:
            "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch syncCoordinator.state {
        case .failed, .missing, .readOnly, .synchronizationPaused:
            Color(nsColor: DarthTheme.failure)
        default:
            Color(nsColor: DarthTheme.accent)
        }
    }

    private var statusActionLabel: String? {
        switch syncCoordinator.state {
        case .recoveredConflict:
            "Restore Local Revision"
        case .readOnly, .missing:
            "Save As…"
        case .failed:
            syncCoordinator.failureRequiresSaveAs ? "Save As…" : "Retry"
        case .synchronizationPaused:
            if syncCoordinator.recoveryMigrationIsPending {
                "Retry Recovery Migration"
            } else if syncCoordinator.latestRawRecoveryURL != nil {
                "Show Recovery File"
            } else {
                "Save As…"
            }
        default:
            nil
        }
    }

    private func performStatusAction() {
        switch syncCoordinator.state {
        case .recoveredConflict:
            syncCoordinator.restoreLatestRecovery()
        case .readOnly, .missing:
            NSApp.sendAction(
                #selector(NSDocument.saveAs(_:)),
                to: nil,
                from: nil
            )
        case .failed:
            if syncCoordinator.failureRequiresSaveAs {
                NSApp.sendAction(
                    #selector(NSDocument.saveAs(_:)),
                    to: nil,
                    from: nil
                )
            } else {
                syncCoordinator.retrySynchronization()
            }
        case .synchronizationPaused:
            if syncCoordinator.recoveryMigrationIsPending {
                syncCoordinator.retryRecoveryMigration()
            } else if let url = syncCoordinator.latestRawRecoveryURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSApp.sendAction(
                    #selector(NSDocument.saveAs(_:)),
                    to: nil,
                    from: nil
                )
            }
        default:
            break
        }
    }
}

private struct PanePositionStatus: View {
    @ObservedObject var pane: EditorPaneModel

    var body: some View {
        Text("Ln \(pane.line), Col \(pane.column)")
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

@MainActor
final class MarkdownWindowController: NSWindowController, NSWindowDelegate {
    let workspaceModel: WorkspaceModel

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
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .preferred
        window.backgroundColor = DarthTheme.background
        super.init(window: window)
        window.delegate = self
        window.setAccessibilityLabel("DarthMD — \(displayName)")
    }

    func windowDidResignKey(_ notification: Notification) {
        (document as? MarkdownDocument)?.flushNow()
    }

    func focusNextPane() {
        guard let window else { return }
        let textViews = descendantTextViews(in: window.contentView)
        guard !textViews.isEmpty else { return }
        let current = window.firstResponder as? NSTextView
        let currentIndex = current.flatMap { textViews.firstIndex(of: $0) } ?? -1
        let nextIndex = (currentIndex + 1) % textViews.count
        let nextTextView = textViews[nextIndex]
        window.makeFirstResponder(nextTextView)
        workspaceModel.activatePane(with: nextTextView.identifier)
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
