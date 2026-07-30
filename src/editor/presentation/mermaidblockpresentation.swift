import AppKit
import Foundation

struct MermaidFencedBlock: Equatable, Sendable {
    let fullRange: NSRange
    let contentRange: NSRange
    let openingFenceRange: NSRange
    let closingFenceRange: NSRange
    let source: String
}

enum MermaidFencedBlockParser {
    private struct OpeningFence {
        let character: unichar
        let length: Int
    }

    static func blocks(
        in source: String,
        shouldCancel: () -> Bool = { false }
    ) -> [MermaidFencedBlock] {
        let text = source as NSString
        guard text.length > 0 else { return [] }

        var result: [MermaidFencedBlock] = []
        var lineLocation = 0
        while lineLocation < text.length {
            if shouldCancel() { return [] }
            let openingLineRange = text.lineRange(
                for: NSRange(location: lineLocation, length: 0)
            )
            let openingContentRange = lineContentRange(
                openingLineRange,
                in: text
            )
            guard let opening = openingFence(
                in: openingContentRange,
                text: text
            ) else {
                lineLocation = NSMaxRange(openingLineRange)
                continue
            }

            var closingLineLocation = NSMaxRange(openingLineRange)
            var foundBlock: MermaidFencedBlock?
            while closingLineLocation < text.length {
                if shouldCancel() { return [] }
                let closingLineRange = text.lineRange(
                    for: NSRange(location: closingLineLocation, length: 0)
                )
                let closingContentRange = lineContentRange(
                    closingLineRange,
                    in: text
                )
                if isClosingFence(
                    in: closingContentRange,
                    opening: opening,
                    text: text
                ) {
                    let contentRange = NSRange(
                        location: NSMaxRange(openingLineRange),
                        length: closingLineRange.location
                            - NSMaxRange(openingLineRange)
                    )
                    let diagramSource = text.substring(with: contentRange)
                    if !diagramSource.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        foundBlock = MermaidFencedBlock(
                            fullRange: NSRange(
                                location: openingContentRange.location,
                                length: NSMaxRange(closingContentRange)
                                    - openingContentRange.location
                            ),
                            contentRange: contentRange,
                            openingFenceRange: openingContentRange,
                            closingFenceRange: closingContentRange,
                            source: diagramSource
                        )
                    }
                    lineLocation = NSMaxRange(closingLineRange)
                    break
                }
                closingLineLocation = NSMaxRange(closingLineRange)
            }

            if let foundBlock {
                result.append(foundBlock)
            } else if closingLineLocation >= text.length {
                lineLocation = text.length
            }
        }
        return result
    }

    private static func openingFence(
        in lineRange: NSRange,
        text: NSString
    ) -> OpeningFence? {
        var cursor = lineRange.location
        let lineEnd = NSMaxRange(lineRange)
        let indentation = consumeSpaces(
            from: &cursor,
            through: lineEnd,
            in: text
        )
        guard indentation <= 3,
              cursor < lineEnd else {
            return nil
        }

        let fenceCharacter = text.character(at: cursor)
        guard fenceCharacter == 0x60 || fenceCharacter == 0x7E else {
            return nil
        }
        let fenceStart = cursor
        while cursor < lineEnd,
              text.character(at: cursor) == fenceCharacter {
            cursor += 1
        }
        let fenceLength = cursor - fenceStart
        guard fenceLength >= 3 else { return nil }

        let info = text.substring(
            with: NSRange(location: cursor, length: lineEnd - cursor)
        )
        if fenceCharacter == 0x60, info.contains("`") {
            return nil
        }
        let language = info
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased()
        guard language == "mermaid" else { return nil }
        return OpeningFence(
            character: fenceCharacter,
            length: fenceLength
        )
    }

    private static func isClosingFence(
        in lineRange: NSRange,
        opening: OpeningFence,
        text: NSString
    ) -> Bool {
        var cursor = lineRange.location
        let lineEnd = NSMaxRange(lineRange)
        let indentation = consumeSpaces(
            from: &cursor,
            through: lineEnd,
            in: text
        )
        guard indentation <= 3 else { return false }

        let fenceStart = cursor
        while cursor < lineEnd,
              text.character(at: cursor) == opening.character {
            cursor += 1
        }
        guard cursor - fenceStart >= opening.length else { return false }
        while cursor < lineEnd {
            let character = text.character(at: cursor)
            guard character == 0x20 || character == 0x09 else {
                return false
            }
            cursor += 1
        }
        return true
    }

    private static func consumeSpaces(
        from cursor: inout Int,
        through end: Int,
        in text: NSString
    ) -> Int {
        let start = cursor
        while cursor < end, text.character(at: cursor) == 0x20 {
            cursor += 1
        }
        return cursor - start
    }

    private static func lineContentRange(
        _ lineRange: NSRange,
        in text: NSString
    ) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            switch text.character(at: end - 1) {
            case 0x0A, 0x0D, 0x2028, 0x2029:
                end -= 1
            default:
                return NSRange(
                    location: lineRange.location,
                    length: end - lineRange.location
                )
            }
        }
        return NSRange(location: lineRange.location, length: 0)
    }
}

