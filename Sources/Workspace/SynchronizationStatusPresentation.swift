import Foundation

struct SynchronizationStatusPresentation: Equatable {
    enum Tone: Equatable {
        case accent
        case failure
    }

    enum Action: Equatable {
        case restoreLocalRevision
        case saveAs
        case retrySynchronization
        case retryRecoveryMigration
        case showRecoveryFile(URL)

        var label: String {
            switch self {
            case .restoreLocalRevision: "Restore Local Revision"
            case .saveAs: "Save As…"
            case .retrySynchronization: "Retry"
            case .retryRecoveryMigration: "Retry Recovery Migration"
            case .showRecoveryFile: "Show Recovery File"
            }
        }
    }

    let message: String
    let systemImage: String
    let tone: Tone
    let primaryAction: Action?
    let offersSaveAs: Bool
    let offersLocalRevisionRestore: Bool
    let offersRawRecoveryDiscard: Bool

    static func make(
        for state: SynchronizationState,
        failureRequiresSaveAs: Bool = false,
        recoveryMigrationIsPending: Bool = false,
        recoveryRetryAvailable: Bool = false,
        rawRecoveryURL: URL? = nil,
        hasLocalRecovery: Bool = false
    ) -> SynchronizationStatusPresentation? {
        guard let message = message(for: state) else { return nil }
        let systemImage: String
        let tone: Tone
        let primaryAction: Action?
        switch state {
        case .recoveredConflict:
            systemImage = "arrow.triangle.branch"
            tone = .accent
            primaryAction = .restoreLocalRevision
        case .readOnly, .missing:
            systemImage = "exclamationmark.triangle.fill"
            tone = .failure
            primaryAction = .saveAs
        case .failed:
            systemImage = "exclamationmark.triangle.fill"
            tone = .failure
            primaryAction =
                failureRequiresSaveAs
                ? .saveAs
                : .retrySynchronization
        case .limitedSyncSafety:
            systemImage = "arrow.triangle.branch"
            tone = .accent
            primaryAction = nil
        case .synchronizationPaused:
            systemImage = "exclamationmark.triangle.fill"
            tone = .failure
            if recoveryMigrationIsPending {
                primaryAction = .retryRecoveryMigration
            } else if recoveryRetryAvailable {
                primaryAction = .retrySynchronization
            } else if let rawRecoveryURL {
                primaryAction = .showRecoveryFile(rawRecoveryURL)
            } else {
                primaryAction = .saveAs
            }
        case .idle,
            .waitingToWrite,
            .writing,
            .checkingExternalChange,
            .reloading,
            .merging:
            return nil
        }
        return SynchronizationStatusPresentation(
            message: message,
            systemImage: systemImage,
            tone: tone,
            primaryAction: primaryAction,
            offersSaveAs:
                state == .synchronizationPaused && recoveryRetryAvailable,
            offersLocalRevisionRestore:
                state == .synchronizationPaused && hasLocalRecovery,
            offersRawRecoveryDiscard:
                state == .synchronizationPaused && rawRecoveryURL != nil
        )
    }

    static func message(for state: SynchronizationState) -> String? {
        switch state {
        case .idle,
            .waitingToWrite,
            .writing,
            .checkingExternalChange,
            .reloading,
            .merging:
            nil
        case .recoveredConflict: "Disk version shown · local revision recoverable"
        case .readOnly: "Read only"
        case .missing: "File missing"
        case .failed(let message): message
        case .limitedSyncSafety: "Limited sync safety"
        case .synchronizationPaused: "Synchronization paused"
        }
    }
}
