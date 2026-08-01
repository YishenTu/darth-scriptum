import Foundation

struct MarkdownSourcePresentation: Equatable {
    let text: String
    let sourceRange: NSRange
    let rendersMarkdown: Bool

    static func make(
        source: String,
        rendersMarkdown: Bool
    ) -> MarkdownSourcePresentation {
        let fullRange = NSRange(
            location: 0,
            length: (source as NSString).length
        )
        guard rendersMarkdown,
            let bodyRange = MarkdownFrontMatter.bodyRange(in: source)
        else {
            return MarkdownSourcePresentation(
                text: source,
                sourceRange: fullRange,
                rendersMarkdown: rendersMarkdown
            )
        }
        return MarkdownSourcePresentation(
            text: (source as NSString).substring(with: bodyRange),
            sourceRange: bodyRange,
            rendersMarkdown: true
        )
    }

    func sourceRange(forPresentedRange range: NSRange) -> NSRange {
        let clamped = Self.clamped(
            range,
            toLength: (text as NSString).length
        )
        return NSRange(
            location: sourceRange.location + clamped.location,
            length: clamped.length
        )
    }

    func presentedRange(forSourceRange range: NSRange) -> NSRange {
        let sourceStart = sourceRange.location
        let sourceEnd = NSMaxRange(sourceRange)
        let rangeStart = min(max(range.location, sourceStart), sourceEnd)
        let rangeEnd = min(
            max(NSMaxRange(range), rangeStart),
            sourceEnd
        )
        return NSRange(
            location: rangeStart - sourceStart,
            length: rangeEnd - rangeStart
        )
    }

    private static func clamped(
        _ range: NSRange,
        toLength length: Int
    ) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }
}

enum MarkdownFrontMatter {
    static func bodyRange(in source: String) -> NSRange? {
        let text = source as NSString
        guard text.length > 0 else { return nil }

        let openingStart = text.character(at: 0) == 0xFEFF ? 1 : 0
        guard let openingLine = line(at: openingStart, in: text),
            delimiter(
                in: text,
                range: openingLine.contents,
                matches: "---"
            ),
            openingLine.end > openingStart
        else {
            return nil
        }

        var location = openingLine.end
        while location < text.length {
            guard let candidate = line(at: location, in: text) else {
                return nil
            }
            if delimiter(
                in: text,
                range: candidate.contents,
                matches: "---"
            )
                || delimiter(
                    in: text,
                    range: candidate.contents,
                    matches: "..."
                )
            {
                let resolvedBodyStart = bodyStart(
                    after: candidate.end,
                    in: text
                )
                return NSRange(
                    location: resolvedBodyStart,
                    length: text.length - resolvedBodyStart
                )
            }
            guard candidate.end > location else { return nil }
            location = candidate.end
        }
        return nil
    }

    private static func bodyStart(
        after closingFenceEnd: Int,
        in text: NSString
    ) -> Int {
        var location = closingFenceEnd
        while location < text.length,
            let candidate = line(at: location, in: text),
            isBlank(candidate.contents, in: text)
        {
            guard candidate.end > location else { break }
            location = candidate.end
        }
        return location
    }

    private static func line(
        at location: Int,
        in text: NSString
    ) -> (contents: NSRange, end: Int)? {
        guard location >= 0, location < text.length else { return nil }
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(
            nil,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: location, length: 0)
        )
        return (
            contents: NSRange(
                location: location,
                length: contentsEnd - location
            ),
            end: lineEnd
        )
    }

    private static func delimiter(
        in text: NSString,
        range: NSRange,
        matches expected: String
    ) -> Bool {
        var end = NSMaxRange(range)
        while end > range.location {
            let character = text.character(at: end - 1)
            guard character == 0x20 || character == 0x09 else { break }
            end -= 1
        }
        return text.substring(
            with: NSRange(
                location: range.location,
                length: end - range.location
            )
        ) == expected
    }

    private static func isBlank(
        _ range: NSRange,
        in text: NSString
    ) -> Bool {
        for location in range.location..<NSMaxRange(range) {
            let character = text.character(at: location)
            guard character == 0x20 || character == 0x09 else {
                return false
            }
        }
        return true
    }
}
