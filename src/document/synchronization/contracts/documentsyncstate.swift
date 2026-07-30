import Foundation

enum DocumentSyncLifecycle: Sendable, Equatable {
    case active
    case closing(DocumentSyncCloseAttempt)
    case closed
}

enum DocumentSyncCloseKind: Sendable, Equatable {
    case managedFile
    case untitledNativeReview
}

struct DocumentSyncCloseAttempt: Sendable, Equatable {
    let token: SyncEffectToken
    var sourceRevision: SourceRevision
    let kind: DocumentSyncCloseKind
    var resolution: DocumentSyncCloseDisposition?
}

struct DocumentSyncFileAttachment: Sendable, Equatable {
    let identity: DocumentIdentity
    let url: URL
    let epoch: UInt64
}

enum DocumentSyncAttachment: Sendable, Equatable {
    case untitled
    case file(DocumentSyncFileAttachment)

    var file: DocumentSyncFileAttachment? {
        guard case .file(let attachment) = self else { return nil }
        return attachment
    }
}

/// A host attachment notification that arrived after a save commit became
/// uncancellable. The reducer applies the latest queued transition once that
/// commit has an authoritative result.
enum DocumentSyncPendingAttachmentTransition: Sendable, Equatable {
    case attach(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )
    case detach
    case detachThenAttach(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )

    func appending(
        _ next: DocumentSyncPendingAttachmentTransition
    ) -> DocumentSyncPendingAttachmentTransition {
        switch (self, next) {
        case (.detach, .attach(let identity, let url, let durableBaseline)),
             (.detachThenAttach(_, _, _), .attach(
                let identity,
                let url,
                let durableBaseline
             )):
            return .detachThenAttach(
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        default:
            return next
        }
    }
}

struct DocumentSyncDirtyState: Sendable, Equatable {
    let revision: SourceRevision
    let scheduledToken: SyncEffectToken?
}

struct DocumentSyncSaveAttempt: Sendable, Equatable {
    let token: SyncEffectToken
    let sourceRevision: SourceRevision
    let snapshot: DocumentSnapshot
    let targetURL: URL
    let identity: DocumentIdentity
    let expectedBaseline: DocumentSyncDurableBaseline?
    let commitGeneration: UInt64
    let pendingSave: PendingSaveToken?
}

enum DocumentSyncLocalState: Sendable, Equatable {
    case clean(SourceRevision)
    case dirty(DocumentSyncDirtyState)
    case preparing(DocumentSyncSaveAttempt)
    case writing(DocumentSyncSaveAttempt, pendingRevision: SourceRevision)

    var isDirty: Bool {
        switch self {
        case .clean:
            false
        case .dirty, .preparing, .writing:
            true
        }
    }

    var isSaveInFlight: Bool {
        switch self {
        case .preparing, .writing:
            true
        case .clean, .dirty:
            false
        }
    }

    /// A commit may already have crossed the point at which cancellation can
    /// prevent durable I/O. Attachment changes must wait for its result.
    var hasUncancellableCommit: Bool {
        if case .writing = self {
            return true
        }
        return false
    }
}

struct DocumentSyncReadTicket: Sendable, Equatable {
    let token: SyncEffectToken
    let targetURL: URL
    let identity: DocumentIdentity
    let expectedBaseline: DocumentSyncDurableBaseline?
}

struct DocumentSyncReadAttempt: Sendable, Equatable {
    let token: SyncEffectToken
    let targetURL: URL
    let identity: DocumentIdentity
    let expectedBaseline: DocumentSyncDurableBaseline?
}

enum DocumentSyncExternalState: Sendable, Equatable {
    case idle
    case debouncing(DocumentSyncReadTicket)
    case reading(DocumentSyncReadAttempt)
}

struct DocumentSyncMergeAttempt: Sendable, Equatable {
    let token: SyncEffectToken
    let baseline: DocumentSyncDurableBaseline?
    let base: DocumentSnapshot?
    let local: DocumentSnapshot
    let localSourceRevision: SourceRevision
    let external: DocumentSyncExternalChange
    let origin: DocumentSyncMergeOrigin
}

enum DocumentSyncMergeOrigin: Sendable, Equatable {
    case externalRead
    case displacedPreimage(
        recoveryRecords: DocumentSyncRecoveryRecords,
        cleanupTarget: DocumentSyncRecoveryDiscardTarget,
        continuation: DocumentSyncDisplacedPreimageContinuation
    )
}

enum DocumentSyncFailure: String, Sendable, Equatable {
    case localSave
    case externalRead
    case merge
    case recovery
    case monitor
    case attachment
    case closeDeadline
    case destinationRequiresSaveAs

