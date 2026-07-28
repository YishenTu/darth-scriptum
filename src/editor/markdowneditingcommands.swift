import Foundation

enum MarkdownLinkResolver {
    private static let allowedSchemes = Set([
        "file",
        "http",
        "https",
        "mailto"
    ])

    static func resolve(
        _ destination: String,
        relativeTo documentURL: URL?
    ) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absoluteURL = URL(string: trimmed),
           let scheme = absoluteURL.scheme?.lowercased() {
            return allowedSchemes.contains(scheme) ? absoluteURL : nil
        }
        guard let documentURL else { return nil }
        let baseURL = documentURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("", isDirectory: true)
        return URL(string: trimmed, relativeTo: baseURL)?
            .absoluteURL
            .standardizedFileURL
    }

    static func resolveLocalFile(
        _ destination: String,
        relativeTo documentURL: URL?
    ) -> URL? {
        guard let url = resolve(destination, relativeTo: documentURL),
              url.isFileURL else {
            return nil
        }
        return url
    }
}

struct MarkdownTextMutation: Equatable {
    let range: NSRange
    let replacement: String
}

enum MarkdownEditingCommands {
    static func taskToggle(
        in text: String,
        selection: NSRange
    ) -> MarkdownTextMutation? {
        let source = text as NSString
        let location = min(max(selection.location, 0), source.length)
        let lineRange = source.lineRange(
            for: NSRange(location: location, length: 0)
        )
        let line = source.substring(with: lineRange) as NSString
        let taskExpression = try? NSRegularExpression(
            pattern: #"^([ \t]*(?:[-+*]|\d+\.)[ \t]+)\[( |x|X)\]"#
        )
        if let match = taskExpression?.firstMatch(
            in: line as String,
            range: NSRange(location: 0, length: line.length)
        ) {
            let marker = line.substring(with: match.range(at: 2))
            return MarkdownTextMutation(
                range: NSRange(
                    location: lineRange.location + match.range(at: 2).location,
                    length: 1
                ),
                replacement: marker == " " ? "x" : " "
            )
        }

        let listExpression = try? NSRegularExpression(
            pattern: #"^([ \t]*(?:[-+*]|\d+\.)[ \t]+)"#
        )
        if let match = listExpression?.firstMatch(
            in: line as String,
            range: NSRange(location: 0, length: line.length)
        ) {
            return MarkdownTextMutation(
                range: NSRange(
                    location: lineRange.location
                        + NSMaxRange(match.range(at: 1)),
                    length: 0
                ),
                replacement: "[ ] "
            )
        }
        return MarkdownTextMutation(
            range: NSRange(location: lineRange.location, length: 0),
            replacement: "- [ ] "
        )
    }

    static func transformLines(_ text: String, indenting: Bool) -> String {
        let source = text as NSString
        var result = ""
        var index = 0
        while index < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentEnd,
                for: NSRange(location: index, length: 0)
            )
            let content = source.substring(
                with: NSRange(
                    location: lineStart,
                    length: contentEnd - lineStart
                )
            )
            let terminator = source.substring(
                with: NSRange(
                    location: contentEnd,
                    length: lineEnd - contentEnd
                )
            )
            if indenting {
                result += content.isEmpty ? content : "  \(content)"
            } else if content.hasPrefix("\t") {
                result += String(content.dropFirst())
            } else if content.hasPrefix("  ") {
                result += String(content.dropFirst(2))
            } else if content.hasPrefix(" ") {
                result += String(content.dropFirst())
            } else {
                result += content
            }
            result += terminator
            index = lineEnd
        }
        return result
    }

    static func firstLineIndentDelta(
        in text: String,
        indenting: Bool
    ) -> Int {
        guard !text.isEmpty else { return 0 }
        if indenting { return 2 }
        if text.hasPrefix("\t") { return -1 }
        if text.hasPrefix("  ") { return -2 }
        if text.hasPrefix(" ") { return -1 }
        return 0
    }
}

struct SelectionAnchor {
    private static let searchRadius = 64 * 1_024
    let selectedRange: NSRange
    let prefix: String
    let selectedText: String
    let suffix: String

    static func capture(
        selectedRange: NSRange,
        in source: String
    ) -> SelectionAnchor {
        let text = source as NSString
        let location = min(max(selectedRange.location, 0), text.length)
        let beforeStart = max(0, location - 24)
        let before = text.substring(
            with: NSRange(
                location: beforeStart,
                length: location - beforeStart
            )
        )
        let selectionEnd = min(NSMaxRange(selectedRange), text.length)
        let after = text.substring(
            with: NSRange(
                location: selectionEnd,
                length: min(24, text.length - selectionEnd)
            )
        )
        return SelectionAnchor(
            selectedRange: selectedRange,
            prefix: before,
            selectedText: text.substring(
                with: NSRange(
                    location: location,
                    length: selectionEnd - location
                )
            ),
            suffix: after
        )
    }

