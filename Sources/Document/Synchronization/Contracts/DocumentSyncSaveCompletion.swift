import Foundation

struct DocumentSyncSaveCompletion: Sendable, Equatable {
    let result: FileCommitResult
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
