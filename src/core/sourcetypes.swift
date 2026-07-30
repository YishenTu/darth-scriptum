import CryptoKit
import Foundation

struct SourceRevision: Sendable, Equatable, Hashable {
    let number: UInt64
    let text: String

    func advanced(to text: String) -> SourceRevision {
        SourceRevision(number: number &+ 1, text: text)
    }
}

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
              NSMaxRange(edit.range) <= source.length else {
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
                   text.character(at: index + 1) == 0x000A {
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
              ) else {
            throw SourceEditError.invalidRange
        }
        let result = NSMutableString(string: source)
        result.replaceCharacters(in: range, with: replacement)
        return revision.advanced(to: result as String)
    }
}

enum SourceSelectionTransformer {
    static func transform(_ selection: NSRange, by edit: SourceEdit) -> NSRange {
        let replacementLength = (edit.replacement as NSString).length
        let editStart = edit.range.location
        let editEnd = NSMaxRange(edit.range)
        let selectionEnd = NSMaxRange(selection)

        if edit.range.length == 0 {
            if selection.length == 0 {
                let location = selection.location >= editStart
                    ? selection.location + replacementLength
                    : selection.location
                return NSRange(location: location, length: 0)
            }
            if editStart <= selection.location {
                return NSRange(
                    location: selection.location + replacementLength,
                    length: selection.length
                )
            }
            if editStart < selectionEnd {
                return NSRange(
                    location: selection.location,
                    length: selection.length + replacementLength
                )
            }
            return selection
        }

        let start = transformedBoundary(
            selection.location,
            editStart: editStart,
            editEnd: editEnd,
            replacementLength: replacementLength,
            prefersTrailingEdge: false
        )
        let end = transformedBoundary(
            selectionEnd,
            editStart: editStart,
            editEnd: editEnd,
            replacementLength: replacementLength,
            prefersTrailingEdge: true
        )
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func transformedBoundary(
        _ location: Int,
        editStart: Int,
        editEnd: Int,
        replacementLength: Int,
        prefersTrailingEdge: Bool
    ) -> Int {
        if location < editStart { return location }
        if location > editEnd {
            return location + replacementLength - (editEnd - editStart)
        }
        if location == editEnd {
            return editStart + replacementLength
        }
        return prefersTrailingEdge
            ? editStart + replacementLength
            : editStart
    }
}

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
                == updated.character(at: prefix) {
            prefix += 1
        }
        if splitsSurrogatePair(at: prefix, in: original)
            || splitsSurrogatePair(at: prefix, in: updated) {
            prefix -= 1
        }

        var suffix = 0
        while suffix < original.length - prefix,
              suffix < updated.length - prefix,
              original.character(at: original.length - suffix - 1)
                == updated.character(at: updated.length - suffix - 1) {
            suffix += 1
        }
        if splitsSurrogatePair(
            at: original.length - suffix,
            in: original
        ) || splitsSurrogatePair(
            at: updated.length - suffix,
            in: updated
        ) {
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
        ) && CFStringIsSurrogateLowCharacter(
            text.character(at: location)
        )
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

enum NewlineStyle: String, Sendable, Equatable {
    case lf
    case crlf

    var sequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        }
    }
}

enum TextEncoding: String, Sendable, Equatable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian
}

struct TextFileFormat: Sendable, Equatable {
    var encoding: TextEncoding
    var dominantNewline: NewlineStyle
    var hasFinalNewline: Bool

    static let newDocument = TextFileFormat(
        encoding: .utf8,
        dominantNewline: .lf,
        hasFinalNewline: false
    )
}

struct DocumentSnapshot: Sendable, Equatable {
    var text: String
    var format: TextFileFormat
}

struct FileFingerprint: Sendable, Equatable, Hashable {
    let byteCount: Int
    let contentDigest: String
    let resourceIdentifier: String?

    static func make(data: Data, resourceIdentifier: String? = nil) -> FileFingerprint {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return FileFingerprint(
            byteCount: data.count,
            contentDigest: digest,
            resourceIdentifier: resourceIdentifier
        )
    }
}

struct DocumentIdentity: Sendable, Equatable, Hashable {
    let stableKey: String

    static func make(url: URL, resourceIdentifier: String? = nil) -> DocumentIdentity {
        _ = resourceIdentifier
        let canonicalPath = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return DocumentIdentity(stableKey: "path:\(canonicalPath)")
    }

    func matches(url: URL) -> Bool {
        self == Self.make(url: url)
    }
}

struct DurableFileState: Sendable, Equatable {
    let snapshot: DocumentSnapshot
    let fingerprint: FileFingerprint
    let generation: UInt64
}

enum FileCommitSafety: String, Sendable, Equatable {
    case atomicSwap
    case coordinatedReplacement
}

/// Bytes whose intrinsic fingerprint was computed from those same bytes.
/// This prevents a completion from pairing one payload with another payload's
/// claimed digest.
struct VerifiedFilePayload: Sendable, Equatable {
    let data: Data
    let fingerprint: FileFingerprint

    init(data: Data, resourceIdentifier: String? = nil) {
        self.data = data
        fingerprint = FileFingerprint.make(
            data: data,
            resourceIdentifier: resourceIdentifier
        )
    }
}

struct CommitRecoveryArtifactBinding: Sendable, Equatable {
    let documentIdentity: DocumentIdentity
    let targetURL: URL
    let expectedPreimageFingerprint: FileFingerprint
    let committedPayloadFingerprint: FileFingerprint
}

struct CommitRecoveryArtifact: Sendable, Equatable {
    let id: UUID
    let journalURL: URL
    let candidateURL: URL
    let replacementDirectoryURL: URL
    let replacementDirectoryResourceIdentifier: String
    /// New journals bind an artifact to one exact commit. Older persisted
    /// journals decode without this value but cannot authorize new commits.
    let binding: CommitRecoveryArtifactBinding?

    init(
        id: UUID,
        journalURL: URL,
        candidateURL: URL,
        replacementDirectoryURL: URL,
        replacementDirectoryResourceIdentifier: String,
        binding: CommitRecoveryArtifactBinding? = nil
    ) {
        self.id = id
        self.journalURL = journalURL
        self.candidateURL = candidateURL
        self.replacementDirectoryURL = replacementDirectoryURL
        self.replacementDirectoryResourceIdentifier =
            replacementDirectoryResourceIdentifier
        self.binding = binding
    }
}

struct FileCommitResult: Sendable, Equatable {
    let generation: UInt64
    let committedFingerprint: FileFingerprint
    let displacedPreimage: VerifiedFilePayload?
    let safety: FileCommitSafety
    let recoveryArtifact: CommitRecoveryArtifact?

    init(
        generation: UInt64,
        committedFingerprint: FileFingerprint,
        displacedPreimage: Data?,
        safety: FileCommitSafety,
        recoveryArtifact: CommitRecoveryArtifact? = nil
    ) {
        self.generation = generation
        self.committedFingerprint = committedFingerprint
        self.displacedPreimage = displacedPreimage.map {
            VerifiedFilePayload(data: $0)
        }
        self.safety = safety
        self.recoveryArtifact = recoveryArtifact
    }
}

struct TextAnchor: Sendable, Equatable {
    var line: Int
    var column: Int
    var contextBefore: String
    var contextAfter: String
}

enum SynchronizationState: Sendable, Equatable {
    case idle
    case waitingToWrite
    case writing
    case checkingExternalChange
    case reloading
    case merging
    case recoveredConflict
    case readOnly
    case missing
    case failed(String)
    case limitedSyncSafety
    case synchronizationPaused
}