    func resolve(in source: String) -> NSRange {
        let text = source as NSString
        let originalLocation = min(selectedRange.location, text.length)
        let searchLowerBound = max(
            0,
            originalLocation - Self.searchRadius
        )
        let searchUpperBound = min(
            text.length,
            originalLocation + Self.searchRadius
        )
        let searchRange = NSRange(
            location: searchLowerBound,
            length: searchUpperBound - searchLowerBound
        )
        var candidates: Set<Int> = [originalLocation]
        collectNearestCandidates(
            matching: prefix,
            in: text,
            range: searchRange,
            expectedMatchLocation: max(
                originalLocation - prefix.utf16.count,
                searchLowerBound
            ),
            locationTransform: NSMaxRange,
            into: &candidates
        )
        collectNearestCandidates(
            matching: suffix,
            in: text,
            range: searchRange,
            expectedMatchLocation: min(
                originalLocation + selectedText.utf16.count,
                searchUpperBound
            ),
            locationTransform: {
                max($0.location - self.selectedText.utf16.count, 0)
            },
            into: &candidates
        )
        let bestLocation = candidates
            .filter { $0 >= 0 && $0 <= text.length }
            .max { left, right in
                let leftScore = contextScore(at: left, in: text)
                let rightScore = contextScore(at: right, in: text)
                if leftScore == rightScore {
                    return abs(left - originalLocation)
                        > abs(right - originalLocation)
                }
                return leftScore < rightScore
            } ?? originalLocation
        return resolvedRange(at: bestLocation, in: text)
    }

    private func collectNearestCandidates(
        matching context: String,
        in text: NSString,
        range: NSRange,
        expectedMatchLocation: Int,
        locationTransform: (NSRange) -> Int,
        into candidates: inout Set<Int>
    ) {
        guard !context.isEmpty else { return }
        let contextLength = context.utf16.count
        let backwardEnd = min(
            NSMaxRange(range),
            expectedMatchLocation + contextLength
        )
        if backwardEnd > range.location {
            let backwardMatch = text.range(
                of: context,
                options: .backwards,
                range: NSRange(
                    location: range.location,
                    length: backwardEnd - range.location
                )
            )
            if backwardMatch.location != NSNotFound {
                candidates.insert(locationTransform(backwardMatch))
            }
        }
        let forwardStart = min(
            max(expectedMatchLocation, range.location),
            NSMaxRange(range)
        )
        if forwardStart < NSMaxRange(range) {
            let forwardMatch = text.range(
                of: context,
                range: NSRange(
                    location: forwardStart,
                    length: NSMaxRange(range) - forwardStart
                )
            )
            if forwardMatch.location != NSNotFound {
                candidates.insert(locationTransform(forwardMatch))
            }
        }
    }

    private func contextScore(at location: Int, in text: NSString) -> Int {
        let prefixLength = min(prefix.utf16.count, location)
        let candidatePrefix = text.substring(
            with: NSRange(
                location: location - prefixLength,
                length: prefixLength
            )
        )
        let selectionLength = min(selectedText.utf16.count, text.length - location)
        let candidateSelection = text.substring(
            with: NSRange(location: location, length: selectionLength)
        )
        let suffixStart = location + selectionLength
        let candidateSuffix = text.substring(
            with: NSRange(
                location: suffixStart,
                length: min(suffix.utf16.count, text.length - suffixStart)
            )
        )
        return commonSuffixLength(prefix, candidatePrefix) * 4
            + commonPrefixLength(selectedText, candidateSelection) * 8
            + commonPrefixLength(suffix, candidateSuffix) * 4
    }

    private func resolvedRange(at location: Int, in text: NSString) -> NSRange {
        let available = max(text.length - location, 0)
        return NSRange(
            location: location,
            length: min(selectedRange.length, available)
        )
    }

    private func commonPrefixLength(_ left: String, _ right: String) -> Int {
        var count = 0
        for (leftUnit, rightUnit) in zip(left.utf16, right.utf16) {
            guard leftUnit == rightUnit else { break }
            count += 1
        }
        return count
    }

    private func commonSuffixLength(_ left: String, _ right: String) -> Int {
        var count = 0
        for (leftUnit, rightUnit) in zip(
            left.utf16.reversed(),
            right.utf16.reversed()
        ) {
            guard leftUnit == rightUnit else { break }
            count += 1
        }
        return count
    }
}
