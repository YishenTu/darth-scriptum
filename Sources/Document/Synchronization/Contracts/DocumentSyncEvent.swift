import Foundation

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
