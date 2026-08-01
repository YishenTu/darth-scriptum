import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testReconciledRestoredRecoveryDiscardClearsCompletedCleanup() throws {
        var recovering = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: recovering.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 26)
            ),
            raw: nil
        )
        let discardToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: recovering.attachmentEpoch,
            operation: .recovery,
            attempt: 92
        )
        recovering.recoveryCleanup = DocumentSyncRecoveryCleanup(
            records: records,
            minimumSourceRevision: recovering.source
        )
        recovering.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: discardToken,
                identity: identity(),
                expectedStoreGeneration: 4,
                purpose: .discardRestoredRecords,
                expectedRecords: records,
                discardTarget: .records(records)
            )
        )
        recovering.activeTokens[.recovery] = discardToken

        let failed = DocumentSyncReducer.reduce(
            recovering,
            event: .operationFailed(token: discardToken, failure: .recovery)
        )
        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        let reconciled = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: 5,
                        records: .empty
                    )
                )
            )
        )

        XCTAssertNil(reconciled.state.recoveryCleanup)
        XCTAssertEqual(reconciled.state.recovery, .clear)
        XCTAssertNil(recoveryDiscardRequest(in: reconciled.effects))
    }

    func testMovedRestoredRecoveryDiscardRetriesWithReconciledRecords() throws {
        var recovering = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: recovering.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 27)
            ),
            raw: nil
        )
        let discardToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: recovering.attachmentEpoch,
            operation: .recovery,
            attempt: 93
        )
        recovering.recoveryCleanup = DocumentSyncRecoveryCleanup(
            records: records,
            minimumSourceRevision: recovering.source
        )
        recovering.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: discardToken,
                identity: identity(),
                expectedStoreGeneration: 4,
                purpose: .discardRestoredRecords,
                expectedRecords: records,
                discardTarget: .records(records)
            )
        )
        recovering.activeTokens[.recovery] = discardToken

        let destinationURL = URL(fileURLWithPath: "/tmp/moved-restored-discard.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let destinationBaseline = durableBaseline(
            for: recovering.snapshot,
            targetURL: destinationURL,
            identity: destination,
            sourceRevision: recovering.source,
            resource: "moved-restored-discard-destination"
        )
        let moved = DocumentSyncReducer.reduce(
            recovering,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: destinationBaseline
            )
        )
        let failed = DocumentSyncReducer.reduce(
            moved.state,
            event: .operationFailed(token: discardToken, failure: .recovery)
        )
        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        let reconciled = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: 5,
                        records: records
                    )
                )
            )
        )
        let migration = try XCTUnwrap(
            recoveryMigrationRequest(in: reconciled.effects)
        )
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)

        let migratedRecords = migratedRecoveryRecords(records, to: destination)
        let migrated = DocumentSyncReducer.reduce(
            reconciled.state,
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
        let retryDiscard = try XCTUnwrap(
            recoveryDiscardRequest(in: migrated.effects)
        )
        XCTAssertEqual(retryDiscard.identity, destination)
        XCTAssertEqual(retryDiscard.target, .records(migratedRecords))

        let discarded = DocumentSyncReducer.reduce(
            migrated.state,
            event: .recoveryFinished(
                token: retryDiscard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: retryDiscard.expectedStoreGeneration,
                        generation: retryDiscard.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertNil(discarded.state.recoveryCleanup)
        XCTAssertEqual(discarded.state.recovery, .clear)
    }

    func testMovingRestoredRecoveryKeepsCleanupUntilTheNewAttachmentIsSaved() throws {
        var recoverable = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: DocumentSnapshot(
                    text: "restored before move",
                    format: .newDocument
                ),
                createdAt: Date(timeIntervalSinceReferenceDate: 29)
            ),
            raw: nil
        )
        recoverable.recovery = .available(records)

        let restored = DocumentSyncReducer.reduce(
            recoverable,
            event: .restoreLocalRecovery
        )
        let restoredRevision = restored.state.source
        XCTAssertNotNil(deadline(in: restored.effects, kind: .localSave))

        let destinationURL = URL(fileURLWithPath: "/tmp/restored-recovery-moved.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let destinationBaseline = durableBaseline(
            for: DocumentSnapshot(text: "base", format: .newDocument),
            targetURL: destinationURL,
            identity: destination,
            sourceRevision: SourceRevision(number: 7, text: "base"),
            resource: "restored-recovery-moved-baseline"
        )
        let moved = DocumentSyncReducer.reduce(
            restored.state,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: destinationBaseline
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: moved.effects))
        XCTAssertEqual(moved.state.recoveryCleanup?.records, records)

        let migratedRecords = migratedRecoveryRecords(records, to: destination)
        let migrated = DocumentSyncReducer.reduce(
            moved.state,
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
        XCTAssertEqual(migrated.state.recoveryCleanup?.records, migratedRecords)
        XCTAssertNil(recoveryDiscardRequest(in: migrated.effects))

        let verificationDeadline = try XCTUnwrap(
            deadline(in: migrated.effects, kind: .externalRead)
        )
        let verifying = DocumentSyncReducer.reduce(
            migrated.state,
            event: .deadlineFired(verificationDeadline)
        )
        let verification = try XCTUnwrap(readRequest(in: verifying.effects))
        let verified = DocumentSyncReducer.reduce(
            verifying.state,
            event: .externalReadFinished(
                token: verification.token,
                result: .unchanged(
                    externalObservation(
                        destinationBaseline.snapshot,
                        targetURL: destinationURL,
                        identity: destination,
                        fingerprint: destinationBaseline.fingerprint
                    )
                )
            )
        )
        let saveDeadline = try XCTUnwrap(
            deadline(in: verified.effects, kind: .localSave)
        )
        let preparing = DocumentSyncReducer.reduce(
            verified.state,
            event: .deadlineFired(saveDeadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        XCTAssertEqual(preparation.targetURL, destinationURL)
        XCTAssertEqual(preparation.identity, destination)
        XCTAssertEqual(preparation.expectedBaseline, destinationBaseline)

        let pendingSave = PendingSaveToken(
            generation: preparation.commitGeneration,
            sourceRevision: preparation.sourceRevision,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: preparation.snapshot
            ),
            expectedDurableState: destinationBaseline.asDurableFileState,
            targetURL: destinationURL
        )
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(
                token: preparation.token,
                pendingSave: pendingSave
            )
        )
        let commit = try XCTUnwrap(commitRequest(in: writing.effects))
        let saved = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: pendingSave.generation,
                        committedFingerprint: fingerprint(
                            preparation.snapshot.text,
                            resource: "restored-recovery-moved"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        XCTAssertEqual(
            saved.state.durableBaseline?.sourceRevision,
            restoredRevision
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: saved.effects))
        XCTAssertEqual(discard.identity, destination)
        XCTAssertEqual(
            discard.target,
            .decoded(try XCTUnwrap(migratedRecords.latestDecoded))
        )

        let discarded = DocumentSyncReducer.reduce(
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
        XCTAssertNil(discarded.state.recoveryCleanup)
        XCTAssertEqual(discarded.state.recovery, .clear)
    }

    func testDetachAndReattachRetargetsAnInFlightRecoveryMigration() throws {
        var recoverable = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: recoverable.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 23)
            ),
            raw: nil
        )
        recoverable.recovery = .available(records)

        let firstURL = URL(fileURLWithPath: "/tmp/detached-first-migration.md")
        let firstIdentity = DocumentIdentity.make(url: firstURL)
        let moving = DocumentSyncReducer.reduce(
            recoverable,
            event: .fileMoved(
                identity: firstIdentity,
                url: firstURL,
                durableBaseline: nil
            )
        )
        let firstMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: moving.effects)
        )

        let detached = DocumentSyncReducer.reduce(moving.state, event: .detach)
        XCTAssertEqual(detached.state.attachment, .untitled)
        XCTAssertEqual(detached.state.activeTokens[.recovery], firstMigration.token)
        XCTAssertEqual(
            detached.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: firstIdentity,
                relocationDestination: nil
            )
        )

        let secondURL = URL(fileURLWithPath: "/tmp/reattached-second-migration.md")
        let secondIdentity = DocumentIdentity.make(url: secondURL)
        let reattached = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: secondIdentity,
                url: secondURL,
                durableBaseline: nil
            )
        )
        XCTAssertNil(recoveryMigrationRequest(in: reattached.effects))
        XCTAssertEqual(reattached.state.activeTokens[.recovery], firstMigration.token)
        XCTAssertEqual(
            reattached.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: firstIdentity,
                relocationDestination: secondIdentity
            )
        )

        let completed = DocumentSyncReducer.reduce(
            reattached.state,
            event: .recoveryFinished(
                token: firstMigration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: firstMigration.expectedStoreGeneration,
                        generation: firstMigration.expectedStoreGeneration + 1,
                        records: migratedRecoveryRecords(
                            firstMigration.records,
                            to: firstIdentity
                        )
                    )
                )
            )
        )
        let secondMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: completed.effects)
        )
        XCTAssertEqual(secondMigration.sourceIdentity, firstIdentity)
        XCTAssertEqual(secondMigration.destinationIdentity, secondIdentity)
    }

    func testDetachedCompletionMigratesCarriedRecoveryOnLaterAttachment() throws {
        var recoverable = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: recoverable.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 28)
            ),
            raw: nil
        )
        recoverable.recovery = .available(records)

        let firstURL = URL(fileURLWithPath: "/tmp/detached-completion-first.md")
        let firstIdentity = DocumentIdentity.make(url: firstURL)
        let moving = DocumentSyncReducer.reduce(
            recoverable,
            event: .fileMoved(
                identity: firstIdentity,
                url: firstURL,
                durableBaseline: nil
            )
        )
        let firstMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: moving.effects)
        )
        let detached = DocumentSyncReducer.reduce(moving.state, event: .detach)
        let migratedRecords = migratedRecoveryRecords(
            firstMigration.records,
            to: firstIdentity
        )
        let completedDetached = DocumentSyncReducer.reduce(
            detached.state,
            event: .recoveryFinished(
                token: firstMigration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: firstMigration.expectedStoreGeneration,
                        generation: firstMigration.expectedStoreGeneration + 1,
                        records: migratedRecords
                    )
                )
            )
        )
        XCTAssertEqual(completedDetached.state.recovery, .available(migratedRecords))
        XCTAssertNil(completedDetached.state.recoveryMutationBarrier)

        let secondURL = URL(fileURLWithPath: "/tmp/detached-completion-second.md")
        let secondIdentity = DocumentIdentity.make(url: secondURL)
        let attached = DocumentSyncReducer.reduce(
            completedDetached.state,
            event: .attach(
                identity: secondIdentity,
                url: secondURL,
                durableBaseline: nil
            )
        )
        let continuation = try XCTUnwrap(
            recoveryMigrationRequest(in: attached.effects)
        )
        XCTAssertNil(recoveryLoadRequest(in: attached.effects))
        XCTAssertEqual(continuation.sourceIdentity, firstIdentity)
        XCTAssertEqual(continuation.destinationIdentity, secondIdentity)
        XCTAssertEqual(continuation.records, migratedRecords)
    }

    func testRepeatedMoveWhileRecoveryLoadsKeepsTheOriginalRecoveryScope() throws {
        var loading = makeState()
        loading.recoveryAccess = .loading
        let firstURL = URL(fileURLWithPath: "/tmp/loading-first-recovery-move.md")
        let firstIdentity = DocumentIdentity.make(url: firstURL)
        let firstMove = DocumentSyncReducer.reduce(
            loading,
            event: .fileMoved(
                identity: firstIdentity,
                url: firstURL,
                durableBaseline: nil
            )
        )
        let firstLoad = try XCTUnwrap(recoveryLoadRequest(in: firstMove.effects))
        XCTAssertEqual(firstLoad.scope, .document(identity()))

        let secondURL = URL(fileURLWithPath: "/tmp/loading-second-recovery-move.md")
        let secondIdentity = DocumentIdentity.make(url: secondURL)
        let secondMove = DocumentSyncReducer.reduce(
            firstMove.state,
            event: .saveAsAttached(
                identity: secondIdentity,
                url: secondURL,
                durableBaseline: nil
            )
        )
        let secondLoad = try XCTUnwrap(recoveryLoadRequest(in: secondMove.effects))

        XCTAssertEqual(secondLoad.scope, .document(identity()))
        XCTAssertNotEqual(secondLoad.token, firstLoad.token)
    }

    func testRecoveryRejectsDiscardResultForConflictPersistence() {
        var persisting = makeState()
        let recoveryToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: persisting.attachmentEpoch,
            operation: .recovery,
            attempt: 99
        )
        persisting.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: recoveryToken,
                identity: identity(),
                expectedStoreGeneration: 4,
                purpose: .persistConflict
            )
        )
        persisting.pendingConflict = DocumentSyncPendingConflict(
            identity: identity(),
            snapshot: DocumentSnapshot(text: "local conflict", format: .newDocument)
        )
        persisting.activeTokens[.recovery] = recoveryToken

        let wrongResult = DocumentSyncReducer.reduce(
            persisting,
            event: .recoveryFinished(
                token: recoveryToken,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: 4,
                        generation: 5,
                        records: .empty
                    )
                )
            )
        )

        XCTAssertEqual(wrongResult.state, persisting)
        XCTAssertTrue(wrongResult.effects.isEmpty)
    }

    func testRecoveryRejectsMutationResultsThatLoseTrackedRecords() throws {
        let original = makeState()
        let decoded = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(text: "protected local", format: .newDocument),
            createdAt: Date(timeIntervalSinceReferenceDate: 8)
        )
        let raw = DocumentSyncRawRecoveryReference(
            id: UUID(),
            documentIdentity: identity(),
            dataURL: URL(fileURLWithPath: "/tmp/protected-raw-recovery.bin"),
            byteCount: 4,
            contentDigest: "raw-digest",
            createdAt: Date(timeIntervalSinceReferenceDate: 9)
        )
        let records = DocumentSyncRecoveryRecords(decoded: decoded, raw: raw)

        var persisting = original
        let persistenceToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: persisting.attachmentEpoch,
            operation: .recovery,
            attempt: 99
        )
        persisting.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: persistenceToken,
                identity: identity(),
                expectedStoreGeneration: 4,
                purpose: .persistConflict,
                snapshot: decoded.snapshot,
                expectedRecords: records
            )
        )
        persisting.pendingConflict = DocumentSyncPendingConflict(
            identity: identity(),
            snapshot: decoded.snapshot
        )
        persisting.activeTokens[.recovery] = persistenceToken
        let missingPersistedConflict = DocumentSyncReducer.reduce(
            persisting,
            event: .recoveryFinished(
                token: persistenceToken,
                result: .persisted(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: 4,
                        generation: 5,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(missingPersistedConflict.state, persisting)
        XCTAssertTrue(missingPersistedConflict.effects.isEmpty)

        var recoverable = original
        recoverable.recovery = .available(records)
        let destinationURL = URL(fileURLWithPath: "/tmp/protected-moved-recovery.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moving = DocumentSyncReducer.reduce(
            recoverable,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: moving.effects))
        let missingMigratedRecords = DocumentSyncReducer.reduce(
            moving.state,
            event: .recoveryFinished(
                token: migration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: migration.expectedStoreGeneration,
                        generation: migration.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(missingMigratedRecords.state, moving.state)
        XCTAssertTrue(missingMigratedRecords.effects.isEmpty)

        let discarding = DocumentSyncReducer.reduce(
            recoverable,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))
        let missingDecodedRecord = DocumentSyncReducer.reduce(
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
        XCTAssertEqual(missingDecodedRecord.state, discarding.state)
        XCTAssertTrue(missingDecodedRecord.effects.isEmpty)
    }

}