    var message: String {
        switch self {
        case .localSave:
            "The document could not be saved."
        case .externalRead:
            "The external document change could not be read."
        case .merge:
            "The local and external changes could not be merged."
        case .recovery:
            "Recovery storage is unavailable."
        case .monitor:
            "File monitoring is unavailable."
        case .attachment:
            "The document attachment is unavailable."
        case .closeDeadline:
            "The document could not be saved before closing."
        case .destinationRequiresSaveAs:
            "The destination requires Save As."
        }
    }
}

enum DocumentSyncRecoveryAccess: Sendable, Equatable {
    case loading
    case ready(generation: UInt64)
    case failed(DocumentSyncFailure)
}

struct DocumentSyncRawRecoveryReference: Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let dataURL: URL?
    let byteCount: Int
    let contentDigest: String
    let createdAt: Date

    init(
        id: UUID,
        documentIdentity: DocumentIdentity,
        dataURL: URL?,
        byteCount: Int,
        contentDigest: String,
        createdAt: Date
    ) {
        self.id = id
        self.documentIdentity = documentIdentity
        self.dataURL = dataURL
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.createdAt = createdAt
    }

    init(entry: RawRecoveryEntry) {
        self.init(
            id: entry.id,
            documentIdentity: entry.documentIdentity,
            dataURL: entry.dataURL,
            byteCount: entry.byteCount,
            contentDigest: entry.contentDigest,
            createdAt: entry.createdAt
        )
    }
}

struct DocumentSyncRecoveryRecords: Sendable, Equatable {
    let decoded: [RecoveryEntry]
    let raw: [DocumentSyncRawRecoveryReference]

    init(
        decoded: [RecoveryEntry],
        raw: [DocumentSyncRawRecoveryReference]
    ) {
        self.decoded = decoded
        self.raw = raw
    }

    init(
        decoded: RecoveryEntry?,
        raw: DocumentSyncRawRecoveryReference?
    ) {
        self.init(
            decoded: decoded.map { [$0] } ?? [],
            raw: raw.map { [$0] } ?? []
        )
    }

    static let empty = DocumentSyncRecoveryRecords(decoded: [], raw: [])

    var isEmpty: Bool {
        decoded.isEmpty && raw.isEmpty
    }

    var rawRecoveryURL: URL? {
        raw.first?.dataURL
    }

    var hasLocalRecovery: Bool {
        !decoded.isEmpty
    }

    var latestDecoded: RecoveryEntry? {
        decoded.first
    }
}

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

struct DocumentSyncSaveCompletion: Sendable, Equatable {
    let result: FileCommitResult

    init(result: FileCommitResult) {
        self.result = result
    }
}

/// An irreversible commit may have completed even when its executor cannot
/// provide a valid completion receipt. Keep the original attachment and
/// prepared payload pinned until a dedicated reconciliation proves one outcome.
struct DocumentSyncUncertainCommit: Sendable, Equatable {
    let attempt: DocumentSyncSaveAttempt
    let pendingRevision: SourceRevision
    let originalAttachment: DocumentSyncFileAttachment
    var reconciliationToken: SyncEffectToken?
}

struct DocumentSyncIssue: Sendable, Equatable {
    let failure: DocumentSyncFailure
    let retryable: Bool
    let requiresSaveAs: Bool
    let rawRecoveryURL: URL?
}

struct DocumentSyncStatusProjection: Sendable, Equatable {
    let presentedState: SynchronizationState?
    let failureRequiresSaveAs: Bool
    let recoveryMigrationIsPending: Bool
    let rawRecoveryURL: URL?
    let hasLocalRecovery: Bool

    static let empty = DocumentSyncStatusProjection(
        presentedState: nil,
        failureRequiresSaveAs: false,
        recoveryMigrationIsPending: false,
        rawRecoveryURL: nil,
        hasLocalRecovery: false
    )
}

enum DocumentSyncExternalReadResult: Sendable, Equatable {
    case unchanged(DocumentSyncExternalReadObservation)
    case changed(DocumentSyncExternalChange)
    case missing
}

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

