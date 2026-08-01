import Darwin
import Foundation

struct PendingCommitRecovery: Sendable, Equatable {
    let artifact: CommitRecoveryArtifact
    let documentIdentity: DocumentIdentity
    let expectedContentDigest: String
    let commitGeneration: UInt64?
    let preparedCandidateResourceIdentifier: String
    let swapCompleted: Bool
    let swapEvidence: CommitRecoverySwapEvidence
    let terminalState: CommitRecoveryTerminalState
}

enum CommitRecoverySwapEvidence: Sendable, Equatable {
    case targetOwnsPreparedCandidate
    case preparedCandidateRemains
    case ambiguous
}

enum CommitRecoveryTerminalState: String, Codable, Sendable, Equatable {
    case prepared
    case cleanupAuthorized
    case committed
    case notCommitted
}

enum CommitRecoveryAcknowledgementPhase: Sendable, Equatable {
    case afterArtifactCleanupBeforeJournalRemoval
    case afterJournalUnlinkBeforeDirectorySync
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
        requestedTargetURL: URL,
        documentIdentity: DocumentIdentity,
        commitGeneration: UInt64,
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
        guard
            let candidateResourceIdentifier =
                candidateFingerprint.resourceIdentifier
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let replacementDirectoryResourceIdentifier =
            try DurableFileIO.resourceIdentifier(
                for: replacementDirectoryURL
            )
        let journal = PersistedCommitRecoveryJournal(
            id: id,
            documentStableKey: documentIdentity.stableKey,
            commitGeneration: commitGeneration,
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
            requestedTargetPath: requestedTargetURL.path,
            candidatePath: candidateURL.path,
            replacementDirectoryPath: replacementDirectoryURL.path,
            terminalState: .prepared
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
                targetURL: requestedTargetURL,
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
            try validateSchema(of: journal)
            let terminalState = journal.terminalState ?? .prepared
            let candidateURL = URL(fileURLWithPath: journal.candidatePath)
            let targetURL = URL(fileURLWithPath: journal.targetPath)
            let requestedTargetURL = URL(
                fileURLWithPath: journal.requestedTargetPath
                    ?? journal.targetPath
            )
            let replacementDirectoryURL = URL(
                fileURLWithPath: journal.replacementDirectoryPath,
                isDirectory: true
            )
            guard
                DocumentIdentity.make(url: targetURL).stableKey
                    == journal.documentStableKey,
                candidateURL.deletingLastPathComponent().standardizedFileURL
                    == replacementDirectoryURL.standardizedFileURL
            else {
                throw JournalError.invalidArtifactPath
            }
            if terminalState == .prepared {
                guard
                    let directoryIdentifier =
                        try? DurableFileIO.resourceIdentifier(
                            for: replacementDirectoryURL
                        ),
                    directoryIdentifier
                        == journal.replacementDirectoryResourceIdentifier
                else {
                    throw JournalError.invalidArtifactPath
                }
            }
            let candidateIdentifier =
                try? DurableFileIO.resourceIdentifier(for: candidateURL)
            let targetIdentifier =
                try? DurableFileIO.resourceIdentifier(for: targetURL)
            let swapEvidence: CommitRecoverySwapEvidence
            if targetIdentifier == journal.preparedCandidateResourceIdentifier,
                candidateIdentifier
                    != journal.preparedCandidateResourceIdentifier
            {
                swapEvidence = .targetOwnsPreparedCandidate
            } else if candidateIdentifier
                == journal.preparedCandidateResourceIdentifier,
                targetIdentifier
                    != journal.preparedCandidateResourceIdentifier
            {
                swapEvidence = .preparedCandidateRemains
            } else {
                swapEvidence = .ambiguous
            }
            let swapCompleted =
                terminalState == .prepared
                && (targetIdentifier
                    == journal.preparedCandidateResourceIdentifier
                    || (candidateIdentifier != nil
                        && candidateIdentifier
                            != journal.preparedCandidateResourceIdentifier))
            let binding: CommitRecoveryArtifactBinding?
            if let expectedPreimageByteCount = journal.expectedPreimageByteCount,
                let committedPayloadByteCount = journal.committedPayloadByteCount,
                let committedPayloadContentDigest =
                    journal.committedPayloadContentDigest
            {
                binding = CommitRecoveryArtifactBinding(
                    documentIdentity: DocumentIdentity(
                        stableKey: journal.documentStableKey
                    ),
                    targetURL: requestedTargetURL,
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
            pending.append(
                PendingCommitRecovery(
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
                    commitGeneration: journal.commitGeneration,
                    preparedCandidateResourceIdentifier:
                        journal.preparedCandidateResourceIdentifier,
                    swapCompleted: swapCompleted,
                    swapEvidence: swapEvidence,
                    terminalState: terminalState
                ))
        }
        return pending
    }

    /// Resolves an uncertain commit only from one exact, durable journal
    /// binding. Target bytes alone never authorize a completion because they
    /// cannot prove which irreversible commit produced them.
    static func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest,
        in recoveryDirectory: URL,
        acknowledgementHook: (
            @Sendable (
                CommitRecoveryAcknowledgementPhase
            ) throws -> Void
        )? = nil
    ) throws -> DocumentSyncCommitReconciliationResult {
        guard request.token.operation == .commitReconciliation,
            request.originalCommitToken.operation == .saveCommit,
            request.token.lifetime == request.originalCommitToken.lifetime,
            request.token.attachmentEpoch == request.attachmentEpoch,
            request.originalCommitToken.attachmentEpoch
                == request.attachmentEpoch,
            request.pendingSave.generation == request.commitGeneration,
            request.pendingSave.targetURL.standardizedFileURL
                == request.targetURL.standardizedFileURL,
            request.identity.matches(url: request.targetURL),
            let expectedBaseline = request.expectedBaseline,
            expectedBaseline.documentIdentity == request.identity,
            request.pendingSave.expectedDurableState
                == expectedBaseline.asDurableFileState
        else {
            return .unresolved
        }

        let matching = try pendingRecoveries(in: recoveryDirectory).filter {
            guard $0.documentIdentity == request.identity,
                $0.commitGeneration == request.commitGeneration,
                let binding = $0.artifact.binding
            else {
                return false
            }
            return binding.documentIdentity == request.identity
                && binding.targetURL.standardizedFileURL
                    == request.targetURL.standardizedFileURL
                && binding.expectedPreimageFingerprint
                    == expectedBaseline.fingerprint
                && binding.committedPayloadFingerprint
                    == request.pendingSave.contentFingerprint
        }
        guard matching.count == 1, let pending = matching.first else {
            return .unresolved
        }

        let targetData = try Data(
            contentsOf: request.targetURL,
            options: [.mappedIfSafe]
        )
        let targetFingerprint = try SafeFileCommitter.fingerprint(
            for: request.targetURL,
            data: targetData
        )
        let targetObservation = try TextFileCodec.externalReadObservation(
            data: targetData,
            targetURL: request.targetURL,
            identity: request.identity,
            fingerprint: targetFingerprint
        )

        switch pending.terminalState {
        case .committed:
            guard
                targetFingerprint.resourceIdentifier
                    == pending.preparedCandidateResourceIdentifier,
                targetFingerprint.byteCount
                    == request.pendingSave.contentFingerprint.byteCount,
                targetFingerprint.contentDigest
                    == request.pendingSave.contentFingerprint.contentDigest
            else {
                return .unresolved
            }
            try acknowledge(
                pending.artifact,
                terminalState: .committed,
                acknowledgementHook: acknowledgementHook
            )
            return .committed(
                completion: DocumentSyncSaveCompletion(
                    result: FileCommitResult(
                        generation: request.commitGeneration,
                        committedFingerprint: targetFingerprint,
                        verifiedDisplacedPreimage: nil,
                        safety: .atomicSwap
                    )
                ),
                targetObservation: targetObservation
            )
        case .notCommitted:
            guard targetFingerprint == expectedBaseline.fingerprint else {
                return .unresolved
            }
            try acknowledge(
                pending.artifact,
                terminalState: .notCommitted,
                acknowledgementHook: acknowledgementHook
            )
            return .notCommitted(targetObservation)
        case .cleanupAuthorized:
            return .unresolved
        case .prepared:
            break
        }

        switch pending.swapEvidence {
        case .targetOwnsPreparedCandidate:
            guard
                targetFingerprint.resourceIdentifier
                    == pending.preparedCandidateResourceIdentifier,
                targetFingerprint.byteCount
                    == request.pendingSave.contentFingerprint.byteCount,
                targetFingerprint.contentDigest
                    == request.pendingSave.contentFingerprint.contentDigest
            else {
                return .unresolved
            }
            // The original commit can fail immediately after RENAME_SWAP,
            // before either affected directory is synchronized. A matching
            // journal proves which swap occurred, but it is not yet a durable
            // completion receipt until both directory entries are flushed.
            try DurableFileIO.synchronizeDirectory(
                request.targetURL
                    .resolvingSymlinksInPath()
                    .deletingLastPathComponent()
            )
            try DurableFileIO.synchronizeDirectory(
                pending.artifact.replacementDirectoryURL
            )
            let displacedData = try Data(
                contentsOf: pending.artifact.candidateURL,
                options: [.mappedIfSafe]
            )
            let displacedFingerprint = try SafeFileCommitter.fingerprint(
                for: pending.artifact.candidateURL,
                data: displacedData
            )
            let displacedPreimage = VerifiedFilePayload(
                data: displacedData,
                resourceIdentifier: displacedFingerprint.resourceIdentifier
            )
            let hasExpectedPreimage =
                displacedPreimage.fingerprint.byteCount
                == expectedBaseline.fingerprint.byteCount
                && displacedPreimage.fingerprint.contentDigest
                    == expectedBaseline.fingerprint.contentDigest
            let recoveryArtifact: CommitRecoveryArtifact?
            if hasExpectedPreimage {
                try acknowledge(
                    pending.artifact,
                    terminalState: .committed,
                    acknowledgementHook: acknowledgementHook
                )
                recoveryArtifact = nil
            } else {
                recoveryArtifact = pending.artifact
            }
            return .committed(
                completion: DocumentSyncSaveCompletion(
                    result: FileCommitResult(
                        generation: request.commitGeneration,
                        committedFingerprint: targetFingerprint,
                        verifiedDisplacedPreimage: displacedPreimage,
                        safety: .atomicSwap,
                        recoveryArtifact: recoveryArtifact
                    )
                ),
                targetObservation: targetObservation
            )
        case .preparedCandidateRemains:
            let candidateIdentifier = try DurableFileIO.resourceIdentifier(
                for: pending.artifact.candidateURL
            )
            guard
                candidateIdentifier
                    == pending.preparedCandidateResourceIdentifier,
                targetFingerprint == expectedBaseline.fingerprint
            else {
                return .unresolved
            }
            try acknowledge(
                pending.artifact,
                terminalState: .notCommitted,
                acknowledgementHook: acknowledgementHook
            )
            return .notCommitted(targetObservation)
        case .ambiguous:
            return .unresolved
        }
    }

