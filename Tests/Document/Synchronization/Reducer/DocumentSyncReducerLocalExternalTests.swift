import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testEditDebounceAndSaveCaptureExactImmutableInputs() throws {
        let initial = makeState()
        let revision = SourceRevision(number: 8, text: "updated")
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(revision, format: .newDocument)
        )
        let scheduledSave = try XCTUnwrap(
            deadlineRequest(in: edited.effects, kind: .localSave)
        )
        XCTAssertEqual(scheduledSave.delay, .milliseconds(500))
        XCTAssertEqual(
            scheduledSave.delay,
            DocumentSyncReducer.localSaveDelay
        )
        let deadline = scheduledSave.deadline

        let preparing = DocumentSyncReducer.reduce(
            edited.state,
            event: .deadlineFired(deadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        XCTAssertEqual(preparation.sourceRevision, revision)
        XCTAssertEqual(
            preparation.snapshot,
            DocumentSnapshot(text: "updated", format: .newDocument)
        )
        XCTAssertEqual(preparation.targetURL, documentURL)
        XCTAssertEqual(preparation.identity, identity())
        XCTAssertEqual(preparation.expectedBaseline, initial.durableBaseline)
        XCTAssertEqual(preparation.commitGeneration, 12)

        let pending = pendingSave(
            sourceRevision: revision,
            snapshot: preparation.snapshot,
            baseline: initial.durableBaseline
        )
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(token: preparation.token, pendingSave: pending)
        )
        let commit = try XCTUnwrap(commitRequest(in: writing.effects))
        XCTAssertEqual(commit.pendingSave, pending)
        XCTAssertEqual(commit.targetURL, documentURL)
        XCTAssertEqual(commit.identity, identity())
        XCTAssertEqual(commit.expectedBaseline, initial.durableBaseline)
        XCTAssertEqual(commit.commitGeneration, preparation.commitGeneration)

        let result = FileCommitResult(
            generation: pending.generation,
            committedFingerprint: fingerprint("updated", resource: "committed"),
            displacedPreimage: nil,
            safety: .atomicSwap
        )
        let finished = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(result)
            )
        )
        XCTAssertEqual(finished.state.local, .clean(revision))
        XCTAssertEqual(finished.state.durableBaseline?.snapshot, pending.snapshot)
        XCTAssertEqual(
            finished.state.durableBaseline?.fingerprint,
            result.committedFingerprint
        )
    }

    func testExplicitSaveReplacesAutosaveDebounceWithImmediateDeadline() throws {
        let initial = makeState()
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "updated"),
                format: .newDocument
            )
        )
        let autosave = try XCTUnwrap(
            deadlineRequest(in: edited.effects, kind: .localSave)
        )

        let requested = DocumentSyncReducer.reduce(
            edited.state,
            event: .saveRequested
        )
        let explicitSave = try XCTUnwrap(
            deadlineRequest(in: requested.effects, kind: .localSave)
        )

        XCTAssertEqual(explicitSave.delay, .zero)
        XCTAssertNotEqual(explicitSave.deadline.token, autosave.deadline.token)
        XCTAssertTrue(
            requested.effects.contains(.cancelDeadline(autosave.deadline))
        )
    }

    func testExternalReadAndMergeCarryCapturedSnapshots() throws {
        let initial = makeState()
        let localRevision = SourceRevision(number: 8, text: "local base")
        let dirty = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(localRevision, format: .newDocument)
        )
        let observed = DocumentSyncReducer.reduce(
            dirty.state,
            event: .monitorSignaled(try monitorToken(in: dirty.state))
        )
        let readDeadline = try XCTUnwrap(
            deadline(in: observed.effects, kind: .externalRead)
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(readDeadline)
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        XCTAssertEqual(read.targetURL, documentURL)
        XCTAssertEqual(read.identity, identity())
        XCTAssertEqual(read.expectedBaseline, initial.durableBaseline)

        let external = externalChange(
            DocumentSnapshot(text: "base external", format: .newDocument),
            targetURL: read.targetURL,
            identity: read.identity,
            resource: "external"
        )
        let merging = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(token: read.token, result: .changed(external))
        )
        let merge = try XCTUnwrap(mergeRequest(in: merging.effects))
        XCTAssertEqual(merge.base, initial.durableBaseline?.snapshot)
        XCTAssertEqual(
            merge.local,
            DocumentSnapshot(text: "local base", format: .newDocument)
        )
        XCTAssertEqual(merge.external, external.snapshot)
        XCTAssertEqual(merge.localSourceRevision, localRevision)

        let forgedRequest = DocumentSyncMergeRequest(
            token: merge.token,
            base: merge.base,
            local: merge.local,
            external: DocumentSnapshot(
                text: "forged external input",
                format: .newDocument
            ),
            localSourceRevision: merge.localSourceRevision
        )
        let forged = DocumentSyncReducer.reduce(
            merging.state,
            event: .mergeFinished(
                token: merge.token,
                result: ThreeWayTextMerger().result(for: forgedRequest)
            )
        )
        XCTAssertEqual(forged.state, merging.state)
        XCTAssertTrue(forged.effects.isEmpty)

        let mergeResult = ThreeWayTextMerger().result(for: merge)
        let merged = DocumentSyncReducer.reduce(
            merging.state,
            event: .mergeFinished(
                token: merge.token,
                result: mergeResult
            )
        )
        XCTAssertEqual(merged.state.source.text, "local base external")
        XCTAssertTrue(merged.state.local.isDirty)
        XCTAssertEqual(merged.state.durableBaseline?.snapshot, external.snapshot)
        XCTAssertEqual(
            merged.state.durableBaseline?.fingerprint,
            external.fingerprint
        )
        XCTAssertEqual(
            merged.state.durableBaseline?.sourceRevision.text,
            external.snapshot.text
        )
        XCTAssertNotNil(deadline(in: merged.effects, kind: .localSave))
    }

    func testLateMergeCannotOverwriteNewerLocalRevision() throws {
        let initial = makeState()
        let local = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "local"),
                format: .newDocument
            )
        )
        let observed = DocumentSyncReducer.reduce(
            local.state,
            event: .monitorSignaled(try monitorToken(in: local.state))
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: observed.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        let merging = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .changed(
                    externalChange(
                        DocumentSnapshot(
                            text: "external",
                            format: .newDocument
                        ),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "external"
                    )
                )
            )
        )
        let merge = try XCTUnwrap(mergeRequest(in: merging.effects))
        let newerRevision = SourceRevision(number: 9, text: "newer local")
        let newer = DocumentSyncReducer.reduce(
            merging.state,
            event: .sourceChanged(newerRevision, format: .newDocument)
        )
        let late = DocumentSyncReducer.reduce(
            newer.state,
            event: .mergeFinished(
                token: merge.token,
                result: ThreeWayTextMerger().result(for: merge)
            )
        )

        XCTAssertEqual(late.state, newer.state)
        XCTAssertTrue(late.effects.isEmpty)
        XCTAssertEqual(late.state.source, newerRevision)
    }

    func testManualSaveDuringWriteDoesNotStartASecondWrite() throws {
        let initial = makeState()
        let revision = SourceRevision(number: 8, text: "updated")
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(revision, format: .newDocument)
        )
        let preparing = DocumentSyncReducer.reduce(
            edited.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: edited.effects, kind: .localSave))
            )
        )
        let prepare = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(
                token: prepare.token,
                pendingSave: pendingSave(
                    sourceRevision: revision,
                    snapshot: prepare.snapshot,
                    baseline: initial.durableBaseline
                )
            )
        )
        let requestedAgain = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveRequested
        )

        XCTAssertEqual(requestedAgain.state, writing.state)
        XCTAssertTrue(requestedAgain.effects.isEmpty)
        XCTAssertNotNil(commitRequest(in: writing.effects))
    }

    func testExternalReadIsRejectedAfterItsCapturedBaselineChanges() throws {
        let initial = makeState()
        let revision = SourceRevision(number: 8, text: "local")
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(revision, format: .newDocument)
        )
        let observed = DocumentSyncReducer.reduce(
            edited.state,
            event: .monitorSignaled(try monitorToken(in: edited.state))
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: observed.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))

        let preparing = DocumentSyncReducer.reduce(
            reading.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: edited.effects, kind: .localSave))
            )
        )
        let prepare = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(
                token: prepare.token,
                pendingSave: pendingSave(
                    sourceRevision: revision,
                    snapshot: prepare.snapshot,
                    baseline: initial.durableBaseline
                )
            )
        )
        let commit = try XCTUnwrap(commitRequest(in: writing.effects))
        let saved = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: commit.commitGeneration,
                        committedFingerprint: fingerprint("local", resource: "new-baseline"),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        let staleRead = DocumentSyncReducer.reduce(
            saved.state,
            event: .externalReadFinished(
                token: read.token,
                result: .changed(
                    externalChange(
                        DocumentSnapshot(
                            text: "stale external",
                            format: .newDocument
                        ),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "external"
                    )
                )
            )
        )

        XCTAssertEqual(staleRead.state.source, revision)
        XCTAssertNotNil(deadline(in: staleRead.effects, kind: .externalRead))
        XCTAssertNil(mergeRequest(in: staleRead.effects))
    }

    func testUnverifiableExternalReadFailsClosedWithoutDurableBaseline() throws {
        let loading = DocumentSyncState(
            lifetime: lifetime,
            source: SourceRevision(number: 1, text: "unsaved"),
            format: .newDocument,
            attachment: .file(
                DocumentSyncFileAttachment(
                    identity: identity(),
                    url: documentURL,
                    epoch: 2
                )
            ),
            attachmentEpoch: 2,
            recoveryAccess: .ready(generation: 4)
        )
        let started = DocumentSyncReducer.reduce(loading, event: .started)
        let observed = DocumentSyncReducer.reduce(
            started.state,
            event: .monitorSignaled(try monitorToken(in: started.state))
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: observed.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        XCTAssertNil(read.expectedBaseline)

        let unverifiable = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .unchanged(
                    externalObservation(
                        DocumentSnapshot(text: "unknown", format: .newDocument),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "unknown-baseline"
                    )
                )
            )
        )
        XCTAssertEqual(unverifiable.state.issue?.failure, .externalRead)
        XCTAssertTrue(unverifiable.effects.isEmpty)

        let changed = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .changed(
                    externalChange(
                        DocumentSnapshot(
                            text: "external",
                            format: .newDocument
                        ),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "external-no-baseline"
                    )
                )
            )
        )
        XCTAssertNil(mergeRequest(in: changed.effects))
        XCTAssertEqual(changed.state.source.text, "external")
        XCTAssertNotNil(recoveryPersistRequest(in: changed.effects))
    }

    func testConflictPersistenceProjectsRecoveredConflictAfterSuccess() throws {
        let initial = makeState()
        let dirty = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "local"),
                format: .newDocument
            )
        )
        let observed = DocumentSyncReducer.reduce(
            dirty.state,
            event: .monitorSignaled(try monitorToken(in: dirty.state))
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: observed.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        let merging = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .changed(
                    externalChange(
                        DocumentSnapshot(
                            text: "external",
                            format: .newDocument
                        ),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "external"
                    )
                )
            )
        )
        let merge = try XCTUnwrap(mergeRequest(in: merging.effects))
        let conflicting = DocumentSyncReducer.reduce(
            merging.state,
            event: .mergeFinished(
                token: merge.token,
                result: ThreeWayTextMerger().result(for: merge)
            )
        )
        let persistence = try XCTUnwrap(recoveryPersistRequest(in: conflicting.effects))
        let persistedSnapshot = try XCTUnwrap(persistence.snapshot)
        let entry = RecoveryEntry(
            id: persistence.entryID,
            documentIdentity: identity(),
            snapshot: persistedSnapshot,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let persisted = DocumentSyncReducer.reduce(
            conflicting.state,
            event: .recoveryFinished(
                token: persistence.token,
                result: .persisted(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: persistence.expectedStoreGeneration,
                        generation: persistence.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: entry,
                            raw: nil
                        )
                    )
                )
            )
        )

        XCTAssertNil(persisted.state.issue)
        XCTAssertEqual(
            persisted.state.statusProjection.presentedState,
            .recoveredConflict
        )
        XCTAssertEqual(persisted.state.source.text, "external")
    }

    func testFailedConflictPersistenceRetainsLocalSnapshotThroughRetry() throws {
        let initial = makeState()
        let dirty = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "local"),
                format: .newDocument
            )
        )
        let observed = DocumentSyncReducer.reduce(
            dirty.state,
            event: .monitorSignaled(try monitorToken(in: dirty.state))
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: observed.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        let merging = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .changed(
                    externalChange(
                        DocumentSnapshot(
                            text: "external",
                            format: .newDocument
                        ),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "external"
                    )
                )
            )
        )
        let merge = try XCTUnwrap(mergeRequest(in: merging.effects))
        let conflicting = DocumentSyncReducer.reduce(
            merging.state,
            event: .mergeFinished(
                token: merge.token,
                result: ThreeWayTextMerger().result(for: merge)
            )
        )
        let persistence = try XCTUnwrap(recoveryPersistRequest(in: conflicting.effects))
        let failed = DocumentSyncReducer.reduce(
            conflicting.state,
            event: .recoveryFinished(token: persistence.token, result: .failed(.recovery))
        )
        XCTAssertEqual(failed.state.pendingConflict?.identity, identity())
        XCTAssertEqual(failed.state.pendingConflict?.snapshot, persistence.snapshot)
        XCTAssertEqual(failed.state.statusProjection.presentedState, .synchronizationPaused)

        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        let reconciliation = try XCTUnwrap(
            recoveryReconciliationRequest(in: retried.effects)
        )
        let resumed = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: 12,
                        records: .empty
                    )
                )
            )
        )
        let resumedPersistence = try XCTUnwrap(
            recoveryPersistRequest(in: resumed.effects)
        )
        XCTAssertEqual(resumedPersistence.snapshot, persistence.snapshot)
        XCTAssertNotEqual(resumedPersistence.token, persistence.token)
    }

    func testEditDuringConflictPersistenceKeepsBothRecoveryAndNewerSource() throws {
        let initial = makeState()
        let dirty = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "older local"),
                format: .newDocument
            )
        )
        let observed = DocumentSyncReducer.reduce(
            dirty.state,
            event: .monitorSignaled(try monitorToken(in: dirty.state))
        )
        let reading = DocumentSyncReducer.reduce(
            observed.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: observed.effects, kind: .externalRead))
            )
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        let merging = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .changed(
                    externalChange(
                        DocumentSnapshot(
                            text: "external",
                            format: .newDocument
                        ),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        resource: "external"
                    )
                )
            )
        )
        let merge = try XCTUnwrap(mergeRequest(in: merging.effects))
        let conflicting = DocumentSyncReducer.reduce(
            merging.state,
            event: .mergeFinished(
                token: merge.token,
                result: ThreeWayTextMerger().result(for: merge)
            )
        )
        let persistence = try XCTUnwrap(recoveryPersistRequest(in: conflicting.effects))
        let persistedSnapshot = try XCTUnwrap(persistence.snapshot)
        let newerRevision = SourceRevision(
            number: conflicting.state.source.number + 1,
            text: "newer local edit"
        )
        let edited = DocumentSyncReducer.reduce(
            conflicting.state,
            event: .sourceChanged(newerRevision, format: .newDocument)
        )
        XCTAssertEqual(edited.state.source, newerRevision)
        XCTAssertTrue(edited.state.local.isDirty)
        XCTAssertEqual(edited.state.pendingConflict?.snapshot, persistence.snapshot)

        let persistedEntry = RecoveryEntry(
            id: persistence.entryID,
            documentIdentity: identity(),
            snapshot: persistedSnapshot,
            createdAt: Date(timeIntervalSinceReferenceDate: 8)
        )
        let persisted = DocumentSyncReducer.reduce(
            edited.state,
            event: .recoveryFinished(
                token: persistence.token,
                result: .persisted(
                    DocumentSyncRecoveryMutationResult(
                        previousGeneration: persistence.expectedStoreGeneration,
                        generation: persistence.expectedStoreGeneration + 1,
                        records: DocumentSyncRecoveryRecords(
                            decoded: persistedEntry,
                            raw: nil
                        )
                    )
                )
            )
        )
        XCTAssertNil(persisted.state.pendingConflict)
        XCTAssertEqual(persisted.state.source, newerRevision)
        XCTAssertNotNil(persisted.state.recoveryCleanup)
        XCTAssertFalse(persisted.state.externalSignalPending)
        let saveDeadline = try XCTUnwrap(
            deadline(in: persisted.effects, kind: .localSave)
        )
        let preparing = DocumentSyncReducer.reduce(
            persisted.state,
            event: .deadlineFired(saveDeadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let pending = PendingSaveToken(
            generation: preparation.commitGeneration,
            sourceRevision: preparation.sourceRevision,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: preparation.snapshot
            ),
            expectedDurableState: preparation.expectedBaseline?
                .asDurableFileState,
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
                            resource: "newer-conflict-edit"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: saved.effects))
        XCTAssertEqual(discard.target, .decoded(persistedEntry))

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
        XCTAssertEqual(cleaned.state.recovery, .clear)
        XCTAssertNil(cleaned.state.recoveryCleanup)
    }

    func testAtomicSwapUnavailableRequiresSaveAsWithoutRetryingCommit() throws {
        let write = try recoveryArtifactValidationWrite()

        let failed = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .commitFailed(
                token: write.commit.token,
                disposition: .destinationRequiresSaveAs
            )
        )

        XCTAssertEqual(failed.state.source, write.writing.state.source)
        XCTAssertTrue(failed.state.local.isDirty)
        XCTAssertEqual(failed.state.fileAttachment, write.writing.state.fileAttachment)
        XCTAssertNil(failed.state.activeTokens[.saveCommit])
        XCTAssertNil(failed.state.uncertainCommit)
        XCTAssertEqual(failed.state.issue?.failure, .destinationRequiresSaveAs)
        XCTAssertEqual(failed.state.issue?.retryable, false)
        XCTAssertEqual(failed.state.issue?.requiresSaveAs, true)
        XCTAssertTrue(failed.effects.isEmpty)

        let retried = DocumentSyncReducer.reduce(failed.state, event: .retry)
        XCTAssertEqual(retried.state, failed.state)
        XCTAssertTrue(retried.effects.isEmpty)

        let requestedSave = DocumentSyncReducer.reduce(
            failed.state,
            event: .saveRequested
        )
        XCTAssertEqual(requestedSave.state, failed.state)
        XCTAssertTrue(requestedSave.effects.isEmpty)

        let laterLocalRevision = SourceRevision(
            number: failed.state.source.number + 1,
            text: "later local edit"
        )
        let edited = DocumentSyncReducer.reduce(
            failed.state,
            event: .sourceChanged(laterLocalRevision, format: .newDocument)
        )
        XCTAssertEqual(edited.state.source, laterLocalRevision)
        XCTAssertEqual(
            edited.state.issue?.failure,
            .destinationRequiresSaveAs
        )
        XCTAssertNil(edited.state.activeTokens[.savePreparation])
        XCTAssertTrue(edited.effects.isEmpty)
    }

}
