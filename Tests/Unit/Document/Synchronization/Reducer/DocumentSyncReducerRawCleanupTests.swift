import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testRestoringDecodedRecoveryPreservesRawRecordsUntilExplicitDiscard() throws {
        var recoverable = makeState()
        let olderEntry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(
                text: "older-decoded-recovery",
                format: .newDocument
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 44)
        )
        let latestEntry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(
                text: "restore-decoded-and-raw",
                format: .newDocument
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 45)
        )
        let firstRaw = rawRecoveryReference(
            id: UUID(),
            identity: identity(),
            data: Data("first-unrelated-raw".utf8)
        )
        let secondRaw = rawRecoveryReference(
            id: UUID(),
            identity: identity(),
            data: Data("second-unrelated-raw".utf8)
        )
        let records = DocumentSyncRecoveryRecords(
            decoded: [latestEntry, olderEntry],
            raw: [firstRaw, secondRaw]
        )
        recoverable.recovery = .available(records)

        let restored = DocumentSyncReducer.reduce(
            recoverable,
            event: .restoreLocalRecovery
        )
        XCTAssertEqual(restored.state.snapshot, latestEntry.snapshot)
        XCTAssertEqual(
            restored.state.recoveryCleanup?.target,
            .decoded(latestEntry)
        )
        let deadline = try XCTUnwrap(
            deadline(in: restored.effects, kind: .localSave)
        )
        let preparing = DocumentSyncReducer.reduce(
            restored.state,
            event: .deadlineFired(deadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let pending = PendingSaveToken(
            generation: preparation.commitGeneration,
            sourceRevision: preparation.sourceRevision,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: preparation.snapshot
            ),
            expectedDurableState: preparation.expectedBaseline?.asDurableFileState,
            targetURL: preparation.targetURL
        )
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(token: preparation.token, pendingSave: pending)
        )
        let commit = try XCTUnwrap(commitRequest(in: writing.effects))
        let saved = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: commit.commitGeneration,
                        committedFingerprint: fingerprint(
                            preparation.snapshot.text,
                            resource: "selected-recovery-cleanup"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: saved.effects))
        XCTAssertEqual(discard.target, .decoded(latestEntry))
        let recordsAfterRestoreCleanup = DocumentSyncRecoveryRecords(
            decoded: [olderEntry],
            raw: [firstRaw, secondRaw]
        )
        let cleaned = DocumentSyncReducer.reduce(
            saved.state,
            event: .recoveryFinished(
                token: discard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: discard.expectedStoreGeneration,
                        generation: discard.expectedStoreGeneration + 1,
                        records: recordsAfterRestoreCleanup
                    )
                )
            )
        )
        XCTAssertNil(cleaned.state.recoveryCleanup)
        XCTAssertEqual(
            cleaned.state.recovery,
            .available(recordsAfterRestoreCleanup)
        )

        let rawDiscarding = DocumentSyncReducer.reduce(
            cleaned.state,
            event: .discardRawRecovery
        )
        let rawDiscard = try XCTUnwrap(
            recoveryDiscardRequest(in: rawDiscarding.effects)
        )
        XCTAssertEqual(rawDiscard.target, .raw([firstRaw, secondRaw]))
        let explicitlyDiscarded = DocumentSyncReducer.reduce(
            rawDiscarding.state,
            event: .recoveryFinished(
                token: rawDiscard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: rawDiscard.expectedStoreGeneration,
                        generation: rawDiscard.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: [olderEntry],
                            raw: []
                        )
                    )
                )
            )
        )
        XCTAssertEqual(
            explicitlyDiscarded.state.recovery,
            .available(
                DocumentSyncRecoveryRecords(
                    decoded: [olderEntry],
                    raw: []
                ))
        )
    }

    func testDecodedCleanupRetainsRawRecoveryAfterDirectPersistence() throws {
        let scenario = try restoredRecoveryWithUnexpectedRawPersistence()
        let newRaw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let recordsWithNewRaw = DocumentSyncRecoveryRecords(
            decoded: [scenario.entry],
            raw: [scenario.oldRaw, newRaw]
        )
        let persisted = DocumentSyncReducer.reduce(
            scenario.persisting.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: scenario.request.expectedStoreGeneration,
                            generation: scenario.request.expectedStoreGeneration + 1,
                            records: recordsWithNewRaw
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        XCTAssertEqual(
            persisted.state.recoveryCleanup?.target,
            .decoded(scenario.entry)
        )
        XCTAssertEqual(
            persisted.state.recoveryCleanup?.records,
            recordsWithNewRaw
        )
        let cleanupDiscard = try XCTUnwrap(
            recoveryDiscardRequest(in: persisted.effects)
        )
        XCTAssertEqual(cleanupDiscard.target, .decoded(scenario.entry))
        let afterCleanup = DocumentSyncReducer.reduce(
            persisted.state,
            event: .recoveryFinished(
                token: cleanupDiscard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: cleanupDiscard.expectedStoreGeneration,
                        generation: cleanupDiscard.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: [],
                            raw: [scenario.oldRaw, newRaw]
                        )
                    )
                )
            )
        )
        XCTAssertNil(afterCleanup.state.recoveryCleanup)
        XCTAssertEqual(
            afterCleanup.state.unresolvedDisplacedPreimage?.entryID,
            newRaw.id
        )
        let rawDiscarding = DocumentSyncReducer.reduce(
            afterCleanup.state,
            event: .discardRawRecovery
        )
        let rawDiscard = try XCTUnwrap(
            recoveryDiscardRequest(in: rawDiscarding.effects)
        )
        XCTAssertEqual(rawDiscard.target, .raw([scenario.oldRaw, newRaw]))
        let cleared = DocumentSyncReducer.reduce(
            rawDiscarding.state,
            event: .recoveryFinished(
                token: rawDiscard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: rawDiscard.expectedStoreGeneration,
                        generation: rawDiscard.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(cleared.state.recovery, .clear)
        XCTAssertNil(cleared.state.unresolvedDisplacedPreimage)
    }

    func testDecodedCleanupRetainsRawRecoveryAfterReconciliation() throws {
        let scenario = try restoredRecoveryWithUnexpectedRawPersistence()
        let failed = DocumentSyncReducer.reduce(
            scenario.persisting.state,
            event: .operationFailed(
                token: scenario.request.token,
                failure: .recovery
            )
        )
        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        let newRaw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let recordsWithNewRaw = DocumentSyncRecoveryRecords(
            decoded: [scenario.entry],
            raw: [scenario.oldRaw, newRaw]
        )
        let reconciled = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: scenario.request.expectedStoreGeneration + 1,
                        records: recordsWithNewRaw,
                        acknowledgedRecoveryArtifact: scenario.artifact
                    )
                )
            )
        )
        XCTAssertEqual(
            reconciled.state.recoveryCleanup?.target,
            .decoded(scenario.entry)
        )
        XCTAssertEqual(
            reconciled.state.recoveryCleanup?.records,
            recordsWithNewRaw
        )
        let cleanupDiscard = try XCTUnwrap(
            recoveryDiscardRequest(in: reconciled.effects)
        )
        XCTAssertEqual(cleanupDiscard.target, .decoded(scenario.entry))
        let afterCleanup = DocumentSyncReducer.reduce(
            reconciled.state,
            event: .recoveryFinished(
                token: cleanupDiscard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: cleanupDiscard.expectedStoreGeneration,
                        generation: cleanupDiscard.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: [],
                            raw: [scenario.oldRaw, newRaw]
                        )
                    )
                )
            )
        )
        XCTAssertNil(afterCleanup.state.recoveryCleanup)
        XCTAssertNotNil(
            recoveryDiscardRequest(
                in: DocumentSyncReducer.reduce(
                    afterCleanup.state,
                    event: .discardRawRecovery
                ).effects))
    }

    func testDecodedCleanupMigratesWithoutSelectingRawRecovery() throws {
        let scenario = try restoredRecoveryWithUnexpectedRawPersistence()
        let destinationURL = URL(fileURLWithPath: "/tmp/selected-cleanup-moved.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let destinationBaseline = durableBaseline(
            for: scenario.persisting.state.snapshot,
            targetURL: destinationURL,
            identity: destination,
            sourceRevision: scenario.persisting.state.source,
            resource: "selected-cleanup-destination"
        )
        let moved = DocumentSyncReducer.reduce(
            scenario.persisting.state,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: destinationBaseline
            )
        )
        let newRawAtOrigin = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let originRecords = DocumentSyncRecoveryRecords(
            decoded: [scenario.entry],
            raw: [scenario.oldRaw, newRawAtOrigin]
        )
        let rawPersisted = DocumentSyncReducer.reduce(
            moved.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: scenario.request.expectedStoreGeneration,
                            generation: scenario.request.expectedStoreGeneration + 1,
                            records: originRecords
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: rawPersisted.effects))
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        let migratedRecords = migratedRecoveryRecords(originRecords, to: destination)
        let migrated = DocumentSyncReducer.reduce(
            rawPersisted.state,
            event: .recoveryFinished(
                token: migration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: migration.expectedStoreGeneration,
                        generation: migration.expectedStoreGeneration + 1,
                        records: migratedRecords
                    )
                )
            )
        )
        let migratedOriginalRecords = migratedRecoveryRecords(
            scenario.originalRecords,
            to: destination
        )
        let migratedEntry = try XCTUnwrap(migratedOriginalRecords.decoded.first)
        XCTAssertEqual(
            migrated.state.recoveryCleanup?.target,
            .decoded(migratedEntry)
        )
        let cleanupDiscard = try XCTUnwrap(
            recoveryDiscardRequest(in: migrated.effects)
        )
        XCTAssertEqual(cleanupDiscard.identity, destination)
        XCTAssertEqual(cleanupDiscard.target, .decoded(migratedEntry))
        let afterCleanup = DocumentSyncReducer.reduce(
            migrated.state,
            event: .recoveryFinished(
                token: cleanupDiscard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: cleanupDiscard.expectedStoreGeneration,
                        generation: cleanupDiscard.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: [],
                            raw: migratedRecords.raw
                        )
                    )
                )
            )
        )
        XCTAssertNil(afterCleanup.state.recoveryCleanup)
        XCTAssertEqual(
            afterCleanup.state.recovery,
            .available(
                DocumentSyncRecoveryRecords(
                    decoded: [],
                    raw: migratedRecords.raw
                ))
        )
    }

    func testRestoreLocalRecoveryRejectsUnresolvedAndWritingStates() throws {
        let unresolvedScenario = try unexpectedPreimagePersistence()
        var unresolved = makeState()
        let entry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(
                text: "unresolved-restore",
                format: .newDocument
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 46)
        )
        let raw = rawRecoveryReference(
            id: UUID(),
            identity: identity(),
            data: Data("unresolved-restore-raw".utf8)
        )
        unresolved.recovery = .available(
            DocumentSyncRecoveryRecords(decoded: [entry], raw: [raw])
        )
        unresolved.unresolvedDisplacedPreimage = try XCTUnwrap(
            unresolvedScenario.request.displacedPreimageContinuation
        )
        let rejectedUnresolved = DocumentSyncReducer.reduce(
            unresolved,
            event: .restoreLocalRecovery
        )
        XCTAssertEqual(rejectedUnresolved.state, unresolved)
        XCTAssertTrue(rejectedUnresolved.effects.isEmpty)

        let recoverable = makeState()
        let edited = DocumentSyncReducer.reduce(
            recoverable,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "write-before-restore"),
                format: .newDocument
            )
        )
        let preparing = DocumentSyncReducer.reduce(
            edited.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: edited.effects, kind: .localSave))
            )
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(
                token: preparation.token,
                pendingSave: PendingSaveToken(
                    generation: preparation.commitGeneration,
                    sourceRevision: preparation.sourceRevision,
                    preparedPayload: try TextFileCodec.prepareSavePayload(
                        for: preparation.snapshot
                    ),
                    expectedDurableState: preparation.expectedBaseline?
                        .asDurableFileState,
                    targetURL: preparation.targetURL
                )
            )
        )
        var writingWithRecovery = writing.state
        writingWithRecovery.recovery = .available(
            DocumentSyncRecoveryRecords(decoded: [entry], raw: [])
        )
        let rejectedWriting = DocumentSyncReducer.reduce(
            writingWithRecovery,
            event: .restoreLocalRecovery
        )
        XCTAssertEqual(rejectedWriting.state, writingWithRecovery)
        XCTAssertTrue(rejectedWriting.effects.isEmpty)
    }

}
