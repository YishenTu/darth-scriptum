import Foundation
import XCTest
@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testManagedCloseFlushesOrRefusesAtDeadlineAndUntitledDefersToNative() throws {
        let initial = makeState()
        let revision = SourceRevision(number: 8, text: "local")
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(revision, format: .newDocument)
        )
        let closeRequested = DocumentSyncReducer.reduce(
            edited.state,
            event: .requestClose
        )
        let closeDeadline = try XCTUnwrap(
            deadline(in: closeRequested.effects, kind: .close)
        )
        XCTAssertNil(deadline(in: closeRequested.effects, kind: .localSave))

        let preparing = DocumentSyncReducer.reduce(
            closeRequested.state,
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
        let flushed = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: commit.commitGeneration,
                        committedFingerprint: fingerprint("local", resource: "committed"),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        XCTAssertEqual(closeResolution(in: flushed.effects)?.disposition, .allowManagedClose)
        let closed = DocumentSyncReducer.reduce(
            flushed.state,
            event: .closeCommitted(
                try XCTUnwrap(closeResolution(in: flushed.effects)?.token)
            )
        )
        XCTAssertEqual(closed.state.lifecycle, .closed)

        let timeout = DocumentSyncReducer.reduce(
            closeRequested.state,
            event: .deadlineFired(closeDeadline)
        )
        XCTAssertEqual(timeout.state.lifecycle, .active)
        XCTAssertEqual(timeout.state.issue?.failure, .closeDeadline)
        XCTAssertEqual(
            closeResolution(in: timeout.effects)?.disposition,
            .refuseManagedClose
        )

        var unsafe = makeState()
        unsafe.issue = DocumentSyncIssue(
            failure: .externalRead,
            retryable: true,
            requiresSaveAs: false,
            rawRecoveryURL: nil
        )
        let refusedUnsafeClose = DocumentSyncReducer.reduce(
            unsafe,
            event: .requestClose
        )
        XCTAssertEqual(refusedUnsafeClose.state.lifecycle, .active)
        XCTAssertEqual(
            closeResolution(in: refusedUnsafeClose.effects)?.disposition,
            .refuseManagedClose
        )

        let untitled = DocumentSyncState(
            lifetime: lifetime,
            source: SourceRevision(number: 1, text: "untitled"),
            format: .newDocument,
            recoveryAccess: .ready(generation: 1)
        )
        let native = DocumentSyncReducer.reduce(untitled, event: .requestClose)
        let nativeResolution = try XCTUnwrap(closeResolution(in: native.effects))
        XCTAssertEqual(nativeResolution.disposition, .deferToNativeUntitledReview)
        XCTAssertNil(deadline(in: native.effects, kind: .close))
        let cancelled = DocumentSyncReducer.reduce(
            native.state,
            event: .closeCancelled(nativeResolution.token)
        )
        XCTAssertEqual(cancelled.state.lifecycle, .active)
    }

    func testCloseDeadlineRetainsAnInFlightCommitUntilItsResultArrives() throws {
        let write = try recoveryArtifactValidationWrite()
        let closing = DocumentSyncReducer.reduce(
            write.writing.state,
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
        XCTAssertEqual(timedOut.state.issue?.failure, .closeDeadline)
        XCTAssertEqual(timedOut.state.local, write.writing.state.local)
        XCTAssertEqual(
            timedOut.state.activeTokens[.saveCommit],
            write.commit.token
        )

        let retried = DocumentSyncReducer.reduce(timedOut.state, event: .retry)
        XCTAssertEqual(retried.state.local, timedOut.state.local)
        XCTAssertEqual(
            retried.state.activeTokens[.saveCommit],
            write.commit.token
        )
        XCTAssertNil(deadline(in: retried.effects, kind: .localSave))
        XCTAssertNil(prepareRequest(in: retried.effects))
        XCTAssertNil(commitRequest(in: retried.effects))

        let completed = DocumentSyncReducer.reduce(
            retried.state,
            event: .saveFinished(
                token: write.commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: write.commit.commitGeneration,
                        committedFingerprint: fingerprint(
                            write.commit.pendingSave.snapshot.text,
                            resource: "late-close-timeout-commit"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        XCTAssertEqual(
            completed.state.local,
            .clean(write.commit.pendingSave.sourceRevision)
        )
        XCTAssertNil(completed.state.issue)
        XCTAssertEqual(
            completed.state.durableBaseline?.snapshot,
            write.commit.pendingSave.snapshot
        )
    }

    func testAttachmentTransitionsQueueBehindAnUncancellableCommit() throws {
        let write = try recoveryArtifactValidationWrite()
        let destinationURL = URL(fileURLWithPath: "/tmp/commit-in-flight-attach.md")
        let destination = DocumentIdentity.make(url: destinationURL)

        let attached = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let moved = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let detached = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .detach
        )
        let detachedThenAttached = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let expectedAttachment = DocumentSyncPendingAttachmentTransition.attach(
            identity: destination,
            url: destinationURL,
            durableBaseline: nil
        )
        XCTAssertEqual(attached.state.pendingAttachmentTransition, expectedAttachment)
        XCTAssertEqual(moved.state.pendingAttachmentTransition, expectedAttachment)
        XCTAssertEqual(detached.state.pendingAttachmentTransition, .detach)
        XCTAssertEqual(
            detachedThenAttached.state.pendingAttachmentTransition,
            .detachThenAttach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertTrue(attached.effects.isEmpty)
        XCTAssertTrue(moved.effects.isEmpty)
        XCTAssertTrue(detached.effects.isEmpty)
        XCTAssertTrue(detachedThenAttached.effects.isEmpty)

        let completed = DocumentSyncReducer.reduce(
            moved.state,
            event: .saveFinished(
                token: write.commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: write.commit.commitGeneration,
                        committedFingerprint: fingerprint(
                            write.commit.pendingSave.snapshot.text,
                            resource: "commit-before-attachment-transition"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        XCTAssertEqual(completed.state.fileAttachment?.identity, destination)
        XCTAssertNil(completed.state.durableBaseline)
        XCTAssertTrue(completed.state.local.isDirty)
        XCTAssertNil(completed.state.pendingAttachmentTransition)

        let failed = DocumentSyncReducer.reduce(
            detached.state,
            event: .operationFailed(
                token: write.commit.token,
                failure: .localSave
            )
        )
        XCTAssertNotNil(failed.state.uncertainCommit)
        XCTAssertEqual(failed.state.fileAttachment?.identity, identity())
        XCTAssertEqual(failed.state.pendingAttachmentTransition, .detach)
        XCTAssertNotNil(commitReconciliationRequest(in: failed.effects))

        let provenNotStarted = DocumentSyncReducer.reduce(
            detached.state,
            event: .commitFailed(
                token: write.commit.token,
                disposition: .notStarted
            )
        )
        XCTAssertNil(provenNotStarted.state.uncertainCommit)
        XCTAssertEqual(provenNotStarted.state.attachment, .untitled)
        XCTAssertNil(provenNotStarted.state.pendingAttachmentTransition)
    }

    func testCommitReconciliationRequiresAuthoritativeGenerationAndFingerprint() throws {
        let write = try recoveryArtifactValidationWrite()
        let uncertain = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .operationFailed(
                token: write.commit.token,
                failure: .localSave
            )
        )
        let firstReconciliation = try XCTUnwrap(
            commitReconciliationRequest(in: uncertain.effects)
        )
        let targetFingerprint = FileFingerprint.make(
            data: write.commit.pendingSave.encodedData,
            resourceIdentifier: "reconciled-target"
        )
        let targetObservation = externalObservation(
            write.commit.pendingSave.snapshot,
            targetURL: firstReconciliation.targetURL,
            identity: firstReconciliation.identity,
            fingerprint: targetFingerprint
        )
        let wrongGeneration = DocumentSyncReducer.reduce(
            uncertain.state,
            event: .commitReconciliationFinished(
                token: firstReconciliation.token,
                result: .committed(
                    completion: saveCompletion(
                        FileCommitResult(
                            generation: write.commit.commitGeneration + 1,
                            committedFingerprint: targetFingerprint,
                            displacedPreimage: nil,
                            safety: .atomicSwap
                        )
                    ),
                    targetObservation: targetObservation
                )
            )
        )
        XCTAssertNotNil(wrongGeneration.state.uncertainCommit)
        XCTAssertTrue(wrongGeneration.state.local.isDirty)
        XCTAssertEqual(wrongGeneration.state.issue?.failure, .recovery)

        let generationRetry = DocumentSyncReducer.reduce(
            wrongGeneration.state,
            event: .retry
        )
        let secondReconciliation = try XCTUnwrap(
            commitReconciliationRequest(in: generationRetry.effects)
        )
        let mismatchedResource = FileFingerprint.make(
            data: write.commit.pendingSave.encodedData,
            resourceIdentifier: "stale-completion-resource"
        )
        let wrongFingerprint = DocumentSyncReducer.reduce(
            generationRetry.state,
            event: .commitReconciliationFinished(
                token: secondReconciliation.token,
                result: .committed(
                    completion: saveCompletion(
                        FileCommitResult(
                            generation: write.commit.commitGeneration,
                            committedFingerprint: mismatchedResource,
                            displacedPreimage: nil,
                            safety: .atomicSwap
                        )
                    ),
                    targetObservation: targetObservation
                )
            )
        )
        XCTAssertNotNil(wrongFingerprint.state.uncertainCommit)
        XCTAssertTrue(wrongFingerprint.state.local.isDirty)
        XCTAssertEqual(wrongFingerprint.state.issue?.failure, .recovery)

        let fingerprintRetry = DocumentSyncReducer.reduce(
            wrongFingerprint.state,
            event: .retry
        )
        let finalReconciliation = try XCTUnwrap(
            commitReconciliationRequest(in: fingerprintRetry.effects)
        )
        let reconciled = DocumentSyncReducer.reduce(
            fingerprintRetry.state,
            event: .commitReconciliationFinished(
                token: finalReconciliation.token,
                result: .committed(
                    completion: saveCompletion(
                        FileCommitResult(
                            generation: write.commit.commitGeneration,
                            committedFingerprint: targetFingerprint,
                            displacedPreimage: nil,
                            safety: .atomicSwap
                        )
                    ),
                    targetObservation: targetObservation
                )
            )
        )
        XCTAssertNil(reconciled.state.uncertainCommit)
        XCTAssertEqual(
            reconciled.state.durableBaseline?.fingerprint,
            targetFingerprint
        )
        XCTAssertEqual(
            reconciled.state.local,
            .clean(write.commit.pendingSave.sourceRevision)
        )
    }

    func testAttachmentRejectsBaselineWhenIdentityDoesNotMatchTargetURL() {
        let initial = makeState()
        let foreignURL = URL(fileURLWithPath: "/tmp/foreign-attachment.md")
        let constructed = DocumentSyncState(
            lifetime: lifetime,
            source: initial.source,
            format: initial.format,
            attachment: .file(
                DocumentSyncFileAttachment(
                    identity: identity(),
                    url: foreignURL,
                    epoch: 9
                )
            ),
            attachmentEpoch: 9,
            durableBaseline: initial.durableBaseline,
            recoveryAccess: .ready(generation: 4)
        )
        XCTAssertNil(constructed.fileAttachment)
        XCTAssertNil(constructed.durableBaseline)
        XCTAssertTrue(constructed.local.isDirty)

        let constructedSave = DocumentSyncReducer.reduce(
            constructed,
            event: .saveRequested
        )
        XCTAssertEqual(constructedSave.state, constructed)
        XCTAssertTrue(constructedSave.effects.isEmpty)

        let attached = DocumentSyncReducer.reduce(
            initial,
            event: .attach(
                identity: identity(),
                url: foreignURL,
                durableBaseline: initial.durableBaseline
            )
        )

        XCTAssertEqual(attached.state, initial)
        XCTAssertTrue(attached.effects.isEmpty)

        let moved = DocumentSyncReducer.reduce(
            initial,
            event: .fileMoved(
                identity: identity(),
                url: foreignURL,
                durableBaseline: initial.durableBaseline
            )
        )
        XCTAssertEqual(moved.state, initial)
        XCTAssertTrue(moved.effects.isEmpty)
    }

    func testUncertainCommitPersistsAcrossEditsAndRetriesWithoutAnIssue() throws {
        let write = try recoveryArtifactValidationWrite()
        let uncertain = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .operationFailed(
                token: write.commit.token,
                failure: .localSave
            )
        )
        let reconciliation = try XCTUnwrap(
            commitReconciliationRequest(in: uncertain.effects)
        )
        let unresolved = DocumentSyncReducer.reduce(
            uncertain.state,
            event: .commitReconciliationFinished(
                token: reconciliation.token,
                result: .unresolved
            )
        )
        let editedRevision = SourceRevision(
            number: 9,
            text: "edited-while-commit-is-uncertain"
        )
        let edited = DocumentSyncReducer.reduce(
            unresolved.state,
            event: .sourceChanged(editedRevision, format: .newDocument)
        )
        XCTAssertNotNil(edited.state.uncertainCommit)
        XCTAssertEqual(edited.state.source, editedRevision)
        XCTAssertTrue(edited.effects.isEmpty)

        var issueCleared = edited.state
        issueCleared.issue = nil
        let retried = DocumentSyncReducer.reduce(issueCleared, event: .retry)
        let retryRequest = try XCTUnwrap(
            commitReconciliationRequest(in: retried.effects)
        )
        XCTAssertEqual(retryRequest.pendingSave, write.commit.pendingSave)
        XCTAssertEqual(retryRequest.targetURL, write.commit.targetURL)
    }

    func testQueuedAttachmentAppliesAfterMalformedCommitResultIsRecovered() throws {
        let write = try recoveryArtifactValidationWrite()
        let destinationURL = URL(fileURLWithPath: "/tmp/recovered-queued-attach.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let queued = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertNotNil(queued.state.pendingAttachmentTransition)

        let malformed = DocumentSyncReducer.reduce(
            queued.state,
            event: .saveFinished(
                token: write.commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: write.commit.commitGeneration,
                        committedFingerprint: fingerprint(
                            "mismatched-commit-bytes",
                            resource: "malformed-commit-result"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        XCTAssertNotNil(malformed.state.uncertainCommit)
        XCTAssertEqual(malformed.state.fileAttachment?.identity, identity())
        XCTAssertNotNil(malformed.state.pendingAttachmentTransition)

        let reconciliation = try XCTUnwrap(
            commitReconciliationRequest(in: malformed.effects)
        )
        let baseline = try XCTUnwrap(write.initial.durableBaseline)
        let recovered = DocumentSyncReducer.reduce(
            malformed.state,
            event: .commitReconciliationFinished(
                token: reconciliation.token,
                result: .notCommitted(
                    externalObservation(
                        baseline.snapshot,
                        targetURL: reconciliation.targetURL,
                        identity: reconciliation.identity,
                        fingerprint: baseline.fingerprint
                    )
                )
            )
        )
        XCTAssertEqual(recovered.state.fileAttachment?.identity, destination)
        XCTAssertNil(recovered.state.pendingAttachmentTransition)
    }

    func testQueuedDetachBoundaryKeepsUnexpectedRawRecoveryAtItsOrigin() throws {
        let write = try recoveryArtifactValidationWrite()
        let destinationURL = URL(fileURLWithPath: "/tmp/queued-detach-raw-destination.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let detached = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .detach
        )
        let queued = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        let artifact = try recoveryArtifact(id: UUID(), for: write.commit)
        let rawData = Data("queued-detach-unexpected-preimage".utf8)
        let persisted = DocumentSyncReducer.reduce(
            queued.state,
            event: .saveFinished(
                token: write.commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: write.commit.commitGeneration,
                        committedFingerprint: fingerprint(
                            write.commit.pendingSave.snapshot.text,
                            resource: "queued-detach-raw-commit"
                        ),
                        displacedPreimage: rawData,
                        safety: .atomicSwap,
                        recoveryArtifact: artifact
                    )
                )
            )
        )
        let request = try XCTUnwrap(recoveryPersistRequest(in: persisted.effects))
        XCTAssertEqual(persisted.state.fileAttachment?.identity, destination)
        XCTAssertNil(
            persisted.state.recoveryMutationBarrier?.relocationDestination
        )
        XCTAssertNil(persisted.state.pendingAttachmentTransition)

        let rawAtOrigin = rawRecoveryReference(
            id: request.entryID,
            identity: identity(),
            data: rawData
        )
        let completed = DocumentSyncReducer.reduce(
            persisted.state,
            event: .recoveryFinished(
                token: request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: request.expectedStoreGeneration,
                            generation: request.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [rawAtOrigin]
                            )
                        ),
                        durablyPersistedRawEntryID: request.entryID,
                        acknowledgedRecoveryArtifact: artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        XCTAssertEqual(completed.state.recovery, .clear)
        XCTAssertNil(recoveryMigrationRequest(in: completed.effects))
        let load = try XCTUnwrap(recoveryLoadRequest(in: completed.effects))
        XCTAssertEqual(load.scope, .document(destination))
    }

    func testCloseTimeoutDoesNotOutliveAnUnexpectedPreimageCommit() throws {
        let write = try recoveryArtifactValidationWrite()
        let closing = DocumentSyncReducer.reduce(
            write.writing.state,
            event: .requestClose
        )
        let timedOut = DocumentSyncReducer.reduce(
            closing.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: closing.effects, kind: .close))
            )
        )
        let artifact = try recoveryArtifact(id: UUID(), for: write.commit)
        let rawData = Data("close-timeout-unexpected-preimage".utf8)
        let rawPersistence = DocumentSyncReducer.reduce(
            timedOut.state,
            event: .saveFinished(
                token: write.commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: write.commit.commitGeneration,
                        committedFingerprint: fingerprint(
                            write.commit.pendingSave.snapshot.text,
                            resource: "close-timeout-unexpected-preimage"
                        ),
                        displacedPreimage: rawData,
                        safety: .atomicSwap,
                        recoveryArtifact: artifact
                    )
                )
            )
        )
        XCTAssertNil(rawPersistence.state.issue)
        let request = try XCTUnwrap(recoveryPersistRequest(in: rawPersistence.effects))
        let raw = rawRecoveryReference(
            id: request.entryID,
            identity: identity(),
            data: rawData
        )
        let persisted = DocumentSyncReducer.reduce(
            rawPersistence.state,
            event: .recoveryFinished(
                token: request.token,
                result: .rawPersisted(
                    DocumentSyncRawRecoveryPersistResult(
                        mutation: DocumentSyncRecoveryMutationResult(
                            previousGeneration: request.expectedStoreGeneration,
                            generation: request.expectedStoreGeneration + 1,
                            records: DocumentSyncRecoveryRecords(
                                decoded: [],
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: request.entryID,
                        acknowledgedRecoveryArtifact: artifact,
                        decodeOutcome: .undecodable
                    )
                )
            )
        )
        XCTAssertEqual(persisted.state.issue?.failure, .recovery)
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
        XCTAssertNil(discarded.state.issue)
        let closingAgain = DocumentSyncReducer.reduce(
            discarded.state,
            event: .requestClose
        )
        XCTAssertNil(closeResolution(in: closingAgain.effects))
        let externalDeadline = try XCTUnwrap(
            deadline(in: discarded.effects, kind: .externalRead)
                ?? deadline(in: closingAgain.effects, kind: .externalRead)
        )
        let reading = DocumentSyncReducer.reduce(
            closingAgain.state,
            event: .deadlineFired(externalDeadline)
        )
        let read = try XCTUnwrap(readRequest(in: reading.effects))
        let settled = DocumentSyncReducer.reduce(
            reading.state,
            event: .externalReadFinished(
                token: read.token,
                result: .unchanged(
                    externalObservation(
                        try XCTUnwrap(read.expectedBaseline?.snapshot),
                        targetURL: read.targetURL,
                        identity: read.identity,
                        fingerprint: try XCTUnwrap(
                            read.expectedBaseline?.fingerprint
                        )
                    )
                )
            )
        )
        XCTAssertEqual(
            closeResolution(in: settled.effects)?.disposition,
            .allowManagedClose
        )
    }

    func testManagedCloseJoinsRestoredRecoverySaveAndCleanup() throws {
        var recoverable = makeState()
        let records = DocumentSyncRecoveryRecords(
            decoded: RecoveryEntry(
                id: UUID(),
                documentIdentity: identity(),
                snapshot: DocumentSnapshot(
                    text: "restored before managed close",
                    format: .newDocument
                ),
                createdAt: Date(timeIntervalSinceReferenceDate: 30)
            ),
            raw: nil
        )
        recoverable.recovery = .available(records)

        let restored = DocumentSyncReducer.reduce(
            recoverable,
            event: .restoreLocalRecovery
        )
        let saveDeadline = try XCTUnwrap(
            deadline(in: restored.effects, kind: .localSave)
        )

        let closing = DocumentSyncReducer.reduce(
            restored.state,
            event: .requestClose
        )
        XCTAssertNil(closeResolution(in: closing.effects))
        XCTAssertNotNil(deadline(in: closing.effects, kind: .close))

        let preparing = DocumentSyncReducer.reduce(
            closing.state,
            event: .deadlineFired(saveDeadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(
                token: preparation.token,
                pendingSave: pendingSave(
                    sourceRevision: preparation.sourceRevision,
                    snapshot: preparation.snapshot,
                    baseline: recoverable.durableBaseline
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
                        committedFingerprint: fingerprint(
                            preparation.snapshot.text,
                            resource: "restored-managed-close"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: saved.effects))
        XCTAssertEqual(
            discard.target,
            .decoded(try XCTUnwrap(records.latestDecoded))
        )

        let cleanedUp = DocumentSyncReducer.reduce(
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
        XCTAssertNil(cleanedUp.state.recoveryCleanup)
        XCTAssertEqual(
            closeResolution(in: cleanedUp.effects)?.disposition,
            .allowManagedClose
        )
    }

    func testManagedCloseJoinsAnEmptyRecoveryMigration() throws {
        let initial = makeState()
        let destinationURL = URL(fileURLWithPath: "/tmp/empty-recovery-migration.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let destinationBaseline = durableBaseline(
            for: initial.snapshot,
            targetURL: destinationURL,
            identity: destination,
            sourceRevision: initial.source,
            resource: "empty-recovery-migration-destination"
        )
        let moved = DocumentSyncReducer.reduce(
            initial,
            event: .fileMoved(
                identity: destination,
                url: destinationURL,
                durableBaseline: destinationBaseline
            )
        )
        let migration = try XCTUnwrap(recoveryMigrationRequest(in: moved.effects))
        XCTAssertEqual(migration.records, .empty)

        let closing = DocumentSyncReducer.reduce(
            moved.state,
            event: .requestClose
        )
        XCTAssertNil(closeResolution(in: closing.effects))
        XCTAssertNotNil(deadline(in: closing.effects, kind: .close))

        let migrated = DocumentSyncReducer.reduce(
            closing.state,
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
        XCTAssertEqual(migrated.state.recovery, .clear)
        XCTAssertEqual(
            closeResolution(in: migrated.effects)?.disposition,
            .allowManagedClose
        )
    }

    func testTokenMismatchesAndClosedEventsAreRejected() throws {
        let initial = makeState()
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "updated"),
                format: .newDocument
            )
        )
        let deadline = try XCTUnwrap(deadline(in: edited.effects, kind: .localSave))
        let token = deadline.token
        let staleTokens = [
            SyncEffectToken(
                lifetime: UUID(),
                attachmentEpoch: token.attachmentEpoch,
                operation: token.operation,
                attempt: token.attempt
            ),
            SyncEffectToken(
                lifetime: token.lifetime,
                attachmentEpoch: token.attachmentEpoch &+ 1,
                operation: token.operation,
                attempt: token.attempt
            ),
            SyncEffectToken(
                lifetime: token.lifetime,
                attachmentEpoch: token.attachmentEpoch,
                operation: .externalRead,
                attempt: token.attempt
            ),
            SyncEffectToken(
                lifetime: token.lifetime,
                attachmentEpoch: token.attachmentEpoch,
                operation: token.operation,
                attempt: token.attempt &+ 1
            )
        ]
        for stale in staleTokens {
            let rejected = DocumentSyncReducer.reduce(
                edited.state,
                event: .operationFailed(token: stale, failure: .localSave)
            )
            XCTAssertEqual(rejected.state, edited.state)
            XCTAssertTrue(rejected.effects.isEmpty)
        }

        let wrongFailure = DocumentSyncReducer.reduce(
            edited.state,
            event: .operationFailed(token: token, failure: .recovery)
        )
        XCTAssertEqual(wrongFailure.state, edited.state)
        XCTAssertTrue(wrongFailure.effects.isEmpty)

        let monitor = try monitorToken(in: edited.state)
        let staleMonitor = SyncEffectToken(
            lifetime: monitor.lifetime,
            attachmentEpoch: monitor.attachmentEpoch,
            operation: .monitor,
            attempt: monitor.attempt &+ 1
        )
        let rejectedMonitor = DocumentSyncReducer.reduce(
            edited.state,
            event: .monitorSignaled(staleMonitor)
        )
        XCTAssertEqual(rejectedMonitor.state, edited.state)
        XCTAssertTrue(rejectedMonitor.effects.isEmpty)

        var waitingForRecovery = edited.state
        waitingForRecovery.recoveryAccess = .loading
        let wrongKindRecoveryResult = DocumentSyncReducer.reduce(
            waitingForRecovery,
            event: .recoveryFinished(
                token: monitor,
                result: .failed(.recovery)
            )
        )
        XCTAssertEqual(wrongKindRecoveryResult.state, waitingForRecovery)
        XCTAssertTrue(wrongKindRecoveryResult.effects.isEmpty)

        var recoveryLoading = makeState()
        recoveryLoading.recoveryAccess = .loading
        let loading = DocumentSyncReducer.reduce(recoveryLoading, event: .started)
        let recoveryLoad = try XCTUnwrap(recoveryLoadRequest(in: loading.effects))
        let wrongRecoveryFailure = DocumentSyncReducer.reduce(
            loading.state,
            event: .recoveryFinished(
                token: recoveryLoad.token,
                result: .failed(.monitor)
            )
        )
        XCTAssertEqual(wrongRecoveryFailure.state, loading.state)
        XCTAssertTrue(wrongRecoveryFailure.effects.isEmpty)

        let rejectedClosed = DocumentSyncReducer.reduce(
            edited.state,
            event: .closed(token)
        )
        XCTAssertEqual(rejectedClosed.state, edited.state)
        XCTAssertTrue(rejectedClosed.effects.isEmpty)

        let clean = makeState()
        let closing = DocumentSyncReducer.reduce(clean, event: .requestClose)
        let closeToken = try XCTUnwrap(closeResolution(in: closing.effects)?.token)
        let cancelled = DocumentSyncReducer.reduce(
            closing.state,
            event: .closeCancelled(closeToken)
        )
        let lateClosed = DocumentSyncReducer.reduce(
            cancelled.state,
            event: .closed(closeToken)
        )
        XCTAssertEqual(lateClosed.state, cancelled.state)
        XCTAssertTrue(lateClosed.effects.isEmpty)

        let closed = DocumentSyncReducer.reduce(
            closing.state,
            event: .closed(closeToken)
        )
        XCTAssertEqual(closed.state.lifecycle, .closed)
        let late = DocumentSyncReducer.reduce(
            closed.state,
            event: .sourceChanged(
                SourceRevision(number: 9, text: "late"),
                format: .newDocument
            )
        )
        XCTAssertEqual(late.state, closed.state)
        XCTAssertTrue(late.effects.isEmpty)
    }

}
