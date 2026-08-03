import Foundation

struct RawRecoveryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let dataURL: URL?
    let byteCount: Int
    let contentDigest: String
    let createdAt: Date
    let residentData: Data?
    let acknowledgedRecoveryArtifactID: UUID?

    init(
        id: UUID,
        documentIdentity: DocumentIdentity,
        dataURL: URL?,
        byteCount: Int,
        contentDigest: String,
        createdAt: Date,
        residentData: Data?,
        acknowledgedRecoveryArtifactID: UUID? = nil
    ) {
        self.id = id
        self.documentIdentity = documentIdentity
        self.dataURL = dataURL
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.createdAt = createdAt
        self.residentData = residentData
        self.acknowledgedRecoveryArtifactID = acknowledgedRecoveryArtifactID
    }

    /// Loading raw data is intentionally asynchronous. A URL-backed recovery
    /// entry must never cause a view or the main actor to synchronously read a
    /// potentially large file.
    func loadData() async throws -> Data {
        let data: Data
        if let residentData {
            data = residentData
        } else {
            guard let dataURL else {
                throw RecoveryStoreIssue.missingRecoveryEntry
            }
            data = try await DocumentFileAccess.recovery.perform {
                try TextFileCodec.readSupportedData(
                    at: dataURL,
                    followingSymbolicLinks: false
                )
            }
        }
        guard data.count == byteCount,
            FileFingerprint.make(data: data).contentDigest == contentDigest
        else {
            throw RecoveryStoreIssue.malformedData
        }
        return data
    }

    var isDataResident: Bool {
        residentData != nil
    }

    static func == (lhs: RawRecoveryEntry, rhs: RawRecoveryEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.documentIdentity == rhs.documentIdentity
            && lhs.dataURL == rhs.dataURL
            && lhs.byteCount == rhs.byteCount
            && lhs.contentDigest == rhs.contentDigest
            && lhs.createdAt == rhs.createdAt
            && lhs.acknowledgedRecoveryArtifactID
                == rhs.acknowledgedRecoveryArtifactID
    }
}
