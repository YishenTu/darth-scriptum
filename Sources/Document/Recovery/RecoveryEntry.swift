import Foundation

struct RecoveryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let preparedContent: PreparedSourceContent
    let createdAt: Date

    var snapshot: DocumentSnapshot {
        preparedContent.snapshot
    }

    init(
        id: UUID,
        documentIdentity: DocumentIdentity,
        snapshot: DocumentSnapshot,
        createdAt: Date
    ) {
        self.init(
            id: id,
            documentIdentity: documentIdentity,
            preparedContent: PreparedSourceContent(snapshot: snapshot),
            createdAt: createdAt
        )
    }

    init(
        id: UUID,
        documentIdentity: DocumentIdentity,
        preparedContent: PreparedSourceContent,
        createdAt: Date
    ) {
        self.id = id
        self.documentIdentity = documentIdentity
        self.preparedContent = preparedContent
        self.createdAt = createdAt
    }
}
