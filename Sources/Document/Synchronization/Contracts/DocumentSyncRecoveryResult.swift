import Foundation

struct DocumentSyncRecoveryLoadResult: Sendable, Equatable {
    let scope: DocumentSyncRecoveryLoadScope
    let generation: UInt64
    let records: DocumentSyncRecoveryRecords
}

struct DocumentSyncRecoveryReconciliationResult: Sendable, Equatable {
    let identity: DocumentIdentity
    let generation: UInt64
    let records: DocumentSyncRecoveryRecords
    /// A commit-journal artifact acknowledged while reconciling a raw recovery
    /// write. A raw entry is not safe to discard until this receipt is present.
    let acknowledgedRecoveryArtifact: CommitRecoveryArtifact?

    init(
        identity: DocumentIdentity,
        generation: UInt64,
        records: DocumentSyncRecoveryRecords,
        acknowledgedRecoveryArtifact: CommitRecoveryArtifact? = nil
    ) {
        self.identity = identity
        self.generation = generation
        self.records = records
        self.acknowledgedRecoveryArtifact = acknowledgedRecoveryArtifact
    }
}

struct DocumentSyncRecoveryMutationResult: Sendable, Equatable {
    let previousGeneration: UInt64
    let generation: UInt64
    let records: DocumentSyncRecoveryRecords
}

enum DocumentSyncDisplacedPreimageDecodeOutcome: Sendable, Equatable {
    case decoded(DocumentSyncExternalChange)
    case undecodable
}

struct DocumentSyncRawRecoveryPersistResult: Sendable, Equatable {
    let mutation: DocumentSyncRecoveryMutationResult
    let durablyPersistedRawEntryID: UUID
    let acknowledgedRecoveryArtifact: CommitRecoveryArtifact?
    let decodeOutcome: DocumentSyncDisplacedPreimageDecodeOutcome
}

enum DocumentSyncRecoveryResult: Sendable, Equatable {
    case loaded(DocumentSyncRecoveryLoadResult)
    case reconciled(DocumentSyncRecoveryReconciliationResult)
    case persisted(DocumentSyncRecoveryMutationResult)
    case rawPersisted(DocumentSyncRawRecoveryPersistResult)
    case migrated(DocumentSyncRecoveryMutationResult)
    case discarded(DocumentSyncRecoveryMutationResult)
    case failed(DocumentSyncFailure)
}
