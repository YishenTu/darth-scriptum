import AppKit

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var isSplit = false
    @Published var sourceMode = false
    @Published var fontSize: CGFloat = 14
    @Published private(set) var activePaneID: UUID

    let primaryPane: EditorPaneModel
    let secondaryPane: EditorPaneModel
    private let sharedImageProvider: MarkdownImageProvider

    init(onOpenMarkdownFile: ((URL) -> Void)? = nil) {
        let latexRenderer = AdaptiveLaTeXRenderer(
            updateNotification: Notification.Name(
                "DarthScriptum.LatexRendererDidUpdate.\(UUID().uuidString)"
            )
        )
        let mermaidRenderer = MermaidRenderer(
            updateNotification: Notification.Name(
                "DarthScriptum.MermaidRendererDidUpdate.\(UUID().uuidString)"
            )
        )
        let imageProvider = MarkdownImageProvider(
            documentURL: nil,
            updateNotification: latexRenderer.updateNotification
        )
        let primaryPane = EditorPaneModel(
            latexRenderer: latexRenderer,
            mermaidRenderer: mermaidRenderer,
            imageProvider: imageProvider,
            onOpenMarkdownFile: onOpenMarkdownFile
        )
        self.primaryPane = primaryPane
        sharedImageProvider = imageProvider
        secondaryPane = EditorPaneModel(
            latexRenderer: latexRenderer,
            mermaidRenderer: mermaidRenderer,
            imageProvider: imageProvider,
            onOpenMarkdownFile: onOpenMarkdownFile
        )
        activePaneID = primaryPane.id
    }

    var activePane: EditorPaneModel {
        if isSplit, activePaneID == secondaryPane.id {
            return secondaryPane
        }
        return primaryPane
    }

    var restorationState: WorkspaceRestorationState {
        let fontSize =
            self.fontSize.isFinite
            ? min(max(self.fontSize, 10), 32)
            : 14
        let isSecondaryActive = isSplit && activePaneID == secondaryPane.id
        return WorkspaceRestorationState(
            isSplit: isSplit,
            sourceMode: sourceMode,
            fontSize: fontSize,
            activePane: isSecondaryActive ? .secondary : .primary,
            primarySelection: Self.restorable(primaryPane.selectedRange),
            primaryVisibleOrigin: Self.restorable(primaryPane.visibleOrigin),
            secondarySelection: Self.restorable(secondaryPane.selectedRange),
            secondaryVisibleOrigin: Self.restorable(secondaryPane.visibleOrigin)
        )!
    }

    func restore(_ state: WorkspaceRestorationState) {
        isSplit = state.isSplit
        sourceMode = state.sourceMode
        fontSize = state.fontSize
        primaryPane.selectedRange = state.primarySelection
        primaryPane.visibleOrigin = state.primaryVisibleOrigin
        secondaryPane.selectedRange = state.secondarySelection
        secondaryPane.visibleOrigin = state.secondaryVisibleOrigin
        activePaneID =
            state.activePane == .secondary
            ? secondaryPane.id
            : primaryPane.id
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
        guard
            pane.id == primaryPane.id
                || isSplit && pane.id == secondaryPane.id
        else {
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

    private static func restorable(_ range: NSRange) -> NSRange {
        let maximum = 1_073_741_824
        let location = min(max(range.location, 0), maximum)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), maximum - location)
        )
    }

    private static func restorable(_ point: NSPoint) -> NSPoint {
        let maximum: CGFloat = 10_000_000
        return NSPoint(
            x: point.x.isFinite ? min(max(point.x, 0), maximum) : 0,
            y: point.y.isFinite ? min(max(point.y, 0), maximum) : 0
        )
    }

    deinit {
        sharedImageProvider.dispose()
    }
}
