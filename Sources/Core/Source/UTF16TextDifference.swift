import Foundation

struct UTF16TextDifference: Sendable, Equatable {
    let originalRange: NSRange
    let updatedRange: NSRange

    static func between(
        original: NSString,
        updated: NSString
    ) -> UTF16TextDifference {
        var prefix = 0
        let sharedLength = min(original.length, updated.length)
        while prefix < sharedLength,
            original.character(at: prefix)
                == updated.character(at: prefix)
        {
            prefix += 1
        }
        if splitsSurrogatePair(at: prefix, in: original)
            || splitsSurrogatePair(at: prefix, in: updated)
        {
            prefix -= 1
        }

        var suffix = 0
        while suffix < original.length - prefix,
            suffix < updated.length - prefix,
            original.character(at: original.length - suffix - 1)
                == updated.character(at: updated.length - suffix - 1)
        {
            suffix += 1
        }
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
