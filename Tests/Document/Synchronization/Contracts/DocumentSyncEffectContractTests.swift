import Foundation
import XCTest

@testable import DarthScriptum

final class DocumentSyncEffectContractTests: XCTestCase {
    func testEvidenceReceiptsRejectForeignDocumentIdentity() throws {
        let targetURL = URL(fileURLWithPath: "/tmp/evidence-target.md")
        let foreignIdentity = DocumentIdentity.make(
            url: URL(fileURLWithPath: "/tmp/evidence-foreign.md")
        )
        let source = SourceRevision(number: 3, text: "source")
        let snapshot = DocumentSnapshot(text: "source", format: .newDocument)
        let data = try TextFileCodec.encode(snapshot)
        let fingerprint = FileFingerprint.make(
            data: data,
            resourceIdentifier: "evidence-resource"
        )

        XCTAssertThrowsError(
            try TextFileCodec.durableBaseline(
                data: data,
                targetURL: targetURL,
                fingerprint: fingerprint,
                documentIdentity: foreignIdentity,
                sourceRevision: source,
                commitGeneration: 9
            )
        ) { error in
            XCTAssertEqual(
                error as? TextFileCodec.EvidenceError,
                .identityDoesNotMatchTarget
            )
        }

        let pendingSave = PendingSaveToken(
            generation: 9,
            sourceRevision: source,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: snapshot
            ),
            expectedDurableState: nil,
            targetURL: targetURL
        )
        XCTAssertNil(
            DocumentSyncDurableBaseline.fromCommittedPayload(
                pendingSave,
                documentIdentity: foreignIdentity,
                committedFingerprint: pendingSave.contentFingerprint,
                sourceRevision: source,
                commitGeneration: 9
            )
        )
    }

    func testEveryEffectCarriesCompleteImmutableExecutionInput() throws {
        let lifetime = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let url = URL(fileURLWithPath: "/tmp/effect-contract.md")
        let identity = DocumentIdentity.make(url: url)
        let source = SourceRevision(number: 3, text: "source")
        var snapshot = DocumentSnapshot(text: "source", format: .newDocument)
        let baselineData = try TextFileCodec.encode(snapshot)
        let baseline = try TextFileCodec.durableBaseline(
            data: baselineData,
            targetURL: url,
            fingerprint: .make(
                data: baselineData,
                resourceIdentifier: "baseline-resource"
            ),
            documentIdentity: identity,
            sourceRevision: source,
            commitGeneration: 9
        )
        let prepareToken = token(
            lifetime: lifetime,
            operation: .savePreparation,
            attempt: 1
        )
        let commitToken = token(
            lifetime: lifetime,
            operation: .saveCommit,
            attempt: 2
        )
        let pendingSave = PendingSaveToken(
            generation: 9,
            sourceRevision: source,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: snapshot
            ),
            expectedDurableState: baseline.asDurableFileState,
            targetURL: url
        )
        let entry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity,
            snapshot: snapshot,
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let raw = DocumentSyncRawRecoveryReference(
            id: UUID(),
            documentIdentity: identity,
            dataURL: URL(fileURLWithPath: "/tmp/raw-contract.bin"),
            byteCount: 3,
            contentDigest: "digest",
            createdAt: Date(timeIntervalSinceReferenceDate: 3)
        )
        let records = DocumentSyncRecoveryRecords(decoded: entry, raw: raw)
        let committedIdentity = DocumentIdentity.make(
            url: URL(fileURLWithPath: "/tmp/committed-contract.md")
        )
        var rawData = Data("raw".utf8)
        let rawArtifact = CommitRecoveryArtifact(
            id: UUID(),
            journalURL: URL(fileURLWithPath: "/tmp/raw-contract-journal.json"),
            candidateURL: URL(fileURLWithPath: "/tmp/raw-contract-candidate"),
            replacementDirectoryURL: URL(
                fileURLWithPath: "/tmp/raw-contract-directory"
            ),
            replacementDirectoryResourceIdentifier: "raw-contract-directory"
        )
        let rawPayload = DocumentSyncRawRecoveryPayload(
            data: rawData,
            targetURL: url,
            recoveryArtifact: rawArtifact
        )
        XCTAssertEqual(rawPayload.data, rawData)
        XCTAssertEqual(rawPayload.fingerprint, FileFingerprint.make(data: rawData))
        XCTAssertEqual(rawPayload.targetURL, url)
        let rawEntryID = UUID()
        let rawContinuation = DocumentSyncDisplacedPreimageContinuation(
            entryID: rawEntryID,
            originIdentity: identity,
            originAttachmentEpoch: 4,
            rawPayload: rawPayload,
            mergeBase: snapshot,
            local: snapshot,
            localSourceRevision: source,
            pendingRevision: source,
            preCommitBaseline: baseline,
            committedBaseline: baseline,
            commitSafety: .atomicSwap
        )
        let rawPersistenceIntent: DocumentSyncRecoveryReconciliationIntent =
            .persist(
                identity: identity,
                entryID: rawEntryID,
                payload: .raw(rawPayload),
                expectedRecords: records,
                expectedStoreGeneration: 9,
                purpose: .persistDisplacedPreimage,
                displacedPreimageContinuation: rawContinuation
            )

        let effects: [DocumentSyncEffect] = [
            .schedule(
                SyncDeadlineRequest(
                    deadline: SyncDeadline(kind: .localSave, token: prepareToken),
                    delay: .milliseconds(100)
                )
            ),
            .cancelDeadline(SyncDeadline(kind: .localSave, token: prepareToken)),
            .cancelAllDeadlines,
            .prepareSave(
                DocumentSyncSavePreparationRequest(
                    token: prepareToken,
                    sourceRevision: source,
                    snapshot: snapshot,
                    targetURL: url,
                    identity: identity,
                    attachmentEpoch: 4,
                    expectedBaseline: baseline,
                    commitGeneration: 10
                )
            ),
            .commitSave(
                DocumentSyncSaveCommitRequest(
                    token: commitToken,
                    pendingSave: pendingSave,
                    targetURL: url,
                    identity: identity,
                    attachmentEpoch: 4,
                    expectedBaseline: baseline,
                    commitGeneration: 9
                )
            ),
            .readExternal(
                DocumentSyncExternalReadRequest(
                    token: token(
                        lifetime: lifetime,
                        operation: .externalRead,
                        attempt: 3
                    ),
                    targetURL: url,
                    identity: identity,
                    attachmentEpoch: 4,
                    expectedBaseline: baseline
                )
            ),
            .merge(
                DocumentSyncMergeRequest(
                    token: token(
                        lifetime: lifetime,
                        operation: .merge,
                        attempt: 4
                    ),
                    base: baseline.snapshot,
                    local: snapshot,
                    external: DocumentSnapshot(
                        text: "external",
                        format: .newDocument
                    ),
                    localSourceRevision: source
                )
            ),
            .recovery(
                .load(
                    DocumentSyncRecoveryLoadRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 5
                        ),
                        scope: .document(identity)
                    )
                )
            ),
            .recovery(
                .reconcile(
                    DocumentSyncRecoveryReconciliationRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 6
                        ),
                        originalIdentity: identity,
                        committedIdentity: committedIdentity,
                        intent: .migrate(
                            sourceIdentity: identity,
                            destinationIdentity: committedIdentity,
                            records: records,
                            expectedStoreGeneration: 9
                        )
                    )
                )
            ),
            .recovery(
                .persist(
                    DocumentSyncRecoveryPersistRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 7
                        ),
                        identity: identity,
                        entryID: entry.id,
                        payload: .snapshot(snapshot),
                        expectedRecords: records,
                        expectedStoreGeneration: 9,
                        purpose: .persistConflict,
                        displacedPreimageContinuation: nil
                    )
                )
            ),
            .recovery(
                .reconcile(
                    DocumentSyncRecoveryReconciliationRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 12
                        ),
                        originalIdentity: identity,
                        committedIdentity: identity,
                        intent: rawPersistenceIntent
                    )
                )
            ),
            .recovery(
                .persist(
                    DocumentSyncRecoveryPersistRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 13
                        ),
                        identity: identity,
                        entryID: rawEntryID,
                        payload: .raw(rawPayload),
                        expectedRecords: records,
                        expectedStoreGeneration: 9,
                        purpose: .persistDisplacedPreimage,
                        displacedPreimageContinuation: rawContinuation
                    )
                )
            ),
            .recovery(
                .migrate(
                    DocumentSyncRecoveryMigrationRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 8
                        ),
                        sourceIdentity: identity,
                        destinationIdentity: DocumentIdentity.make(
                            url: URL(fileURLWithPath: "/tmp/moved-contract.md")
                        ),
                        records: records,
                        expectedStoreGeneration: 9
                    )
                )
            ),
            .recovery(
                .discard(
                    DocumentSyncRecoveryDiscardRequest(
                        token: token(
                            lifetime: lifetime,
                            operation: .recovery,
                            attempt: 9
                        ),
                        identity: identity,
                        target: .records(records),
                        expectedRecords: records,
                        expectedStoreGeneration: 9
                    )
                )
            ),
            .monitor(
                DocumentSyncMonitorRequest(
                    token: token(
                        lifetime: lifetime,
                        operation: .monitor,
                        attempt: 10
                    ),
                    action: .start,
                    targetURL: url,
                    identity: identity,
                    attachmentEpoch: 4
                )
            ),
            .resolveClose(
                DocumentSyncCloseResolution(
                    token: token(
                        lifetime: lifetime,
                        operation: .close,
                        attempt: 11
                    ),
                    disposition: .allowManagedClose
                )
            ),
            .reconcileCommit(
                DocumentSyncCommitReconciliationRequest(
                    token: token(
                        lifetime: lifetime,
                        operation: .commitReconciliation,
                        attempt: 14
                    ),
                    originalCommitToken: commitToken,
                    pendingSave: pendingSave,
                    targetURL: url,
                    identity: identity,
                    attachmentEpoch: 4,
                    expectedBaseline: baseline,
                    commitGeneration: 9
                )
            ),
        ]

        snapshot.text = "mutated-after-effect-construction"
        rawData.append(0)

        XCTAssertEqual(effects.count, 17)
        guard case .prepareSave(let preparation) = effects[3] else {
            return XCTFail("Expected an immutable save preparation effect.")
        }
        XCTAssertEqual(preparation.snapshot.text, "source")
        XCTAssertEqual(preparation.targetURL, url)
        XCTAssertEqual(preparation.identity, identity)
        XCTAssertEqual(preparation.expectedBaseline, baseline)
        XCTAssertEqual(preparation.commitGeneration, 10)
        guard case .commitSave(let commit) = effects[4] else {
            return XCTFail("Expected a complete save commit effect.")
        }
        XCTAssertEqual(commit.pendingSave.encodedData, Data("source".utf8))
        XCTAssertEqual(commit.targetURL, url)
        XCTAssertEqual(commit.identity, identity)
        guard case .recovery(.reconcile(let reconciliation)) = effects[8] else {
            return XCTFail("Expected a typed recovery reconciliation effect.")
        }
        XCTAssertEqual(reconciliation.originalIdentity, identity)
        XCTAssertNotEqual(
            reconciliation.originalIdentity,
            reconciliation.committedIdentity
        )
        XCTAssertEqual(
            reconciliation.intent,
            .migrate(
                sourceIdentity: identity,
                destinationIdentity: committedIdentity,
                records: records,
                expectedStoreGeneration: 9
            )
        )
        guard case .recovery(.persist(let persistence)) = effects[9] else {
            return XCTFail("Expected a typed recovery persistence effect.")
        }
        XCTAssertEqual(
            persistence,
            DocumentSyncRecoveryPersistRequest(
                token: token(
                    lifetime: lifetime,
                    operation: .recovery,
                    attempt: 7
                ),
                identity: identity,
                entryID: entry.id,
                payload: .snapshot(
                    DocumentSnapshot(text: "source", format: .newDocument)
                ),
                expectedRecords: records,
                expectedStoreGeneration: 9,
                purpose: .persistConflict,
                displacedPreimageContinuation: nil
            ))
        XCTAssertEqual(
            persistence.payload,
            .snapshot(DocumentSnapshot(text: "source", format: .newDocument))
        )
        XCTAssertEqual(persistence.expectedRecords, records)
        XCTAssertEqual(persistence.purpose, .persistConflict)
        XCTAssertNil(persistence.displacedPreimageContinuation)
        guard case .recovery(.reconcile(let rawReconciliation)) = effects[10] else {
            return XCTFail("Expected a raw recovery reconciliation effect.")
        }
        XCTAssertEqual(rawReconciliation.originalIdentity, identity)
        XCTAssertEqual(rawReconciliation.committedIdentity, identity)
        XCTAssertEqual(rawReconciliation.intent, rawPersistenceIntent)
        guard case .recovery(.persist(let rawPersistence)) = effects[11] else {
            return XCTFail("Expected a raw recovery persistence effect.")
        }
        XCTAssertEqual(rawPersistence.identity, identity)
        XCTAssertEqual(rawPersistence.entryID, rawEntryID)
        XCTAssertEqual(rawPersistence.payload, .raw(rawPayload))
        XCTAssertEqual(rawPersistence.rawPayload?.data, Data("raw".utf8))
        XCTAssertEqual(
            rawPersistence.rawPayload?.fingerprint,
            FileFingerprint.make(data: Data("raw".utf8))
        )
        XCTAssertEqual(rawPersistence.rawPayload?.recoveryArtifact, rawArtifact)
        XCTAssertEqual(rawPersistence.expectedRecords, records)
        XCTAssertEqual(rawPersistence.expectedStoreGeneration, 9)
        XCTAssertEqual(rawPersistence.purpose, .persistDisplacedPreimage)
        XCTAssertEqual(
            rawPersistence.displacedPreimageContinuation,
            rawContinuation
        )
        guard case .recovery(.migrate(let migration)) = effects[12] else {
            return XCTFail("Expected a typed recovery migration effect.")
        }
        XCTAssertNotEqual(migration.sourceIdentity, migration.destinationIdentity)
        XCTAssertEqual(migration.records, records)
        guard case .recovery(.discard(let discard)) = effects[13] else {
            return XCTFail("Expected a typed recovery discard effect.")
        }
        XCTAssertEqual(discard.target, .records(records))
        guard case .reconcileCommit(let commitReconciliation) = effects[16] else {
            return XCTFail("Expected a complete commit reconciliation effect.")
        }
        XCTAssertEqual(commitReconciliation.originalCommitToken, commitToken)
        XCTAssertEqual(commitReconciliation.pendingSave, pendingSave)
        XCTAssertEqual(commitReconciliation.targetURL, url)
        XCTAssertEqual(commitReconciliation.identity, identity)
        XCTAssertEqual(commitReconciliation.expectedBaseline, baseline)
    }

    func testTokenValueIdentityIncludesEveryStaleResultDimension() {
        let lifetime = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let token = self.token(
            lifetime: lifetime,
            operation: .externalRead,
            attempt: 11
        )
        let variants: Set<SyncEffectToken> = [
            token,
            self.token(lifetime: UUID(), operation: .externalRead, attempt: 11),
            SyncEffectToken(
                lifetime: lifetime,
                attachmentEpoch: 5,
                operation: .externalRead,
                attempt: 11
            ),
            self.token(lifetime: lifetime, operation: .merge, attempt: 11),
            self.token(lifetime: lifetime, operation: .externalRead, attempt: 12),
        ]

        XCTAssertEqual(variants.count, 5)
    }

    private func token(
        lifetime: UUID,
        operation: SyncOperationKind,
        attempt: UInt64
    ) -> SyncEffectToken {
        SyncEffectToken(
            lifetime: lifetime,
            attachmentEpoch: 4,
            operation: operation,
            attempt: attempt
        )
    }
}
