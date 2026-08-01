import Foundation

struct DocumentSynchronizationStatusSnapshot: Equatable {
    let presentedState: SynchronizationState?
    let failureRequiresSaveAs: Bool
    let recoveryMigrationIsPending: Bool
    let recoveryRetryAvailable: Bool
    let rawRecoveryURL: URL?
    let hasLocalRecovery: Bool

    static let empty = DocumentSynchronizationStatusSnapshot(
        presentedState: nil,
        failureRequiresSaveAs: false,
        recoveryMigrationIsPending: false,
        recoveryRetryAvailable: false,
        rawRecoveryURL: nil,
        hasLocalRecovery: false
    )
}
