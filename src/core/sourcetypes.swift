import CryptoKit
import Foundation

struct SourceRevision: Sendable, Equatable, Hashable {
    let number: UInt64
    let text: String

    func advanced(to text: String) -> SourceRevision {
        SourceRevision(number: number &+ 1, text: text)
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
}

struct DurableFileState: Sendable, Equatable {
    let snapshot: DocumentSnapshot
    let fingerprint: FileFingerprint
    let generation: UInt64
}

struct PendingSaveToken: Sendable, Equatable {
    let generation: UInt64
    let sourceRevision: SourceRevision
    let snapshot: DocumentSnapshot
    let encodedData: Data
    let expectedDurableState: DurableFileState?
    let targetURL: URL
}

enum FileCommitSafety: String, Sendable, Equatable {
    case atomicSwap
    case coordinatedReplacement
}

struct CommitRecoveryArtifact: Sendable, Equatable {
    let id: UUID
    let journalURL: URL
    let candidateURL: URL
    let replacementDirectoryURL: URL
    let replacementDirectoryResourceIdentifier: String
}

struct FileCommitResult: Sendable, Equatable {
    let generation: UInt64
    let committedFingerprint: FileFingerprint
    let displacedPreimage: Data?
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
        self.displacedPreimage = displacedPreimage
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
