import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func testUnexpectedDisplacedPreimagePersistsCapturedRawInputBeforeAdvancing() throws {
        let scenario = try unexpectedPreimagePersistence()
        let payload = try XCTUnwrap(scenario.request.rawPayload)
        let continuation = try XCTUnwrap(
            scenario.request.displacedPreimageContinuation
        )

        XCTAssertEqual(scenario.request.identity, identity())
        XCTAssertEqual(scenario.request.entryID, scenario.artifact.id)
        XCTAssertEqual(scenario.request.expectedRecords, .empty)
        XCTAssertEqual(scenario.request.expectedStoreGeneration, 4)
        XCTAssertEqual(scenario.request.purpose, .persistDisplacedPreimage)
        XCTAssertEqual(payload.data, scenario.rawData)
        XCTAssertEqual(payload.fingerprint, FileFingerprint.make(data: scenario.rawData))
        XCTAssertEqual(payload.targetURL, documentURL)
        XCTAssertEqual(payload.recoveryArtifact, scenario.artifact)
        XCTAssertEqual(continuation.entryID, scenario.artifact.id)
        XCTAssertEqual(continuation.originIdentity, identity())
        XCTAssertEqual(
            continuation.local,
            DocumentSnapshot(
                text: "local-after-unexpected-preimage",
                format: .newDocument
            ))
        XCTAssertEqual(
            scenario.transition.state.durableBaseline,
            scenario.initial.durableBaseline
        )
        XCTAssertTrue(scenario.transition.state.local.isDirty)
        XCTAssertEqual(
            scenario.transition.state.pendingDisplacedPreimage,
            continuation
        )
        XCTAssertNil(scenario.transition.state.mergeAttempt)
    }

    func testRecoveryArtifactRequiresAnUnexpectedVerifiedDisplacedPreimage() throws {
        let write = try recoveryArtifactValidationWrite()
        let artifact = recoveryArtifact(id: UUID())
        let matchingPreimage = Data("base".utf8)
        let committedFingerprint = fingerprint(
            write.pending.snapshot.text,
            resource: "artifact-validation-commit"
        )
        let invalidCompletions = [
            saveCompletion(
                FileCommitResult(
                    generation: write.pending.generation,
                    committedFingerprint: committedFingerprint,
                    displacedPreimage: nil,
                    safety: .atomicSwap,
                    recoveryArtifact: artifact
                )
            ),
            saveCompletion(
                FileCommitResult(
                    generation: write.pending.generation,
                    committedFingerprint: committedFingerprint,
                    displacedPreimage: matchingPreimage,
                    safety: .atomicSwap,
                    recoveryArtifact: artifact
                )
            ),
        ]

        for completion in invalidCompletions {
            let rejected = DocumentSyncReducer.reduce(
                write.writing.state,
                event: .saveFinished(token: write.commit.token, completion: completion)
            )
            XCTAssertNotNil(rejected.state.uncertainCommit)
            XCTAssertEqual(rejected.state.issue?.failure, .recovery)
            XCTAssertEqual(rejected.state.durableBaseline, write.initial.durableBaseline)
            XCTAssertTrue(rejected.state.local.isDirty)
            XCTAssertNil(recoveryPersistRequest(in: rejected.effects))

            let closing = DocumentSyncReducer.reduce(rejected.state, event: .requestClose)
            XCTAssertEqual(
                closeResolution(in: closing.effects)?.disposition,
                .refuseManagedClose
            )
        }
    }

    func testRawPersistenceRequiresArtifactAcknowledgmentAndDurableReceipt() throws {
        let scenario = try unexpectedPreimagePersistence()
        let nonDurableRaw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData,
            dataURL: nil
        )
        let nonDurableResult = DocumentSyncRawRecoveryPersistResult(
            mutation: DocumentSyncRecoveryMutationResult(
                previousGeneration: scenario.request.expectedStoreGeneration,
                generation: scenario.request.expectedStoreGeneration + 1,
                records: DocumentSyncRecoveryRecords(decoded: [], raw: [nonDurableRaw])
            ),
            durablyPersistedRawEntryID: scenario.request.entryID,
            acknowledgedRecoveryArtifact: scenario.artifact,
            decodeOutcome: .undecodable
        )
        let rejectedNonDurable = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(nonDurableResult)
            )
        )
        XCTAssertEqual(rejectedNonDurable.state, scenario.transition.state)
        XCTAssertTrue(rejectedNonDurable.effects.isEmpty)

        let durableRaw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let missingAcknowledgment = DocumentSyncRawRecoveryPersistResult(
            mutation: DocumentSyncRecoveryMutationResult(
                previousGeneration: scenario.request.expectedStoreGeneration,
                generation: scenario.request.expectedStoreGeneration + 1,
                records: DocumentSyncRecoveryRecords(decoded: [], raw: [durableRaw])
            ),
            durablyPersistedRawEntryID: scenario.request.entryID,
            acknowledgedRecoveryArtifact: nil,
            decodeOutcome: .undecodable
        )
        let rejectedAcknowledgment = DocumentSyncReducer.reduce(
            scenario.transition.state,
            event: .recoveryFinished(
                token: scenario.request.token,
                result: .rawPersisted(missingAcknowledgment)
            )
        )
        XCTAssertEqual(rejectedAcknowledgment.state, scenario.transition.state)
        XCTAssertTrue(rejectedAcknowledgment.effects.isEmpty)
    }

    func testRawReconciliationRequiresArtifactReceiptBeforeItCanBeDiscarded() throws {
        let scenario = try unexpectedPreimagePersistence()
        let failed = DocumentSyncReducer.reduce(
            scenario.transition.state,
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
        let records = DocumentSyncRecoveryRecords(decoded: [], raw: [raw])

        let missingAcknowledgment = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: scenario.request.expectedStoreGeneration + 1,
                        records: records
                    )
                )
            )
        )
        XCTAssertEqual(missingAcknowledgment.state, retried.state)
        XCTAssertTrue(missingAcknowledgment.effects.isEmpty)

        let acknowledged = DocumentSyncReducer.reduce(
            retried.state,
            event: .recoveryFinished(
                token: reconciliation.token,
                result: .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: identity(),
                        generation: scenario.request.expectedStoreGeneration + 1,
                        records: records,
                        acknowledgedRecoveryArtifact: scenario.artifact
                    )
                )
            )
        )
        XCTAssertEqual(acknowledged.state.recovery, .available(records))
        XCTAssertEqual(
            acknowledged.state.unresolvedDisplacedPreimage?.entryID,
            scenario.request.entryID
        )
        XCTAssertEqual(acknowledged.state.issue?.failure, .recovery)

        let discarding = DocumentSyncReducer.reduce(
            acknowledged.state,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))
        XCTAssertEqual(discard.target, .raw([raw]))
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
        XCTAssertNil(discarded.state.unresolvedDisplacedPreimage)
        XCTAssertEqual(discarded.state.recovery, .clear)
    }

    func testReconciledSuccessfulRawDiscardClearsTheUnresolvedLatch() throws {
        let scenario = try unexpectedPreimagePersistence()
        let raw = rawRecoveryReference(
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
        let discarding = DocumentSyncReducer.reduce(
            persisted.state,
            event: .discardRawRecovery
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: discarding.effects))
        let failed = DocumentSyncReducer.reduce(
            discarding.state,
            event: .operationFailed(token: discard.token, failure: .recovery)
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
                        generation: discard.expectedStoreGeneration + 1,
                        records: .empty
                    )
                )
            )
        )

        XCTAssertEqual(reconciled.state.recovery, .clear)
        XCTAssertNil(reconciled.state.unresolvedDisplacedPreimage)
        XCTAssertNil(reconciled.state.issue)
        XCTAssertNil(recoveryDiscardRequest(in: reconciled.effects))
    }

    func testDurablyStoredRawRecoveryDoesNotWedgeANewAttachmentAfterDetach() throws {
        let scenario = try unexpectedPreimagePersistence()
        let raw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let completed = DocumentSyncReducer.reduce(
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
            completed.state.unresolvedDisplacedPreimage?.entryID,
            scenario.request.entryID
        )

        let detached = DocumentSyncReducer.reduce(completed.state, event: .detach)
        XCTAssertNil(detached.state.unresolvedDisplacedPreimage)
        XCTAssertEqual(detached.state.recovery, .clear)
        XCTAssertNil(detached.state.issue)

        let destinationURL = URL(fileURLWithPath: "/tmp/new-attachment-after-raw.md")
        let destination = DocumentIdentity.make(url: destinationURL)
        let attached = DocumentSyncReducer.reduce(
            detached.state,
            event: .attach(
                identity: destination,
                url: destinationURL,
                durableBaseline: nil
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(recoveryLoadRequest(in: attached.effects)).scope,
            .document(destination)
        )
        XCTAssertNil(attached.state.statusProjection.rawRecoveryURL)
        XCTAssertNotEqual(
            attached.state.statusProjection.presentedState,
            .synchronizationPaused
        )
    }

    func testDecodedDisplacedPreimageMergesThenCleansOnlyItsRawRecord() throws {
        let scenario = try unexpectedPreimagePersistence(
            rawText: "base external",
            localText: "local base"
        )
        let raw = rawRecoveryReference(
            id: scenario.request.entryID,
            identity: identity(),
            data: scenario.rawData
        )
        let external = externalChange(
            DocumentSnapshot(
                text: "base external",
                format: .newDocument
            ),
            identity: identity(),
            resource: "decoded-displaced-preimage"
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
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .decoded(external)
                    )
                )
            )
        )
        let merge = try XCTUnwrap(mergeRequest(in: persisted.effects))
        XCTAssertEqual(merge.base, scenario.initial.durableBaseline?.snapshot)
        XCTAssertEqual(
            merge.local,
            DocumentSnapshot(text: "local base", format: .newDocument)
        )
        XCTAssertEqual(merge.external, external.snapshot)
        XCTAssertEqual(
            merge.localSourceRevision,
            SourceRevision(
                number: 8,
                text: "local base"
            ))

        let mergeResult = ThreeWayTextMerger().result(for: merge)
        let merged = DocumentSyncReducer.reduce(
            persisted.state,
            event: .mergeFinished(
                token: merge.token,
                result: mergeResult
            )
        )
        XCTAssertNil(merged.state.unresolvedDisplacedPreimage)
        XCTAssertEqual(merged.state.recoveryCleanup?.target, .raw([raw]))
        let rejectedManualDiscard = DocumentSyncReducer.reduce(
            merged.state,
            event: .discardRawRecovery
        )
        XCTAssertEqual(rejectedManualDiscard.state, merged.state)
        XCTAssertTrue(rejectedManualDiscard.effects.isEmpty)
        let saveDeadline = try XCTUnwrap(
            deadline(in: merged.effects, kind: .localSave)
        )
        let preparing = DocumentSyncReducer.reduce(
            merged.state,
            event: .deadlineFired(saveDeadline)
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let pending = PendingSaveToken(
            generation: preparation.commitGeneration,
            sourceRevision: preparation.sourceRevision,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: preparation.snapshot
            ),
            expectedDurableState: merged.state.durableBaseline?.asDurableFileState,
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
                            resource: "merged-after-preimage"
                        ),
                        displacedPreimage: nil,
                        safety: .atomicSwap
                    )
                )
            )
        )
        let discard = try XCTUnwrap(recoveryDiscardRequest(in: saved.effects))
        XCTAssertEqual(discard.target, .raw([raw]))
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
        XCTAssertEqual(discarded.state.recovery, .clear)
        XCTAssertNil(discarded.state.recoveryCleanup)
    }

    func testRawMergeWaitsForManagedCloseAndFailsClosedAfterANewerEdit() throws {
        let scenario = try unexpectedPreimagePersistence(
            rawText: "raw-merge-input"
        )
        let raw = rawRecoveryReference(
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
                                raw: [raw]
                            )
                        ),
                        durablyPersistedRawEntryID: scenario.request.entryID,
                        acknowledgedRecoveryArtifact: scenario.artifact,
                        decodeOutcome: .decoded(
                            externalChange(
                                DocumentSnapshot(
                                    text: "raw-merge-input",
                                    format: .newDocument
                                ),
                                identity: identity(),
                                resource: "raw-merge-input"
                            )
                        )
                    )
                )
            )
        )
        let merge = try XCTUnwrap(mergeRequest(in: persisted.effects))
        let rejectedDiscardDuringMerge = DocumentSyncReducer.reduce(
            persisted.state,
            event: .discardRawRecovery
        )
        XCTAssertEqual(rejectedDiscardDuringMerge.state, persisted.state)
        XCTAssertTrue(rejectedDiscardDuringMerge.effects.isEmpty)
        let closing = DocumentSyncReducer.reduce(persisted.state, event: .requestClose)
        XCTAssertNil(closeResolution(in: closing.effects))
        XCTAssertNotNil(deadline(in: closing.effects, kind: .close))

        let newerRevision = SourceRevision(number: 9, text: "newer-while-raw-merge")
        let edited = DocumentSyncReducer.reduce(
            persisted.state,
            event: .sourceChanged(newerRevision, format: .newDocument)
        )
        XCTAssertEqual(edited.state.source, newerRevision)
        XCTAssertEqual(
            edited.state.unresolvedDisplacedPreimage?.entryID,
            scenario.request.entryID
        )
        XCTAssertEqual(edited.state.issue?.failure, .recovery)
        let lateMerge = DocumentSyncReducer.reduce(
            edited.state,
            event: .mergeFinished(
                token: merge.token,
                result: ThreeWayTextMerger().result(for: merge)
            )
        )
        XCTAssertEqual(lateMerge.state, edited.state)
        XCTAssertTrue(lateMerge.effects.isEmpty)
    }

}
