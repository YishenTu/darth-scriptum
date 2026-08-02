import AppKit
import MarkdownEngine
import SwiftUI

/// Isolates the project assumptions about MarkdownEngine 0.11.0.
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
    /// MarkdownEngine 0.11.0 center-aligns standalone display math and images.
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

    /// MarkdownEngine 0.11.0 treats the configured syntax-highlighter
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

    /// Detects the outer-pipe table syntax supported by MarkdownEngine 0.11.0.
    ///
    /// This reads source text instead of rendered attributes, which may not
    /// exist for an offscreen, lazily laid-out, or actively edited table.
    static func containsTableCandidate(in source: String) -> Bool {
        var previousLine: String?
        var found = false
        source.enumerateLines { line, stop in
            if let previousLine,
                isOuterPipeTableRow(previousLine),
                isOuterPipeTableSeparator(line)
            {
                found = true
                stop = true
            } else {
                previousLine = line
            }
        }
        return found
    }

    private static func isOuterPipeTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3
            && trimmed.hasPrefix("|")
            && trimmed.hasSuffix("|")
    }

    private static func isOuterPipeTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3,
            trimmed.hasPrefix("|"),
            trimmed.hasSuffix("|")
        else {
            return false
        }
        let middle = trimmed.dropFirst().dropLast()
        return !middle.isEmpty
            && middle.allSatisfy {
                $0 == "-" || $0 == ":" || $0 == "|"
                    || $0 == " " || $0 == "\t"
            }
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
    /// MarkdownEngine 0.11.0 derives marker visibility from editability and
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
        // MarkdownEngine 0.11.0 internal MarkdownTextLayoutFragment keys.
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
