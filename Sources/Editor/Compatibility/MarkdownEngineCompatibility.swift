import AppKit
import MarkdownEngine
import SwiftUI

/// Isolates the project assumptions about MarkdownEngine 0.12.0.
///
/// The public wrapper creates an NSScrollView, but the native text view and
/// overlay attribute keys are internal to the dependency. Keep those
/// assumptions here and rerun the compatibility tests before changing the pin.
@MainActor
enum MarkdownEngineCompatibility {
    struct RenderedBlock {
        let image: NSImage
        let bounds: CGRect
        let isBlock: Bool
        let sourceIdentity: Int?
        let displayWidth: CGFloat?
    }

    static func makeEditorView(
        text: Binding<String>,
        configuration: MarkdownEditorConfiguration,
        fontName: String,
        fontSize: CGFloat,
        documentID: String
    ) -> some View {
        NativeTextViewWrapper(
            text: text,
            configuration: configuration,
            fontName: fontName,
            fontSize: fontSize,
            documentId: documentID,
            retainedScrollDocumentIds: [documentID]
        )
        .accessibilityLabel("Markdown editor")
    }

    /// Returns every text view from a valid public wrapper hierarchy.
    ///
    /// A wrapper is valid only when one scroll view owns a document view with
    /// exactly one descendant text view. Unexpected hierarchy changes are
    /// ignored instead of binding pane state to an arbitrary text view.
    static func nativeTextViews(in rootView: NSView) -> [NSTextView] {
        descendantScrollViews(in: rootView).compactMap {
            nativeTextView(in: $0)
        }
    }