@MainActor
final class MermaidBlockPresenter {
    private static let markerFont = NSFont.systemFont(ofSize: 0.1)
    private static let maximumDisplayHeight: CGFloat = 4_096
    private static let horizontalPadding: CGFloat = 16
    private static let paragraphSpacing: CGFloat = 10

    private let renderer: MermaidRenderer

    init(renderer: MermaidRenderer) {
        self.renderer = renderer
    }

    func apply(
        to textView: NSTextView,
        rendersMarkdown: Bool,
        source: String,
        blocks: [MermaidFencedBlock]
    ) {
        guard rendersMarkdown,
              let textStorage = textView.textStorage,
              textStorage.length > 0,
              textStorage.length == (source as NSString).length,
              !blocks.isEmpty else {
            return
        }

        let selectedRange = textView.selectedRange()
        let sourceText = source as NSString
        let maximumWidth = availableWidth(in: textView)
        guard maximumWidth > 0 else { return }

        textStorage.beginEditing()
        defer {
            textStorage.endEditing()
            textView.setNeedsDisplay(textView.visibleRect)
        }

        for block in blocks {
            guard NSMaxRange(block.fullRange) <= textStorage.length,
                  NSMaxRange(block.contentRange) <= textStorage.length,
                  sourceText.substring(with: block.contentRange) == block.source,
                  textStorage.mutableString.compare(
                      sourceText.substring(with: block.fullRange),
                      options: .literal,
                      range: block.fullRange
                  ) == .orderedSame,
                  !selection(selectedRange, intersects: block.fullRange),
                  let diagram = renderer.diagram(for: block.source),
                  let displaySize = displaySize(
                      for: diagram.naturalSize,
                      maximumWidth: maximumWidth
                  ),
                  let anchorLocation = anchorLocation(
                      in: block.contentRange,
                      text: sourceText
                  ) else {
                continue
            }

            let sourceIdentity = block.source.hashValue
            if isAlreadyPresented(
                textStorage: textStorage,
                anchorLocation: anchorLocation,
                sourceIdentity: sourceIdentity,
                displayWidth: displaySize.width
            ) {
                continue
            }

            present(
                block,
                diagram: diagram,
                displaySize: displaySize,
                anchorLocation: anchorLocation,
                sourceIdentity: sourceIdentity,
                textStorage: textStorage
            )
        }
    }

    private func present(
        _ block: MermaidFencedBlock,
        diagram: MermaidRenderedDiagram,
        displaySize: CGSize,
        anchorLocation: Int,
        sourceIdentity: Int,
        textStorage: NSTextStorage
    ) {
        let text = textStorage.string as NSString
        let paragraphRange = text.paragraphRange(for: block.fullRange)
        guard NSMaxRange(paragraphRange) <= textStorage.length else { return }

        let image = (diagram.image.copy() as? NSImage) ?? diagram.image
        image.size = displaySize
        let baseFont = textStorage.attribute(
            .font,
            at: anchorLocation,
            effectiveRange: nil
        ) as? NSFont ?? AppTheme.editorFont(size: 14)
        let baseLineHeight = max(
            1,
            baseFont.ascender - baseFont.descender + baseFont.leading
        )

        let visibleParagraph = NSMutableParagraphStyle()
        visibleParagraph.alignment = .center
        visibleParagraph.lineBreakMode = .byClipping
        visibleParagraph.minimumLineHeight = max(
            baseLineHeight,
            displaySize.height
        )
        visibleParagraph.maximumLineHeight = visibleParagraph.minimumLineHeight
        visibleParagraph.paragraphSpacing = Self.paragraphSpacing

        let collapsedParagraph = NSMutableParagraphStyle()
        collapsedParagraph.maximumLineHeight = 1
        collapsedParagraph.paragraphSpacing = 0
        collapsedParagraph.paragraphSpacingBefore = 0

        textStorage.addAttributes(
            [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .font: Self.markerFont
            ],
            range: block.fullRange
        )
        textStorage.addAttribute(
            .backgroundColor,
            value: NSColor.clear,
            range: paragraphRange
        )

        text.enumerateSubstrings(
            in: paragraphRange,
            options: .byParagraphs
        ) { _, _, enclosingRange, _ in
            let paragraphStyle = NSLocationInRange(
                anchorLocation,
                enclosingRange
            ) ? visibleParagraph : collapsedParagraph
            textStorage.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: enclosingRange
            )
        }

