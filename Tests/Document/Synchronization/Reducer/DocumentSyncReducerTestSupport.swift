import Foundation
import XCTest

@testable import DarthScriptum

extension DocumentSyncReducerTests {
    func restoredRecoveryWithUnexpectedRawPersistence() throws -> (
        originalRecords: DocumentSyncRecoveryRecords,
        entry: RecoveryEntry,
        oldRaw: DocumentSyncRawRecoveryReference,
        persisting: DocumentSyncTransition,
        request: DocumentSyncRecoveryPersistRequest,
        artifact: CommitRecoveryArtifact,
        rawData: Data
    ) {
        var recoverable = makeState()
        let entry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity(),
            snapshot: DocumentSnapshot(
                text: "restored selected cleanup",
                format: .newDocument
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 48)
        )
        let oldRaw = rawRecoveryReference(
            id: UUID(),
            identity: identity(),
            data: Data("selected-cleanup-original-raw".utf8)
        )
        let originalRecords = DocumentSyncRecoveryRecords(
            decoded: [entry],
            raw: [oldRaw]
        )
        recoverable.recovery = .available(originalRecords)

        let restored = DocumentSyncReducer.reduce(
            recoverable,
            event: .restoreLocalRecovery
        )
        let preparing = DocumentSyncReducer.reduce(
            restored.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: restored.effects, kind: .localSave))
            )
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
        let artifact = try recoveryArtifact(id: UUID(), for: commit)
        let rawData = Data("selected-cleanup-new-raw".utf8)
        let persisting = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: commit.commitGeneration,
                        committedFingerprint: .make(
                            data: commit.pendingSave.encodedData,
                            resourceIdentifier: "selected-cleanup-commit"
                        ),
                        displacedPreimage: rawData,
                        safety: .atomicSwap,
                        recoveryArtifact: artifact
                    )
                )
            )
        )
        return (
            originalRecords,
            entry,
            oldRaw,
            persisting,
            try XCTUnwrap(recoveryPersistRequest(in: persisting.effects)),
            artifact,
            rawData
        )
    }

    func recoveryArtifactValidationWrite() throws -> (
        initial: DocumentSyncState,
        pending: PendingSaveToken,
        writing: DocumentSyncTransition,
        commit: DocumentSyncSaveCommitRequest
    ) {
        let initial = makeState()
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(
                SourceRevision(number: 8, text: "artifact-validation-local"),
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
        let pending = pendingSave(
            sourceRevision: preparation.sourceRevision,
            snapshot: preparation.snapshot,
            baseline: initial.durableBaseline
        )
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(token: preparation.token, pendingSave: pending)
        )
        return (
            initial,
            pending,
            writing,
            try XCTUnwrap(commitRequest(in: writing.effects))
        )
    }

    func unexpectedPreimagePersistence(
        rawText: String = "unexpected-external-preimage",
        localText: String = "local-after-unexpected-preimage"
    ) throws -> (
        initial: DocumentSyncState,
        transition: DocumentSyncTransition,
        request: DocumentSyncRecoveryPersistRequest,
        artifact: CommitRecoveryArtifact,
        rawData: Data
    ) {
        let initial = makeState()
        let localRevision = SourceRevision(
            number: 8,
            text: localText
        )
        let edited = DocumentSyncReducer.reduce(
            initial,
            event: .sourceChanged(localRevision, format: .newDocument)
        )
        let preparing = DocumentSyncReducer.reduce(
            edited.state,
            event: .deadlineFired(
                try XCTUnwrap(deadline(in: edited.effects, kind: .localSave))
            )
        )
        let preparation = try XCTUnwrap(prepareRequest(in: preparing.effects))
        let pending = pendingSave(
            sourceRevision: preparation.sourceRevision,
            snapshot: preparation.snapshot,
            baseline: initial.durableBaseline
        )
        let writing = DocumentSyncReducer.reduce(
            preparing.state,
            event: .savePrepared(token: preparation.token, pendingSave: pending)
        )
        let commit = try XCTUnwrap(commitRequest(in: writing.effects))
        let artifact = try recoveryArtifact(id: UUID(), for: commit)
        let rawData = Data(rawText.utf8)
        let transition = DocumentSyncReducer.reduce(
            writing.state,
            event: .saveFinished(
                token: commit.token,
                completion: saveCompletion(
                    FileCommitResult(
                        generation: pending.generation,
                        committedFingerprint: fingerprint(
                            preparation.snapshot.text,
                            resource: "committed-after-unexpected-preimage"
                        ),
                        displacedPreimage: rawData,
                        safety: .atomicSwap,
                        recoveryArtifact: artifact
                    )
                )
            )
        )
        return (
            initial,
            transition,
            try XCTUnwrap(recoveryPersistRequest(in: transition.effects)),
            artifact,
            rawData
        )
    }

    func rawRecoveryReference(
        id: UUID,
        identity: DocumentIdentity,
        data: Data,
        dataURL: URL? = URL(fileURLWithPath: "/tmp/raw-recovery-reference.bin")
    ) -> DocumentSyncRawRecoveryReference {
        let fingerprint = FileFingerprint.make(data: data)
        return DocumentSyncRawRecoveryReference(
            id: id,
            documentIdentity: identity,
            dataURL: dataURL,
            byteCount: fingerprint.byteCount,
            contentDigest: fingerprint.contentDigest,
            createdAt: Date(timeIntervalSinceReferenceDate: 41)
        )
    }

    func recoveryArtifact(id: UUID) -> CommitRecoveryArtifact {
        let replacementDirectory = URL(fileURLWithPath: "/tmp/recovery-artifact")
        return CommitRecoveryArtifact(
            id: id,
            journalURL: replacementDirectory.appendingPathComponent("journal.json"),
            candidateURL: replacementDirectory.appendingPathComponent("candidate"),
            replacementDirectoryURL: replacementDirectory,
            replacementDirectoryResourceIdentifier: "test-recovery-artifact"
        )
    }

    func recoveryArtifact(
        id: UUID,
        for commit: DocumentSyncSaveCommitRequest
    ) throws -> CommitRecoveryArtifact {
        let replacementDirectory = URL(fileURLWithPath: "/tmp/recovery-artifact")
        let expectedBaseline = try XCTUnwrap(commit.expectedBaseline)
        return CommitRecoveryArtifact(
            id: id,
            journalURL: replacementDirectory.appendingPathComponent("journal.json"),
            candidateURL: replacementDirectory.appendingPathComponent("candidate"),
            replacementDirectoryURL: replacementDirectory,
            replacementDirectoryResourceIdentifier: "test-recovery-artifact",
            binding: CommitRecoveryArtifactBinding(
                documentIdentity: commit.identity,
                targetURL: commit.targetURL,
                expectedPreimageFingerprint: expectedBaseline.fingerprint,
                committedPayloadFingerprint: commit.pendingSave.contentFingerprint
            )
        )
    }

    func makeState() -> DocumentSyncState {
        let snapshot = DocumentSnapshot(text: "base", format: .newDocument)
        let data = try! TextFileCodec.encode(snapshot)
        let baseline = try! TextFileCodec.durableBaseline(
            data: data,
            targetURL: documentURL,
            fingerprint: .make(
                data: data,
                resourceIdentifier: "base-resource"
            ),
            documentIdentity: identity(),
            sourceRevision: SourceRevision(number: 7, text: "base"),
            commitGeneration: 11
        )
        let state = DocumentSyncState(
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
            durableBaseline: baseline,
            recoveryAccess: .ready(generation: 4)
        )
        return DocumentSyncReducer.reduce(state, event: .started).state
    }

    func durableBaseline(
        for snapshot: DocumentSnapshot,
        targetURL: URL,
        identity: DocumentIdentity,
        sourceRevision: SourceRevision,
        resource: String,
        commitGeneration: UInt64 = 11
    ) -> DocumentSyncDurableBaseline {
        let data = try! TextFileCodec.encode(snapshot)
        return try! TextFileCodec.durableBaseline(
            data: data,
            targetURL: targetURL,
            fingerprint: .make(data: data, resourceIdentifier: resource),
            documentIdentity: identity,
            sourceRevision: sourceRevision,
            commitGeneration: commitGeneration
        )
    }

    func identity() -> DocumentIdentity {
        DocumentIdentity.make(url: documentURL)
    }

    func migratedRecoveryRecords(
        _ records: DocumentSyncRecoveryRecords,
        to identity: DocumentIdentity
    ) -> DocumentSyncRecoveryRecords {
        let decoded = records.decoded.map {
            RecoveryEntry(
                id: $0.id,
                documentIdentity: identity,
                snapshot: $0.snapshot,
                createdAt: $0.createdAt
            )
        }
        let raw = records.raw.map {
            DocumentSyncRawRecoveryReference(
                id: $0.id,
                documentIdentity: identity,
                dataURL: $0.dataURL,
                byteCount: $0.byteCount,
                contentDigest: $0.contentDigest,
                createdAt: $0.createdAt
            )
        }
        return DocumentSyncRecoveryRecords(decoded: decoded, raw: raw)
    }

    func monitorToken(
        in state: DocumentSyncState
    ) throws -> SyncEffectToken {
        try XCTUnwrap(state.activeTokens[.monitor])
    }

    func fingerprint(_ text: String, resource: String) -> FileFingerprint {
        .make(data: Data(text.utf8), resourceIdentifier: resource)
    }

    func externalChange(
        _ snapshot: DocumentSnapshot,
        targetURL: URL? = nil,
        identity: DocumentIdentity? = nil,
        resource: String = "external"
    ) -> DocumentSyncExternalChange {
        let data = try! TextFileCodec.encode(snapshot)
        let resolvedTargetURL = targetURL ?? documentURL
        let targetIdentity =
            identity
            ?? DocumentIdentity.make(
                url: resolvedTargetURL
            )
        return try! TextFileCodec.decodeExternalChange(
            data: data,
            targetURL: resolvedTargetURL,
            identity: targetIdentity,
            fingerprint: .make(data: data, resourceIdentifier: resource)
        )
    }

    func externalObservation(
        _ snapshot: DocumentSnapshot,
        targetURL: URL? = nil,
        identity: DocumentIdentity? = nil,
        fingerprint expectedFingerprint: FileFingerprint? = nil,
        resource: String = "external"
    ) -> DocumentSyncExternalReadObservation {
        let data = try! TextFileCodec.encode(snapshot)
        let resolvedTargetURL = targetURL ?? documentURL
        let targetIdentity =
            identity
            ?? DocumentIdentity.make(
                url: resolvedTargetURL
            )
        return try! TextFileCodec.externalReadObservation(
            data: data,
            targetURL: resolvedTargetURL,
            identity: targetIdentity,
            fingerprint: expectedFingerprint
                ?? .make(data: data, resourceIdentifier: resource)
        )
    }

    func pendingSave(
        sourceRevision: SourceRevision,
        snapshot: DocumentSnapshot,
        baseline: DocumentSyncDurableBaseline?
    ) -> PendingSaveToken {
        PendingSaveToken(
            generation: 12,
            sourceRevision: sourceRevision,
            preparedPayload: try! TextFileCodec.prepareSavePayload(
                for: snapshot
            ),
            expectedDurableState: baseline?.asDurableFileState,
            targetURL: documentURL
        )
    }

    func deadline(
        in effects: [DocumentSyncEffect],
        kind: SyncDeadlineKind
    ) -> SyncDeadline? {
        deadlineRequest(in: effects, kind: kind)?.deadline
    }

    func deadlineRequest(
        in effects: [DocumentSyncEffect],
        kind: SyncDeadlineKind
    ) -> SyncDeadlineRequest? {
        for effect in effects {
            guard case .schedule(let request) = effect,
                request.deadline.kind == kind
            else {
                continue
            }
            return request
        }
        return nil
    }

    func prepareRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncSavePreparationRequest? {
        for effect in effects {
            if case .prepareSave(let request) = effect {
                return request
            }
        }
        return nil
    }

    func commitRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncSaveCommitRequest? {
        for effect in effects {
            if case .commitSave(let request) = effect {
                return request
            }
        }
        return nil
    }

    func commitReconciliationRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncCommitReconciliationRequest? {
        for effect in effects {
            if case .reconcileCommit(let request) = effect {
                return request
            }
        }
        return nil
    }

    func readRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncExternalReadRequest? {
        for effect in effects {
            if case .readExternal(let request) = effect {
                return request
            }
        }
        return nil
    }

    func mergeRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncMergeRequest? {
        for effect in effects {
            if case .merge(let request) = effect {
                return request
            }
        }
        return nil
    }

    func recoveryPersistRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncRecoveryPersistRequest? {
        for effect in effects {
            if case .recovery(.persist(let request)) = effect {
                return request
            }
        }
        return nil
    }

    func recoveryLoadRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncRecoveryLoadRequest? {
        for effect in effects {
            if case .recovery(.load(let request)) = effect {
                return request
            }
        }
        return nil
    }

    func recoveryReconciliationRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncRecoveryReconciliationRequest? {
        for effect in effects {
            if case .recovery(.reconcile(let request)) = effect {
                return request
            }
        }
        return nil
    }

    func recoveryMigrationRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncRecoveryMigrationRequest? {
        for effect in effects {
            if case .recovery(.migrate(let request)) = effect {
                return request
            }
        }
        return nil
    }

    func recoveryDiscardRequest(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncRecoveryDiscardRequest? {
        for effect in effects {
            if case .recovery(.discard(let request)) = effect {
                return request
            }
        }
        return nil
    }

    func monitorRequest(
        in effects: [DocumentSyncEffect],
        action: DocumentSyncMonitorAction? = nil
    ) -> DocumentSyncMonitorRequest? {
        for effect in effects {
            if case .monitor(let request) = effect,
                action == nil || request.action == action
            {
                return request
            }
        }
        return nil
    }

    func closeResolution(
        in effects: [DocumentSyncEffect]
    ) -> DocumentSyncCloseResolution? {
        for effect in effects {
            if case .resolveClose(let resolution) = effect {
                return resolution
            }
        }
        return nil
    }

    func saveCompletion(
        _ result: FileCommitResult
    ) -> DocumentSyncSaveCompletion {
        DocumentSyncSaveCompletion(result: result)
    }
}
