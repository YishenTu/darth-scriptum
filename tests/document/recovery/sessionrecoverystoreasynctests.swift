import Foundation
import XCTest
@testable import DarthScriptum

@MainActor
final class SessionRecoveryStoreAsyncTests: XCTestCase {
    func testSameSessionCommitReconciliationAcknowledgesExactCompletedSwap()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()

        XCTAssertThrowsError(
            try fixture.committer(
                afterAtomicSwap: {
                    throw ReconciliationInjectedError.afterAtomicSwap
                }
            ).commit(fixture.pendingSave)
        )

        let pendingArtifact = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            ).first?.artifact
        )
        let result = await store.reconcileCommit(fixture.request())

        guard case .committed(let completion, let observation) = result else {
            return XCTFail("Expected an authoritative committed result")
        }
        XCTAssertEqual(observation.identity, fixture.identity)
        XCTAssertEqual(
            observation.targetURL.standardizedFileURL,
            fixture.targetURL.standardizedFileURL
        )
        XCTAssertEqual(completion.result.generation, fixture.pendingSave.generation)
        XCTAssertEqual(completion.result.safety, .atomicSwap)
        XCTAssertEqual(completion.result.displacedPreimage?.data, fixture.original)
        XCTAssertNil(completion.result.recoveryArtifact)
        XCTAssertEqual(
            completion.result.committedFingerprint,
            observation.fingerprint
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: pendingArtifact.journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: pendingArtifact.candidateURL.path
            )
        )
    }

    func testCompletedSwapReturnsUnexpectedPreimageWithBoundJournal()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()
        let unexpected = Data("external\n".utf8)

        XCTAssertThrowsError(
            try fixture.committer(
                beforeAtomicSwap: {
                    try unexpected.write(to: fixture.targetURL)
                },
                afterAtomicSwap: {
                    throw ReconciliationInjectedError.afterAtomicSwap
                }
            ).commit(fixture.pendingSave)
        )

        let result = await store.reconcileCommit(fixture.request())

        guard case .committed(let completion, _) = result else {
            return XCTFail("Expected an authoritative committed result")
        }
        let artifact = try XCTUnwrap(completion.result.recoveryArtifact)
        defer {
            try? CommitRecoveryJournalStore.acknowledge(artifact)
        }
        XCTAssertEqual(completion.result.displacedPreimage?.data, unexpected)
        XCTAssertEqual(artifact.binding?.documentIdentity, fixture.identity)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.candidateURL.path)
        )
        let records = try await store.records(for: fixture.identity)
        XCTAssertTrue(records.raw.isEmpty)
    }

    func testProvenUnswappedCommitAcknowledgesBeforeReturningNotCommitted()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()
        let artifact = try fixture.prepareUnswappedJournal()

        let result = await store.reconcileCommit(fixture.request())

        guard case .notCommitted(let observation) = result else {
            return XCTFail("Expected a proven not-committed result")
        }
        XCTAssertEqual(observation?.fingerprint, fixture.baseline.fingerprint)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.candidateURL.path)
        )
    }

    func testCompletedSwapAcknowledgementInterruptionRetriesFromTerminalJournal()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()
        XCTAssertThrowsError(
            try fixture.committer(
                afterAtomicSwap: {
                    throw ReconciliationInjectedError.afterAtomicSwap
                }
            ).commit(fixture.pendingSave)
        )
        let request = fixture.request()

        let interrupted = await reconcileCommit(
            request,
            in: fixture.recoveryDirectory,
            acknowledgementHook: { phase in
                guard phase
                        == .afterArtifactCleanupBeforeJournalRemoval else {
                    return
                }
                throw ReconciliationInjectedError.acknowledgementInterrupted
            }
        )

        XCTAssertEqual(interrupted, .unresolved)
        let terminal = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            ).first
        )
        XCTAssertEqual(terminal.terminalState, .committed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: terminal.artifact.journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: terminal.artifact.candidateURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: terminal.artifact.replacementDirectoryURL.path
            )
        )

        let retried = await store.reconcileCommit(request)

        guard case .committed(let completion, _) = retried else {
            return XCTFail("Expected terminal committed reconciliation")
        }
        XCTAssertEqual(
            completion.result.committedFingerprint.contentDigest,
            fixture.pendingSave.contentFingerprint.contentDigest
        )
        XCTAssertNil(completion.result.displacedPreimage)
        XCTAssertNil(completion.result.recoveryArtifact)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: terminal.artifact.journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: terminal.artifact.replacementDirectoryURL.path
            )
        )
    }

    func testUnswappedAcknowledgementInterruptionRetriesFromTerminalJournal()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()
        let artifact = try fixture.prepareUnswappedJournal()
        let request = fixture.request()

        let interrupted = await reconcileCommit(
            request,
            in: fixture.recoveryDirectory,
            acknowledgementHook: { phase in
                guard phase
                        == .afterArtifactCleanupBeforeJournalRemoval else {
                    return
                }
                throw ReconciliationInjectedError.acknowledgementInterrupted
            }
        )

        XCTAssertEqual(interrupted, .unresolved)
        let terminal = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            ).first
        )
        XCTAssertEqual(terminal.terminalState, .notCommitted)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifact.journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.candidateURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.replacementDirectoryURL.path
            )
        )

        let retried = await store.reconcileCommit(request)

        guard case .notCommitted(let observation) = retried else {
            return XCTFail("Expected terminal not-committed reconciliation")
        }
        XCTAssertEqual(observation?.fingerprint, fixture.baseline.fingerprint)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.replacementDirectoryURL.path
            )
        )
    }

    func testCompletedSwapRemainsAuthoritativeAfterJournalUnlinkSyncFailure()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try fixture.committer(
                afterAtomicSwap: {
                    throw ReconciliationInjectedError.afterAtomicSwap
                }
            ).commit(fixture.pendingSave)
        )
        let artifact = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            ).first?.artifact
        )

        let result = await reconcileCommit(
            fixture.request(),
            in: fixture.recoveryDirectory,
            acknowledgementHook: { phase in
                guard phase
                        == .afterJournalUnlinkBeforeDirectorySync else {
                    return
                }
                throw ReconciliationInjectedError.acknowledgementInterrupted
            }
        )

        guard case .committed(let completion, _) = result else {
            return XCTFail("Journal unlink must preserve committed authority")
        }
        XCTAssertEqual(
            completion.result.committedFingerprint.contentDigest,
            fixture.pendingSave.contentFingerprint.contentDigest
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
    }

    func testUnswappedRemainsAuthoritativeAfterJournalUnlinkSyncFailure()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let artifact = try fixture.prepareUnswappedJournal()

        let result = await reconcileCommit(
            fixture.request(),
            in: fixture.recoveryDirectory,
            acknowledgementHook: { phase in
                guard phase
                        == .afterJournalUnlinkBeforeDirectorySync else {
                    return
                }
                throw ReconciliationInjectedError.acknowledgementInterrupted
            }
        )

        guard case .notCommitted(let observation) = result else {
            return XCTFail("Journal unlink must preserve not-committed authority")
        }
        XCTAssertEqual(observation?.fingerprint, fixture.baseline.fingerprint)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
    }

    func testGenericAcknowledgementCompletesAfterJournalUnlinkSyncFailure()
        throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let artifact = try fixture.prepareUnswappedJournal()

        XCTAssertNoThrow(
            try CommitRecoveryJournalStore.acknowledge(
                artifact,
                acknowledgementHook: { phase in
                    guard phase
                            == .afterJournalUnlinkBeforeDirectorySync else {
                        return
                    }
                    throw ReconciliationInjectedError
                        .acknowledgementInterrupted
                }
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.replacementDirectoryURL.path
            )
        )
    }

    func testSchema1AcknowledgementInterruptionUpgradesToCleanupTombstone()
        async throws {
        try await assertLegacyAcknowledgementInterruptionIsRetrySafe(
            schemaVersion: nil
        )
    }

    func testSchema2AcknowledgementInterruptionUpgradesToCleanupTombstone()
        async throws {
        try await assertLegacyAcknowledgementInterruptionIsRetrySafe(
            schemaVersion: 2
        )
    }

    private func assertLegacyAcknowledgementInterruptionIsRetrySafe(
        schemaVersion: Int?
    ) async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let artifact = try fixture.prepareUnswappedJournal()
        try rewriteCommitJournal(at: artifact.journalURL) { journal in
            if let schemaVersion {
                journal["schemaVersion"] = schemaVersion
            } else {
                journal.removeValue(forKey: "schemaVersion")
                journal.removeValue(
                    forKey: "expectedPreimageByteCount"
                )
                journal.removeValue(
                    forKey: "expectedPreimageResourceIdentifier"
                )
                journal.removeValue(
                    forKey: "committedPayloadByteCount"
                )
                journal.removeValue(
                    forKey: "committedPayloadContentDigest"
                )
            }
            journal.removeValue(forKey: "commitGeneration")
            journal.removeValue(forKey: "requestedTargetPath")
            journal.removeValue(forKey: "terminalState")
        }
        let legacyPending = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            ).first
        )
        XCTAssertEqual(legacyPending.terminalState, .prepared)
        XCTAssertNil(legacyPending.commitGeneration)

        XCTAssertThrowsError(
            try CommitRecoveryJournalStore.acknowledge(
                artifact,
                acknowledgementHook: { phase in
                    guard phase
                            == .afterArtifactCleanupBeforeJournalRemoval else {
                        return
                    }
                    throw ReconciliationInjectedError
                        .acknowledgementInterrupted
                }
            )
        )

        let upgraded = try commitJournalObject(
            at: artifact.journalURL
        )
        XCTAssertEqual(upgraded["schemaVersion"] as? Int, 3)
        XCTAssertEqual(
            upgraded["terminalState"] as? String,
            CommitRecoveryTerminalState.cleanupAuthorized.rawValue
        )
        XCTAssertNil(upgraded["commitGeneration"])
        XCTAssertNil(upgraded["requestedTargetPath"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.candidateURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.replacementDirectoryURL.path
            )
        )
        let pending = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            ).first
        )
        XCTAssertEqual(pending.terminalState, .cleanupAuthorized)
        XCTAssertNil(pending.commitGeneration)
        let sameSessionResult = await reconcileCommit(
            fixture.request(),
            in: fixture.recoveryDirectory,
            acknowledgementHook: { _ in }
        )
        XCTAssertEqual(
            sameSessionResult,
            .unresolved
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifact.journalURL.path
            )
        )

        let reopened = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await reopened.start()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.journalURL.path
            )
        )
    }

    func testCommitReconciliationMismatchesAndUnboundNewFilesRemainUnresolved()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()
        let artifact = try fixture.prepareUnswappedJournal()

        let mismatchedGenerationResult = await store.reconcileCommit(
            fixture.request(
                commitGeneration: fixture.pendingSave.generation + 1
            )
        )
        XCTAssertEqual(mismatchedGenerationResult, .unresolved)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )

        let newTarget = fixture.directory.appendingPathComponent("new.md")
        let newSnapshot = DocumentSnapshot(
            text: "new\n",
            format: .newDocument
        )
        let newPendingSave = PendingSaveToken(
            generation: 1,
            sourceRevision: SourceRevision(number: 1, text: "new\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: newSnapshot
            ),
            expectedDurableState: nil,
            targetURL: newTarget
        )
        let newIdentity = DocumentIdentity.make(url: newTarget)
        let unboundNewFileResult = await store.reconcileCommit(
            DocumentSyncCommitReconciliationRequest(
                token: fixture.effectToken(attempt: 3),
                originalCommitToken: fixture.commitToken,
                pendingSave: newPendingSave,
                targetURL: newTarget,
                identity: newIdentity,
                attachmentEpoch: 1,
                expectedBaseline: nil,
                commitGeneration: 1
            )
        )
        XCTAssertEqual(unboundNewFileResult, .unresolved)
    }

    func testCurrentPreparedJournalMissingExactBindingFailsClosed() throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let artifact = try fixture.prepareUnswappedJournal()
        try rewriteCommitJournal(at: artifact.journalURL) { journal in
            journal.removeValue(forKey: "commitGeneration")
            journal.removeValue(forKey: "committedPayloadContentDigest")
            journal.removeValue(forKey: "requestedTargetPath")
        }
        let malformedBytes = try Data(contentsOf: artifact.journalURL)

        XCTAssertThrowsError(
            try CommitRecoveryJournalStore.pendingRecoveries(
                in: fixture.recoveryDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? CommitRecoveryJournalStore.JournalError,
                .malformedJournal
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: artifact.journalURL),
            malformedBytes
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.candidateURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifact.replacementDirectoryURL.path
            )
        )
    }

    func testCommitReconciliationRequiresEveryExactJournalBindingField()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )
        _ = try await store.start()
        let artifact = try fixture.prepareUnswappedJournal()
        let differentTarget = fixture.directory.appendingPathComponent(
            "different.md"
        )
        let differentIdentity = DocumentIdentity.make(url: differentTarget)
        let differentPayload = PendingSaveToken(
            generation: fixture.pendingSave.generation,
            sourceRevision: SourceRevision(number: 2, text: "other\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(Data("other\n".utf8))
            ),
            expectedDurableState: fixture.baseline.asDurableFileState,
            targetURL: fixture.targetURL
        )
        let differentPreimage = Data("different baseline\n".utf8)
        let differentBaseline = try TextFileCodec.durableBaseline(
            data: differentPreimage,
            targetURL: fixture.targetURL,
            fingerprint: FileFingerprint.make(
                data: differentPreimage,
                resourceIdentifier:
                    fixture.baseline.fingerprint.resourceIdentifier
            ),
            documentIdentity: fixture.identity,
            sourceRevision: fixture.baseline.sourceRevision,
            commitGeneration: fixture.baseline.commitGeneration
        )
        let differentBaselinePendingSave = PendingSaveToken(
            generation: fixture.pendingSave.generation,
            sourceRevision: fixture.pendingSave.sourceRevision,
            preparedPayload: fixture.pendingSave.preparedPayload,
            expectedDurableState: differentBaseline.asDurableFileState,
            targetURL: fixture.targetURL
        )

        let mismatches = [
            fixture.request(
                commitGeneration: fixture.pendingSave.generation + 1
            ),
            fixture.request(
                identity: differentIdentity,
                targetURL: differentTarget
            ),
            fixture.request(pendingSave: differentPayload),
            fixture.request(
                pendingSave: differentBaselinePendingSave,
                expectedBaseline: differentBaseline
            ),
            fixture.request(
                token: SyncEffectToken(
                    lifetime: UUID(),
                    attachmentEpoch: 1,
                    operation: .commitReconciliation,
                    attempt: 2
                )
            )
        ]
        for request in mismatches {
            let result = await store.reconcileCommit(request)
            XCTAssertEqual(result, .unresolved)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: artifact.journalURL.path
                )
            )
        }
    }

    func testCommitReconciliationWaitsBehindTheActorWideFIFO() async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let migrationGate = BlockingRecoveryIOGate()
        let commandRecorder = RecoveryCommandEnqueueRecorder()
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory,
            migrationWriteHook: { writeCount in
                guard writeCount == 1 else { return }
                migrationGate.blockUntilReleased()
            },
            commandEnqueueHook: { kind in
                commandRecorder.record(kind)
            }
        )
        defer { migrationGate.release() }
        _ = try await store.start()
        _ = try fixture.prepareUnswappedJournal()
        let source = DocumentIdentity(
            stableKey: "path:/tmp/reconciliation-fifo-source.md"
        )
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/reconciliation-fifo-destination.md"
        )
        let persisted = try await store.add(
            snapshot: DocumentSnapshot(
                text: "recovery\n",
                format: .newDocument
            ),
            for: source
        )
        let sourceEntry = try XCTUnwrap(persisted.decodedEntries.first)
        let migration = Task {
            try await store.moveEntries(
                from: source,
                to: destination,
                expectedRecords: DocumentSyncRecoveryRecords(
                    decoded: [sourceEntry],
                    raw: []
                ),
                expectedGeneration: persisted.generation
            )
        }
        await migrationGate.waitUntilBlocked()

        let completion = RecoveryTaskCompletionProbe()
        let reconciliation = Task {
            defer { completion.markCompleted() }
            return await store.reconcileCommit(fixture.request())
        }
        await commandRecorder.waitForCount(
            of: .reconcileCommit,
            atLeast: 1
        )
        XCTAssertFalse(completion.isCompleted)

        migrationGate.release()
        _ = try await migration.value
        let result = await reconciliation.value
        guard case .notCommitted = result else {
            return XCTFail("Expected reconciliation after FIFO migration")
        }
    }

    func testCommitReconciliationStartupFailureReturnsUnresolvedAndKeepsJournal()
        async throws {
        let fixture = try ReconciliationFixture()
        defer { fixture.remove() }
        let artifact = try fixture.prepareUnswappedJournal()
        try Data("{ malformed migration".utf8).write(
            to: fixture.recoveryDirectory.appendingPathComponent(
                "migration.json"
            )
        )
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory
        )

        let result = await store.reconcileCommit(fixture.request())

        XCTAssertEqual(result, .unresolved)
        let status = await store.status()
        XCTAssertEqual(status, .failed(.malformedData))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.candidateURL.path)
        )
    }

    func testStartupImportsExistingRecoveryAndTransitionsFromLoadingToReady()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/startup-import.md")
        let snapshot = DocumentSnapshot(
            text: "existing recovery\n",
            format: .newDocument
        )

        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(snapshot: snapshot, for: identity)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        let loadingStatus = await store.status()
        XCTAssertEqual(loadingStatus, .loading)

        let imported = try await store.start()

        let readyStatus = await store.status()
        XCTAssertEqual(readyStatus, .ready(generation: 1))
        XCTAssertEqual(imported.records(for: identity).decoded.first?.snapshot, snapshot)
    }

    func testFailedStartupPreservesMalformedEvidenceUntilRetrySucceeds()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let migrationURL = directory.appendingPathComponent("migration.json")
        try Data("{ malformed".utf8).write(to: migrationURL)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await store.start()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .malformedData)
        }
        let failedStatus = await store.status()
        XCTAssertEqual(failedStatus, .failed(.malformedData))
        XCTAssertEqual(try Data(contentsOf: migrationURL), Data("{ malformed".utf8))

        try FileManager.default.removeItem(at: migrationURL)
        let imported = try await store.retryStartup()

        XCTAssertTrue(imported.records.isEmpty)
        let readyStatus = await store.status()
        XCTAssertEqual(readyStatus, .ready(generation: 0))
    }

    func testQueuedMutationWaitsForStartupImportAndUsesTheImportedGeneration()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/queued-intent.md")
        let importedSnapshot = DocumentSnapshot(
            text: "imported\n",
            format: .newDocument
        )
        let newSnapshot = DocumentSnapshot(
            text: "queued\n",
            format: .newDocument
        )

        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(snapshot: importedSnapshot, for: identity)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        async let queued = store.add(
            snapshot: newSnapshot,
            for: identity,
            expectedGeneration: 1
        )
        let receipt = try await queued

        XCTAssertEqual(receipt.previousGeneration, 1)
        XCTAssertEqual(receipt.generation, 2)
        XCTAssertEqual(receipt.decodedEntries.map(\.snapshot), [newSnapshot, importedSnapshot])
    }

    func testFIFOQueueSerializesCrossDocumentMigrationTrimAndDeletion()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DocumentIdentity(stableKey: "path:/tmp/fifo-source.md")
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/fifo-destination.md"
        )
        let sibling = DocumentIdentity(stableKey: "path:/tmp/fifo-sibling.md")
        let sourceSnapshot = DocumentSnapshot(
            text: "source recovery\n",
            format: .newDocument
        )
        let initialSiblingSnapshot = DocumentSnapshot(
            text: "first sibling recovery\n",
            format: .newDocument
        )
        let trimmedSiblingSnapshot = DocumentSnapshot(
            text: "second sibling recovery\n",
            format: .newDocument
        )
        let migrationGate = BlockingRecoveryIOGate()
        let commandRecorder = RecoveryCommandEnqueueRecorder()
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            perDocumentLimit: 1,
            migrationWriteHook: { writeCount in
                guard writeCount == 1 else { return }
                migrationGate.blockUntilReleased()
            },
            commandEnqueueHook: { kind in
                commandRecorder.record(kind)
            }
        )
        defer { migrationGate.release() }

        let sourceSeed = try await store.add(
            snapshot: sourceSnapshot,
            for: source
        )
        let sourceEntry = try XCTUnwrap(sourceSeed.decodedEntries.first)
        let siblingSeed = try await store.add(
            snapshot: initialSiblingSnapshot,
            for: sibling
        )
        XCTAssertEqual(sourceSeed.generation, 1)
        XCTAssertEqual(siblingSeed.generation, 1)

        let migration = Task {
            try await store.moveEntries(
                from: source,
                to: destination,
                expectedRecords: DocumentSyncRecoveryRecords(
                    decoded: [sourceEntry],
                    raw: []
                ),
                expectedGeneration: sourceSeed.generation
            )
        }
        await migrationGate.waitUntilBlocked()
        XCTAssertEqual(commandRecorder.count(of: .migrate), 1)

        let snapshotCommandsBeforeSibling = commandRecorder.count(
            of: .persistSnapshot
        )
        let siblingCompletion = RecoveryTaskCompletionProbe()
        let siblingWrite = Task {
            defer { siblingCompletion.markCompleted() }
            return try await store.add(
                snapshot: trimmedSiblingSnapshot,
                for: sibling
            )
        }
        await commandRecorder.waitForCount(
            of: .persistSnapshot,
            atLeast: snapshotCommandsBeforeSibling + 1
        )
        XCTAssertFalse(siblingCompletion.isCompleted)

        migrationGate.release()
        let migrationReceipt = try await migration.value
        let siblingReceipt = try await siblingWrite.value

        XCTAssertEqual(migrationReceipt.previousGeneration, sourceSeed.generation)
        XCTAssertEqual(migrationReceipt.generation, 2)
        XCTAssertEqual(
            migrationReceipt.decodedEntries.map(\.snapshot),
            [sourceSnapshot]
        )
        XCTAssertEqual(siblingReceipt.previousGeneration, siblingSeed.generation)
        XCTAssertEqual(siblingReceipt.generation, 2)
        XCTAssertEqual(
            siblingReceipt.decodedEntries.map(\.snapshot),
            [trimmedSiblingSnapshot]
        )

        let retainedSibling = try XCTUnwrap(siblingReceipt.decodedEntries.first)
        let deletionReceipt = try await store.discardExactDecodedConflict(
            retainedSibling,
            for: sibling,
            expectedGeneration: siblingReceipt.generation
        )
        XCTAssertEqual(deletionReceipt.previousGeneration, siblingReceipt.generation)
        XCTAssertEqual(deletionReceipt.generation, 3)
        XCTAssertTrue(deletionReceipt.decodedEntries.isEmpty)
        XCTAssertEqual(commandRecorder.count(of: .discard), 1)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        let sourceAfterMove = try await reopened.latest(for: source)
        XCTAssertNil(sourceAfterMove)
        let destinationAfterMove = try await reopened.latest(for: destination)
        XCTAssertEqual(destinationAfterMove?.snapshot, sourceSnapshot)
        let siblingAfterDeletion = try await reopened.latest(for: sibling)
        XCTAssertNil(siblingAfterDeletion)
    }

    func testLargeRecoveryStartupDoesNotBlockTheMainActor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/large-startup.md")
        let snapshot = DocumentSnapshot(
            text: String(repeating: "x", count: 2 * 1_024 * 1_024),
            format: .newDocument
        )
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(snapshot: snapshot, for: identity)

        let startupGate = BlockingRecoveryIOGate()
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            startupReadHook: {
                startupGate.blockUntilReleased()
            }
        )
        defer { startupGate.release() }

        let startup = Task { try await store.start() }
        await startupGate.waitUntilBlocked()

        let heartbeat = MainActorHeartbeat()
        Task { @MainActor in
            heartbeat.record()
        }
        await heartbeat.waitForRecord()
        XCTAssertTrue(heartbeat.didRecord)
        let statusWhileBlocked = await store.status()
        XCTAssertEqual(statusWhileBlocked, .loading)

        startupGate.release()
        let imported = try await startup.value
        XCTAssertEqual(imported.records(for: identity).decoded.first?.snapshot, snapshot)
    }

    func testNewerSchemaFailsClosedWithoutReplacingThePersistedPayload()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entryID = UUID().uuidString.lowercased()
        let snapshotURL = directory.appendingPathComponent("\(entryID).snapshot.json")
        let newerPayload = Data(
            """
            {"schemaVersion":999,"id":"\(entryID)","stableKey":"path:/tmp/newer.md","text":"preserve","encoding":"utf8","newline":"lf","hasFinalNewline":false,"createdAt":0}
            """.utf8
        )
        try newerPayload.write(to: snapshotURL)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await store.start()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .unsupportedSchema)
        }
        let failedStatus = await store.status()
        XCTAssertEqual(failedStatus, .failed(.unsupportedSchema))
        XCTAssertEqual(try Data(contentsOf: snapshotURL), newerPayload)
    }

    func testOrphanRawPayloadFailsClosedWithoutDiscardingItsBytes()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadURL = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).raw"
        )
        let payload = Data([0xFF, 0x00, 0xC0])
        try payload.write(to: payloadURL)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await store.start()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .malformedData)
        }

        XCTAssertEqual(try Data(contentsOf: payloadURL), payload)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private enum ReconciliationInjectedError: Error {
    case afterAtomicSwap
    case acknowledgementInterrupted
}

