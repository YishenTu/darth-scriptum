import Foundation

/// A durable, identity-scoped mutation receipt. The disk operation finishes
/// before this receipt is returned or the actor index changes.
struct SessionRecoveryStoreMutationReceipt: Sendable, Equatable {
    let previousGeneration: UInt64
    let generation: UInt64
    let decodedEntries: [RecoveryEntry]
    let rawEntries: [RawRecoveryEntry]
}

struct SessionRecoveryStoreRawMutationReceipt: Sendable, Equatable {
    let mutation: SessionRecoveryStoreMutationReceipt
    let entry: RawRecoveryEntry
    let acknowledgedRecoveryArtifact: CommitRecoveryArtifact?
}
