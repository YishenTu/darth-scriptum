import Foundation

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
        self.init(
            generation: generation,
            committedFingerprint: committedFingerprint,
            verifiedDisplacedPreimage: displacedPreimage.map {
                VerifiedFilePayload(data: $0)
            },
            safety: safety,
            recoveryArtifact: recoveryArtifact
        )
    }

    init(
        generation: UInt64,
        committedFingerprint: FileFingerprint,
        verifiedDisplacedPreimage: VerifiedFilePayload?,
        safety: FileCommitSafety,
        recoveryArtifact: CommitRecoveryArtifact? = nil
    ) {
        self.generation = generation
        self.committedFingerprint = committedFingerprint
        self.displacedPreimage = verifiedDisplacedPreimage
        self.safety = safety
        self.recoveryArtifact = recoveryArtifact
    }
}
