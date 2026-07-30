import Foundation
import XCTest
@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testSameIdentityReattachRetainsTargetedRecoveryCleanup() throws {
        var recoverable = makeState()
        let entry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(
                text: "restore-before-same-identity-reattach",
                format: .newDocument
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 40)
        )
        let records = DocumentSyncRecoveryRecords(decoded: [entry], raw: [])
        recoverable.recovery = .available(records)
        let restored = DocumentSyncReducer.reduce(
            recoverable,
            event: .restoreLocalRecovery
        )
        let reattached = DocumentSyncReducer.reduce(
            restored.state,
            event: .attach(
                identity: identity(),
                url: documentURL,
                durableBaseline: restored.state.durableBaseline
            )
        )
        let load = try XCTUnwrap(recoveryLoadRequest(in: reattached.effects))
        XCTAssertEqual(reattached.state.recoveryCleanup?.target, .decoded(entry))

        let loaded = DocumentSyncReducer.reduce(
            reattached.state,
            event: .recoveryFinished(
                token: load.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: .document(identity()),
                        generation: 5,
                        records: records
                    )
                )
            )
        )
        XCTAssertEqual(loaded.state.recoveryCleanup?.target, .decoded(entry))
        let saveDeadline = try XCTUnwrap(
            deadline(in: loaded.effects, kind: .localSave)
        )
        let preparing = DocumentSyncReducer.reduce(
            loaded.state,
            event: .deadlineFired(saveDeadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let pending = PendingSaveToken(
            generation: preparation.commitGeneration,
            sourceRevision: preparation.sourceRevision,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: preparation.snapshot
            ),
            expectedDurableState: loaded.state.durableBaseline?.asDurableFileState,
            targetURL: documentURL
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
                        generation: pending.generation,
                        committedFingerprint: fingerprint(
                            preparation.snapshot.text,
                            resource: "same-identity-recovery-cleanup"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: saved.effects))
        XCTAssertEqual(discard.target, .decoded(entry))
        let cleaned = DocumentSyncReducer.reduce(
            saved.state,
            event: .recoveryFinished(
                token: discard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: discard.expectedStoreGeneration,
                        generation: discard.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertNil(cleaned.state.recoveryCleanup)
        XCTAssertEqual(
            closeResolution(
                in: DocumentSyncReducer.reduce(cleaned.state, event: .requestClose).effects
            )?.disposition,
            .allowManagedClose
        )
    }

    func testMovedRawWriteRetriesAtItsOriginThenMigratesAfterAbsentReconciliation() throws {
        let scenario = try unexpectedPreimagePersistence()
        let destinationURL = URL(fileURLWithPath: "/tmp/moved-raw-preimage.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertEqual(
            moved.state.recoveryMutationBarrier?.relocationDestination,
            destination
        )
        let failed = DocumentSyncReducer.reduce(
            moved.state,
            event: .operationFailed(token: scenario.request.token, failure: .recovery)
        )
        XCTAssertEqual(
            failed.state.recoveryMutationBarrier?.relocationDestination,
            destination
        )
        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        XCTAssertEqual(
            retried.state.recoveryMutationBarrier?.relocationDestination,
            destination
        )
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        let reissued = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: scenario.request.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        let retryPersistence = try XCTUnwrap(
            recoveryPersistRequest(in: reissued.effects)
        )
        XCTAssertEqual(
            reissued.state.recoveryMutationBarrier?.relocationDestination,
            destination
        )
        XCTAssertEqual(retryPersistence.identity, identity())
        XCTAssertEqual(retryPersistence.entryID, scenario.request.entryID)
        XCTAssertEqual(retryPersistence.rawPayload?.data, scenario.rawData)
        XCTAssertEqual(
            retryPersistence.rawPayload?.recoveryArtifact,
            scenario.artifact
        )

        let raw = rawRecoveryReference(
            id: retryPersistence.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let stored = DocumentSyncReducer.reduce(
            reissued.state,
            event: .recoveryFinished(
                token: retryPersistence.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: retryPersistence.expectedStoreGeneration,
                            generation: retryPersistence.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: retryPersistence.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: stored.effects))
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        XCTAssertEqual(migration.records, DocumentSyncRecoveryRecords(
            decoded: [],
            raw: [raw]
        ))
        let migratedRecords = migratedRecoveryRecords(
            DocumentSyncRecoveryRecords(decoded: [], raw: [raw]),
            to: destination
        )
        let migrated = DocumentSyncReducer.reduce(
            stored.state,
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
        XCTAssertEqual(migrated.state.recovery, .available(migratedRecords))
        XCTAssertEqual(
            migrated.state.unresolvedDisplacedPreimage?.entryID,
            scenario.request.entryID
        )
    }

    func testDetachedRawWriteCompletionLeavesEvidenceAtTheOriginalIdentity() throws {
        let scenario = try unexpectedPreimagePersistence()
        let detached = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .detach
        )
        let destinationURL = URL(fileURLWithPath: "/tmp/unrelated-attachment.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let attached = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertNil(attached.state.recoveryMutationBarrier?.relocationDestination)
        XCTAssertNil(recoveryLoadRequest(in: attached.effects))
        let raw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let completed = DocumentSyncReducer.reduce(
            attached.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: scenario.request.expectedStoreGeneration,
                            generation: scenario.request.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        XCTAssertEqual(completed.state.recovery, .clear)
        XCTAssertNil(completed.state.unresolvedDisplacedPreimage)
        XCTAssertEqual(
            completed.state.fileAttachment?.identity,
            destination
        )
        XCTAssertNil(recoveryMigrationRequest(in: completed.effects))
        XCTAssertEqual(completed.state.recoveryAccess, .loading)
        XCTAssertNil(deadline(in: completed.effects, kind: .localSave))
        let load = try XCTUnwrap(recoveryLoadRequest(in: completed.effects))
        XCTAssertEqual(load.scope, .document(destination))
        let destinationRaw = rawRecoveryReference(
            id: UUID(),
            identity: destination,
            data: Data("destination raw recovery".utf8)
        )
        let loaded = DocumentSyncReducer.reduce(
            completed.state,
            event: .recoveryFinished(
                token: load.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: .document(destination),
                        generation: 9,
                        records: DocumentSyncRecoveryRecords(
                            decoded: [],
                            raw: [destinationRaw]
                        )
                    )
                )
            )
        )
        XCTAssertEqual(loaded.state.recoveryAccess, .ready(generation: 9))
        XCTAssertEqual(loaded.state.statusProjection.presentedState, .synchronizationPaused)
        XCTAssertNil(deadline(in: loaded.effects, kind: .localSave))
    }

    func testSameIdentityReattachKeepsAnInFlightRawWriteUnresolved() throws {
        let scenario = try unexpectedPreimagePersistence()
        let detached = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .detach
        )
        let reattached = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: identity(),
                url: documentURL,
                durableBaseline: nil
            )
        )
        XCTAssertEqual(
            reattached.state.recoveryMutationBarrier?.relocationDestination,
            identity()
        )
        let raw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let completed = DocumentSyncReducer.reduce(
            reattached.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: scenario.request.expectedStoreGeneration,
                            generation: scenario.request.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )

        XCTAssertEqual(
            completed.state.recovery,
            .available(DocumentSyncRecoveryRecords(decoded: [], raw: [raw]))
        )
        XCTAssertEqual(
            completed.state.unresolvedDisplacedPreimage?.entryID,
            scenario.request.entryID
        )
        XCTAssertEqual(completed.state.issue?.failure, .recovery)
        XCTAssertNil(recoveryMigrationRequest(in: completed.effects))
    }

    func testDetachedRawDiscardRetainsOnlyItsLastConfirmedAttachment() throws {
        let scenario = try unexpectedPreimagePersistence()
        let rawAtOrigin = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let persisted = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: scenario.request.expectedStoreGeneration,
                            generation: scenario.request.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [rawAtOrigin]
                            )
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        let destinationURL = URL(fileURLWithPath: "/tmp/migrated-raw-discard.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            persisted.state,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: moved.effects))
        let rawAtDestination = migratedRecoveryRecords(
            DocumentSyncRecoveryRecords(decoded: [], raw: [rawAtOrigin]),
            to: destination
        )
        let migrated = DocumentSyncReducer.reduce(
            moved.state,
            event: .recoveryFinished(
                token: migration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: migration.expectedStoreGeneration,
                        generation: migration.expectedStoreGeneration + 1,
                        records: rawAtDestination
                    )
                )
            )
        )
        let discarding = DocumentSyncReducer.reduce(
            migrated.state,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))

        let reattachedAtDestination = DocumentSyncReducer.reduce(
            DocumentSyncReducer.reduce(discarding.state, event: .detach).state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertEqual(
            reattachedAtDestination.state.recoveryMutationBarrier?.relocationDestination,
            destination
        )
        let failedAtDestination = DocumentSyncReducer.reduce(
            reattachedAtDestination.state,
            event: .operationFailed(token: discard.token, failure: .recovery)
        )
        let retryAtDestination = DocumentSyncReducer.reduce(
            failedAtDestination.state,
            event: .retry
        )
        let reconcileAtDestination = try XCTUnwrap(
            recoveryReconciliationRequest(in: retryAtDestination.effects)
        )
        let foundAtDestination = DocumentSyncReducer.reduce(
            retryAtDestination.state,
            event: .recoveryFinished(
                token: reconcileAtDestination.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: destination,
                        generation: discard.expectedStoreGeneration + 1,
                        records: rawAtDestination
                    )
                )
            )
        )
        XCTAssertEqual(foundAtDestination.state.recovery, .available(rawAtDestination))
        XCTAssertEqual(
            foundAtDestination.state.unresolvedDisplacedPreimage?.entryID,
            scenario.request.entryID
        )
        XCTAssertNil(recoveryMigrationRequest(in: foundAtDestination.effects))

        let unrelatedURL = URL(fileURLWithPath: "/tmp/unrelated-raw-discard.md")
        let unrelated = DocumentIdentity.make(url: unrelatedURL)
        let attachedElsewhere = DocumentSyncReducer.reduce(
            DocumentSyncReducer.reduce(discarding.state, event: .detach).state,
            event: .attach(
                identity: unrelated,
                url: unrelatedURL,
                durableBaseline: nil
            )
        )
        XCTAssertNil(attachedElsewhere.state.recoveryMutationBarrier?.relocationDestination)
        let failedElsewhere = DocumentSyncReducer.reduce(
            attachedElsewhere.state,
            event: .operationFailed(token: discard.token, failure: .recovery)
        )
        let retryElsewhere = DocumentSyncReducer.reduce(
            failedElsewhere.state,
            event: .retry
        )
        let reconcileElsewhere = try XCTUnwrap(
            recoveryReconciliationRequest(in: retryElsewhere.effects)
        )
        let foundElsewhere = DocumentSyncReducer.reduce(
            retryElsewhere.state,
            event: .recoveryFinished(
                token: reconcileElsewhere.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: destination,
                        generation: discard.expectedStoreGeneration + 1,
                        records: rawAtDestination
                    )
                )
            )
        )
        XCTAssertEqual(foundElsewhere.state.recovery, .clear)
        XCTAssertNil(foundElsewhere.state.unresolvedDisplacedPreimage)
        XCTAssertNil(recoveryMigrationRequest(in: foundElsewhere.effects))
        XCTAssertEqual(foundElsewhere.state.fileAttachment?.identity, unrelated)
    }

    func testNewerEditDuringRawPersistenceRecordsTheCommittedBaselineBeforeDiscard() throws {
        let scenario = try unexpectedPreimagePersistence()
        let continuation = try XCTUnwrap(
            scenario.request.displacedPreimageContinuation
        )
        let newerRevision = SourceRevision(
            number: 9,
            text: "newer-after-raw-persistence"
        )
        let edited = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .sourceChanged(newerRevision, format: .newDocument)
        )
        let raw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let persisted = DocumentSyncReducer.reduce(
            edited.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: scenario.request.expectedStoreGeneration,
                            generation: scenario.request.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        XCTAssertEqual(
            persisted.state.durableBaseline,
            continuation.committedBaseline
        )
        XCTAssertEqual(persisted.state.source, newerRevision)
        XCTAssertTrue(persisted.state.local.isDirty)

        let discarding = DocumentSyncReducer.reduce(
            persisted.state,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))
        let discarded = DocumentSyncReducer.reduce(
            discarding.state,
            event: .recoveryFinished(
                token: discard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: discard.expectedStoreGeneration,
                        generation: discard.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(discarded.state.recovery, .clear)
        XCTAssertNil(discarded.state.unresolvedDisplacedPreimage)
        XCTAssertTrue(discarded.state.local.isDirty)
        let preparation = DocumentSyncReducer.reduce(
            discarded.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: discarded.effects, kind: .localSave))
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(prepareRequest(in: preparation.effects)).expectedBaseline,
            continuation.committedBaseline
        )
    }

    func testRawReconciliationAfterANewerEditRecordsTheCommittedBaselineBeforeDiscard() throws {
        let scenario = try unexpectedPreimagePersistence()
        let continuation = try XCTUnwrap(
            scenario.request.displacedPreimageContinuation
        )
        let edited = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .sourceChanged(
                SourceRevision(number: 9, text: "newer-after-lost-raw-result"),
                format: .newDocument
            )
        )
        let failed = DocumentSyncReducer.reduce(
            edited.state,
            event: .operationFailed(token: scenario.request.token, failure: .recovery)
        )
        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        let raw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let reconciled = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: scenario.request.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: [],
                            raw: [raw]
                        ),
                        acknowledgedRecoveryArtifact: scenario.artifact
                    )
                )
            )
        )
        XCTAssertEqual(
            reconciled.state.durableBaseline,
            continuation.committedBaseline
        )
        XCTAssertTrue(reconciled.state.local.isDirty)

        let discarding = DocumentSyncReducer.reduce(
            reconciled.state,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))
        let discarded = DocumentSyncReducer.reduce(
            discarding.state,
            event: .recoveryFinished(
                token: discard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: discard.expectedStoreGeneration,
                        generation: discard.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(discarded.state.recovery, .clear)
        XCTAssertNil(discarded.state.unresolvedDisplacedPreimage)
        XCTAssertTrue(discarded.state.local.isDirty)
        let reading = DocumentSyncReducer.reduce(
            discarded.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: discarded.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        XCTAssertEqual(read.expectedBaseline, continuation.committedBaseline)
        let rescheduled = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .unchanged(
                    externalObservation(
                        continuation.committedBaseline.snapshot,
                        targetURL: read.targetURL,
                        identity: read.identity,
                        fingerprint: continuation.committedBaseline.fingerprint
                    )
                )
            )
        )
        let preparation = DocumentSyncReducer.reduce(
            rescheduled.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: rescheduled.effects, kind: .localSave))
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(prepareRequest(in: preparation.effects)).expectedBaseline,
            continuation.committedBaseline
        )
    }

}
