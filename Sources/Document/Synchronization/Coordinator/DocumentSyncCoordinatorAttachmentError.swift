import Foundation

enum DocumentSyncCoordinatorAttachmentError: Error, Sendable, Equatable {
    case invalidSaveAsEvidence
    case verificationUnavailable
    case verificationInterrupted
    case recoveryBlocksVerification
}
