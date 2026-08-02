import AppKit
import MarkdownEngine
import SwiftUI

@MainActor
final class EditorPaneModel: ObservableObject, Identifiable {
    private struct ConfigurationKey: Equatable {
        let rawSourceMode: Bool
        let fontSize: CGFloat
        let documentPath: String?
    }

    let id = UUID()
    let latexRenderer: AdaptiveLaTeXRenderer
    let mermaidRenderer: MermaidRenderer
    let imageProvider: MarkdownImageProvider
    let onOpenMarkdownFile: ((URL) -> Void)?
    let bindingMutationAccumulator = EditorBindingMutationAccumulator()
    let textBindingContext = EditorTextBindingContext()
    private var cachedConfigurationKey: ConfigurationKey?
    private var cachedConfiguration: MarkdownEditorConfiguration?
    @Published var selectedRange = NSRange(location: 0, length: 0)
    @Published var visibleOrigin = NSPoint.zero
    @Published var line = 1
    @Published var column = 1
    @Published var isPositionPending = false

    init(
        latexRenderer: AdaptiveLaTeXRenderer? = nil,
        mermaidRenderer: MermaidRenderer? = nil,
        imageProvider: MarkdownImageProvider? = nil,
        onOpenMarkdownFile: ((URL) -> Void)? = nil
    ) {
        self.latexRenderer =
            latexRenderer
            ?? AdaptiveLaTeXRenderer(
                updateNotification: Notification.Name(
                    "DarthScriptum.LatexRendererDidUpdate.\(UUID().uuidString)"
                )
            )
        self.mermaidRenderer =
            mermaidRenderer
            ?? MermaidRenderer(
                updateNotification: Notification.Name(
                    "DarthScriptum.MermaidRendererDidUpdate.\(UUID().uuidString)"
                )
            )
        self.imageProvider =
            imageProvider
            ?? MarkdownImageProvider(documentURL: nil)
        self.onOpenMarkdownFile = onOpenMarkdownFile
    }

    func configuration(
        rawSourceMode: Bool,
        fontSize: CGFloat,
        documentURL: URL?
    ) -> MarkdownEditorConfiguration {
        let standardizedURL = documentURL?.standardizedFileURL
        imageProvider.update(documentURL: standardizedURL)
        let key = ConfigurationKey(
            rawSourceMode: rawSourceMode,
            fontSize: fontSize,
            documentPath: standardizedURL?.path
        )
        if key == cachedConfigurationKey,
            let cachedConfiguration
        {
            return cachedConfiguration
        }
        let configuration = MarkdownConfigurationFactory.make(
            rawSourceMode: rawSourceMode,
            fontSize: fontSize,
            documentURL: standardizedURL,
            latexRenderer: latexRenderer,
            imageProvider: imageProvider
        )
        cachedConfigurationKey = key
        cachedConfiguration = configuration
        return configuration
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
        updateTextBindingContext()
        return EditorPaneStateCoordinator(
            sourceBuffer: sourceBuffer,
            pane: pane,
            presentation: presentation,
            normalizesDisplayMathSelection: !usesRawSource,
            onOpenMarkdownFile: pane.onOpenMarkdownFile,
            onBecameActive: onBecameActive
        )
    }

    func makeNSView(
        context: Context
    ) -> EditorLayoutHostingView {
        updateTextBindingContext()
        let hostingView = EditorLayoutHostingView(
            rootView: AnyView(editorView)
        )
        hostingView.sizingOptions = []
        let coordinator = context.coordinator
        hostingView.onWidthWillChange = { [weak coordinator] width in
            coordinator?.editorWidthWillChange(to: width)
        }
        hostingView.onLayoutDidComplete = { [weak coordinator] in
            coordinator?.editorLayoutDidComplete()
        }
        context.coordinator.start()
        context.coordinator.scheduleAttachment(in: hostingView)
        return hostingView
    }

    func updateNSView(
        _ hostingView: EditorLayoutHostingView,
        context: Context
    ) {
        updateTextBindingContext()
        context.coordinator.setPresentation(presentation)
        context.coordinator.setNormalizesDisplayMathSelection(!usesRawSource)
        hostingView.rootView = AnyView(editorView)
        context.coordinator.scheduleAttachment(in: hostingView)
    }

    static func dismantleNSView(
        _ hostingView: EditorLayoutHostingView,
        coordinator: EditorPaneStateCoordinator
    ) {
        hostingView.onWidthWillChange = nil
        hostingView.onLayoutDidComplete = nil
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
        return MarkdownEngineCompatibility.makeEditorView(
            text: editorText,
            configuration: pane.configuration(
                rawSourceMode: rawSourceMode,
                fontSize: fontSize,
                documentURL: documentURL
            ),
            fontName: AppTheme.editorFont(size: fontSize).fontName,
            fontSize: fontSize,
            documentID: pane.id.uuidString
        )
    }

    private var usesRawSource: Bool {
        MarkdownPresentationPolicy.usesRawSource(
            requestedSourceMode: sourceMode,
            metrics: sourceBuffer.metrics
        )
    }

    private var presentation: MarkdownSourcePresentation {
        MarkdownPresentationPolicy.presentation(
            requestedSourceMode: sourceMode,
            text: sourceBuffer.revision.text,
            metrics: sourceBuffer.metrics
        )
    }