    static func acknowledge(_ artifact: CommitRecoveryArtifact) throws {
        try acknowledge(
            artifact,
            terminalState: nil,
            acknowledgementHook: nil
        )
    }

    static func acknowledge(
        _ artifact: CommitRecoveryArtifact,
        acknowledgementHook:
            @escaping @Sendable (
                CommitRecoveryAcknowledgementPhase
            ) throws -> Void
    ) throws {
        try acknowledge(
            artifact,
            terminalState: nil,
            acknowledgementHook: acknowledgementHook
        )
    }

    private static func acknowledge(
        _ artifact: CommitRecoveryArtifact,
        terminalState requestedTerminalState: CommitRecoveryTerminalState?,
        acknowledgementHook: (
            @Sendable (
                CommitRecoveryAcknowledgementPhase
            ) throws -> Void
        )?
    ) throws {
        let replacementDirectory =
            artifact.replacementDirectoryURL.standardizedFileURL
        guard
            artifact.candidateURL.deletingLastPathComponent()
                .standardizedFileURL == replacementDirectory
        else {
            throw JournalError.invalidArtifactPath
        }
        let fileManager = FileManager.default
        let persistedJournal: PersistedCommitRecoveryJournal?
        if fileManager.fileExists(atPath: artifact.journalURL.path) {
            persistedJournal = try loadJournal(
                for: artifact,
                replacementDirectory: replacementDirectory
            )
        } else {
            persistedJournal = nil
        }
        var terminalState = persistedJournal?.terminalState ?? .prepared
        var hasDurableTerminalReceipt = false
        if let persistedJournal,
            terminalState != .prepared
        {
            // A prior atomic rewrite can become visible before its parent
            // directory synchronization reports failure. Rewriting the same
            // terminal receipt makes durability explicit before Retry removes
            // any remaining artifact or the journal itself.
            try persist(
                try persistedJournal.withTerminalState(terminalState),
                to: artifact.journalURL
            )
            hasDurableTerminalReceipt = true
        }
        if fileManager.fileExists(atPath: replacementDirectory.path) {
            let ownsReplacementDirectory =
                try DurableFileIO.resourceIdentifier(
                    for: replacementDirectory
                ) == artifact.replacementDirectoryResourceIdentifier
            if !ownsReplacementDirectory {
                guard terminalState != .prepared else {
                    throw JournalError.unownedReplacementDirectory
                }
            } else if let persistedJournal, terminalState == .prepared {
                if let requestedTerminalState {
                    try persist(
                        try persistedJournal.withTerminalState(
                            requestedTerminalState
                        ),
                        to: artifact.journalURL
                    )
                    terminalState = requestedTerminalState
                } else if persistedJournal.supportsAuthoritativeTerminalState {
                    terminalState = try inferredTerminalState(
                        from: persistedJournal,
                        artifact: artifact
                    )
                    try persist(
                        try persistedJournal.withTerminalState(terminalState),
                        to: artifact.journalURL
                    )
                } else {
                    // Legacy schema 1/2 journals cannot authorize a
                    // same-session result. Upgrade them only to a durable
                    // cleanup tombstone before deleting their artifacts.
                    terminalState = .cleanupAuthorized
                    try persist(
                        persistedJournal
                            .upgradedForCleanupAuthorization(),
                        to: artifact.journalURL
                    )
                }
                hasDurableTerminalReceipt = true
            }
            if ownsReplacementDirectory,
                fileManager.fileExists(atPath: artifact.candidateURL.path)
            {
                let unlinkResult = artifact.candidateURL.path.withCString {
                    Darwin.unlink($0)
                }
                guard unlinkResult == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
            }
            if ownsReplacementDirectory {
                let removeDirectoryResult =
                    replacementDirectory.path.withCString {
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
        } else if persistedJournal != nil, terminalState == .prepared {
            throw JournalError.invalidArtifactPath
        }
        if let requestedTerminalState,
            terminalState != requestedTerminalState
        {
            throw JournalError.malformedJournal
        }
        try acknowledgementHook?(
            .afterArtifactCleanupBeforeJournalRemoval
        )
        if fileManager.fileExists(atPath: artifact.journalURL.path) {
            let unlinkResult = artifact.journalURL.path.withCString {
                Darwin.unlink($0)
            }
            guard unlinkResult == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            do {
                try acknowledgementHook?(
                    .afterJournalUnlinkBeforeDirectorySync
                )
                try DurableFileIO.synchronizeDirectory(
                    artifact.journalURL.deletingLastPathComponent()
                )
            } catch {
                // Once unlink succeeds, a previously durable non-prepared
                // receipt makes both crash outcomes safe: either the removal
                // is durable, or restart sees the terminal receipt again.
                guard hasDurableTerminalReceipt else {
                    throw error
                }
            }
        }
    }

    private static func loadJournal(
        for artifact: CommitRecoveryArtifact,
        replacementDirectory: URL
    ) throws -> PersistedCommitRecoveryJournal {
        let data = try Data(
            contentsOf: artifact.journalURL,
            options: [.mappedIfSafe]
        )
        let journal: PersistedCommitRecoveryJournal
        do {
            journal = try JSONDecoder().decode(
                PersistedCommitRecoveryJournal.self,
                from: data
            )
        } catch {
            throw JournalError.malformedJournal
        }
        try validateSchema(of: journal)
        guard journal.id == artifact.id,
            URL(fileURLWithPath: journal.candidatePath)
                .standardizedFileURL
                == artifact.candidateURL.standardizedFileURL,
            URL(
                fileURLWithPath: journal.replacementDirectoryPath,
                isDirectory: true
            ).standardizedFileURL == replacementDirectory,
            journal.replacementDirectoryResourceIdentifier
                == artifact.replacementDirectoryResourceIdentifier
        else {
            throw JournalError.invalidArtifactPath
        }
        return journal
    }

    private static func validateSchema(
        of journal: PersistedCommitRecoveryJournal
    ) throws {
        if let schemaVersion = journal.schemaVersion,
            schemaVersion > PersistedCommitRecoveryJournal.currentSchemaVersion
        {
            throw JournalError.unsupportedSchema
        }
        let terminalState = journal.terminalState ?? .prepared
        if journal.schemaVersion
            == PersistedCommitRecoveryJournal.currentSchemaVersion
        {
            switch terminalState {
            case .prepared, .committed, .notCommitted:
                guard journal.supportsAuthoritativeTerminalState else {
                    throw JournalError.malformedJournal
                }
            case .cleanupAuthorized:
                break
            }
        } else if terminalState != .prepared {
            throw JournalError.malformedJournal
        }
    }

    private static func inferredTerminalState(
        from journal: PersistedCommitRecoveryJournal,
        artifact: CommitRecoveryArtifact
    ) throws -> CommitRecoveryTerminalState {
        let targetURL = URL(fileURLWithPath: journal.targetPath)
        let targetIdentifier =
            try? DurableFileIO.resourceIdentifier(for: targetURL)
        let candidateIdentifier =
            try? DurableFileIO.resourceIdentifier(for: artifact.candidateURL)
        if targetIdentifier == journal.preparedCandidateResourceIdentifier,
            candidateIdentifier
                != journal.preparedCandidateResourceIdentifier
        {
            let candidateData = try Data(
                contentsOf: artifact.candidateURL,
                options: [.mappedIfSafe]
            )
            let candidateFingerprint = FileFingerprint.make(
                data: candidateData
            )
            if candidateFingerprint.byteCount
                == journal.expectedPreimageByteCount,
                candidateFingerprint.contentDigest
                    == journal.expectedContentDigest
            {
                return .committed
            }
            return .cleanupAuthorized
        }
        if candidateIdentifier == journal.preparedCandidateResourceIdentifier,
            targetIdentifier != journal.preparedCandidateResourceIdentifier
        {
            let targetData = try Data(
                contentsOf: targetURL,
                options: [.mappedIfSafe]
            )
            let targetFingerprint = try SafeFileCommitter.fingerprint(
                for: targetURL,
                data: targetData
            )
            if targetFingerprint.byteCount
                == journal.expectedPreimageByteCount,
                targetFingerprint.contentDigest
                    == journal.expectedContentDigest,
                targetFingerprint.resourceIdentifier
                    == journal.expectedPreimageResourceIdentifier
            {
                return .notCommitted
            }
        }
        return .cleanupAuthorized
    }

    private static func persist(
        _ journal: PersistedCommitRecoveryJournal,
        to journalURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFileIO.writeAtomically(
            try encoder.encode(journal),
            to: journalURL
        )
    }

}

private struct PersistedCommitRecoveryJournal: Codable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int?
    let id: UUID
    let documentStableKey: String
    let commitGeneration: UInt64?
    let expectedContentDigest: String
    let expectedPreimageByteCount: Int?
    let expectedPreimageResourceIdentifier: String?
    let committedPayloadByteCount: Int?
    let committedPayloadContentDigest: String?
    let preparedCandidateResourceIdentifier: String
    let replacementDirectoryResourceIdentifier: String
    let targetPath: String
    let requestedTargetPath: String?
    let candidatePath: String
    let replacementDirectoryPath: String
    let terminalState: CommitRecoveryTerminalState?

    init(
        id: UUID,
        documentStableKey: String,
        commitGeneration: UInt64,
        expectedContentDigest: String,
        expectedPreimageByteCount: Int?,
        expectedPreimageResourceIdentifier: String?,
        committedPayloadByteCount: Int?,
        committedPayloadContentDigest: String?,
        preparedCandidateResourceIdentifier: String,
        replacementDirectoryResourceIdentifier: String,
        targetPath: String,
        requestedTargetPath: String,
        candidatePath: String,
        replacementDirectoryPath: String,
        terminalState: CommitRecoveryTerminalState
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.documentStableKey = documentStableKey
        self.commitGeneration = commitGeneration
        self.expectedContentDigest = expectedContentDigest
        self.expectedPreimageByteCount = expectedPreimageByteCount
        self.expectedPreimageResourceIdentifier = expectedPreimageResourceIdentifier
        self.committedPayloadByteCount = committedPayloadByteCount
        self.committedPayloadContentDigest = committedPayloadContentDigest
        self.preparedCandidateResourceIdentifier = preparedCandidateResourceIdentifier
        self.replacementDirectoryResourceIdentifier = replacementDirectoryResourceIdentifier
        self.targetPath = targetPath
        self.requestedTargetPath = requestedTargetPath
        self.candidatePath = candidatePath
        self.replacementDirectoryPath = replacementDirectoryPath
        self.terminalState = terminalState
    }

    private init(
        schemaVersion: Int,
        id: UUID,
        documentStableKey: String,
        commitGeneration: UInt64?,
        expectedContentDigest: String,
        expectedPreimageByteCount: Int?,
        expectedPreimageResourceIdentifier: String?,
        committedPayloadByteCount: Int?,
        committedPayloadContentDigest: String?,
        preparedCandidateResourceIdentifier: String,
        replacementDirectoryResourceIdentifier: String,
        targetPath: String,
        requestedTargetPath: String?,
        candidatePath: String,
        replacementDirectoryPath: String,
        terminalState: CommitRecoveryTerminalState
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.documentStableKey = documentStableKey
        self.commitGeneration = commitGeneration
        self.expectedContentDigest = expectedContentDigest
        self.expectedPreimageByteCount = expectedPreimageByteCount
        self.expectedPreimageResourceIdentifier =
            expectedPreimageResourceIdentifier
        self.committedPayloadByteCount = committedPayloadByteCount
        self.committedPayloadContentDigest =
            committedPayloadContentDigest
        self.preparedCandidateResourceIdentifier =
            preparedCandidateResourceIdentifier
        self.replacementDirectoryResourceIdentifier =
            replacementDirectoryResourceIdentifier
        self.targetPath = targetPath
        self.requestedTargetPath = requestedTargetPath
        self.candidatePath = candidatePath
        self.replacementDirectoryPath = replacementDirectoryPath
        self.terminalState = terminalState
    }

    func withTerminalState(
        _ terminalState: CommitRecoveryTerminalState
    ) throws -> PersistedCommitRecoveryJournal {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CommitRecoveryJournalStore.JournalError.malformedJournal
        }
        if terminalState != .cleanupAuthorized,
            !supportsAuthoritativeTerminalState
        {
            throw CommitRecoveryJournalStore.JournalError.malformedJournal
        }
        return PersistedCommitRecoveryJournal(
            schemaVersion: Self.currentSchemaVersion,
            id: id,
            documentStableKey: documentStableKey,
            commitGeneration: commitGeneration,
            expectedContentDigest: expectedContentDigest,
            expectedPreimageByteCount: expectedPreimageByteCount,
            expectedPreimageResourceIdentifier:
                expectedPreimageResourceIdentifier,
            committedPayloadByteCount: committedPayloadByteCount,
            committedPayloadContentDigest: committedPayloadContentDigest,
            preparedCandidateResourceIdentifier:
                preparedCandidateResourceIdentifier,
            replacementDirectoryResourceIdentifier:
                replacementDirectoryResourceIdentifier,
            targetPath: targetPath,
            requestedTargetPath: requestedTargetPath,
            candidatePath: candidatePath,
            replacementDirectoryPath: replacementDirectoryPath,
            terminalState: terminalState
        )
    }

