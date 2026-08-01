import Foundation

struct DocumentSyncTransition: Sendable, Equatable {
    let state: DocumentSyncState
    let effects: [DocumentSyncEffect]
}
