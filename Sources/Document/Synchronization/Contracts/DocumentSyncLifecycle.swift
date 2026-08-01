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
