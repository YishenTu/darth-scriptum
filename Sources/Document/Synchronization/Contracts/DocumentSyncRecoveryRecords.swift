import Foundation

struct DocumentSyncRawRecoveryReference: Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let dataURL: URL?
    let byteCount: Int
    let contentDigest: String
    let createdAt: Date

    init(
        id: UUID,
        documentIdentity: DocumentIdentity,
        dataURL: URL?,
        byteCount: Int,
        contentDigest: String,
        createdAt: Date
    ) {
        self.id = id
        self.documentIdentity = documentIdentity
        self.dataURL = dataURL
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.createdAt = createdAt
    }

    init(entry: RawRecoveryEntry) {
        self.init(
            id: entry.id,
            documentIdentity: entry.documentIdentity,
            dataURL: entry.dataURL,
            byteCount: entry.byteCount,
            contentDigest: entry.contentDigest,
            createdAt: entry.createdAt
        )
    }
}

struct DocumentSyncRecoveryRecords: Sendable, Equatable {
    let decoded: [RecoveryEntry]
    let raw: [DocumentSyncRawRecoveryReference]

    init(
        decoded: [RecoveryEntry],
        raw: [DocumentSyncRawRecoveryReference]
    ) {
        self.decoded = decoded
        self.raw = raw
    }

    init(
        decoded: RecoveryEntry?,
        raw: DocumentSyncRawRecoveryReference?
    ) {
        self.init(
            decoded: decoded.map { [$0] } ?? [],
            raw: raw.map { [$0] } ?? []
        )
    }

    static let empty = DocumentSyncRecoveryRecords(decoded: [], raw: [])

    var isEmpty: Bool {
        decoded.isEmpty && raw.isEmpty
    }

    var rawRecoveryURL: URL? {
        raw.first?.dataURL
    }

    var hasRawRecovery: Bool {
        !raw.isEmpty
    }

    var hasLocalRecovery: Bool {
        !decoded.isEmpty
    }

    var latestDecoded: RecoveryEntry? {
        decoded.first
    }
}
