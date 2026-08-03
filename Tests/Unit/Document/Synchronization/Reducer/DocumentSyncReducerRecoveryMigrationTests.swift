import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testReattachingMovedDocumentRetainsItsInFlightRecoveryMigration() throws {
        let initial = makeState()
        let destinationURL = URL(fileURLWithPath: "/tmp/reattached-moved-contract.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            initial,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let originalMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: moved.effects)
        )

        let reattached = DocumentSyncReducer.reduce(
            moved.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )

        guard case .migrationPending(let migration) = reattached.state.recovery else {
            return XCTFail("Reattaching must not discard a pending recovery migration.")
        }
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        XCTAssertEqual(migration.token, originalMigration.token)
        XCTAssertEqual(
            reattached.state.activeTokens[.recovery],
            originalMigration.token
        )
        XCTAssertNil(recoveryLoadRequest(in: reattached.effects))
        XCTAssertNil(recoveryMigrationRequest(in: reattached.effects))

        let completed = DocumentSyncReducer.reduce(
            reattached.state,
            event: .recoveryFinished(
                token: originalMigration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: originalMigration.expectedStoreGeneration,
                        generation: originalMigration.expectedStoreGeneration + 1,
                        records: migratedRecoveryRecords(
                            originalMigration.records,
                            to: destination
                        )
                    )
                )
            )
        )
        XCTAssertNil(completed.state.activeTokens[.recovery])
        XCTAssertFalse(completed.state.statusProjection.recoveryMigrationIsPending)
    }

    func testRepeatedMoveQueuesRecoveryMigrationsBehindConfirmedCompletions() throws {
        var initial = makeState()
        initial.recovery = .available(
            DocumentSyncRecoveryRecords(
                decoded: RecoveryEntry(
                    id: UUID(),
                    documentIdentity: identity(),
                    snapshot: initial.snapshot,
                    createdAt: Date(timeIntervalSinceReferenceDate: 12)
                ),
                raw: nil
            )
        )
        let firstURL = URL(fileURLWithPath: "/tmp/first-recovery-move.md")
        let firstIdentity = DocumentIdentity.make(url: firstURL)
        let firstMove = DocumentSyncReducer.reduce(
            initial,
            event: .fileMoved(
                identity: firstIdentity,
                url: firstURL,
                durableBaseline: nil
            )
        )
        let firstMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: firstMove.effects)
        )

        let secondURL = URL(fileURLWithPath: "/tmp/second-recovery-move.md")
        let secondIdentity = DocumentIdentity.make(url: secondURL)
        let secondMove = DocumentSyncReducer.reduce(
            firstMove.state,
            event: .saveAsAttached(
                identity: secondIdentity,
                url: secondURL,
                durableBaseline: nil
            )
        )
        XCTAssertNil(recoveryMigrationRequest(in: secondMove.effects))
        XCTAssertEqual(secondMove.state.activeTokens[.recovery], firstMigration.token)
        XCTAssertEqual(
            secondMove.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: firstIdentity,
                relocationDestination: secondIdentity
            )
        )

        let firstCompleted = DocumentSyncReducer.reduce(
            secondMove.state,
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
            recoveryMigrationRequest(in: firstCompleted.effects)
        )
        XCTAssertEqual(secondMigration.sourceIdentity, firstIdentity)
        XCTAssertEqual(secondMigration.destinationIdentity, secondIdentity)
        XCTAssertEqual(
            secondMigration.records,
            migratedRecoveryRecords(firstMigration.records, to: firstIdentity)
        )
        XCTAssertNotEqual(secondMigration.token, firstMigration.token)

        let thirdURL = URL(fileURLWithPath: "/tmp/third-recovery-move.md")
        let thirdIdentity = DocumentIdentity.make(url: thirdURL)
        let thirdMove = DocumentSyncReducer.reduce(
            firstCompleted.state,
            event: .fileMoved(
                identity: thirdIdentity,
                url: thirdURL,
                durableBaseline: nil
            )
        )
        XCTAssertNil(recoveryMigrationRequest(in: thirdMove.effects))
        XCTAssertEqual(thirdMove.state.activeTokens[.recovery], secondMigration.token)
        XCTAssertEqual(
            thirdMove.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: firstIdentity,
                committedIdentity: secondIdentity,
                relocationDestination: thirdIdentity
            )
        )

        let secondCompleted = DocumentSyncReducer.reduce(
            thirdMove.state,
            event: .recoveryFinished(
                token: secondMigration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: secondMigration.expectedStoreGeneration,
                        generation: secondMigration.expectedStoreGeneration + 1,
                        records: migratedRecoveryRecords(
                            secondMigration.records,
                            to: secondIdentity
                        )
                    )
                )
            )
        )
        let thirdMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: secondCompleted.effects)
        )
        XCTAssertEqual(thirdMigration.sourceIdentity, secondIdentity)
        XCTAssertEqual(thirdMigration.destinationIdentity, thirdIdentity)
        XCTAssertEqual(
            thirdMigration.records,
            migratedRecoveryRecords(secondMigration.records, to: secondIdentity)
        )

        let finished = DocumentSyncReducer.reduce(
            secondCompleted.state,
            event: .recoveryFinished(
                token: thirdMigration.token,
                result: .migrated(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: thirdMigration.expectedStoreGeneration,
                        generation: thirdMigration.expectedStoreGeneration + 1,
                        records: migratedRecoveryRecords(
                            thirdMigration.records,
                            to: thirdIdentity
                        )
                    )
                )
            )
        )
        XCTAssertEqual(
            finished.state.statusProjection.presentedState,
            .recoveredConflict
        )
    }

    func testMovedConflictPersistenceMigratesOnlyItsConfirmedRecords() throws {
        var persisting = makeState()
        let snapshot = DocumentSnapshot(
            text: "conflict retained during move",
            format: .newDocument
        )
        let persistenceToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: persisting.attachmentEpoch,
            operation: .recovery,
            attempt: 90
        )
        let persistenceEntryID = UUID()
        persisting.pendingConflict = DocumentSyncPendingConflict(
            identity: identity(),
            snapshot: snapshot
        )
        persisting.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: persistenceToken,
                identity: identity(),
                entryID: persistenceEntryID,
                expectedStoreGeneration: 4,
                purpose: .persistConflict,
                snapshot: snapshot,
                expectedRecords: .empty
            )
        )
        persisting.activeTokens[.recovery] = persistenceToken

        let destinationURL = URL(fileURLWithPath: "/tmp/persisted-conflict-move.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            persisting,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )

        XCTAssertNil(recoveryMigrationRequest(in: moved.effects))
        XCTAssertEqual(moved.state.activeTokens[.recovery], persistenceToken)
        XCTAssertEqual(
            moved.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: identity(),
                relocationDestination: destination
            )
        )

        let persistedRecords = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: persistenceEntryID,
                documentIdentity: identity(),
                snapshot: snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 18)
            ),
            raw: nil
        )
        let staleGeneration = DocumentSyncReducer.reduce(
            moved.state,
            event: .recoveryFinished(
                token: persistenceToken,
                result: .persisted(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: 5,
                        generation: 6,
                        records: persistedRecords
                    )
                )
            )
        )
        XCTAssertEqual(staleGeneration.state, moved.state)
        XCTAssertTrue(staleGeneration.effects.isEmpty)

        let completed = DocumentSyncReducer.reduce(
            moved.state,
            event: .recoveryFinished(
                token: persistenceToken,
                result: .persisted(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: 4,
                        generation: 5,
                        records: persistedRecords
                    )
                )
            )
        )
        let migration = try XCTUnwrap(
            recoveryMigrationRequest(in: completed.effects)
        )
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        XCTAssertEqual(migration.records, persistedRecords)
        XCTAssertEqual(migration.expectedStoreGeneration, 5)
        XCTAssertNil(completed.state.recoveryMutationBarrier)
        XCTAssertNil(completed.state.pendingConflict)
    }

    func testMovedRawDiscardMigratesTheConfirmedResidualRecords() throws {
        var recoverable = makeState()
        let decoded = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(
                text: "decoded record survives raw discard",
                format: .newDocument
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let raw = DocumentSyncRawRecoveryReference(
            id: UUID(),
            documentIdentity: identity(),
            dataURL: URL(fileURLWithPath: "/tmp/moved-raw-discard.bin"),
            byteCount: 12,
            contentDigest: "moved-raw-discard",
            createdAt: Date(timeIntervalSinceReferenceDate: 21)
        )
        let originalRecords = DocumentSyncRecoveryRecords(decoded: decoded, raw: raw)
        recoverable.recovery = .available(originalRecords)

        let discarding = DocumentSyncReducer.reduce(
            recoverable,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))

        let destinationURL = URL(fileURLWithPath: "/tmp/discarded-raw-move.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            discarding.state,
            event: .saveAsAttached(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )

        XCTAssertNil(recoveryMigrationRequest(in: moved.effects))
        XCTAssertEqual(moved.state.activeTokens[.recovery], discard.token)
        XCTAssertEqual(
            moved.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: identity(),
                relocationDestination: destination
            )
        )

        let residualRecords = DocumentSyncRecoveryRecords(decoded: decoded, raw: nil)
        let completed = DocumentSyncReducer.reduce(
            moved.state,
            event: .recoveryFinished(
                token: discard.token,
                result: .discarded(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: discard.expectedStoreGeneration,
                        generation: discard.expectedStoreGeneration + 1,
                        records: residualRecords
                    )
                )
            )
        )
        let migration = try XCTUnwrap(
            recoveryMigrationRequest(in: completed.effects)
        )
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        XCTAssertEqual(migration.records, residualRecords)
    }

    func testFailedMovedRecoveryMutationReconcilesBeforeRelocation() throws {
        var persisting = makeState()
        let snapshot = DocumentSnapshot(
            text: "reconcile after uncertain persistence",
            format: .newDocument
        )
        let persistenceToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: persisting.attachmentEpoch,
            operation: .recovery,
            attempt: 91
        )
        let persistenceEntryID = UUID()
        persisting.pendingConflict = DocumentSyncPendingConflict(
            identity: identity(),
            snapshot: snapshot
        )
        persisting.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: persistenceToken,
                identity: identity(),
                entryID: persistenceEntryID,
                expectedStoreGeneration: 4,
                purpose: .persistConflict,
                snapshot: snapshot,
                expectedRecords: .empty
            )
        )
        persisting.activeTokens[.recovery] = persistenceToken

        let destinationURL = URL(fileURLWithPath: "/tmp/reconciled-recovery-move.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            persisting,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let failed = DocumentSyncReducer.reduce(
            moved.state,
            event: .operationFailed(token: persistenceToken, failure: .recovery)
        )

        XCTAssertNil(failed.state.activeTokens[.recovery])
        XCTAssertEqual(failed.state.recoveryAccess, .failed(.recovery))
        XCTAssertEqual(
            failed.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: identity(),
                relocationDestination: destination
            )
        )

        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        XCTAssertEqual(reconciliation.originalIdentity, identity())
        XCTAssertEqual(reconciliation.committedIdentity, identity())
        XCTAssertEqual(retried.state.recoveryAccess, .loading)

        let reconciledRecords = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: persistenceEntryID,
                documentIdentity: identity(),
                snapshot: snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 22)
            ),
            raw: nil
        )
        let completed = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: 5,
                        records: reconciledRecords
                    )
                )
            )
        )
        let migration = try XCTUnwrap(
            recoveryMigrationRequest(in: completed.effects)
        )
        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        XCTAssertEqual(migration.records, reconciledRecords)
        XCTAssertEqual(migration.expectedStoreGeneration, 5)
    }

    func testRecoveryReconciliationRejectsALoadResult() throws {
        var persisting = makeState()
        let snapshot = DocumentSnapshot(
            text: "reconciliation result kind",
            format: .newDocument
        )
        let persistenceToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: persisting.attachmentEpoch,
            operation: .recovery,
            attempt: 94
        )
        let persistenceEntryID = UUID()
        persisting.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: persistenceToken,
                identity: identity(),
                entryID: persistenceEntryID,
                expectedStoreGeneration: 4,
                purpose: .persistConflict,
                snapshot: snapshot,
                expectedRecords: .empty
            )
        )
        persisting.pendingConflict = DocumentSyncPendingConflict(
            identity: identity(),
            snapshot: snapshot
        )
        persisting.activeTokens[.recovery] = persistenceToken

        let failed = DocumentSyncReducer.reduce(
            persisting,
            event: .operationFailed(token: persistenceToken, failure: .recovery)
        )
        let reconciling = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: reconciling.effects)
        )
        let wrongResult = DocumentSyncReducer.reduce(
            reconciling.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: .document(identity()),
                        generation: 5,
                        records: .empty
                    )
                )
            )
        )

        XCTAssertEqual(wrongResult.state, reconciling.state)
        XCTAssertTrue(wrongResult.effects.isEmpty)
    }

    func testUncertainMigrationReconcilesOriginalRecordsToLatestAttachment() throws {
        var recoverable = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: recoverable.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 24)
            ),
            raw: nil
        )
        recoverable.recovery = .available(records)

        let tentativeURL = URL(fileURLWithPath: "/tmp/tentative-migration.md")
        let tentativeIdentity = DocumentIdentity.make(url: tentativeURL)
        let tentativeMove = DocumentSyncReducer.reduce(
            recoverable,
            event: .fileMoved(
                identity: tentativeIdentity,
                url: tentativeURL,
                durableBaseline: nil
            )
        )
        let tentativeMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: tentativeMove.effects)
        )

        let latestURL = URL(fileURLWithPath: "/tmp/latest-migration.md")
        let latestIdentity = DocumentIdentity.make(url: latestURL)
        let latestMove = DocumentSyncReducer.reduce(
            tentativeMove.state,
            event: .saveAsAttached(
                identity: latestIdentity,
                url: latestURL,
                durableBaseline: nil
            )
        )
        let failed = DocumentSyncReducer.reduce(
            latestMove.state,
            event: .operationFailed(
                token: tentativeMigration.token,
                failure: .recovery
            )
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

        let retryMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: reconciled.effects)
        )
        XCTAssertEqual(retryMigration.sourceIdentity, identity())
        XCTAssertEqual(retryMigration.destinationIdentity, latestIdentity)
        XCTAssertEqual(retryMigration.records, records)
    }

    func testReattachedMigrationRetainsItsDestinationDuringReconciliation() throws {
        var recoverable = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: recoverable.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 25)
            ),
            raw: nil
        )
        recoverable.recovery = .available(records)

        let destinationURL = URL(fileURLWithPath: "/tmp/reattached-reconcile.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            recoverable,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: moved.effects))
        let reattached = DocumentSyncReducer.reduce(
            moved.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let failed = DocumentSyncReducer.reduce(
            reattached.state,
            event: .operationFailed(token: migration.token, failure: .recovery)
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

        let retryMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: reconciled.effects)
        )
        XCTAssertEqual(retryMigration.sourceIdentity, identity())
        XCTAssertEqual(retryMigration.destinationIdentity, destination)
        XCTAssertEqual(retryMigration.records, records)
    }

}
