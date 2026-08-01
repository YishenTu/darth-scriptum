import Foundation

// Immutable recovery-effect construction and recovery-mutation progression.
// Methods without `private` are reducer-internal boundaries shared with
// recovery events and other transition domains.
extension DocumentSyncReducer {
    static func startRecoveryLoad(
        _ state: inout DocumentSyncState,
        scope: DocumentSyncRecoveryLoadScope,
        retriesStartup: Bool = false
    ) -> DocumentSyncEffect {
        let token = makeToken(&state, operation: .recovery)
        return .recovery(
            .load(
                DocumentSyncRecoveryLoadRequest(
                    token: token,
                    scope: scope,
                    retriesStartup: retriesStartup
                )
            )
        )
    }

    static func startRecoveryReconciliation(
        _ state: inout DocumentSyncState,
        barrier: DocumentSyncRecoveryMutationBarrier
    ) -> DocumentSyncEffect? {
        guard let intent = recoveryReconciliationIntent(for: state),
            intent.originalIdentity == barrier.originalIdentity,
            intent.committedIdentity == barrier.committedIdentity
        else {
            return nil
        }
        let token = makeToken(&state, operation: .recovery)
        return .recovery(
            .reconcile(
                DocumentSyncRecoveryReconciliationRequest(
                    token: token,
                    originalIdentity: barrier.originalIdentity,
                    committedIdentity: barrier.committedIdentity,
                    intent: intent
                )
            )
        )
    }

