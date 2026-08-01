import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testDetachClearsAttachedRecoveryPresentationAndRejectsOldMonitor() throws {
        var attached = makeState()
        let raw = DocumentSyncRawRecoveryReference(
            id: UUID(),
            documentIdentity: identity(),
            dataURL: URL(fileURLWithPath: "/tmp/detached-raw-recovery.bin"),
            byteCount: 3,
            contentDigest: "digest",
            createdAt: Date(timeIntervalSinceReferenceDate: 6)
        )
        attached.recovery = .available(
            DocumentSyncRecoveryRecords(decoded: nil, raw: raw)
        )
        let oldMonitor = try monitorToken(in: attached)

        let detached = DocumentSyncReducer.reduce(attached, event: .detach)
        XCTAssertEqual(detached.state.attachment, .untitled)
        XCTAssertEqual(detached.state.recovery, .clear)
        XCTAssertNil(detached.state.statusProjection.presentedState)

        let lateMonitor = DocumentSyncReducer.reduce(
            detached.state,
            event: .monitorSignaled(oldMonitor)
        )
        XCTAssertEqual(lateMonitor.state, detached.state)
        XCTAssertTrue(lateMonitor.effects.isEmpty)
    }

    func testDetachPreservesNewerSourceAlongsidePendingConflict() throws {
        var attached = makeState()
        let newerRevision = SourceRevision(number: 9, text: "newer local edit")
        attached.source = newerRevision
        attached.local = .dirty(
            DocumentSyncDirtyState(
                revision: newerRevision,
                scheduledToken: nil
            )
        )
        attached.pendingConflict = DocumentSyncPendingConflict(
            identity: identity(),
            snapshot: DocumentSnapshot(text: "older conflict", format: .newDocument)
        )

        let detached = DocumentSyncReducer.reduce(attached, event: .detach)
        XCTAssertEqual(detached.state.source, newerRevision)
        XCTAssertEqual(
            detached.state.pendingConflict?.snapshot.text,
            "older conflict"
        )
        XCTAssertEqual(
            detached.state.statusProjection.presentedState,
            .synchronizationPaused
        )

        let destinationURL = URL(fileURLWithPath: "/tmp/reattached-conflict.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let reattached = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertEqual(reattached.state.pendingConflict?.identity, destination)
        XCTAssertNotNil(recoveryLoadRequest(in: reattached.effects))
    }

    func testStatusProjectionPreservesCompatibilityStatesAndFields() {
        var state = makeState()
        state.issue = DocumentSyncIssue(
            failure: .destinationRequiresSaveAs,
            retryable: false,
            requiresSaveAs: true,
            rawRecoveryURL: nil
        )
        XCTAssertEqual(
            state.statusProjection.presentedState,
            .failed("The destination requires Save As.")
        )
        XCTAssertTrue(state.statusProjection.failureRequiresSaveAs)

        state.issue = DocumentSyncIssue(
            failure: .monitor,
            retryable: true,
            requiresSaveAs: false,
            rawRecoveryURL: nil
        )
        XCTAssertEqual(
            state.statusProjection.presentedState,
            .failed("File monitoring is unavailable.")
        )

        state.issue = DocumentSyncIssue(
            failure: .attachment,
            retryable: true,
            requiresSaveAs: false,
            rawRecoveryURL: nil
        )
        XCTAssertEqual(state.statusProjection.presentedState, .missing)

        state.issue = nil
        state.lastCommitSafety = .coordinatedReplacement
        XCTAssertEqual(
            state.statusProjection.presentedState,
            .limitedSyncSafety
        )
    }

    func testStartupMoveMigrationAndPausedRawRecoveryAreExplicit() throws {
        let initial = makeState()
        let rawURL = URL(fileURLWithPath: "/tmp/raw-recovery.bin")
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: initial.snapshot,
                createdAt: Date(timeIntervalSinceReferenceDate: 2)
            ),
            raw: DocumentSyncRawRecoveryReference(
                id: UUID(),
                documentIdentity: identity(),
                dataURL: rawURL,
                byteCount: 3,
                contentDigest: "digest",
                createdAt: Date(timeIntervalSinceReferenceDate: 3)
            )
        )
        var withRecovery = initial
        withRecovery.recovery = .available(records)
        let destinationURL = URL(fileURLWithPath: "/tmp/moved-contract.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let moved = DocumentSyncReducer.reduce(
            withRecovery,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: moved.effects))

        XCTAssertEqual(migration.sourceIdentity, identity())
        XCTAssertEqual(migration.destinationIdentity, destination)
        XCTAssertEqual(moved.state.statusProjection.presentedState, .synchronizationPaused)
        XCTAssertTrue(moved.state.statusProjection.recoveryMigrationIsPending)
        XCTAssertEqual(moved.state.statusProjection.rawRecoveryURL, rawURL)

        let migratedRecords = migratedRecoveryRecords(records, to: destination)
        let completed = DocumentSyncReducer.reduce(
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
        XCTAssertFalse(completed.state.statusProjection.recoveryMigrationIsPending)
        XCTAssertEqual(
            completed.state.statusProjection.presentedState,
            .synchronizationPaused
        )
        XCTAssertEqual(completed.state.statusProjection.rawRecoveryURL, rawURL)

        let discarding = DocumentSyncReducer.reduce(
            completed.state,
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
                        records: DocumentSyncRecoveryRecords(
                            decoded: migratedRecords.decoded,
                            raw: []
                        )
                    )
                )
            )
        )
        XCTAssertEqual(
            discarded.state.statusProjection.presentedState,
            .recoveredConflict
        )
    }

}
