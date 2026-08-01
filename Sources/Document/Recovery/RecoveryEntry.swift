import Foundation

struct RecoveryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let snapshot: DocumentSnapshot
    let createdAt: Date
}