enum DocumentSyncEvent: Sendable, Equatable {
    case started
    case saveRequested
    case attach(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )
    case fileMoved(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )
    case saveAsAttached(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )
    case detach
    case sourceChanged(SourceRevision, format: TextFileFormat)
    case deadlineFired(SyncDeadline)
    case savePrepared(token: SyncEffectToken, pendingSave: PendingSaveToken)
    case saveFinished(token: SyncEffectToken, completion: DocumentSyncSaveCompletion)
    case commitFailed(
        token: SyncEffectToken,
        disposition: DocumentSyncCommitFailureDisposition
    )
    case commitReconciliationFinished(
        token: SyncEffectToken,
        result: DocumentSyncCommitReconciliationResult
    )
    case monitorSignaled(SyncEffectToken)
    case externalReadFinished(
        token: SyncEffectToken,
        result: DocumentSyncExternalReadResult
    )
    case mergeFinished(token: SyncEffectToken, result: DocumentSyncMergeResult)
    case recoveryFinished(
        token: SyncEffectToken,
        result: DocumentSyncRecoveryResult
    )
    case operationFailed(token: SyncEffectToken, failure: DocumentSyncFailure)
    case retry
    case restoreLocalRecovery
    case discardRawRecovery
    case requestClose
    case closeCommitted(SyncEffectToken)
    case closeCancelled(SyncEffectToken)
    case closed(SyncEffectToken)
}

struct DocumentSyncTransition: Sendable, Equatable {
    let state: DocumentSyncState
    let effects: [DocumentSyncEffect]
}

struct DocumentSyncState: Sendable, Equatable {
    let lifetime: UUID
    var lifecycle: DocumentSyncLifecycle
    var attachment: DocumentSyncAttachment
    var attachmentEpoch: UInt64
    var source: SourceRevision
    var format: TextFileFormat
    var durableBaseline: DocumentSyncDurableBaseline?
    var lastCommitSafety: FileCommitSafety?
    var local: DocumentSyncLocalState
    var external: DocumentSyncExternalState
    var mergeAttempt: DocumentSyncMergeAttempt?
    var recoveryAccess: DocumentSyncRecoveryAccess
    var recovery: DocumentSyncRecoveryState
    var recoveryMutationBarrier: DocumentSyncRecoveryMutationBarrier?
    var recoveryCleanup: DocumentSyncRecoveryCleanup?
    var uncertainCommit: DocumentSyncUncertainCommit?
    var pendingAttachmentTransition: DocumentSyncPendingAttachmentTransition?
    var pendingConflict: DocumentSyncPendingConflict?
    var pendingDisplacedPreimage: DocumentSyncDisplacedPreimageContinuation?
    var unresolvedDisplacedPreimage: DocumentSyncDisplacedPreimageContinuation?
    var issue: DocumentSyncIssue?
    var nextAttempt: UInt64
    var nextCommitGeneration: UInt64
    var activeTokens: [SyncOperationKind: SyncEffectToken]
    var externalSignalPending: Bool

    init(
        lifetime: UUID = UUID(),
        source: SourceRevision,
        format: TextFileFormat,
        attachment: DocumentSyncAttachment = .untitled,
        attachmentEpoch: UInt64 = 0,
        durableBaseline: DocumentSyncDurableBaseline? = nil,
        lastCommitSafety: FileCommitSafety? = nil,
        recoveryAccess: DocumentSyncRecoveryAccess = .loading,
        lifecycle: DocumentSyncLifecycle = .active,
        recovery: DocumentSyncRecoveryState = .clear,
        recoveryMutationBarrier: DocumentSyncRecoveryMutationBarrier? = nil,
        recoveryCleanup: DocumentSyncRecoveryCleanup? = nil,
        uncertainCommit: DocumentSyncUncertainCommit? = nil,
        pendingAttachmentTransition:
            DocumentSyncPendingAttachmentTransition? = nil,
        pendingConflict: DocumentSyncPendingConflict? = nil,
        pendingDisplacedPreimage:
            DocumentSyncDisplacedPreimageContinuation? = nil,
        unresolvedDisplacedPreimage:
            DocumentSyncDisplacedPreimageContinuation? = nil,
        issue: DocumentSyncIssue? = nil,
        nextAttempt: UInt64 = 1,
        nextCommitGeneration: UInt64 = 1,
        activeTokens: [SyncOperationKind: SyncEffectToken] = [:],
        externalSignalPending: Bool = false
    ) {
        self.lifetime = lifetime
        self.lifecycle = lifecycle
        let attachmentIdentityMatchesURL = attachment.file.map {
            $0.identity.matches(url: $0.url)
        } ?? true
        let normalizedAttachment: DocumentSyncAttachment = attachmentIdentityMatchesURL
            ? attachment
            : .untitled
        self.attachment = normalizedAttachment
        self.attachmentEpoch = attachmentEpoch
        self.source = source
        self.format = format
        let verifiedBaseline: DocumentSyncDurableBaseline? = durableBaseline.flatMap {
            baseline -> DocumentSyncDurableBaseline? in
            guard let fileAttachment = normalizedAttachment.file,
                  fileAttachment.identity.matches(url: fileAttachment.url),
                  baseline.documentIdentity == fileAttachment.identity else {
                return nil
            }
            return baseline
        }
        self.durableBaseline = verifiedBaseline
        self.lastCommitSafety = verifiedBaseline == nil ? nil : lastCommitSafety
        if verifiedBaseline?.sourceRevision == source {
            local = .clean(source)
        } else {
            local = .dirty(
                DocumentSyncDirtyState(
                    revision: source,
                    scheduledToken: nil
                )
            )
        }
        external = .idle
        mergeAttempt = nil
        self.recoveryAccess = recoveryAccess
        self.recovery = recovery
        self.recoveryMutationBarrier = recoveryMutationBarrier
        self.recoveryCleanup = recoveryCleanup
        self.uncertainCommit = uncertainCommit
        self.pendingAttachmentTransition = pendingAttachmentTransition
        self.pendingConflict = pendingConflict
        self.pendingDisplacedPreimage = pendingDisplacedPreimage
        self.unresolvedDisplacedPreimage = unresolvedDisplacedPreimage
        self.issue = issue
        self.nextAttempt = nextAttempt
        self.nextCommitGeneration = nextCommitGeneration
        self.activeTokens = activeTokens
        self.externalSignalPending = externalSignalPending
            || (
                durableBaseline != nil
                    && verifiedBaseline == nil
                    && normalizedAttachment.file != nil
            )
    }