@MainActor
private func reconcileCommit(
    _ request: DocumentSyncCommitReconciliationRequest,
    in recoveryDirectory: URL,
    acknowledgementHook: @escaping @Sendable (
        CommitRecoveryAcknowledgementPhase
    ) throws -> Void
) async -> DocumentSyncCommitReconciliationResult {
    do {
        return try await DocumentFileAccess.perform {
            try CommitRecoveryJournalStore.reconcileCommit(
                request,
                in: recoveryDirectory,
                acknowledgementHook: acknowledgementHook
            )
        }
    } catch {
        return .unresolved
    }
}

private func rewriteCommitJournal(
    at url: URL,
    mutate: (inout [String: Any]) -> Void
) throws {
    var journal = try commitJournalObject(at: url)
    mutate(&journal)
    let data = try JSONSerialization.data(
        withJSONObject: journal,
        options: [.sortedKeys]
    )
    try data.write(to: url)
}

private func commitJournalObject(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
    )
}

private struct ReconciliationFixture {
    let directory: URL
    let recoveryDirectory: URL
    let targetURL: URL
    let original: Data
    let updated: Data
    let identity: DocumentIdentity
    let baseline: DocumentSyncDurableBaseline
    let pendingSave: PendingSaveToken
    let commitToken: SyncEffectToken

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        recoveryDirectory = directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        targetURL = directory.appendingPathComponent("managed.md")
        original = Data("base\n".utf8)
        updated = Data("local\n".utf8)
        identity = DocumentIdentity.make(url: targetURL)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try original.write(to: targetURL)
        let sourceRevision = SourceRevision(number: 1, text: "base\n")
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: targetURL,
            data: original
        )
        baseline = try TextFileCodec.durableBaseline(
            data: original,
            targetURL: targetURL,
            fingerprint: fingerprint,
            documentIdentity: identity,
            sourceRevision: sourceRevision,
            commitGeneration: 1
        )
        pendingSave = PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: "local\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(updated)
            ),
            expectedDurableState: baseline.asDurableFileState,
            targetURL: targetURL
        )
        commitToken = SyncEffectToken(
            lifetime: UUID(),
            attachmentEpoch: 1,
            operation: .saveCommit,
            attempt: 1
        )
    }

    func committer(
        beforeAtomicSwap: (@Sendable () throws -> Void)? = nil,
        afterAtomicSwap: (@Sendable () throws -> Void)? = nil
    ) -> SafeFileCommitter {
        SafeFileCommitter(
            recoveryDirectory: recoveryDirectory,
            beforeAtomicSwap: beforeAtomicSwap,
            afterAtomicSwap: afterAtomicSwap
        )
    }

    func prepareUnswappedJournal() throws -> CommitRecoveryArtifact {
        let replacementDirectory = directory.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let candidateURL = replacementDirectory.appendingPathComponent(
            "candidate"
        )
        try updated.write(to: candidateURL)
        return try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: targetURL,
            requestedTargetURL: targetURL,
            documentIdentity: identity,
            commitGeneration: pendingSave.generation,
            expectedPreimageFingerprint: baseline.fingerprint,
            committedPayloadFingerprint: pendingSave.contentFingerprint,
            recoveryDirectory: recoveryDirectory
        )
    }

    func request(
        identity requestedIdentity: DocumentIdentity? = nil,
        targetURL requestedTargetURL: URL? = nil,
        commitGeneration: UInt64? = nil,
        pendingSave requestedPendingSave: PendingSaveToken? = nil,
        expectedBaseline requestedBaseline: DocumentSyncDurableBaseline? = nil,
        token requestedToken: SyncEffectToken? = nil
    ) -> DocumentSyncCommitReconciliationRequest {
        DocumentSyncCommitReconciliationRequest(
            token: requestedToken ?? effectToken(attempt: 2),
            originalCommitToken: commitToken,
            pendingSave: requestedPendingSave ?? pendingSave,
            targetURL: requestedTargetURL ?? targetURL,
            identity: requestedIdentity ?? identity,
            attachmentEpoch: 1,
            expectedBaseline: requestedBaseline ?? baseline,
            commitGeneration: commitGeneration ?? pendingSave.generation
        )
    }

    func effectToken(attempt: UInt64) -> SyncEffectToken {
        SyncEffectToken(
            lifetime: commitToken.lifetime,
            attachmentEpoch: 1,
            operation: .commitReconciliation,
            attempt: attempt
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class BlockingRecoveryIOGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var hasEntered = false
    private var hasReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() {
        let waiters: [CheckedContinuation<Void, Never>]
        let shouldBlock: Bool
        lock.lock()
        hasEntered = true
        waiters = entryWaiters
        entryWaiters.removeAll()
        shouldBlock = !hasReleased
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
                return
            }
            entryWaiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        let shouldSignal: Bool
        lock.lock()
        if hasReleased {
            lock.unlock()
            return
        }
        hasReleased = true
        shouldSignal = hasEntered
        lock.unlock()

        if shouldSignal {
            releaseSemaphore.signal()
        }
    }
}

