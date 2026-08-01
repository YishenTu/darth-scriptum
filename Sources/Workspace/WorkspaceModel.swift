import AppKit

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var isSplit = false
    @Published var sourceMode = false
    @Published var fontSize: CGFloat = 14
    @Published private(set) var activePaneID: UUID

    let primaryPane: EditorPaneModel
    let secondaryPane: EditorPaneModel

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
        let imageProvider = MarkdownImageProvider(documentURL: nil)
        let primaryPane = EditorPaneModel(
            latexRenderer: latexRenderer,
            mermaidRenderer: mermaidRenderer,
            imageProvider: imageProvider,
            onOpenMarkdownFile: onOpenMarkdownFile
        )
        self.primaryPane = primaryPane
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
}
