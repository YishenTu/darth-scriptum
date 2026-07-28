import AppKit
import MarkdownEngine
import SwiftUI

@MainActor
final class EditorPaneModel: ObservableObject, Identifiable {
    let id = UUID()
    let latexRenderer: AdaptiveLatexRenderer
    let mermaidRenderer: MermaidRenderer
    @Published var selectedRange = NSRange(location: 0, length: 0)
    @Published var visibleOrigin = NSPoint.zero
    @Published var line = 1
    @Published var column = 1
    @Published var isPositionPending = false

    init(
        latexRenderer: AdaptiveLatexRenderer? = nil,
        mermaidRenderer: MermaidRenderer? = nil
    ) {
        self.latexRenderer = latexRenderer ?? AdaptiveLatexRenderer(
            updateNotification: Notification.Name(
                "DarthScriptum.LatexRendererDidUpdate.\(UUID().uuidString)"
            )
        )
        self.mermaidRenderer = mermaidRenderer ?? MermaidRenderer(
            updateNotification: Notification.Name(
                "DarthScriptum.MermaidRendererDidUpdate.\(UUID().uuidString)"
            )
        )
    }
}

@MainActor
struct LivePreviewTextView: NSViewRepresentable {
    @ObservedObject var sourceBuffer: MarkdownSourceBuffer
    let pane: EditorPaneModel
    var sourceMode: Bool
    var fontSize: CGFloat
    var newlineStyle: NewlineStyle
    var documentURL: URL?
    var onBecameActive: @MainActor () -> Void = {}

    func makeCoordinator() -> EditorPaneStateCoordinator {
        EditorPaneStateCoordinator(
            sourceBuffer: sourceBuffer,
            pane: pane,
            presentation: presentation,
            normalizesDisplayMathSelection: !usesRawSource,
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
        context.coordinator.setPresentation(presentation)
        context.coordinator.setNormalizesDisplayMathSelection(!usesRawSource)
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
        let rawSourceMode = usesRawSource
        pane.latexRenderer.prepareForPresentation(
            revisionNumber: sourceBuffer.revision.number,
            fontSize: fontSize,
            rawSourceMode: rawSourceMode,
            source: sourceBuffer.revision.text
        )
        return NativeTextViewWrapper(
            text: editorText,
            configuration: MarkdownConfigurationFactory.make(
                rawSourceMode: rawSourceMode,
                fontSize: fontSize,
                documentURL: documentURL,
                latexRenderer: pane.latexRenderer
            ),
            fontName: AppTheme.editorFont(size: fontSize).fontName,
            fontSize: fontSize,
            documentId: pane.id.uuidString,
            retainedScrollDocumentIds: [pane.id.uuidString]
        )
        .accessibilityLabel("Markdown editor")
    }

    private var usesRawSource: Bool {
        MarkdownPresentationPolicy.usesRawSource(
            requestedSourceMode: sourceMode,
            text: sourceBuffer.revision.text
        )
    }

    private var presentation: MarkdownSourcePresentation {
        MarkdownPresentationPolicy.presentation(
            requestedSourceMode: sourceMode,
            text: sourceBuffer.revision.text
        )
    }

    private var editorText: Binding<String> {
        Binding(
            get: {
                presentation.text
            },
            set: { updatedText in
                let revision = sourceBuffer.revision
                let currentPresentation = MarkdownPresentationPolicy.presentation(
                    requestedSourceMode: sourceMode,
                    text: revision.text
                )
                guard let edit = MarkdownEditorTextAdapter.sourceEdit(
                    editorText: updatedText,
                    currentRevision: revision,
                    newlineStyle: newlineStyle,
                    origin: .localEditor(paneID: pane.id),
                    presentedSourceRange: currentPresentation.sourceRange
                ) else {
                    return
                }
                do {
                    try sourceBuffer.apply(edit)
                } catch {
                    assertionFailure(
                        "The editor produced an invalid source edit: \(error)"
                    )
                    sourceBuffer.replace(
                        with: MarkdownEditorTextAdapter.reconcile(
                            editorText: updatedText,
                            currentSource: revision.text,
                            newlineStyle: newlineStyle,
                            presentedSourceRange:
                                currentPresentation.sourceRange
                        ),
                        origin: .localEditor(paneID: pane.id)
                    )
                }
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

    static func presentation(
        requestedSourceMode: Bool,
        text: String
    ) -> MarkdownSourcePresentation {
        MarkdownSourcePresentation.make(
            source: text,
            rendersMarkdown: !usesRawSource(
                requestedSourceMode: requestedSourceMode,
                text: text
            )
        )
    }
}

enum MarkdownEditorTextAdapter {
    static func sourceEdit(
        editorText: String,
        currentRevision: SourceRevision,
        newlineStyle: NewlineStyle,
        origin: DocumentChangeOrigin,
        presentedSourceRange: NSRange? = nil
    ) -> SourceEdit? {
        let source = currentRevision.text as NSString
        let sourceRange = presentedSourceRange ?? NSRange(
            location: 0,
            length: source.length
        )
        guard sourceRange.location >= 0,
              sourceRange.length >= 0,
              NSMaxRange(sourceRange) <= source.length else {
            assertionFailure("Presented source range is outside the document.")
            return nil
        }
        let presentedSource = source.substring(with: sourceRange)
        guard editorText != presentedSource else { return nil }

        let presented = presentedSource as NSString
        let edited = editorText as NSString
        let difference = UTF16TextDifference.between(
            original: presented,
            updated: edited
        )
        let normalizedReplacement = normalizeNewlines(
            edited.substring(with: difference.updatedRange),
            to: newlineStyle
        )
        return SourceEdit(
            range: NSRange(
                location: sourceRange.location
                    + difference.originalRange.location,
                length: difference.originalRange.length
            ),
            replacement: terminatingFrontMatterNewlineIfNeeded(
                normalizedReplacement,
                currentSource: currentRevision.text,
                sourceRange: sourceRange,
                newlineStyle: newlineStyle
            ),
            expectedRevision: currentRevision.number,
            origin: origin
        )
    }

    static func reconcile(
        editorText: String,
        currentSource: String,
        newlineStyle: NewlineStyle,
        presentedSourceRange: NSRange? = nil
    ) -> String {
        let revision = SourceRevision(number: 0, text: currentSource)
        guard let edit = sourceEdit(
            editorText: editorText,
            currentRevision: revision,
            newlineStyle: newlineStyle,
            origin: .localEditor(paneID: UUID()),
            presentedSourceRange: presentedSourceRange
        ) else {
            return currentSource
        }
        return (try? edit.applying(to: revision).text) ?? currentSource
    }

    private static func terminatingFrontMatterNewlineIfNeeded(
        _ replacement: String,
        currentSource: String,
        sourceRange: NSRange,
        newlineStyle: NewlineStyle
    ) -> String {
        let sourceLength = (currentSource as NSString).length
        guard !replacement.isEmpty,
              replacement.first != "\n",
              replacement.first != "\r",
              sourceLength > 0,
              sourceRange == NSRange(location: sourceLength, length: 0),
              MarkdownFrontMatter.bodyRange(in: currentSource)
                == sourceRange,
              !isLineTerminator(
                (currentSource as NSString).character(at: sourceLength - 1)
              ) else {
            return replacement
        }
        switch newlineStyle {
        case .lf:
            return "\n" + replacement
        case .crlf:
            return "\r\n" + replacement
        }
    }

    private static func isLineTerminator(_ character: unichar) -> Bool {
        character == 0x0A
            || character == 0x0D
            || character == 0x2028
            || character == 0x2029
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
