import Foundation

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