    /// Returns a text view only when the root contains one valid wrapper.
    static func nativeTextView(in rootView: NSView) -> NSTextView? {
        let candidates = nativeTextViews(in: rootView)
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    /// Applies one source-authorized edit through MarkdownEngine's existing
    /// native text-change lifecycle. The exact transition guards keep display
    /// transformations such as UUID-backed wiki links on the full rebuild path.
    @discardableResult
    static func applyIncrementalSourceEdit(
        _ edit: SourceEdit,
        from previousPresentation: MarkdownSourcePresentation,
        to updatedPresentation: MarkdownSourcePresentation,
        restoringSelection selectedRange: NSRange,
        in textView: NSTextView
    ) -> Bool {
        guard
            previousPresentation.rendersMarkdown
                == updatedPresentation.rendersMarkdown,
            previousPresentation.sourceRange.location
                == updatedPresentation.sourceRange.location,
            edit.range.location >= previousPresentation.sourceRange.location,
            NSMaxRange(edit.range)
                <= NSMaxRange(previousPresentation.sourceRange),
            let coordinator = textView.delegate
                as? NativeTextViewCoordinator,
            !textView.hasMarkedText()
        else {
            return false
        }
        if #available(macOS 15.0, *), textView.isWritingToolsActive {
            return false
        }

        let presentedRange = NSRange(
            location: edit.range.location
                - previousPresentation.sourceRange.location,
            length: edit.range.length
        )
        let previousText = previousPresentation.text as NSString
        guard NSMaxRange(presentedRange) <= previousText.length,
            textView.string == previousPresentation.text,
            textView.textStorage?.length == previousText.length
        else {
            return false
        }
        let expectedText = NSMutableString(string: previousText)
        expectedText.replaceCharacters(
            in: presentedRange,
            with: edit.replacement
        )
        guard expectedText as String == updatedPresentation.text,
            let textStorage = textView.textStorage
        else {
            return false
        }

        // MarkdownEngine exposes its delegate lifecycle but not a dedicated
        // external-edit API. Register only edits whose replacement cannot
        // trigger its Markdown smart-input interceptors. This gives its parser
        // the trusted edit descriptor needed for incremental parsing while
        // punctuation, structural edits, and batches continue to fail closed.
        guard
            isPlainTextEdit(
                presentedRange,
                replacement: edit.replacement,
                in: previousText
            )
        else {
            return false
        }
        // The engine uses editability to decide whether selection reveals
        // syntax. Keep peer edits and selection restoration in one focus-aware
        // styling scope, just like the full-restyle path below.
        let wasEditable = textView.isEditable
        textView.isEditable = wasEditable && textView.window?.firstResponder === textView
        defer { textView.isEditable = wasEditable }
        let unchangedText = textView.string
        guard
            coordinator.textView(
                textView,
                shouldChangeTextIn: presentedRange,
                replacementString: edit.replacement
            ), textView.string == unchangedText
        else {
            return false
        }

        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: presentedRange,
            with: edit.replacement
        )
        textStorage.endEditing()
        textView.didChangeText()
        if textView.selectedRange() != selectedRange {
            textView.setSelectedRange(selectedRange)
        }
        return textView.string == updatedPresentation.text
    }

    private static func isPlainTextEdit(
        _ range: NSRange,
        replacement: String,
        in source: NSString
    ) -> Bool {
        guard range.length <= 1,
            replacement.utf16.count <= 1
        else {
            return false
        }
        let replacedText = source.substring(with: range)
        return (replacedText.isEmpty || isPlainTextCharacter(replacedText))
            && (replacement.isEmpty || isPlainTextCharacter(replacement))
    }

    private static func isPlainTextCharacter(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    /// Restores a drifted text container origin.
    ///
    /// TextKit 2 shifts `textContainerOrigin.x` when laid-out content extends
    /// past the container's leading edge — exactly what a stale, over-wide
    /// centered rendered block (display math, a re-render-pending diagram)
    /// produces at every step of a rapid shrink. The adjustment is sticky:
    /// nothing restores the origin after the block re-renders, so the whole
    /// text column stays offset (growing leading gutter, vanishing trailing
    /// gutter). Re-assigning the container size makes AppKit recompute the
    /// origin from the current layout.
    static func normalizeTextContainerOrigin(in textView: NSTextView) {
        let inset = textView.textContainerInset
        let origin = textView.textContainerOrigin
        guard abs(origin.x - inset.width) > 0.5,
            let container = textView.textContainer
        else {
            return
        }
        container.size = container.size
    }

    /// Prevents centered rendered blocks from extending past the leading edge.
    ///
    /// MarkdownEngine 0.12.0 center-aligns standalone display math and images.
    /// During a shrink, TextKit lays out the stale-width line before the block
    /// can be refreshed. Its negative leading edge permanently shifts
    /// `textContainerOrigin.x`. Left alignment plus an equivalent leading
    /// indent preserves the centered appearance while making stale content
    /// overflow only on the trailing edge.
    ///
    /// This intentionally performs one attributed-storage pass at resize
    /// boundaries. Callers must not put it on edit, selection, or per-frame
    /// paths.
    @discardableResult
    static func stabilizeCenteredRenderedBlocks(
        in textView: NSTextView,
        viewportWidth: CGFloat? = nil
    ) -> Bool {
        guard let textStorage = textView.textStorage,
            textStorage.length > 0,
            let containerWidth = renderedBlockContainerWidth(
                in: textView,
                viewportWidth: viewportWidth
            )
        else {
            return false
        }

        struct Update {
            let anchorRange: NSRange
            let paragraphRange: NSRange
            let paragraphStyle: NSParagraphStyle
            let indent: CGFloat
        }

        let source = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var updates: [Update] = []
        textStorage.enumerateAttribute(
            Attribute.renderedImage,
            in: fullRange
        ) { value, imageRange, _ in
            guard value is NSImage,
                imageRange.length > 0,
                textStorage.attribute(
                    Attribute.isBlock,
                    at: imageRange.location,
                    effectiveRange: nil
                ) as? Bool == true,
                let bounds =
                    (textStorage.attribute(
                        Attribute.imageBounds,
                        at: imageRange.location,
                        effectiveRange: nil
                    ) as? NSValue)?.rectValue,
                bounds.width.isFinite,
                bounds.width > 0
            else {
                return
            }
            let paragraphStyle =
                textStorage.attribute(
                    .paragraphStyle,
                    at: imageRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle ?? NSParagraphStyle.default
            let wasStabilized =
                textStorage.attribute(
                    Attribute.centeredRenderedBlock,
                    at: imageRange.location,
                    effectiveRange: nil
                ) as? Bool == true
            guard wasStabilized || paragraphStyle.alignment == .center else {
                return
            }
            let indent = max(0, (containerWidth - bounds.width) / 2)
            if wasStabilized,
                paragraphStyle.alignment == .left,
                abs(paragraphStyle.headIndent - indent) <= 0.5,
                abs(paragraphStyle.firstLineHeadIndent - indent) <= 0.5
            {
                return
            }
            updates.append(
                Update(
                    anchorRange: imageRange,
                    paragraphRange: source.paragraphRange(
                        for: NSRange(location: imageRange.location, length: 0)
                    ),
                    paragraphStyle: paragraphStyle,
                    indent: indent
                )
            )
        }
        guard !updates.isEmpty else { return false }

        textStorage.beginEditing()
        for update in updates {
            let paragraph =
                (update.paragraphStyle.mutableCopy()
                    as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.headIndent = update.indent
            paragraph.firstLineHeadIndent = update.indent
            textStorage.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: update.paragraphRange
            )
            textStorage.addAttribute(
                Attribute.centeredRenderedBlock,
                value: true,
                range: update.anchorRange
            )
        }
        textStorage.endEditing()
        return true
    }

    /// MarkdownEngine 0.12.0 treats the configured syntax-highlighter
    /// appearance notification as its public full-restyle invalidation channel.
    /// Keep that dependency-specific contract behind this adapter.
    static func requestFullRestyle(
        of textView: NSTextView,
        notification: Notification.Name
    ) {
        NotificationCenter.default.post(
            name: notification,
            object: textView
        )
    }

    /// Broadcasts the same public restyle request when an asynchronous service
    /// has new output but does not own a concrete text view.
    static func requestFullRestyle(
        notificationCenter: NotificationCenter = .default,
        notification: Notification.Name
    ) {
        notificationCenter.post(name: notification, object: nil)
    }

    private static func renderedBlockContainerWidth(
        in textView: NSTextView,
        viewportWidth: CGFloat?
    ) -> CGFloat? {
        if let viewportWidth,
            viewportWidth.isFinite,
            viewportWidth > 0
        {
            return max(
                1,
                viewportWidth - textView.textContainerInset.width * 2
            )
        }
        if let width = textView.textContainer?.containerSize.width,
            width.isFinite,
            width > 0,
            width < 100_000
        {
            return width
        }
        return nil
    }

    static func beginObservingSelection(
        of textView: NSTextView,
        observer: NSObject,
        selector: Selector
    ) {
        NotificationCenter.default.addObserver(
            observer,
            selector: selector,
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
    }

    static func endObservingSelection(
        of textView: NSTextView?,
        observer: NSObject
    ) {
        guard let textView else { return }
        NotificationCenter.default.removeObserver(
            observer,
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
    }

    /// Recomputes caret-sensitive live-preview attributes for a focus change.
    ///
    /// MarkdownEngine 0.12.0 derives marker visibility from editability and
    /// selection, but does not accept focus as an input or restyle when an
    /// editor resigns first responder. Drive its public full-restyle channel
    /// with editability suppressed while unfocused, then restore the actual
    /// editing contract without changing the document or its selection.
    static func refreshSelectionPresentation(
        in textView: NSTextView,
        revealsActiveSyntax: Bool,
        notification: Notification.Name
    ) {
        let wasEditable = textView.isEditable
        textView.isEditable = wasEditable && revealsActiveSyntax
        defer { textView.isEditable = wasEditable }
        requestFullRestyle(of: textView, notification: notification)
    }

    static func applyRenderedBlockImage(
        _ image: NSImage,
        bounds: CGRect,
        sourceIdentity: Int,
        displayWidth: CGFloat,
        to textStorage: NSTextStorage,
        range: NSRange
    ) {
        guard isValid(range, in: textStorage) else { return }
        textStorage.addAttributes(
            [
                Attribute.renderedImage: image,
                Attribute.imageBounds: NSValue(rect: bounds),
                Attribute.isBlock: true,
                Attribute.sourceIdentity: sourceIdentity,
                Attribute.displayWidth: displayWidth,
            ],
            range: range
        )
    }

    static func renderedBlock(
        in textStorage: NSTextStorage,
        at location: Int
    ) -> RenderedBlock? {
        guard location >= 0,
            location < textStorage.length,
            let image = textStorage.attribute(
                Attribute.renderedImage,
                at: location,
                effectiveRange: nil
            ) as? NSImage
        else {
            return nil
        }
        let bounds =
            (textStorage.attribute(
                Attribute.imageBounds,
                at: location,
                effectiveRange: nil
            ) as? NSValue)?.rectValue ?? .zero
        let isBlock =
            textStorage.attribute(
                Attribute.isBlock,
                at: location,
                effectiveRange: nil
            ) as? Bool ?? false
        let sourceIdentity =
            textStorage.attribute(
                Attribute.sourceIdentity,
                at: location,
                effectiveRange: nil
            ) as? Int
        let displayWidth =
            textStorage.attribute(
                Attribute.displayWidth,
                at: location,
                effectiveRange: nil
            ) as? CGFloat
        return RenderedBlock(
            image: image,
            bounds: bounds,
            isBlock: isBlock,
            sourceIdentity: sourceIdentity,
            displayWidth: displayWidth
        )
    }

    static func containsRenderedImage(
        in textStorage: NSTextStorage,
        range: NSRange
    ) -> Bool {
        guard isValid(range, in: textStorage) else { return false }
        var found = false
        textStorage.enumerateAttribute(
            Attribute.renderedImage,
            in: range
        ) { value, _, stop in
            if value is NSImage {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Identifies an engine-rendered table whose image is recomputed when the
    /// text container width changes. MarkdownEngine performs that restyle as
    /// an attribute-only edit, so callers cannot infer it from source changes.
    static func containsWidthAdaptiveTable(
        in textStorage: NSTextStorage,
        range: NSRange
    ) -> Bool {
        guard isValid(range, in: textStorage), range.length > 0 else {
            return false
        }
        var found = false
        textStorage.enumerateAttribute(
            Attribute.widthAdaptiveTableRange,
            in: range
        ) { value, _, stop in
            if value is NSValue {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func isBulletListMarker(
        in textStorage: NSTextStorage,
        at location: Int
    ) -> Bool {
        guard location >= 0, location < textStorage.length else {
            return false
        }
        return textStorage.attribute(
            Attribute.bulletListMarker,
            at: location,
            effectiveRange: nil
        ) as? Bool == true
    }

    private enum Attribute {
        // MarkdownEngine 0.12.0 internal MarkdownTextLayoutFragment keys.
        static let renderedImage = NSAttributedString.Key(
            "LatexRenderedImage"
        )
        static let imageBounds = NSAttributedString.Key("LatexImageBounds")
        static let isBlock = NSAttributedString.Key("LatexIsBlock")
        static let centeredRenderedBlock = NSAttributedString.Key(
            "DarthScriptum.CenteredRenderedBlock"
        )
        static let bulletListMarker = NSAttributedString.Key(
            "BulletListMarker"
        )
        static let widthAdaptiveTableRange = NSAttributedString.Key(
            "ScrollableBlockFullRange"
        )

        // Project-owned metadata used to avoid reapplying Mermaid presentation.
        static let sourceIdentity = NSAttributedString.Key(
            "MermaidSourceIdentity"
        )
        static let displayWidth = NSAttributedString.Key(
            "MermaidDisplayWidth"
        )
    }

    private static func nativeTextView(
        in scrollView: NSScrollView
    ) -> NSTextView? {
        guard let documentView = scrollView.documentView else {
            return nil
        }
        let textViews = descendantTextViews(in: documentView)
        guard textViews.count == 1 else { return nil }
        return textViews[0]
    }

    private static func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        var result = (view as? NSScrollView).map { [$0] } ?? []
        for subview in view.subviews {
            result += descendantScrollViews(in: subview)
        }
        return result
    }

    private static func descendantTextViews(in view: NSView) -> [NSTextView] {
        var result = (view as? NSTextView).map { [$0] } ?? []
        for subview in view.subviews {
            result += descendantTextViews(in: subview)
        }
        return result
    }

    private static func isValid(
        _ range: NSRange,
        in textStorage: NSTextStorage
    ) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= textStorage.length
            && range.length <= textStorage.length - range.location
    }
}