    private var editorText: Binding<String> {
        Binding(
            get: {
                pane.textBindingContext.presentation(
                    text: sourceBuffer.revision.text,
                    metrics: sourceBuffer.metrics
                ).text
            },
            set: { updatedText in
                let revision = sourceBuffer.revision
                let currentPresentation = pane.textBindingContext.presentation(
                    text: revision.text,
                    metrics: sourceBuffer.metrics
                )
                let capturedMutation = pane.bindingMutationAccumulator.consume()
                if let capturedMutation,
                    capturedMutation.presentedSourceRange
                        != currentPresentation.sourceRange
                {
                    assertionFailure(
                        "The editor mutation used a stale presentation range."
                    )
                    return
                }
                guard
                    let edit = MarkdownEditorTextAdapter.sourceEdit(
                        editorText: updatedText,
                        capturedMutation: capturedMutation,
                        currentRevision: revision,
                        newlineStyle: pane.textBindingContext.newlineStyle,
                        origin: .localEditor(paneID: pane.id),
                        presentedSourceRange: currentPresentation.sourceRange
                    )
                else {
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
                            newlineStyle: pane.textBindingContext.newlineStyle,
                            presentedSourceRange:
                                currentPresentation.sourceRange
                        ),
                        origin: .localEditor(paneID: pane.id)
                    )
                }
            }
        )
    }

    private func updateTextBindingContext() {
        pane.textBindingContext.update(
            requestedSourceMode: sourceMode,
            newlineStyle: newlineStyle
        )
    }
}

enum MarkdownPresentationPolicy {
    static let maximumLivePreviewBytes = 512 * 1_024
    static let maximumLivePreviewLines = 20_000

    static func usesRawSource(
        requestedSourceMode: Bool,
        metrics: DocumentMetrics
    ) -> Bool {
        requestedSourceMode
            || metrics.utf8ByteCount > maximumLivePreviewBytes
            || metrics.lineCount > maximumLivePreviewLines
    }

    static func usesRawSource(
        requestedSourceMode: Bool,
        text: String
    ) -> Bool {
        usesRawSource(
            requestedSourceMode: requestedSourceMode,
            metrics: DocumentMetrics(text: text)
        )
    }

    static func presentation(
        requestedSourceMode: Bool,
        text: String,
        metrics: DocumentMetrics? = nil
    ) -> MarkdownSourcePresentation {
        MarkdownSourcePresentation.make(
            source: text,
            rendersMarkdown: !usesRawSource(
                requestedSourceMode: requestedSourceMode,
                metrics: metrics ?? DocumentMetrics(text: text)
            )
        )
    }
}

enum MarkdownEditorTextAdapter {
    private static let maximumTrustedMutationLength = 64 * 1_024

    static func sourceEdit(
        editorText: String,
        capturedMutation: EditorBindingMutation? = nil,
        currentRevision: SourceRevision,
        newlineStyle: NewlineStyle,
        origin: DocumentChangeOrigin,
        presentedSourceRange: NSRange? = nil
    ) -> SourceEdit? {
        let source = currentRevision.text as NSString
        let sourceRange =
            presentedSourceRange
            ?? NSRange(
                location: 0,
                length: source.length
            )
        guard sourceRange.location >= 0,
            sourceRange.length >= 0,
            NSMaxRange(sourceRange) <= source.length
        else {
            assertionFailure("Presented source range is outside the document.")
            return nil
        }
        if let capturedMutation,
            let edit = sourceEdit(
                capturedMutation: capturedMutation,
                editorText: editorText,
                currentRevision: currentRevision,
                newlineStyle: newlineStyle,
                origin: origin,
                sourceRange: sourceRange
            )
        {
            return edit
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

    private static func sourceEdit(
        capturedMutation: EditorBindingMutation,
        editorText: String,
        currentRevision: SourceRevision,
        newlineStyle: NewlineStyle,
        origin: DocumentChangeOrigin,
        sourceRange: NSRange
    ) -> SourceEdit? {
        guard capturedMutation.sourceRevisionNumber == currentRevision.number,
            capturedMutation.presentedSourceRange == sourceRange,
            capturedMutation.originalPresentedLength == sourceRange.length,
            capturedMutation.range.location >= 0,
            capturedMutation.range.length >= 0,
            NSMaxRange(capturedMutation.range) <= sourceRange.length,
            capturedMutation.range.length <= maximumTrustedMutationLength
        else {
            return nil
        }

        let replacementLength = (capturedMutation.replacement as NSString).length
        guard replacementLength <= maximumTrustedMutationLength,
            capturedMutation.updatedPresentedLength
                == sourceRange.length
                - capturedMutation.range.length
                + replacementLength
        else {
            return nil
        }

        let edited = editorText as NSString
        guard edited.length == capturedMutation.updatedPresentedLength else {
            return nil
        }
        let replacementRange = NSRange(
            location: capturedMutation.range.location,
            length: replacementLength
        )
        guard NSMaxRange(replacementRange) <= edited.length,
            edited.substring(with: replacementRange)
                == capturedMutation.replacement
        else {
            return nil
        }

        let normalizedReplacement = normalizeNewlines(
            capturedMutation.replacement,
            to: newlineStyle
        )
        return SourceEdit(
            range: NSRange(
                location: sourceRange.location
                    + capturedMutation.range.location,
                length: capturedMutation.range.length
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
        guard
            let edit = sourceEdit(
                editorText: editorText,
                currentRevision: revision,
                newlineStyle: newlineStyle,
                origin: .localEditor(paneID: UUID()),
                presentedSourceRange: presentedSourceRange
            )
        else {
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
            )
        else {
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
        let lineFeedText =
            text
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
