import Foundation

struct DocumentMetrics: Sendable, Equatable {
    private static let mermaidNeedle = Array("mermaid".utf8)
    private static let editContextLength = mermaidNeedle.count

    let utf8ByteCount: Int
    let lineCount: Int
    let mermaidCandidateCount: Int

    var containsMermaidCandidate: Bool {
        mermaidCandidateCount > 0
    }

    init(text: String) {
        let counts =
            text.utf8.withContiguousStorageIfAvailable(Self.scan)
            ?? Array(text.utf8).withUnsafeBufferPointer(Self.scan)
        utf8ByteCount = counts.bytes
        lineCount = counts.lineBreaks + 1
        mermaidCandidateCount = counts.mermaid
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

        let oldMetrics = DocumentMetrics(text: oldContext as String)
        let newMetrics = DocumentMetrics(text: newContext as String)
        let removed = source.substring(with: edit.range).utf8.count
        return DocumentMetrics(
            utf8ByteCount: max(
                0,
                utf8ByteCount - removed + edit.replacement.utf8.count
            ),
            lineCount: max(
                1,
                lineCount
                    - oldMetrics.lineCount
                    + newMetrics.lineCount
            ),
            mermaidCandidateCount: max(
                0,
                mermaidCandidateCount
                    - oldMetrics.mermaidCandidateCount
                    + newMetrics.mermaidCandidateCount
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

    // UTF-8 preserves ASCII delimiters verbatim. Scan the native bytes once,
    // including the two Unicode line separators, without bridging the document
    // to NSString or sending an Objective-C message for each code unit.
    private static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>
    ) -> (bytes: Int, lineBreaks: Int, mermaid: Int) {
        var lineBreaks = 0
        var mermaid = 0
        for index in bytes.indices {
            let byte = bytes[index]
            if byte == 0x0D {
                lineBreaks += 1
            } else if byte == 0x0A {
                if index == 0 || bytes[index - 1] != 0x0D {
                    lineBreaks += 1
                }
            } else if byte == 0xE2, index + 2 < bytes.count,
                bytes[index + 1] == 0x80,
                bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9
            {
                lineBreaks += 1
            }
            if byte | 0x20 == mermaidNeedle[0],
                bytes.count - index >= mermaidNeedle.count
            {
                var matches = true
                for offset in 1..<mermaidNeedle.count {
                    if bytes[index + offset] | 0x20 != mermaidNeedle[offset] {
                        matches = false
                        break
                    }
                }
                if matches {
                    mermaid += 1
                }
            }
        }
        return (bytes.count, lineBreaks, mermaid)
    }
}
