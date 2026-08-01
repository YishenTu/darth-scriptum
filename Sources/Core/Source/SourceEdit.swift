import Foundation

enum DocumentChangeOrigin: Sendable, Equatable {
    case initialLoad
    case localEditor(paneID: UUID)
    case undoRedo
    case externalReload
    case merge
    case recovery
}

struct SourceEdit: Sendable, Equatable {
    let range: NSRange
    let replacement: String
    let expectedRevision: UInt64
    let origin: DocumentChangeOrigin

    func applying(to revision: SourceRevision) throws -> SourceRevision {
        guard revision.number == expectedRevision else {
            throw SourceEditError.staleRevision
        }
        let source = revision.text as NSString
        guard range.location >= 0,
            range.length >= 0,
            range.location <= source.length,
            NSMaxRange(range) <= source.length,
            !UTF16TextDifference.splitsSurrogatePair(
                at: range.location,
                in: source
            ),
            !UTF16TextDifference.splitsSurrogatePair(
                at: NSMaxRange(range),
                in: source
            )
        else {
            throw SourceEditError.invalidRange
        }
        let result = NSMutableString(string: source)
        result.replaceCharacters(in: range, with: replacement)
        return revision.advanced(to: result as String)
    }
}

enum SourceEditError: LocalizedError, Equatable {
    case staleRevision
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .staleRevision:
            "The edit was based on an outdated document revision."
        case .invalidRange:
            "The edit range is invalid for the current document."
        }
    }
}
