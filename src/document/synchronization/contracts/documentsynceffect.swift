import Foundation

enum SyncOperationKind: String, Sendable, Equatable, Hashable {
    case savePreparation
    case saveCommit
    case commitReconciliation
    case externalRead
    case merge
    case recovery
    case monitor
    case close
}

struct SyncEffectToken: Sendable, Equatable, Hashable {
    let lifetime: UUID
    let attachmentEpoch: UInt64
    let operation: SyncOperationKind
    let attempt: UInt64
}

enum SyncDeadlineKind: String, Sendable, Equatable, Hashable {
    case localSave
    case externalRead
    case close

    var operation: SyncOperationKind {
        switch self {
        case .localSave:
            .savePreparation
        case .externalRead:
            .externalRead
        case .close:
            .close
        }
    }
}

struct SyncDeadline: Sendable, Equatable, Hashable {
    let kind: SyncDeadlineKind
    let token: SyncEffectToken
}

struct SyncDeadlineRequest: Sendable, Equatable {
    let deadline: SyncDeadline
    let delay: Duration
}

/// A commit capability created from one verified, immutable preparation
/// payload. The snapshot, encoded bytes, and intrinsic content fingerprint can
/// no longer be supplied as unrelated values.
struct PendingSaveToken: Sendable, Equatable {
    let generation: UInt64
    let sourceRevision: SourceRevision
    let preparedPayload: DocumentSyncPreparedSavePayload
    let expectedDurableState: DurableFileState?
    let targetURL: URL

    var snapshot: DocumentSnapshot {
        preparedPayload.snapshot
    }

    var encodedData: Data {
        preparedPayload.encodedData
    }

    var contentFingerprint: FileFingerprint {
        preparedPayload.contentFingerprint
    }
}

struct DocumentSyncSavePreparationRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let sourceRevision: SourceRevision
    let snapshot: DocumentSnapshot
    let targetURL: URL
    let identity: DocumentIdentity
    let attachmentEpoch: UInt64
    let expectedBaseline: DocumentSyncDurableBaseline?
    let commitGeneration: UInt64
}

struct DocumentSyncSaveCommitRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let pendingSave: PendingSaveToken
    let targetURL: URL
    let identity: DocumentIdentity
    let attachmentEpoch: UInt64
    let expectedBaseline: DocumentSyncDurableBaseline?
    let commitGeneration: UInt64
}

enum DocumentSyncCommitFailureDisposition: Sendable, Equatable {
    /// The executor proved that no irreversible write was attempted.
    case notStarted
    /// The executor crossed, or may have crossed, the irreversible commit
    /// boundary and cannot prove the final target/journal outcome.
    case outcomeUnknown
}

struct DocumentSyncCommitReconciliationRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let originalCommitToken: SyncEffectToken
    let pendingSave: PendingSaveToken
    let targetURL: URL
    let identity: DocumentIdentity
    let attachmentEpoch: UInt64
    let expectedBaseline: DocumentSyncDurableBaseline?
    let commitGeneration: UInt64
}

enum DocumentSyncCommitReconciliationResult: Sendable, Equatable {
    /// `nil` is valid only for a new-file commit whose target is proven absent.
    case notCommitted(DocumentSyncExternalReadObservation?)
    /// A fresh read of the captured target proves the exact committed payload
    /// is present before the original commit completion may be replayed.
    case committed(
        completion: DocumentSyncSaveCompletion,
        targetObservation: DocumentSyncExternalReadObservation
    )
    case unresolved
}

struct DocumentSyncExternalReadRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let targetURL: URL
    let identity: DocumentIdentity
    let attachmentEpoch: UInt64
    let expectedBaseline: DocumentSyncDurableBaseline?
}

struct DocumentSyncMergeRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let base: DocumentSnapshot?
    let local: DocumentSnapshot
    let external: DocumentSnapshot
    let localSourceRevision: SourceRevision
}

enum DocumentSyncRecoveryLoadScope: Sendable, Equatable {
    case document(DocumentIdentity)
    case unattached
}

struct DocumentSyncRecoveryLoadRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let scope: DocumentSyncRecoveryLoadScope
}

struct DocumentSyncRecoveryReconciliationRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let originalIdentity: DocumentIdentity
    let committedIdentity: DocumentIdentity
    let intent: DocumentSyncRecoveryReconciliationIntent
}

struct DocumentSyncRecoveryPersistRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let identity: DocumentIdentity
    let entryID: UUID
    let payload: DocumentSyncRecoveryPersistencePayload
    let expectedRecords: DocumentSyncRecoveryRecords
    let expectedStoreGeneration: UInt64
    let purpose: DocumentSyncRecoveryMutationPurpose
    let displacedPreimageContinuation: DocumentSyncDisplacedPreimageContinuation?

    var snapshot: DocumentSnapshot? {
        payload.snapshot
    }

    var rawPayload: DocumentSyncRawRecoveryPayload? {
        payload.raw
    }
}

struct DocumentSyncRecoveryMigrationRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let sourceIdentity: DocumentIdentity
    let destinationIdentity: DocumentIdentity
    let records: DocumentSyncRecoveryRecords
    let expectedStoreGeneration: UInt64
}

enum DocumentSyncRecoveryDiscardTarget: Sendable, Equatable {
    case decoded(RecoveryEntry)
    case raw([DocumentSyncRawRecoveryReference])
    /// An immutable, nonempty subset of decoded and/or raw entries to remove.
    case selected(DocumentSyncRecoveryRecords)
    /// The complete recovery record set to remove.
    case records(DocumentSyncRecoveryRecords)
}

enum DocumentSyncRecoveryReconciliationIntent: Sendable, Equatable {
    case persist(
        identity: DocumentIdentity,
        entryID: UUID,
        payload: DocumentSyncRecoveryPersistencePayload,
        expectedRecords: DocumentSyncRecoveryRecords,
        expectedStoreGeneration: UInt64,
        purpose: DocumentSyncRecoveryMutationPurpose,
        displacedPreimageContinuation: DocumentSyncDisplacedPreimageContinuation?
    )
    case migrate(
        sourceIdentity: DocumentIdentity,
        destinationIdentity: DocumentIdentity,
        records: DocumentSyncRecoveryRecords,
        expectedStoreGeneration: UInt64
    )
    case discard(
        identity: DocumentIdentity,
        target: DocumentSyncRecoveryDiscardTarget,
        expectedRecords: DocumentSyncRecoveryRecords,
        expectedStoreGeneration: UInt64,
        purpose: DocumentSyncRecoveryMutationPurpose
    )

    var originalIdentity: DocumentIdentity {
        switch self {
        case .persist(let identity, _, _, _, _, _, _),
             .discard(let identity, _, _, _, _):
            identity
        case .migrate(let sourceIdentity, _, _, _):
            sourceIdentity
        }
    }

    var committedIdentity: DocumentIdentity {
        switch self {
        case .persist(let identity, _, _, _, _, _, _),
             .discard(let identity, _, _, _, _):
            identity
        case .migrate(_, let destinationIdentity, _, _):
            destinationIdentity
        }
    }

    var expectedStoreGeneration: UInt64 {
        switch self {
        case .persist(_, _, _, _, let expectedStoreGeneration, _, _),
             .migrate(_, _, _, let expectedStoreGeneration),
             .discard(_, _, _, let expectedStoreGeneration, _):
            expectedStoreGeneration
        }
    }
}

struct DocumentSyncRecoveryDiscardRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let identity: DocumentIdentity
    let target: DocumentSyncRecoveryDiscardTarget
    let expectedStoreGeneration: UInt64
}

enum DocumentSyncRecoveryRequest: Sendable, Equatable {
    case load(DocumentSyncRecoveryLoadRequest)
    case reconcile(DocumentSyncRecoveryReconciliationRequest)
    case persist(DocumentSyncRecoveryPersistRequest)
    case migrate(DocumentSyncRecoveryMigrationRequest)
    case discard(DocumentSyncRecoveryDiscardRequest)

    var token: SyncEffectToken {
        switch self {
        case .load(let request):
            request.token
        case .reconcile(let request):
            request.token
        case .persist(let request):
            request.token
        case .migrate(let request):
            request.token
        case .discard(let request):
            request.token
        }
    }
}

enum DocumentSyncMonitorAction: String, Sendable, Equatable {
    case start
    case stop
}

struct DocumentSyncMonitorRequest: Sendable, Equatable {
    let token: SyncEffectToken
    let action: DocumentSyncMonitorAction
    let targetURL: URL
    let identity: DocumentIdentity
    let attachmentEpoch: UInt64
}

enum DocumentSyncCloseDisposition: Sendable, Equatable {
    case allowManagedClose
    case refuseManagedClose
    case deferToNativeUntitledReview
}

struct DocumentSyncCloseResolution: Sendable, Equatable {
    let token: SyncEffectToken
    let disposition: DocumentSyncCloseDisposition
}

enum DocumentSyncEffect: Sendable, Equatable {
    case schedule(SyncDeadlineRequest)
    case cancelDeadline(SyncDeadline)
    case cancelAllDeadlines
    case prepareSave(DocumentSyncSavePreparationRequest)
    case commitSave(DocumentSyncSaveCommitRequest)
    case reconcileCommit(DocumentSyncCommitReconciliationRequest)
    case readExternal(DocumentSyncExternalReadRequest)
    case merge(DocumentSyncMergeRequest)
    case recovery(DocumentSyncRecoveryRequest)
    case monitor(DocumentSyncMonitorRequest)
    case resolveClose(DocumentSyncCloseResolution)
}
