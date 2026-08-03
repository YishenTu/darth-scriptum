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

    func cancel(token: SyncEffectToken)

    func cancelAll()
}

/// Executes CPU and file work solely from immutable effect request values.
/// It deliberately has no coordinator, host, source-buffer, or status access.
@MainActor
final class DocumentSyncDefaultEffectExecutor:
    DocumentSyncCoordinatorEffectExecuting
{
    private struct CPUOperation {
        let cancel: @MainActor () -> Void
    }

    private let recoveryStore: SessionRecoveryStore
    private let fileAccessLane: DocumentFileAccessLane
    private let cpuOperationStartedHook: (@Sendable (SyncEffectToken) -> Void)?
    private var cpuOperations: [SyncEffectToken: CPUOperation] = [:]

    var activeCPUOperationTokens: Set<SyncEffectToken> {
        Set(cpuOperations.keys)
    }

    init(
        recoveryStore: SessionRecoveryStore,
        fileAccessLane: DocumentFileAccessLane =
            DocumentFileAccess.makeDocumentLane(),
        cpuOperationStartedHook: (@Sendable (SyncEffectToken) -> Void)? = nil
    ) {
        self.recoveryStore = recoveryStore
        self.fileAccessLane = fileAccessLane
        self.cpuOperationStartedHook = cpuOperationStartedHook
    }

    func prepareSave(
        _ request: DocumentSyncSavePreparationRequest,
        completion: @escaping @MainActor (DocumentSyncSavePreparationExecution) -> Void
    ) {
        cancel(token: request.token)
        let startedHook = cpuOperationStartedHook
        let worker = Task.detached(priority: .utility) {
            startedHook?(request.token)
            return Self.prepareSave(request)
        }
        let delivery = Task { @MainActor [weak self] in
            let execution = await worker.value
            guard let self else { return }
            self.cpuOperations.removeValue(forKey: request.token)
            guard !Task.isCancelled, let execution else { return }
            completion(execution)
        }
        cpuOperations[request.token] = CPUOperation {
            worker.cancel()
            delivery.cancel()
        }
    }

    func readExternal(
        _ request: DocumentSyncExternalReadRequest,
        completion: @escaping @MainActor (DocumentSyncExternalReadExecution) -> Void
    ) {
        Task {
            let result: DocumentSyncExternalReadExecution
            do {
                result = try await fileAccessLane.perform {
                    Self.readExternal(request)
                }
            } catch {
                result = .failed(.externalRead)
            }
            completion(result)
        }
    }

    func merge(
        _ request: DocumentSyncMergeRequest,
        completion: @escaping @MainActor (DocumentSyncMergeExecution) -> Void
    ) {
        cancel(token: request.token)
        let startedHook = cpuOperationStartedHook
        let worker = Task.detached(priority: .utility) {
            startedHook?(request.token)
            return Self.merge(request)
        }
        let delivery = Task { @MainActor [weak self] in
            let execution = await worker.value
            guard let self else { return }
            self.cpuOperations.removeValue(forKey: request.token)
            guard !Task.isCancelled, let execution else { return }
            completion(execution)
        }
        cpuOperations[request.token] = CPUOperation {
            worker.cancel()
            delivery.cancel()
        }
    }

    func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest,
        completion: @escaping @MainActor (DocumentSyncCommitReconciliationResult) -> Void
    ) {
        Task {
            let result = await recoveryStore.reconcileCommit(request)
            completion(result)
        }
    }

    func cancel(token: SyncEffectToken) {
        cpuOperations.removeValue(forKey: token)?.cancel()
    }

    func cancelAll() {
        let operations = cpuOperations.values
        cpuOperations.removeAll()
        for operation in operations {
            operation.cancel()
        }
    }

    private nonisolated static func prepareSave(
        _ request: DocumentSyncSavePreparationRequest
    ) -> DocumentSyncSavePreparationExecution? {
        do {
            try Task.checkCancellation()
            let payload = try TextFileCodec.prepareSavePayload(
                for: request.snapshot
            )
            try Task.checkCancellation()
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
        } catch is CancellationError {
            return nil
        } catch {
            return .failed(.localSave)
        }
    }

    private nonisolated static func merge(
        _ request: DocumentSyncMergeRequest
    ) -> DocumentSyncMergeExecution? {
        do {
            return .finished(
                try ThreeWayTextMerger().cancellableResult(for: request)
            )
        } catch is CancellationError {
            return nil
        } catch {
            return .failed(.merge)
        }
    }

    private nonisolated static func readExternal(
        _ request: DocumentSyncExternalReadRequest
    ) -> DocumentSyncExternalReadExecution {
        do {
            let payload = try TextFileCodec.readVerifiedFilePayload(
                at: request.targetURL
            )
            let data = payload.data
            let fingerprint = payload.fingerprint
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
        } catch let error as POSIXError where error.code == .ENOENT {
            return .finished(.missing)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .finished(.missing)
        } catch {
            return .failed(.externalRead)
        }
    }

}
