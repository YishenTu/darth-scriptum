import Foundation

struct UTF16TextDifference: Sendable, Equatable {
    let originalRange: NSRange
    let updatedRange: NSRange

    static func between(
        original: NSString,
        updated: NSString
    ) -> UTF16TextDifference {
        let sharedLength = min(original.length, updated.length)
        var prefix = matchingLength(
            original: original,
            updated: updated,
            limit: sharedLength,
            backwards: false
        )
        if splitsSurrogatePair(at: prefix, in: original)
            || splitsSurrogatePair(at: prefix, in: updated)
        {
            prefix -= 1
        }

        var suffix = matchingLength(
            original: original,
            updated: updated,
            limit: sharedLength - prefix,
            backwards: true
        )
        if splitsSurrogatePair(
            at: original.length - suffix,
            in: original
        )
            || splitsSurrogatePair(
                at: updated.length - suffix,
                in: updated
            )
        {
            suffix -= 1
        }

        return UTF16TextDifference(
            originalRange: NSRange(
                location: prefix,
                length: original.length - prefix - suffix
            ),
            updatedRange: NSRange(
                location: prefix,
                length: updated.length - prefix - suffix
            )
        )
    }

    private static func matchingLength(
        original: NSString,
        updated: NSString,
        limit: Int,
        backwards: Bool
    ) -> Int {
        guard limit > 0 else { return 0 }
        let capacity = 1_024
        // Bound scratch space independently of document size. Bulk extraction
        // avoids millions of character(at:) dispatches for unchanged spans.
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: capacity * 2) { buffer in
            let oldUnits = buffer.baseAddress!
            let newUnits = oldUnits + capacity
            var matched = 0
            while matched < limit {
                let count = min(capacity, limit - matched)
                original.getCharacters(
                    oldUnits,
                    range: NSRange(
                        location: backwards ? original.length - matched - count : matched,
                        length: count
                    ))
                updated.getCharacters(
                    newUnits,
                    range: NSRange(
                        location: backwards ? updated.length - matched - count : matched,
                        length: count
                    ))
                if memcmp(oldUnits, newUnits, count * MemoryLayout<unichar>.stride) == 0 {
                    matched += count
                    continue
                }
                for offset in 0..<count {
                    let index = backwards ? count - offset - 1 : offset
                    if oldUnits[index] != newUnits[index] {
                        return matched + offset
                    }
                }
            }
            return matched
        }
    }

    static func splitsSurrogatePair(
        at location: Int,
        in text: NSString
    ) -> Bool {
        guard location > 0, location < text.length else { return false }
        return CFStringIsSurrogateHighCharacter(
            text.character(at: location - 1)
        )
            && CFStringIsSurrogateLowCharacter(
                text.character(at: location)
            )
    }
}