        addCollapsedWidth(
            range: NSRange(
                location: block.contentRange.location,
                length: anchorLocation - block.contentRange.location
            ),
            text: text,
            textStorage: textStorage
        )

        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorCharacter = text.substring(with: anchorRange)
        MarkdownEngineCompatibility.applyRenderedBlockImage(
            image,
            bounds: CGRect(origin: .zero, size: displaySize),
            sourceIdentity: sourceIdentity,
            displayWidth: displaySize.width,
            to: textStorage,
            range: anchorRange
        )
        textStorage.addAttributes(
            [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .font: Self.markerFont,
                .kern: displaySize.width
                    - Self.textWidth(anchorCharacter, font: Self.markerFont)
            ],
            range: anchorRange
        )

        addCollapsedWidth(
            range: NSRange(
                location: anchorLocation + 1,
                length: NSMaxRange(block.contentRange) - anchorLocation - 1
            ),
            text: text,
            textStorage: textStorage
        )
        addCollapsedWidth(
            range: block.openingFenceRange,
            text: text,
            textStorage: textStorage
        )
        addCollapsedWidth(
            range: block.closingFenceRange,
            text: text,
            textStorage: textStorage
        )
    }

    private func addCollapsedWidth(
        range: NSRange,
        text: NSString,
        textStorage: NSTextStorage
    ) {
        guard range.length > 0 else { return }
        let source = text.substring(with: range)
        textStorage.addAttributes(
            [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .font: Self.markerFont,
                .kern: -Self.textWidth(source, font: Self.markerFont)
            ],
            range: range
        )
    }

    private func isAlreadyPresented(
        textStorage: NSTextStorage,
        anchorLocation: Int,
        sourceIdentity: Int,
        displayWidth: CGFloat
    ) -> Bool {
        guard let current = MarkdownEngineCompatibility.renderedBlock(
            in: textStorage,
            at: anchorLocation
        ) else {
            return false
        }
        return current.sourceIdentity == sourceIdentity
            && current.displayWidth.map {
                abs($0 - displayWidth) < 0.5
            } == true
    }

    private func availableWidth(in textView: NSTextView) -> CGFloat {
        let containerWidth = textView.textContainer?.size.width
        let fallbackWidth = textView.bounds.width
            - textView.textContainerInset.width * 2
        let finiteWidth: CGFloat
        if let containerWidth,
           containerWidth.isFinite,
           containerWidth > Self.horizontalPadding,
           containerWidth < 100_000 {
            finiteWidth = containerWidth
        } else {
            finiteWidth = fallbackWidth
        }
        guard finiteWidth.isFinite,
              finiteWidth > Self.horizontalPadding else {
            return 0
        }
        return finiteWidth - Self.horizontalPadding
    }

    private func displaySize(
        for naturalSize: CGSize,
        maximumWidth: CGFloat
    ) -> CGSize? {
        guard naturalSize.width.isFinite,
              naturalSize.height.isFinite,
              naturalSize.width > 0,
              naturalSize.height > 0 else {
            return nil
        }
        let scale = min(
            1,
            maximumWidth / naturalSize.width,
            Self.maximumDisplayHeight / naturalSize.height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        return CGSize(
            width: max(1, naturalSize.width * scale),
            height: max(1, naturalSize.height * scale)
        )
    }

    private func anchorLocation(
        in range: NSRange,
        text: NSString
    ) -> Int? {
        guard range.length > 0 else { return nil }
        for location in range.location..<NSMaxRange(range) {
            let codeUnit = text.character(at: location)
            guard let scalar = UnicodeScalar(UInt32(codeUnit)) else {
                return location
            }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return location
            }
        }
        return nil
    }

    private func selection(
        _ selection: NSRange,
        intersects blockRange: NSRange
    ) -> Bool {
        if selection.length == 0 {
            return NSLocationInRange(selection.location, blockRange)
        }
        return NSIntersectionRange(selection, blockRange).length > 0
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