private final class RecoveryCommandEnqueueRecorder: @unchecked Sendable {
    private struct Waiter {
        let kind: SessionRecoveryStoreCommandKind
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var kinds: [SessionRecoveryStoreCommandKind] = []
    private var waiters: [Waiter] = []

    func record(_ kind: SessionRecoveryStoreCommandKind) {
        var readyWaiters: [Waiter] = []
        var remainingWaiters: [Waiter] = []
        lock.lock()
        kinds.append(kind)
        let currentCount = count(of: kind, in: kinds)
        for waiter in waiters {
            if waiter.kind == kind && currentCount >= waiter.minimumCount {
                readyWaiters.append(waiter)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        waiters = remainingWaiters
        lock.unlock()

        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func count(of kind: SessionRecoveryStoreCommandKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count(of: kind, in: kinds)
    }

    func waitForCount(
        of kind: SessionRecoveryStoreCommandKind,
        atLeast minimumCount: Int
    ) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count(of: kind, in: kinds) >= minimumCount {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(
                Waiter(
                    kind: kind,
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            )
            lock.unlock()
        }
    }

    private func count(
        of kind: SessionRecoveryStoreCommandKind,
        in recordedKinds: [SessionRecoveryStoreCommandKind]
    ) -> Int {
        recordedKinds.filter { $0 == kind }.count
    }
}

private final class RecoveryTaskCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

@MainActor
private final class MainActorHeartbeat {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didRecord = false

    func record() {
        didRecord = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitForRecord() async {
        if didRecord { return }
        await withCheckedContinuation { continuation in
            if didRecord {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: @MainActor (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error, but the operation succeeded.")
    } catch {
        handler(error)
    }
}
