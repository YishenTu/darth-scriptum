import Foundation

struct SessionRecoveryStoreReconciliationReceipt: Sendable, Equatable {
    let identity: DocumentIdentity
    let generation: UInt64
    let records: SessionRecoveryStoreRecords
    let acknowledgedRecoveryArtifact: CommitRecoveryArtifact?
}