    var snapshot: DocumentSnapshot {
        DocumentSnapshot(text: source.text, format: format)
    }

    var fileAttachment: DocumentSyncFileAttachment? {
        attachment.file
    }

    var recoveryRecords: DocumentSyncRecoveryRecords? {
        recovery.records ?? recoveryCleanup?.records
    }

    var statusProjection: DocumentSyncStatusProjection {
        guard lifecycle != .closed else {
            return .empty
        }

        let records = recoveryRecords
        let rawRecoveryURL = records?.rawRecoveryURL ?? issue?.rawRecoveryURL
        let migrationIsPending: Bool
        if case .migrationPending = recovery {
            migrationIsPending = true
        } else {
            migrationIsPending = false
        }
        let recoveryIsPaused: Bool
        switch recoveryAccess {
        case .failed:
            recoveryIsPaused = true
        case .loading, .ready:
            recoveryIsPaused = false
        }

        let pendingConflictIsUnresolved = pendingConflict != nil
            && activeTokens[.recovery] == nil
        let displacedPreimageIsUnresolved = pendingDisplacedPreimage != nil
            || unresolvedDisplacedPreimage != nil
        if migrationIsPending
            || uncertainCommit != nil
            || recoveryMutationBarrier != nil
            || rawRecoveryURL != nil
            || recoveryIsPaused
            || displacedPreimageIsUnresolved
            || (pendingConflictIsUnresolved
                && issue?.failure != .closeDeadline) {
            return DocumentSyncStatusProjection(
                presentedState: .synchronizationPaused,
                failureRequiresSaveAs: issue?.requiresSaveAs ?? false,
                recoveryMigrationIsPending: migrationIsPending,
                rawRecoveryURL: rawRecoveryURL,
                hasLocalRecovery: records?.hasLocalRecovery ?? false
            )
        }

        if let records, records.hasLocalRecovery {
            return DocumentSyncStatusProjection(
                presentedState: .recoveredConflict,
                failureRequiresSaveAs: false,
                recoveryMigrationIsPending: false,
                rawRecoveryURL: nil,
                hasLocalRecovery: true
            )
        }

        if let issue {
            let presentedState: SynchronizationState
            switch issue.failure {
            case .attachment:
                presentedState = .missing
            case .monitor:
                presentedState = .failed(issue.failure.message)
            case .recovery:
                presentedState = .synchronizationPaused
            case .localSave,
                 .externalRead,
                 .merge,
                 .closeDeadline,
                 .destinationRequiresSaveAs:
                presentedState = .failed(issue.failure.message)
            }
            return DocumentSyncStatusProjection(
                presentedState: presentedState,
                failureRequiresSaveAs: issue.requiresSaveAs,
                recoveryMigrationIsPending: false,
                rawRecoveryURL: rawRecoveryURL,
                hasLocalRecovery: false
            )
        }

        if lastCommitSafety == .coordinatedReplacement {
            return DocumentSyncStatusProjection(
                presentedState: .limitedSyncSafety,
                failureRequiresSaveAs: false,
                recoveryMigrationIsPending: false,
                rawRecoveryURL: nil,
                hasLocalRecovery: false
            )
        }

        return DocumentSyncStatusProjection(
            presentedState: nil,
            failureRequiresSaveAs: false,
            recoveryMigrationIsPending: false,
            rawRecoveryURL: nil,
            hasLocalRecovery: false
        )
    }
}
