import Foundation

struct DocumentSyncRawRecoveryPayload: Sendable, Equatable {
    private let verifiedPayload: VerifiedFilePayload
    /// The immutable file location whose raw bytes are being preserved. Raw
    /// recovery decoding must not reconstruct it from mutable host state or
    /// an identity implementation detail.
    let targetURL: URL
    let recoveryArtifact: CommitRecoveryArtifact?

    init(
        data: Data,
        targetURL: URL,
        resourceIdentifier: String? = nil,
        recoveryArtifact: CommitRecoveryArtifact?
    ) {
        verifiedPayload = VerifiedFilePayload(
            data: data,
            resourceIdentifier: resourceIdentifier
        )
        self.targetURL = targetURL
        self.recoveryArtifact = recoveryArtifact
    }

    init(
        verifiedPayload: VerifiedFilePayload,
        targetURL: URL,
        recoveryArtifact: CommitRecoveryArtifact?
    ) {
        self.verifiedPayload = verifiedPayload
        self.targetURL = targetURL
        self.recoveryArtifact = recoveryArtifact
    }

    var data: Data {
        verifiedPayload.data
    }

    var fingerprint: FileFingerprint {
        verifiedPayload.fingerprint
    }
}

enum DocumentSyncRecoveryPersistencePayload: Sendable, Equatable {
    case snapshot(DocumentSnapshot)
    case raw(DocumentSyncRawRecoveryPayload)

    var snapshot: DocumentSnapshot? {
        guard case .snapshot(let snapshot) = self else { return nil }
        return snapshot
    }

    var raw: DocumentSyncRawRecoveryPayload? {
        guard case .raw(let payload) = self else { return nil }
        return payload
    }
}

struct DocumentSyncDisplacedPreimageContinuation: Sendable, Equatable {
    let entryID: UUID
    let originIdentity: DocumentIdentity
    let originAttachmentEpoch: UInt64
    let rawPayload: DocumentSyncRawRecoveryPayload
    let mergeBase: DocumentSnapshot
    let local: DocumentSnapshot
    let localSourceRevision: SourceRevision
    let pendingRevision: SourceRevision
    let preCommitBaseline: DocumentSyncDurableBaseline?
    let committedBaseline: DocumentSyncDurableBaseline
    let commitSafety: FileCommitSafety
}
