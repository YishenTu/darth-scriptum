import Foundation

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
        let attachmentIdentityMatchesURL =
            attachment.file.map {
                $0.identity.matches(url: $0.url)
            } ?? true
        let normalizedAttachment: DocumentSyncAttachment =
            attachmentIdentityMatchesURL
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
                baseline.documentIdentity == fileAttachment.identity
            else {
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
        self.externalSignalPending =
            externalSignalPending
            || (durableBaseline != nil
                && verifiedBaseline == nil
                && normalizedAttachment.file != nil)
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
        let recoveryRetryAvailable: Bool
        switch recoveryAccess {
        case .failed:
            recoveryIsPaused = true
            recoveryRetryAvailable = true
        case .loading, .ready:
            recoveryIsPaused = false
            recoveryRetryAvailable = false
        }

        let pendingConflictIsUnresolved =
            pendingConflict != nil
            && activeTokens[.recovery] == nil
        let displacedPreimageIsUnresolved =
            pendingDisplacedPreimage != nil
            || unresolvedDisplacedPreimage != nil
        if migrationIsPending
            || uncertainCommit != nil
            || recoveryMutationBarrier != nil
            || records?.hasRawRecovery == true
            || recoveryIsPaused
            || displacedPreimageIsUnresolved
            || (pendingConflictIsUnresolved
                && issue?.failure != .closeDeadline)
        {
            return DocumentSyncStatusProjection(
                presentedState: .synchronizationPaused,
                failureRequiresSaveAs: issue?.requiresSaveAs ?? false,
                recoveryMigrationIsPending: migrationIsPending,
                recoveryRetryAvailable: recoveryRetryAvailable,
                rawRecoveryURL: rawRecoveryURL,
                hasLocalRecovery: records?.hasLocalRecovery ?? false
            )
        }

        if let records, records.hasLocalRecovery {
            return DocumentSyncStatusProjection(
                presentedState: .recoveredConflict,
                failureRequiresSaveAs: false,
                recoveryMigrationIsPending: false,
                recoveryRetryAvailable: false,
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
                recoveryRetryAvailable: recoveryRetryAvailable,
                rawRecoveryURL: rawRecoveryURL,
                hasLocalRecovery: false
            )
        }

        if lastCommitSafety == .coordinatedReplacement {
            return DocumentSyncStatusProjection(
                presentedState: .limitedSyncSafety,
                failureRequiresSaveAs: false,
                recoveryMigrationIsPending: false,
                recoveryRetryAvailable: false,
                rawRecoveryURL: nil,
                hasLocalRecovery: false
            )
        }

        return DocumentSyncStatusProjection(
            presentedState: nil,
            failureRequiresSaveAs: false,
            recoveryMigrationIsPending: false,
            recoveryRetryAvailable: false,
            rawRecoveryURL: nil,
            hasLocalRecovery: false
        )
    }
}
