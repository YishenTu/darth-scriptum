import AppKit
import MarkdownEngine
import SwiftUI

/// Isolates the project assumptions about the pinned MarkdownEngine 0.10.1.
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
                Attribute.displayWidth: displayWidth
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
              ) as? NSImage else {
            return nil
        }
        let bounds = (
            textStorage.attribute(
                Attribute.imageBounds,
                at: location,
                effectiveRange: nil
            ) as? NSValue
        )?.rectValue ?? .zero
        let isBlock = textStorage.attribute(
            Attribute.isBlock,
            at: location,
            effectiveRange: nil
        ) as? Bool ?? false
        let sourceIdentity = textStorage.attribute(
            Attribute.sourceIdentity,
            at: location,
            effectiveRange: nil
        ) as? Int
        let displayWidth = textStorage.attribute(
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
        // MarkdownEngine 0.10.1 internal MarkdownTextLayoutFragment keys.
        static let renderedImage = NSAttributedString.Key(
            "LatexRenderedImage"
        )
        static let imageBounds = NSAttributedString.Key("LatexImageBounds")
        static let isBlock = NSAttributedString.Key("LatexIsBlock")
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
