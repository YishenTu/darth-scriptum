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
        expectedContentDigest: String,
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
            expectedContentDigest: expectedContentDigest,
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
                replacementDirectoryResourceIdentifier
        )
    }

    static func pendingRecoveries(
        in recoveryDirectory: URL
    ) -> [PendingCommitRecovery] {
        let journalDirectory = recoveryDirectory.appendingPathComponent(
            "commit-journals",
            isDirectory: true
        )
        guard let journalURLs = try? FileManager.default.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return journalURLs.compactMap { journalURL in
            guard journalURL.lastPathComponent.hasSuffix(".commit.json"),
                  let encoded = try? Data(contentsOf: journalURL),
                  let journal = try? JSONDecoder().decode(
                    PersistedCommitRecoveryJournal.self,
                    from: encoded
                  ) else {
                quarantine(journalURL, in: journalDirectory)
                return nil
            }
            let candidateURL = URL(fileURLWithPath: journal.candidatePath)
            let targetURL = URL(fileURLWithPath: journal.targetPath)
            let replacementDirectoryURL = URL(
                fileURLWithPath: journal.replacementDirectoryPath,
                isDirectory: true
            )
            guard candidateURL.deletingLastPathComponent().standardizedFileURL
                    == replacementDirectoryURL.standardizedFileURL,
                  let directoryIdentifier =
                    try? DurableFileIO.resourceIdentifier(
                        for: replacementDirectoryURL
                    ),
                  directoryIdentifier
                    == journal.replacementDirectoryResourceIdentifier else {
                quarantine(journalURL, in: journalDirectory)
                return nil
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
            return PendingCommitRecovery(
                artifact: CommitRecoveryArtifact(
                    id: journal.id,
                    journalURL: journalURL,
                    candidateURL: candidateURL,
                    replacementDirectoryURL: replacementDirectoryURL,
                    replacementDirectoryResourceIdentifier:
                        journal.replacementDirectoryResourceIdentifier
                ),
                documentIdentity: DocumentIdentity(
                    stableKey: journal.documentStableKey
                ),
                expectedContentDigest: journal.expectedContentDigest,
                swapCompleted: swapCompleted
            )
        }
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

    private static func quarantine(
        _ journalURL: URL,
        in journalDirectory: URL
    ) {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return
        }
        let quarantineDirectory = journalDirectory.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        do {
            try DurableFileIO.createDirectory(at: quarantineDirectory)
            let destination = quarantineDirectory.appendingPathComponent(
                "\(journalURL.deletingPathExtension().lastPathComponent)-"
                    + "\(UUID().uuidString.lowercased()).invalid.json"
            )
            try FileManager.default.moveItem(
                at: journalURL,
                to: destination
            )
            try DurableFileIO.synchronizeDirectory(journalDirectory)
            try DurableFileIO.synchronizeDirectory(quarantineDirectory)
        } catch {
            return
        }
    }
}

private struct PersistedCommitRecoveryJournal: Codable {
    let id: UUID
    let documentStableKey: String
    let expectedContentDigest: String
    let preparedCandidateResourceIdentifier: String
    let replacementDirectoryResourceIdentifier: String
    let targetPath: String
    let candidatePath: String
    let replacementDirectoryPath: String
}
