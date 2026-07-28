import AppKit
import MarkdownEngine
import SwiftUI

@MainActor
final class EditorPaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var selectedRange = NSRange(location: 0, length: 0)
    @Published var visibleOrigin = NSPoint.zero
    @Published var line = 1
    @Published var column = 1
}

@MainActor
struct LivePreviewTextView: NSViewRepresentable {
    @ObservedObject var sourceBuffer: MarkdownSourceBuffer
    @ObservedObject var pane: EditorPaneModel
    var sourceMode: Bool
    var fontSize: CGFloat
    var newlineStyle: NewlineStyle
    var documentURL: URL?
    var onBecameActive: @MainActor () -> Void = {}

    func makeCoordinator() -> EditorPaneStateCoordinator {
        EditorPaneStateCoordinator(
            sourceBuffer: sourceBuffer,
            pane: pane,
            onBecameActive: onBecameActive
        )
    }

    func makeNSView(
        context: Context
    ) -> NSHostingView<AnyView> {
        let hostingView = NSHostingView(rootView: AnyView(editorView))
        hostingView.sizingOptions = []
        context.coordinator.start()
        context.coordinator.scheduleAttachment(in: hostingView)
        return hostingView
    }

    func updateNSView(
        _ hostingView: NSHostingView<AnyView>,
        context: Context
    ) {
        hostingView.rootView = AnyView(editorView)
        context.coordinator.scheduleAttachment(in: hostingView)
    }

    static func dismantleNSView(
        _ hostingView: NSHostingView<AnyView>,
        coordinator: EditorPaneStateCoordinator
    ) {
        coordinator.stop()
    }

    private var editorView: some View {
        NativeTextViewWrapper(
            text: editorText,
            configuration: DarthMarkdownConfiguration.make(
                rawSourceMode: MarkdownPresentationPolicy.usesRawSource(
                    requestedSourceMode: sourceMode,
                    text: sourceBuffer.revision.text
                ),
                fontSize: fontSize,
                documentURL: documentURL
            ),
            fontName: DarthTheme.editorFont(size: fontSize).fontName,
            fontSize: fontSize,
            documentId: pane.id.uuidString,
            retainedScrollDocumentIds: [pane.id.uuidString]
        )
        .accessibilityLabel("Markdown editor")
    }

    private var editorText: Binding<String> {
        Binding(
            get: {
                sourceBuffer.revision.text
            },
            set: { updatedText in
                sourceBuffer.replace(
                    with: MarkdownEditorTextAdapter.reconcile(
                        editorText: updatedText,
                        currentSource: sourceBuffer.revision.text,
                        newlineStyle: newlineStyle
                    ),
                    origin: .localEditor(paneID: pane.id)
                )
            }
        )
    }
}

enum MarkdownPresentationPolicy {
    static let maximumLivePreviewBytes = 2 * 1_024 * 1_024

    static func usesRawSource(
        requestedSourceMode: Bool,
        text: String
    ) -> Bool {
        requestedSourceMode || text.utf8.count > maximumLivePreviewBytes
    }
}

enum MarkdownEditorTextAdapter {
    static func reconcile(
        editorText: String,
        currentSource: String,
        newlineStyle: NewlineStyle
    ) -> String {
        guard editorText != currentSource else { return currentSource }

        let source = currentSource as NSString
        let edited = editorText as NSString
        let difference = UTF16TextDifference.between(
            original: source,
            updated: edited
        )
        let replacement = normalizeNewlines(
            edited.substring(with: difference.updatedRange),
            to: newlineStyle
        )
        let result = NSMutableString(string: currentSource)
        result.replaceCharacters(
            in: difference.originalRange,
            with: replacement
        )
        return result as String
    }

    private static func normalizeNewlines(
        _ text: String,
        to style: NewlineStyle
    ) -> String {
        let lineFeedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        switch style {
        case .lf:
            return lineFeedText
        case .crlf:
            return lineFeedText.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }
}
