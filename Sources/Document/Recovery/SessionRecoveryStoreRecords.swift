import Foundation

struct SessionRecoveryStoreRecords: Sendable, Equatable {
    let decoded: [RecoveryEntry]
    let raw: [RawRecoveryEntry]

    static let empty = SessionRecoveryStoreRecords(decoded: [], raw: [])

    var isEmpty: Bool {
        decoded.isEmpty && raw.isEmpty
    }
}

struct SessionRecoveryStoreSnapshot: Sendable, Equatable {
    let decodedEntries: [RecoveryEntry]
    let rawEntries: [RawRecoveryEntry]
    private let generations: [String: UInt64]

    init(
        decodedEntries: [RecoveryEntry],
        rawEntries: [RawRecoveryEntry],
        generations: [String: UInt64]
    ) {
        self.decodedEntries = decodedEntries
        self.rawEntries = rawEntries
        self.generations = generations
    }

    var records: SessionRecoveryStoreRecords {
        SessionRecoveryStoreRecords(
            decoded: decodedEntries,
            raw: rawEntries
        )
    }

    func records(for identity: DocumentIdentity) -> SessionRecoveryStoreRecords {
        SessionRecoveryStoreRecords(
            decoded: decodedEntries.filter { $0.documentIdentity == identity },
            raw: rawEntries.filter { $0.documentIdentity == identity }
        )
    }

    func generation(for identity: DocumentIdentity) -> UInt64 {
        generations[identity.stableKey, default: 0]
    }
}

struct SessionRecoveryStoreLoadReceipt: Sendable, Equatable {
    let scope: DocumentSyncRecoveryLoadScope
    let generation: UInt64
    let records: SessionRecoveryStoreRecords
}
