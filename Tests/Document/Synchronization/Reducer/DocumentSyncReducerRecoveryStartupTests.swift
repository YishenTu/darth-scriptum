import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testRecoveryFailureInvalidatesScheduledWorkAndRequiresToken() throws {
        let initial = makeState()
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "local"),
                format: .newDocument
            )
        )
        let localDeadline = try XCTUnwrap(
            deadline(in: edited.effects, kind: .localSave)
        )
        var loading = edited.state
        let recoveryToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: loading.attachmentEpoch,
            operation: .recovery,
            attempt: 90
        )
        loading.recoveryAccess = .loading
        loading.activeTokens[.recovery] = recoveryToken
        let activeMonitor = try monitorToken(in: loading)
        let failed = DocumentSyncReducer.reduce(
            loading,
            event: .recoveryFinished(token: recoveryToken, result: .failed(.recovery))
        )

        XCTAssertEqual(failed.state.recoveryAccess, .failed(.recovery))
        XCTAssertTrue(failed.state.activeTokens.isEmpty)
        XCTAssertTrue(failed.effects.contains(.cancelAllDeadlines))
        XCTAssertEqual(
            monitorRequest(in: failed.effects, action: .stop)?.token,
            activeMonitor
        )
        if case .dirty(let dirty) = failed.state.local {
            XCTAssertNil(dirty.scheduledToken)
        } else {
            XCTFail("Recovery failure must leave unsaved local work dirty.")
        }
        let lateSave = DocumentSyncReducer.reduce(
            failed.state,
            event: .deadlineFired(localDeadline)
        )
        XCTAssertEqual(lateSave.state, failed.state)
        XCTAssertTrue(lateSave.effects.isEmpty)
        let lateMonitorFailure = DocumentSyncReducer.reduce(
            failed.state,
            event: .operationFailed(token: activeMonitor, failure: .monitor)
        )
        XCTAssertEqual(lateMonitorFailure.state, failed.state)
        XCTAssertTrue(lateMonitorFailure.effects.isEmpty)
    }

    func testRetryAfterStartupFailureMarksTheLoadAsAnExplicitStoreRestart()
        throws
    {
        var loading = makeState()
        let recoveryToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: loading.attachmentEpoch,
            operation: .recovery,
            attempt: 91
        )
        loading.recoveryAccess = .loading
        loading.activeTokens[.recovery] = recoveryToken
        let failed = DocumentSyncReducer.reduce(
            loading,
            event: .recoveryFinished(token: recoveryToken, result: .failed(.recovery))
        )

        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let load = try XCTUnwrap(recoveryLoadRequest(in: retried.effects))

        XCTAssertTrue(load.retriesStartup)
    }

    func testStartupRecoveryLoadValidatesItsCapturedScope() throws {
        let loading = DocumentSyncState(
            lifetime: lifetime,
            source: SourceRevision(number: 7, text: "base"),
            format: .newDocument,
            attachment: .file(
                DocumentSyncFileAttachment(
                    identity: identity(),
                    url: documentURL,
                    epoch: 2
                )
            ),
            attachmentEpoch: 2,
            recoveryAccess: .loading
        )
        let started = DocumentSyncReducer.reduce(loading, event: .started)
        let load = try XCTUnwrap(recoveryLoadRequest(in: started.effects))
        XCTAssertEqual(load.scope, .document(identity()))
        XCTAssertNotNil(monitorRequest(in: started.effects))

        let wrongScope = DocumentSyncReducer.reduce(
            started.state,
            event: .recoveryFinished(
                token: load.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: .unattached,
                        generation: 5,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(wrongScope.state, started.state)
        XCTAssertTrue(wrongScope.effects.isEmpty)

        let loaded = DocumentSyncReducer.reduce(
            started.state,
            event: .recoveryFinished(
                token: load.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: load.scope,
                        generation: 5,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(loaded.state.recoveryAccess, .ready(generation: 5))
        XCTAssertEqual(loaded.state.recovery, .clear)
    }

    func testAttachLoadsRecoveryWhenTheStoreIsAlreadyReady() throws {
        let unattached = DocumentSyncState(
            lifetime: lifetime,
            source: SourceRevision(number: 1, text: "base"),
            format: .newDocument,
            recoveryAccess: .ready(generation: 4)
        )
        let attached = DocumentSyncReducer.reduce(
            unattached,
            event: .attach(
                identity: identity(),
                url: documentURL,
                durableBaseline: nil
            )
        )
        let load = try XCTUnwrap(recoveryLoadRequest(in: attached.effects))
        XCTAssertEqual(load.scope, .document(identity()))
        XCTAssertEqual(attached.state.recoveryAccess, .loading)

        let entry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(text: "recover", format: .newDocument),
            createdAt: Date(timeIntervalSinceReferenceDate: 7)
        )
        let loaded = DocumentSyncReducer.reduce(
            attached.state,
            event: .recoveryFinished(
                token: load.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: load.scope,
                        generation: 5,
                        records: DocumentSyncRecoveryRecords(
                            decoded: entry,
                            raw: nil
                        )
                    )
                )
            )
        )
        XCTAssertEqual(loaded.state.statusProjection.presentedState, .recoveredConflict)
    }

    func testCloseTimeoutMakesInterruptedRecoveryReloadableAndRestartsMonitor() throws {
        var waitingForRecovery = makeState()
        let priorMonitor = try monitorToken(in: waitingForRecovery)
        let recoveryToken = SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: waitingForRecovery.attachmentEpoch,
            operation: .recovery,
            attempt: 99
        )
        waitingForRecovery.recoveryAccess = .loading
        waitingForRecovery.activeTokens[.recovery] = recoveryToken
        let closing = DocumentSyncReducer.reduce(
            waitingForRecovery,
            event: .requestClose
        )
        let closeDeadline = try XCTUnwrap(
            deadline(in: closing.effects, kind: .close)
        )
        let timedOut = DocumentSyncReducer.reduce(
            closing.state,
            event: .deadlineFired(closeDeadline)
        )
        XCTAssertEqual(timedOut.state.recoveryAccess, .loading)
        XCTAssertNil(timedOut.state.activeTokens[.recovery])
        XCTAssertEqual(
            timedOut.state.statusProjection.presentedState,
            .failed("The document could not be saved before closing.")
        )
        let restartedMonitor = try XCTUnwrap(
            monitorRequest(in: timedOut.effects, action: .start)
        )
        let stoppedMonitor = try XCTUnwrap(
            monitorRequest(in: timedOut.effects, action: .stop)
        )
        XCTAssertEqual(stoppedMonitor.token, priorMonitor)
        XCTAssertNotEqual(stoppedMonitor.token, restartedMonitor.token)
        XCTAssertEqual(timedOut.state.activeTokens[.monitor], restartedMonitor.token)

        let lateStopFailure = DocumentSyncReducer.reduce(
            timedOut.state,
            event: .operationFailed(token: stoppedMonitor.token, failure: .monitor)
        )
        XCTAssertEqual(lateStopFailure.state, timedOut.state)
        XCTAssertTrue(lateStopFailure.effects.isEmpty)

        let retried = DocumentSyncReducer.reduce(timedOut.state, event: .retry)
        let reload = try XCTUnwrap(recoveryLoadRequest(in: retried.effects))
        let resumed = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reload.token,
                result: .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: reload.scope,
                        generation: 6,
                        records: .empty
                    )
                )
            )
        )
        XCTAssertEqual(
            resumed.state.activeTokens[.monitor],
            restartedMonitor.token
        )
    }

    func testCloseTimeoutDuringRecoveryMutationRequiresReconciliation() throws {
        var recoverable = makeState()
        let raw = DocumentSyncRawRecoveryReference(
            id: UUID(),
            documentIdentity: identity(),
            dataURL: URL(fileURLWithPath: "/tmp/close-timeout-recovery.bin"),
            byteCount: 8,
            contentDigest: "close-timeout-recovery",
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        recoverable.recovery = .available(
            DocumentSyncRecoveryRecords(decoded: nil, raw: raw)
        )
        let discarding = DocumentSyncReducer.reduce(
            recoverable,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))
        let closing = DocumentSyncReducer.reduce(
            discarding.state,
            event: .requestClose
        )
        let closeDeadline = try XCTUnwrap(
            deadline(in: closing.effects, kind: .close)
        )

        let timedOut = DocumentSyncReducer.reduce(
            closing.state,
            event: .deadlineFired(closeDeadline)
        )

        XCTAssertEqual(timedOut.state.lifecycle, .active)
        XCTAssertNil(timedOut.state.activeTokens[.recovery])
        XCTAssertEqual(timedOut.state.recoveryAccess, .failed(.recovery))
        XCTAssertEqual(timedOut.state.issue?.failure, .closeDeadline)
        XCTAssertEqual(
            timedOut.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: identity(),
                relocationDestination: identity()
            )
        )

        let retried = DocumentSyncReducer.reduce(timedOut.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        XCTAssertEqual(reconciliation.originalIdentity, discard.identity)
        XCTAssertEqual(reconciliation.committedIdentity, discard.identity)
        XCTAssertNil(recoveryLoadRequest(in: retried.effects))
    }

    func testMigrationFailureReconcilesBeforeRetryingTheMigration() throws {
        var initial = makeState()
        initial.recovery = .available(
            DocumentSyncRecoveryRecords(
                decoded: RecoveryEntry(
                    id: UUID(),
                    documentIdentity: identity(),
                    snapshot: initial.snapshot,
                    createdAt: Date(timeIntervalSinceReferenceDate: 10)
                ),
                raw: nil
            )
        )
        let destinationURL = URL(fileURLWithPath: "/tmp/retry-moved-contract.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            initial,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let initialMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: moved.effects)
        )
        let failed = DocumentSyncReducer.reduce(
            moved.state,
            event: .recoveryFinished(
                token: initialMigration.token,
                result: .failed(.recovery)
            )
        )
        guard case .migrationPending(let pending) = failed.state.recovery else {
            return XCTFail("The migration intent must remain retryable after failure.")
        }
        XCTAssertEqual(pending.token, initialMigration.token)
        XCTAssertEqual(
            pending.expectedStoreGeneration,
            initialMigration.expectedStoreGeneration
        )
        XCTAssertEqual(
            failed.state.recoveryMutationBarrier,
            DocumentSyncRecoveryMutationBarrier(
                originalIdentity: identity(),
                committedIdentity: destination,
                relocationDestination: destination
            )
        )

        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        XCTAssertEqual(reconciliation.originalIdentity, identity())
        XCTAssertEqual(reconciliation.committedIdentity, destination)

        let reconciled = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: 9,
                        records: initialMigration.records
                    )
                )
            )
        )
        let retriedMigration = try XCTUnwrap(
            recoveryMigrationRequest(in: reconciled.effects)
        )
        XCTAssertEqual(retriedMigration.sourceIdentity, identity())
        XCTAssertEqual(retriedMigration.destinationIdentity, destination)
        XCTAssertNotEqual(retriedMigration.token, initialMigration.token)
    }

}
