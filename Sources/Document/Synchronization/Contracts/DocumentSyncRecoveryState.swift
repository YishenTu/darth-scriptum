import Foundation

enum DocumentSyncRecoveryAccess: Sendable, Equatable {
    case loading
    case ready(generation: UInt64)
    case failed(DocumentSyncFailure)
}

enum DocumentSyncRecoveryMutationPurpose: Sendable, Equatable {
    case persistConflict
    case persistDisplacedPreimage
    case discardRaw
    case discardRestoredRecords
    case discardResolvedDisplacedPreimage
}

struct DocumentSyncRecoveryAttempt: Sendable, Equatable {
    let token: SyncEffectToken
    let identity: DocumentIdentity
    let entryID: UUID?
    let expectedStoreGeneration: UInt64
    let purpose: DocumentSyncRecoveryMutationPurpose
    let payload: DocumentSyncRecoveryPersistencePayload?
    let expectedRecords: DocumentSyncRecoveryRecords?
    let discardTarget: DocumentSyncRecoveryDiscardTarget?
    let displacedPreimageContinuation: DocumentSyncDisplacedPreimageContinuation?
    let cleanupMinimumSourceRevision: SourceRevision?
    let cleanupTarget: DocumentSyncRecoveryDiscardTarget?
    let cleanupPurpose: DocumentSyncRecoveryMutationPurpose?

    var snapshot: DocumentSnapshot? {
        payload?.snapshot
    }

    var rawPayload: DocumentSyncRawRecoveryPayload? {
        payload?.raw
    }

    init(
        token: SyncEffectToken,
        identity: DocumentIdentity,
        entryID: UUID? = nil,
        expectedStoreGeneration: UInt64,
        purpose: DocumentSyncRecoveryMutationPurpose,
        payload: DocumentSyncRecoveryPersistencePayload?,
        expectedRecords: DocumentSyncRecoveryRecords? = nil,
        discardTarget: DocumentSyncRecoveryDiscardTarget? = nil,
        displacedPreimageContinuation:
            DocumentSyncDisplacedPreimageContinuation? = nil,
        cleanupMinimumSourceRevision: SourceRevision? = nil,
        cleanupTarget: DocumentSyncRecoveryDiscardTarget? = nil,
        cleanupPurpose: DocumentSyncRecoveryMutationPurpose? = nil
    ) {
        self.token = token
        self.identity = identity
        self.entryID = entryID
        self.expectedStoreGeneration = expectedStoreGeneration
        self.purpose = purpose
        self.payload = payload
        self.expectedRecords = expectedRecords
        self.discardTarget = discardTarget
        self.displacedPreimageContinuation = displacedPreimageContinuation
        self.cleanupMinimumSourceRevision = cleanupMinimumSourceRevision
        self.cleanupTarget = cleanupTarget
        self.cleanupPurpose = cleanupPurpose
    }

    init(
        token: SyncEffectToken,
        identity: DocumentIdentity,
        entryID: UUID? = nil,
        expectedStoreGeneration: UInt64,
        purpose: DocumentSyncRecoveryMutationPurpose,
        snapshot: DocumentSnapshot? = nil,
        expectedRecords: DocumentSyncRecoveryRecords? = nil,
        discardTarget: DocumentSyncRecoveryDiscardTarget? = nil,
        cleanupMinimumSourceRevision: SourceRevision? = nil,
        cleanupTarget: DocumentSyncRecoveryDiscardTarget? = nil,
        cleanupPurpose: DocumentSyncRecoveryMutationPurpose? = nil
    ) {
        self.init(
            token: token,
            identity: identity,
            entryID: entryID,
            expectedStoreGeneration: expectedStoreGeneration,
            purpose: purpose,
            payload: snapshot.map(DocumentSyncRecoveryPersistencePayload.snapshot),
            expectedRecords: expectedRecords,
            discardTarget: discardTarget,
            cleanupMinimumSourceRevision: cleanupMinimumSourceRevision,
            cleanupTarget: cleanupTarget,
            cleanupPurpose: cleanupPurpose
        )
    }
}

struct DocumentSyncRecoveryMigration: Sendable, Equatable {
    var token: SyncEffectToken?
    let sourceIdentity: DocumentIdentity
    let destinationIdentity: DocumentIdentity
    var expectedStoreGeneration: UInt64?
    var records: DocumentSyncRecoveryRecords
}

struct DocumentSyncRecoveryMutationBarrier: Sendable, Equatable {
    let originalIdentity: DocumentIdentity
    let committedIdentity: DocumentIdentity
    var relocationDestination: DocumentIdentity?
}

struct DocumentSyncRecoveryCleanup: Sendable, Equatable {
    let records: DocumentSyncRecoveryRecords
    let target: DocumentSyncRecoveryDiscardTarget
    let discardPurpose: DocumentSyncRecoveryMutationPurpose
    let minimumSourceRevision: SourceRevision

    init(
        records: DocumentSyncRecoveryRecords,
        target: DocumentSyncRecoveryDiscardTarget? = nil,
        discardPurpose: DocumentSyncRecoveryMutationPurpose = .discardRestoredRecords,
        minimumSourceRevision: SourceRevision
    ) {
        self.records = records
        self.target = target ?? .records(records)
        self.discardPurpose = discardPurpose
        self.minimumSourceRevision = minimumSourceRevision
    }
}

struct DocumentSyncPendingConflict: Sendable, Equatable {
    var identity: DocumentIdentity
    let snapshot: DocumentSnapshot
}

enum DocumentSyncRecoveryState: Sendable, Equatable {
    case clear
    case persisting(DocumentSyncRecoveryAttempt)
    case available(DocumentSyncRecoveryRecords)
    case migrationPending(DocumentSyncRecoveryMigration)

    var records: DocumentSyncRecoveryRecords? {
        switch self {
        case .clear, .persisting:
            nil
        case .available(let records):
            records
        case .migrationPending(let migration):
            migration.records
        }
    }
}
