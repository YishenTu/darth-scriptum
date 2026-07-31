import Darwin
import Foundation

struct PendingCommitRecovery: Sendable, Equatable {
    let artifact: CommitRecoveryArtifact
    let documentIdentity: DocumentIdentity
    let expectedContentDigest: String
    let swapCompleted: Bool
}

enum CommitRecoveryJournalStore {
    enum JournalError: Error, Equatable {
        case invalidArtifactPath
        case unownedReplacementDirectory
        case malformedJournal
        case unsupportedSchema
    }

    static let defaultRecoveryDirectory: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(
            "DarthScriptum/recovery",
            isDirectory: true
        )
    }()

    static func prepare(
        candidateURL: URL,
        replacementDirectoryURL: URL,
        targetURL: URL,
        documentIdentity: DocumentIdentity,
        expectedPreimageFingerprint: FileFingerprint,
        committedPayloadFingerprint: FileFingerprint,
        recoveryDirectory: URL
    ) throws -> CommitRecoveryArtifact {
        let id = UUID()
        let journalDirectory = recoveryDirectory.appendingPathComponent(
            "commit-journals",
            isDirectory: true
        )
        try DurableFileIO.createDirectory(at: journalDirectory)
        try DurableFileIO.synchronizeDirectoryEntry(
            for: replacementDirectoryURL
        )
        let candidateFingerprint = try SafeFileCommitter.fingerprint(
            for: candidateURL
        )
        guard let candidateResourceIdentifier =
                candidateFingerprint.resourceIdentifier else {
            throw CocoaError(.fileWriteUnknown)
        }
        let replacementDirectoryResourceIdentifier =
            try DurableFileIO.resourceIdentifier(
                for: replacementDirectoryURL
            )
        let journal = PersistedCommitRecoveryJournal(
            id: id,
            documentStableKey: documentIdentity.stableKey,
            expectedContentDigest: expectedPreimageFingerprint.contentDigest,
            expectedPreimageByteCount: expectedPreimageFingerprint.byteCount,
            expectedPreimageResourceIdentifier:
                expectedPreimageFingerprint.resourceIdentifier,
            committedPayloadByteCount: committedPayloadFingerprint.byteCount,
            committedPayloadContentDigest:
                committedPayloadFingerprint.contentDigest,
            preparedCandidateResourceIdentifier: candidateResourceIdentifier,
            replacementDirectoryResourceIdentifier:
                replacementDirectoryResourceIdentifier,
            targetPath: targetURL.path,
            candidatePath: candidateURL.path,
            replacementDirectoryPath: replacementDirectoryURL.path
        )
        let journalURL = journalDirectory.appendingPathComponent(
            "\(id.uuidString.lowercased()).commit.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFileIO.writeAtomically(
            try encoder.encode(journal),
            to: journalURL
        )
        return CommitRecoveryArtifact(
            id: id,
            journalURL: journalURL,
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectoryURL,
            replacementDirectoryResourceIdentifier:
                replacementDirectoryResourceIdentifier,
            binding: CommitRecoveryArtifactBinding(
                documentIdentity: documentIdentity,
                targetURL: targetURL,
                expectedPreimageFingerprint: expectedPreimageFingerprint,
                committedPayloadFingerprint: committedPayloadFingerprint
            )
        )
    }

    /// Reads pending durable commit evidence without modifying it. A malformed
    /// or newer journal is recovery evidence, not disposable cache data; the
    /// async recovery actor reports it and leaves its bytes untouched for
    /// Retry or a newer application version.
    static func pendingRecoveries(
        in recoveryDirectory: URL
    ) throws -> [PendingCommitRecovery] {
        let journalDirectory = recoveryDirectory.appendingPathComponent(
            "commit-journals",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: journalDirectory.path) else {
            return []
        }
        let journalURLs = try FileManager.default.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil
        )
        var pending: [PendingCommitRecovery] = []
        for journalURL in journalURLs {
            guard journalURL.lastPathComponent.hasSuffix(".commit.json") else {
                continue
            }
            let encoded = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
            let journal: PersistedCommitRecoveryJournal
            do {
                journal = try JSONDecoder().decode(
                    PersistedCommitRecoveryJournal.self,
                    from: encoded
                )
            } catch {
                throw JournalError.malformedJournal
            }
            if let schemaVersion = journal.schemaVersion,
               schemaVersion > PersistedCommitRecoveryJournal.currentSchemaVersion {
                throw JournalError.unsupportedSchema
            }
            let candidateURL = URL(fileURLWithPath: journal.candidatePath)
            let targetURL = URL(fileURLWithPath: journal.targetPath)
            let replacementDirectoryURL = URL(
                fileURLWithPath: journal.replacementDirectoryPath,
                isDirectory: true
            )
            guard DocumentIdentity.make(url: targetURL).stableKey
                    == journal.documentStableKey,
                  candidateURL.deletingLastPathComponent().standardizedFileURL
                    == replacementDirectoryURL.standardizedFileURL,
                  let directoryIdentifier = try? DurableFileIO.resourceIdentifier(
                    for: replacementDirectoryURL
                  ),
                  directoryIdentifier == journal.replacementDirectoryResourceIdentifier else {
                throw JournalError.invalidArtifactPath
            }
            let candidateIdentifier =
                try? DurableFileIO.resourceIdentifier(for: candidateURL)
            let targetIdentifier =
                try? DurableFileIO.resourceIdentifier(for: targetURL)
            let swapCompleted =
                targetIdentifier
                    == journal.preparedCandidateResourceIdentifier
                || (
                    candidateIdentifier != nil
                        && candidateIdentifier
                    != journal.preparedCandidateResourceIdentifier
                )
            let binding: CommitRecoveryArtifactBinding?
            if let expectedPreimageByteCount = journal.expectedPreimageByteCount,
               let committedPayloadByteCount = journal.committedPayloadByteCount,
               let committedPayloadContentDigest =
                journal.committedPayloadContentDigest {
                binding = CommitRecoveryArtifactBinding(
                    documentIdentity: DocumentIdentity(
                        stableKey: journal.documentStableKey
                    ),
                    targetURL: targetURL,
                    expectedPreimageFingerprint: FileFingerprint(
                        byteCount: expectedPreimageByteCount,
                        contentDigest: journal.expectedContentDigest,
                        resourceIdentifier:
                            journal.expectedPreimageResourceIdentifier
                    ),
                    committedPayloadFingerprint: FileFingerprint(
                        byteCount: committedPayloadByteCount,
                        contentDigest: committedPayloadContentDigest,
                        resourceIdentifier: nil
                    )
                )
            } else {
                binding = nil
            }
            pending.append(PendingCommitRecovery(
                artifact: CommitRecoveryArtifact(
                    id: journal.id,
                    journalURL: journalURL,
                    candidateURL: candidateURL,
                    replacementDirectoryURL: replacementDirectoryURL,
                    replacementDirectoryResourceIdentifier:
                        journal.replacementDirectoryResourceIdentifier,
                    binding: binding
                ),
                documentIdentity: DocumentIdentity(
                    stableKey: journal.documentStableKey
                ),
                expectedContentDigest: journal.expectedContentDigest,
                swapCompleted: swapCompleted
            ))
        }
        return pending
    }

    static func acknowledge(_ artifact: CommitRecoveryArtifact) throws {
        let replacementDirectory =
            artifact.replacementDirectoryURL.standardizedFileURL
        guard artifact.candidateURL.deletingLastPathComponent()
                .standardizedFileURL == replacementDirectory else {
            throw JournalError.invalidArtifactPath
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: replacementDirectory.path) {
            guard try DurableFileIO.resourceIdentifier(
                for: replacementDirectory
            ) == artifact.replacementDirectoryResourceIdentifier else {
                throw JournalError.unownedReplacementDirectory
            }
            if fileManager.fileExists(atPath: artifact.candidateURL.path) {
                let unlinkResult = artifact.candidateURL.path.withCString {
                    Darwin.unlink($0)
                }
                guard unlinkResult == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
            }
            let removeDirectoryResult = replacementDirectory.path.withCString {
                Darwin.rmdir($0)
            }
            if removeDirectoryResult != 0 && errno != ENOTEMPTY {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            try DurableFileIO.synchronizeDirectory(
                replacementDirectory.deletingLastPathComponent()
            )
        }
        if fileManager.fileExists(atPath: artifact.journalURL.path) {
            let unlinkResult = artifact.journalURL.path.withCString {
                Darwin.unlink($0)
            }
            guard unlinkResult == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            try DurableFileIO.synchronizeDirectory(
                artifact.journalURL.deletingLastPathComponent()
            )
        }
    }

}