    func upgradedForCleanupAuthorization()
        -> PersistedCommitRecoveryJournal
    {
        PersistedCommitRecoveryJournal(
            schemaVersion: Self.currentSchemaVersion,
            id: id,
            documentStableKey: documentStableKey,
            commitGeneration: commitGeneration,
            expectedContentDigest: expectedContentDigest,
            expectedPreimageByteCount: expectedPreimageByteCount,
            expectedPreimageResourceIdentifier:
                expectedPreimageResourceIdentifier,
            committedPayloadByteCount: committedPayloadByteCount,
            committedPayloadContentDigest:
                committedPayloadContentDigest,
            preparedCandidateResourceIdentifier:
                preparedCandidateResourceIdentifier,
            replacementDirectoryResourceIdentifier:
                replacementDirectoryResourceIdentifier,
            targetPath: targetPath,
            requestedTargetPath: requestedTargetPath,
            candidatePath: candidatePath,
            replacementDirectoryPath: replacementDirectoryPath,
            terminalState: .cleanupAuthorized
        )
    }

    var supportsAuthoritativeTerminalState: Bool {
        schemaVersion == Self.currentSchemaVersion
            && commitGeneration != nil
            && expectedPreimageByteCount != nil
            && committedPayloadByteCount != nil
            && committedPayloadContentDigest != nil
            && requestedTargetPath != nil
    }
}
