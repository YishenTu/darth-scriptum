import Foundation

struct DocumentSyncReadTicket: Sendable, Equatable {
    let token: SyncEffectToken
    let targetURL: URL
    let identity: DocumentIdentity
    let expectedBaseline: DocumentSyncDurableBaseline?
}

struct DocumentSyncReadAttempt: Sendable, Equatable {
    let token: SyncEffectToken
    let targetURL: URL
    let identity: DocumentIdentity
    let expectedBaseline: DocumentSyncDurableBaseline?
}

enum DocumentSyncExternalState: Sendable, Equatable {
    case idle
    case debouncing(DocumentSyncReadTicket)
    case reading(DocumentSyncReadAttempt)
}

enum DocumentSyncExternalReadResult: Sendable, Equatable {
    case unchanged(DocumentSyncExternalReadObservation)
    case changed(DocumentSyncExternalChange)
    case missing
}
