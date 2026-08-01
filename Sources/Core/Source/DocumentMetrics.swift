import Foundation

struct DocumentMetrics: Sendable, Equatable {
    private static let mermaidNeedle: [unichar] = Array("mermaid".utf16)
    private static let editContextLength = mermaidNeedle.count

    let utf8ByteCount: Int
    let lineCount: Int
    let mermaidCandidateCount: Int

    var containsMermaidCandidate: Bool {
        mermaidCandidateCount > 0
    }

    init(text: String) {
        let source = text as NSString
        utf8ByteCount = text.utf8.count
        lineCount = Self.logicalLineBreakCount(in: source) + 1
        mermaidCandidateCount = Self.mermaidCount(in: source)
    }

    func applying(_ edit: SourceEdit, to previous: String) -> DocumentMetrics {
        let source = previous as NSString
        guard edit.range.location >= 0,
            edit.range.length >= 0,
            NSMaxRange(edit.range) <= source.length
        else {
            return self
        }

        let contextStart = max(
            0,
            edit.range.location - Self.editContextLength
        )
        let contextEnd = min(
            source.length,
            NSMaxRange(edit.range) + Self.editContextLength
        )
        let contextRange = NSRange(
            location: contextStart,
            length: contextEnd - contextStart
        )
        let oldContext = source.substring(with: contextRange) as NSString
        let newContext = NSMutableString(string: oldContext)
        newContext.replaceCharacters(
            in: NSRange(
                location: edit.range.location - contextStart,
                length: edit.range.length
            ),
            with: edit.replacement
        )

        let removed = source.substring(with: edit.range).utf8.count
        return DocumentMetrics(
            utf8ByteCount: max(
                0,
                utf8ByteCount - removed + edit.replacement.utf8.count
            ),
            lineCount: max(
                1,
                lineCount
                    - Self.logicalLineBreakCount(in: oldContext)
                    + Self.logicalLineBreakCount(in: newContext)
            ),
            mermaidCandidateCount: max(
                0,
                mermaidCandidateCount
                    - Self.mermaidCount(in: oldContext)
                    + Self.mermaidCount(in: newContext)
            )
        )
    }

    private init(
        utf8ByteCount: Int,
        lineCount: Int,
        mermaidCandidateCount: Int
    ) {
        self.utf8ByteCount = utf8ByteCount
        self.lineCount = lineCount
        self.mermaidCandidateCount = mermaidCandidateCount
    }

    private static func logicalLineBreakCount(in text: NSString) -> Int {
        var count = 0
        var index = 0
        while index < text.length {
            switch text.character(at: index) {
            case 0x000D:
                count += 1
                if index + 1 < text.length,
                    text.character(at: index + 1) == 0x000A
                {
                    index += 1
                }
            case 0x000A, 0x2028, 0x2029:
                count += 1
            default:
                break
            }
            index += 1
        }
        return count
    }

    private static func mermaidCount(in text: NSString) -> Int {
        guard text.length >= mermaidNeedle.count else { return 0 }
        var count = 0
        let lastStart = text.length - mermaidNeedle.count
        for start in 0...lastStart {
            var matches = true
            for offset in mermaidNeedle.indices {
                let character = text.character(at: start + offset)
                let folded: unichar
                if character >= 0x0041, character <= 0x005A {
                    folded = character + 0x0020
                } else {
                    folded = character
                }
                if folded != mermaidNeedle[offset] {
                    matches = false
                    break
                }
            }
            if matches {
                count += 1
            }
        }
        return count
    }
}
