import Foundation

enum DocumentSyncSavePreparationExecution: Sendable {
    case prepared(PendingSaveToken)
    case failed(DocumentSyncFailure)
}

enum DocumentSyncExternalReadExecution: Sendable {
    case finished(DocumentSyncExternalReadResult)
    case failed(DocumentSyncFailure)
}

enum DocumentSyncMergeExecution: Sendable {
    case finished(DocumentSyncMergeResult)
    case failed(DocumentSyncFailure)
}

@MainActor
protocol DocumentSyncCoordinatorEffectExecuting: AnyObject {
    func prepareSave(
        _ request: DocumentSyncSavePreparationRequest,
        completion: @escaping @MainActor (DocumentSyncSavePreparationExecution) -> Void
    )

    func readExternal(
        _ request: DocumentSyncExternalReadRequest,
        completion: @escaping @MainActor (DocumentSyncExternalReadExecution) -> Void
    )

    func merge(
        _ request: DocumentSyncMergeRequest,
        completion: @escaping @MainActor (DocumentSyncMergeExecution) -> Void
    )

    func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest,
        completion: @escaping @MainActor (DocumentSyncCommitReconciliationResult) -> Void
    )
}

/// Executes CPU and file work solely from immutable effect request values.
/// It deliberately has no coordinator, host, source-buffer, or status access.
@MainActor
final class DocumentSyncDefaultEffectExecutor:
    DocumentSyncCoordinatorEffectExecuting {
    func prepareSave(
        _ request: DocumentSyncSavePreparationRequest,
        completion: @escaping @MainActor (DocumentSyncSavePreparationExecution) -> Void
    ) {
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.prepareSave(request)
            }.value
            completion(result)
        }
    }

    func readExternal(
        _ request: DocumentSyncExternalReadRequest,
        completion: @escaping @MainActor (DocumentSyncExternalReadExecution) -> Void
    ) {
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.readExternal(request)
            }.value
            completion(result)
        }
    }

    func merge(
        _ request: DocumentSyncMergeRequest,
        completion: @escaping @MainActor (DocumentSyncMergeExecution) -> Void
    ) {
        Task {
            let result: DocumentSyncMergeExecution = await Task.detached(
                priority: .utility
            ) { () -> DocumentSyncMergeExecution in
                .finished(ThreeWayTextMerger().result(for: request))
            }.value
            completion(result)
        }
    }

    func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest,
        completion: @escaping @MainActor (DocumentSyncCommitReconciliationResult) -> Void
    ) {
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.reconcileCommit(request)
            }.value
            completion(result)
        }
    }

    private nonisolated static func prepareSave(
        _ request: DocumentSyncSavePreparationRequest
    ) -> DocumentSyncSavePreparationExecution {
        do {
            let payload = try TextFileCodec.prepareSavePayload(
                for: request.snapshot
            )
            return .prepared(
                PendingSaveToken(
                    generation: request.commitGeneration,
                    sourceRevision: request.sourceRevision,
                    preparedPayload: payload,
                    expectedDurableState: request.expectedBaseline?
                        .asDurableFileState,
                    targetURL: request.targetURL
                )
            )
        } catch {
            return .failed(.localSave)
        }
    }

    private nonisolated static func readExternal(
        _ request: DocumentSyncExternalReadRequest
    ) -> DocumentSyncExternalReadExecution {
        do {
            let data = try Data(
                contentsOf: request.targetURL,
                options: [.mappedIfSafe]
            )
            let fingerprint = try SafeFileCommitter.fingerprint(
                for: request.targetURL,
                data: data
            )
            if request.expectedBaseline?.fingerprint == fingerprint {
                return .finished(
                    .unchanged(
                        try TextFileCodec.externalReadObservation(
                            data: data,
                            targetURL: request.targetURL,
                            identity: request.identity,
                            fingerprint: fingerprint
                        )
                    )
                )
            }
            return .finished(
                .changed(
                    try TextFileCodec.decodeExternalChange(
                        data: data,
                        targetURL: request.targetURL,
                        identity: request.identity,
                        fingerprint: fingerprint
                    )
                )
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .finished(.missing)
        } catch {
            return .failed(.externalRead)
        }
    }

    private nonisolated static func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest
    ) -> DocumentSyncCommitReconciliationResult {
        do {
            let data = try Data(
                contentsOf: request.targetURL,
                options: [.mappedIfSafe]
            )
            let fingerprint = try SafeFileCommitter.fingerprint(
                for: request.targetURL,
                data: data
            )
            guard fingerprint.contentDigest
                    == request.pendingSave.contentFingerprint.contentDigest,
                  fingerprint.byteCount
                    == request.pendingSave.contentFingerprint.byteCount else {
                return .notCommitted(
                    try TextFileCodec.externalReadObservation(
                        data: data,
                        targetURL: request.targetURL,
                        identity: request.identity,
                        fingerprint: fingerprint
                    )
                )
            }

            // A recovered byte match proves only the payload. The legacy
            // committer does not retain sufficient immutable evidence to
            // recreate an authoritative FileCommitResult safety receipt.
            // P1 supplies that durable reconciliation boundary.
            return .unresolved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return request.expectedBaseline == nil
                ? .notCommitted(nil)
                : .unresolved
        } catch {
            return .unresolved
        }
    }
}
