import Foundation

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
    let recoveryRetryAvailable: Bool
    let rawRecoveryURL: URL?
    let hasLocalRecovery: Bool

    static let empty = DocumentSyncStatusProjection(
        presentedState: nil,
        failureRequiresSaveAs: false,
        recoveryMigrationIsPending: false,
        recoveryRetryAvailable: false,
        rawRecoveryURL: nil,
        hasLocalRecovery: false
    )
}
