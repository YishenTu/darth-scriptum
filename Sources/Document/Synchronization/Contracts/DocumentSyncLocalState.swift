import Foundation

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