private struct PersistedCommitRecoveryJournal: Codable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int?
    let id: UUID
    let documentStableKey: String
    let expectedContentDigest: String
    let expectedPreimageByteCount: Int?
    let expectedPreimageResourceIdentifier: String?
    let committedPayloadByteCount: Int?
    let committedPayloadContentDigest: String?
    let preparedCandidateResourceIdentifier: String
    let replacementDirectoryResourceIdentifier: String
    let targetPath: String
    let candidatePath: String
    let replacementDirectoryPath: String

    init(
        id: UUID,
        documentStableKey: String,
        expectedContentDigest: String,
        expectedPreimageByteCount: Int?,
        expectedPreimageResourceIdentifier: String?,
        committedPayloadByteCount: Int?,
        committedPayloadContentDigest: String?,
        preparedCandidateResourceIdentifier: String,
        replacementDirectoryResourceIdentifier: String,
        targetPath: String,
        candidatePath: String,
        replacementDirectoryPath: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.documentStableKey = documentStableKey
        self.expectedContentDigest = expectedContentDigest
        self.expectedPreimageByteCount = expectedPreimageByteCount
        self.expectedPreimageResourceIdentifier = expectedPreimageResourceIdentifier
        self.committedPayloadByteCount = committedPayloadByteCount
        self.committedPayloadContentDigest = committedPayloadContentDigest
        self.preparedCandidateResourceIdentifier = preparedCandidateResourceIdentifier
        self.replacementDirectoryResourceIdentifier = replacementDirectoryResourceIdentifier
        self.targetPath = targetPath
        self.candidatePath = candidatePath
        self.replacementDirectoryPath = replacementDirectoryPath
    }
}
