import Foundation

/// Executes recovery-store work solely from immutable reducer requests.
/// The store remains responsible for FIFO ordering and all blocking I/O.
@MainActor
final class DocumentSyncRecoveryEffectExecutor {
    private let recoveryStore: SessionRecoveryStore

    init(recoveryStore: SessionRecoveryStore) {
        self.recoveryStore = recoveryStore
    }

    func execute(
        _ request: DocumentSyncRecoveryRequest,
        completion: @escaping @MainActor (DocumentSyncRecoveryResult) -> Void
    ) {
        Task {
            let result = await execute(request)
            guard !Task.isCancelled else { return }
            completion(result)
        }
    }

    private func execute(
        _ request: DocumentSyncRecoveryRequest
    ) async -> DocumentSyncRecoveryResult {
        do {
            switch request {
            case .load(let load):
                if load.retriesStartup {
                    _ = try await recoveryStore.retryStartup()
                }
                let receipt = try await recoveryStore.load(scope: load.scope)
                return .loaded(
                    DocumentSyncRecoveryLoadResult(
                        scope: receipt.scope,
                        generation: receipt.generation,
                        records: recoveryRecords(from: receipt.records)
                    )
                )
            case .reconcile(let reconciliation):
                let receipt = try await recoveryStore.reconcile(
                    reconciliation.intent
                )
                return .reconciled(
                    DocumentSyncRecoveryReconciliationResult(
                        identity: receipt.identity,
                        generation: receipt.generation,
                        records: recoveryRecords(from: receipt.records),
                        acknowledgedRecoveryArtifact:
                            receipt.acknowledgedRecoveryArtifact
                    )
                )
            case .persist(let persistence):
                return try await persist(persistence)
            case .migrate(let migration):
                let receipt = try await recoveryStore.moveEntries(
                    from: migration.sourceIdentity,
                    to: migration.destinationIdentity,
                    expectedRecords: migration.records,
                    expectedGeneration: migration.expectedStoreGeneration
                )
                return .migrated(mutationResult(from: receipt))
            case .discard(let discard):
                let receipt = try await recoveryStore.discard(
                    target: discard.target,
                    for: discard.identity,
                    expectedRecords: discard.expectedRecords,
                    expectedGeneration: discard.expectedStoreGeneration
                )
                return .discarded(mutationResult(from: receipt))
            }
        } catch {
            return .failed(.recovery)
        }
    }

    private func persist(
        _ persistence: DocumentSyncRecoveryPersistRequest
    ) async throws -> DocumentSyncRecoveryResult {
        switch persistence.payload {
        case .snapshot(let snapshot):
            let receipt = try await recoveryStore.add(
                id: persistence.entryID,
                snapshot: snapshot,
                for: persistence.identity,
                expectedRecords: persistence.expectedRecords,
                expectedGeneration: persistence.expectedStoreGeneration
            )
            return .persisted(mutationResult(from: receipt))
        case .raw(let payload):
            let receipt = try await recoveryStore.persistRawData(
                payload.data,
                for: persistence.identity,
                id: persistence.entryID,
                expectedRecords: persistence.expectedRecords,
                expectedGeneration: persistence.expectedStoreGeneration,
                recoveryArtifact: payload.recoveryArtifact
            )
            let decodeOutcome = await Self.decodeRawRecovery(
                payload,
                identity: persistence.identity
            )
            return .rawPersisted(
                DocumentSyncRawRecoveryPersistResult(
                    mutation: mutationResult(from: receipt.mutation),
                    durablyPersistedRawEntryID: receipt.entry.id,
                    acknowledgedRecoveryArtifact:
                        receipt.acknowledgedRecoveryArtifact,
                    decodeOutcome: decodeOutcome
                )
            )
        }
    }

    private func mutationResult(
        from receipt: SessionRecoveryStoreMutationReceipt
    ) -> DocumentSyncRecoveryMutationResult {
        DocumentSyncRecoveryMutationResult(
            previousGeneration: receipt.previousGeneration,
            generation: receipt.generation,
            records: DocumentSyncRecoveryRecords(
                decoded: receipt.decodedEntries,
                raw: receipt.rawEntries.map(DocumentSyncRawRecoveryReference.init)
            )
        )
    }

    private func recoveryRecords(
        from records: SessionRecoveryStoreRecords
    ) -> DocumentSyncRecoveryRecords {
        DocumentSyncRecoveryRecords(
            decoded: records.decoded,
            raw: records.raw.map(DocumentSyncRawRecoveryReference.init)
        )
    }

    private nonisolated static func decodeRawRecovery(
        _ payload: DocumentSyncRawRecoveryPayload,
        identity: DocumentIdentity
    ) async -> DocumentSyncDisplacedPreimageDecodeOutcome {
        do {
            let change = try await DocumentFileAccess.perform {
                try TextFileCodec.decodeExternalChange(
                    data: payload.data,
                    targetURL: payload.targetURL,
                    identity: identity,
                    fingerprint: payload.fingerprint
                )
            }
            return .decoded(change)
        } catch {
            return .undecodable
        }
    }
}