    static func startRecoveryPersistence(
        _ state: inout DocumentSyncState,
        attachment: DocumentSyncFileAttachment,
        snapshot: DocumentSnapshot,
        cleanupMinimumSourceRevision: SourceRevision? = nil,
        cleanupTarget: DocumentSyncRecoveryDiscardTarget? = nil,
        cleanupPurpose: DocumentSyncRecoveryMutationPurpose = .discardRestoredRecords
    ) -> [DocumentSyncEffect] {
        guard case .ready(let generation) = state.recoveryAccess,
            state.recoveryMutationBarrier == nil,
            state.activeTokens[.recovery] == nil
        else {
            return []
        }
        let expectedRecords = state.recovery.records ?? .empty
        state.pendingConflict = DocumentSyncPendingConflict(
            identity: attachment.identity,
            snapshot: snapshot
        )
        let entryID = UUID()
        let token = makeToken(&state, operation: .recovery)
        state.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: token,
                identity: attachment.identity,
                entryID: entryID,
                expectedStoreGeneration: generation,
                purpose: .persistConflict,
                payload: .snapshot(snapshot),
                expectedRecords: expectedRecords,
                cleanupMinimumSourceRevision: cleanupMinimumSourceRevision,
                cleanupTarget: cleanupTarget,
                cleanupPurpose: cleanupMinimumSourceRevision == nil
                    ? nil
                    : cleanupPurpose
            )
        )
        return [
            .recovery(
                .persist(
                    DocumentSyncRecoveryPersistRequest(
                        token: token,
                        identity: attachment.identity,
                        entryID: entryID,
                        payload: .snapshot(snapshot),
                        expectedRecords: expectedRecords,
                        expectedStoreGeneration: generation,
                        purpose: .persistConflict,
                        displacedPreimageContinuation: nil
                    )
                )
            )
        ]
    }

    static func startDisplacedPreimagePersistence(
        _ state: inout DocumentSyncState,
        continuation: DocumentSyncDisplacedPreimageContinuation
    ) -> [DocumentSyncEffect] {
        guard state.pendingDisplacedPreimage == continuation,
            case .ready(let generation) = state.recoveryAccess,
            state.activeTokens[.recovery] == nil
        else {
            return []
        }
        if let barrier = state.recoveryMutationBarrier {
            guard barrier.originalIdentity == continuation.originIdentity else {
                return []
            }
        } else {
            guard let attachment = state.fileAttachment,
                attachment.identity == continuation.originIdentity,
                attachment.epoch == continuation.originAttachmentEpoch
            else {
                return []
            }
        }
        let expectedRecords: DocumentSyncRecoveryRecords
        if let records = state.recovery.records {
            expectedRecords = records
        } else if case .persisting(let attempt) = state.recovery,
            let records = attempt.expectedRecords
        {
            expectedRecords = records
        } else {
            expectedRecords = .empty
        }
        let token = makeToken(&state, operation: .recovery)
        state.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: token,
                identity: continuation.originIdentity,
                entryID: continuation.entryID,
                expectedStoreGeneration: generation,
                purpose: .persistDisplacedPreimage,
                payload: .raw(continuation.rawPayload),
                expectedRecords: expectedRecords,
                displacedPreimageContinuation: continuation
            )
        )
        return [
            .recovery(
                .persist(
                    DocumentSyncRecoveryPersistRequest(
                        token: token,
                        identity: continuation.originIdentity,
                        entryID: continuation.entryID,
                        payload: .raw(continuation.rawPayload),
                        expectedRecords: expectedRecords,
                        expectedStoreGeneration: generation,
                        purpose: .persistDisplacedPreimage,
                        displacedPreimageContinuation: continuation
                    )
                )
            )
        ]
    }

    static func startRecoveryMigration(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard case .migrationPending(var migration) = state.recovery,
            migration.token == nil,
            state.recoveryMutationBarrier == nil,
            let attachment = state.fileAttachment,
            attachment.identity == migration.destinationIdentity,
            case .ready(let generation) = state.recoveryAccess
        else {
            return []
        }
        let token = makeToken(&state, operation: .recovery)
        migration.token = token
        migration.expectedStoreGeneration = generation
        state.recovery = .migrationPending(migration)
        return [
            .recovery(
                .migrate(
                    DocumentSyncRecoveryMigrationRequest(
                        token: token,
                        sourceIdentity: migration.sourceIdentity,
                        destinationIdentity: migration.destinationIdentity,
                        records: migration.records,
                        expectedStoreGeneration: generation
                    )
                )
            )
        ]
    }

    static func startRecoveryDiscard(
        _ state: inout DocumentSyncState,
        attachment: DocumentSyncFileAttachment,
        target: DocumentSyncRecoveryDiscardTarget,
        purpose: DocumentSyncRecoveryMutationPurpose
    ) -> [DocumentSyncEffect] {
        guard case .ready(let generation) = state.recoveryAccess else {
            return []
        }
        guard state.recoveryMutationBarrier == nil else {
            return []
        }
        guard case .available(let records) = state.recovery,
            recordsAfterDiscard(target, from: records) != nil
        else {
            return []
        }
        let token = makeToken(&state, operation: .recovery)
        state.recovery = .persisting(
            DocumentSyncRecoveryAttempt(
                token: token,
                identity: attachment.identity,
                expectedStoreGeneration: generation,
                purpose: purpose,
                expectedRecords: records,
                discardTarget: target
            )
        )
        return [
            .recovery(
                .discard(
                    DocumentSyncRecoveryDiscardRequest(
                        token: token,
                        identity: attachment.identity,
                        target: target,
                        expectedRecords: records,
                        expectedStoreGeneration: generation
                    )
                )
            )
        ]
    }

    static func finishRecoveryMutation(
        _ state: inout DocumentSyncState,
        records: DocumentSyncRecoveryRecords,
        generation: UInt64,
        recordsIdentity: DocumentIdentity
    ) -> [DocumentSyncEffect] {
        state.activeTokens.removeValue(forKey: .recovery)
        state.recoveryAccess = .ready(generation: generation)

        guard let barrier = state.recoveryMutationBarrier else {
            state.recovery = records.isEmpty ? .clear : .available(records)
            if state.unresolvedDisplacedPreimage != nil {
                if let cleanupEffects = resumeIndependentRecoveryCleanup(
                    whileRawIsUnresolved: &state
                ) {
                    return cleanupEffects
                }
                state.issue = issue(for: .recovery)
                return refuseCloseIfNeeded(&state)
            }
            state.issue = nil
            return continueSynchronization(&state)
        }

        state.recoveryMutationBarrier = nil
        if barrier.relocationDestination == nil,
            detachedRecoveryMutationContainsRawEvidence(
                state,
                records: records
            )
        {
            // A detached document must leave its durable raw evidence at the
            // last confirmed identity, without carrying stale recovery state
            // into the next unrelated attachment.
            state.recovery = .clear
            state.recoveryCleanup = nil
            state.pendingDisplacedPreimage = nil
            state.unresolvedDisplacedPreimage = nil
            state.issue = nil
            if let attachment = state.fileAttachment {
                state.recoveryAccess = .loading
                return [
                    startRecoveryLoad(
                        &state,
                        scope: .document(attachment.identity)
                    )
                ]
            }
            return continueSynchronization(&state)
        }
        guard let destination = barrier.relocationDestination,
            destination != recordsIdentity,
            !records.isEmpty
        else {
            state.recovery = records.isEmpty ? .clear : .available(records)
            if state.unresolvedDisplacedPreimage != nil {
                if let cleanupEffects = resumeIndependentRecoveryCleanup(
                    whileRawIsUnresolved: &state
                ) {
                    return cleanupEffects
                }
                state.issue = issue(for: .recovery)
                return refuseCloseIfNeeded(&state)
            }
            state.issue = nil
            return continueSynchronization(&state)
        }

        state.recovery = .migrationPending(
            DocumentSyncRecoveryMigration(
                token: nil,
                sourceIdentity: recordsIdentity,
                destinationIdentity: destination,
                expectedStoreGeneration: generation,
                records: records
            )
        )
        guard let attachment = state.fileAttachment,
            attachment.identity == destination
        else {
            state.issue = issue(for: .recovery)
            return []
        }
        state.issue = nil
        return startRecoveryMigration(&state)
    }

    static func resumeRecoveryCleanupIfNeeded(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect]? {
        guard let cleanup = state.recoveryCleanup else { return nil }
        guard case .available(let records) = state.recovery,
            records == cleanup.records,
            let durableBaseline = state.durableBaseline,
            durableBaseline.sourceRevision.number
                >= cleanup.minimumSourceRevision.number,
            let attachment = state.fileAttachment,
            recordsBelongToIdentity(records, identity: attachment.identity)
        else {
            return nil
        }
        let effects = startRecoveryDiscard(
            &state,
            attachment: attachment,
            target: cleanup.target,
            purpose: cleanup.discardPurpose
        )
        return effects.isEmpty ? nil : effects
    }

    static func resumeIndependentRecoveryCleanup(
        whileRawIsUnresolved state: inout DocumentSyncState
    ) -> [DocumentSyncEffect]? {
        guard let unresolved = state.unresolvedDisplacedPreimage,
            let cleanup = state.recoveryCleanup,
            !discardTargetContainsRawEntry(
                cleanup.target,
                containsRawEntryID: unresolved.entryID
            )
        else {
            return nil
        }
        return resumeRecoveryCleanupIfNeeded(&state)
    }
}
