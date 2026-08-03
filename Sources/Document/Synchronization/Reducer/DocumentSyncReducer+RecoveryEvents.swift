import Foundation

// Recovery completion events and user-facing recovery intents. Methods without
// `private` are reducer-internal dispatcher boundaries.
extension DocumentSyncReducer {
    static func recoveryFinished(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        result: DocumentSyncRecoveryResult
    ) -> DocumentSyncTransition {
        guard token.operation == .recovery,
            accepts(state, token: token)
        else {
            return unchanged(state)
        }

        switch result {
        case .failed(let failure):
            guard accepts(failure, for: token.operation) else {
                return unchanged(state)
            }
            return failRecovery(state, failure: failure)
        case .loaded(let result):
            guard state.recoveryMutationBarrier == nil,
                case .loading = state.recoveryAccess,
                result.scope == recoveryLoadScope(for: state),
                records(result.records, belongTo: result.scope)
            else {
                return unchanged(state)
            }
            var updated = state
            updated.activeTokens.removeValue(forKey: .recovery)
            updated.recoveryAccess = .ready(generation: result.generation)
            var effects: [DocumentSyncEffect] = []
            if let attachment = updated.fileAttachment,
                attachment.identity.matches(url: attachment.url),
                updated.activeTokens[.monitor] == nil
            {
                effects.append(startMonitor(&updated, attachment: attachment))
            }
            if updated.recoveryMutationBarrier != nil {
                updated.issue = issue(for: .recovery)
                return transition(updated, effects: effects)
            }
            if case .migrationPending(var migration) = updated.recovery {
                migration.records = result.records
                migration.expectedStoreGeneration = result.generation
                updated.recovery = .migrationPending(migration)
                effects += startRecoveryMigration(&updated)
                return transition(updated, effects: effects)
            }
            if let cleanup = updated.recoveryCleanup {
                guard recordsPreserve(cleanup.records, in: result.records),
                    recordsAfterDiscard(cleanup.target, from: result.records)
                        != nil
                else {
                    updated.recoveryAccess = .failed(.recovery)
                    updated.issue = issue(for: .recovery)
                    return transition(updated, effects: effects)
                }
                updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                    records: result.records,
                    target: cleanup.target,
                    discardPurpose: cleanup.discardPurpose,
                    minimumSourceRevision: cleanup.minimumSourceRevision
                )
            }
            updated.recovery =
                result.records.isEmpty
                ? .clear
                : .available(result.records)
            if let deferred = applyPendingAttachmentTransition(updated) {
                return transition(
                    deferred.state,
                    effects: effects + deferred.effects
                )
            }
            effects += continueSynchronization(&updated)
            return transition(updated, effects: effects)
        case .reconciled(let result):
            guard case .loading = state.recoveryAccess,
                let barrier = state.recoveryMutationBarrier,
                let intent = recoveryReconciliationIntent(for: state),
                intent.originalIdentity == barrier.originalIdentity,
                intent.committedIdentity == barrier.committedIdentity,
                result.identity == barrier.originalIdentity
                    || result.identity == barrier.committedIdentity,
                result.generation >= intent.expectedStoreGeneration,
                records(
                    result.records,
                    belongTo: .document(result.identity)
                ),
                reconciliationResult(result, matches: intent)
            else {
                return unchanged(state)
            }
            var updated = state
            if case .persisting(let attempt) = state.recovery,
                let cleanup = state.recoveryCleanup,
                let discardTarget = attempt.discardTarget,
                discardTarget == cleanup.target,
                attempt.purpose == cleanup.discardPurpose,
                let expectedResult = recordsAfterDiscard(
                    discardTarget,
                    from: cleanup.records
                )
            {
                if result.records == expectedResult {
                    updated.recoveryCleanup = nil
                }
            } else if case .persisting(let attempt) = state.recovery,
                let cleanup = state.recoveryCleanup,
                let discardTarget = attempt.discardTarget,
                let expectedResult = recordsAfterDiscard(
                    discardTarget,
                    from: cleanup.records
                ),
                result.records == expectedResult
            {
                updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                    records: result.records,
                    target: cleanup.target,
                    discardPurpose: cleanup.discardPurpose,
                    minimumSourceRevision: cleanup.minimumSourceRevision
                )
            } else if case .migrationPending(let migration) = state.recovery,
                let cleanup = state.recoveryCleanup,
                cleanup.records == migration.records
            {
                let target =
                    result.identity == migration.destinationIdentity
                    ? migratedDiscardTarget(
                        cleanup.target,
                        to: migration.destinationIdentity
                    )
                    : cleanup.target
                updated.recoveryCleanup =
                    result.records.isEmpty
                    ? nil
                    : DocumentSyncRecoveryCleanup(
                        records: result.records,
                        target: target,
                        discardPurpose: cleanup.discardPurpose,
                        minimumSourceRevision: cleanup.minimumSourceRevision
                    )
            }
            if case .persisting(let attempt) = state.recovery,
                let expectedRecords = attempt.expectedRecords,
                let discardTarget = attempt.discardTarget,
                let expectedResult = recordsAfterDiscard(
                    discardTarget,
                    from: expectedRecords
                ),
                result.records == expectedResult,
                let unresolved = updated.unresolvedDisplacedPreimage,
                discardTargetContainsRawEntry(
                    discardTarget,
                    containsRawEntryID: unresolved.entryID
                )
            {
                updated.unresolvedDisplacedPreimage = nil
            }
            if case .persisting(let attempt) = state.recovery,
                attempt.purpose == .persistDisplacedPreimage,
                let entryID = attempt.entryID,
                let payload = attempt.rawPayload,
                let continuation = attempt.displacedPreimageContinuation,
                rawRecord(
                    with: entryID,
                    identity: result.identity,
                    payload: payload,
                    isPresentIn: result.records
                )
            {
                if let cleanup = state.recoveryCleanup {
                    guard
                        recordsAfterDiscard(
                            cleanup.target,
                            from: result.records
                        ) != nil
                    else {
                        return failRecovery(state, failure: .recovery)
                    }
                    updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                        records: result.records,
                        target: cleanup.target,
                        discardPurpose: cleanup.discardPurpose,
                        minimumSourceRevision: cleanup.minimumSourceRevision
                    )
                }
                updated.pendingDisplacedPreimage = nil
                updated.unresolvedDisplacedPreimage = continuation
                applyCommittedDisplacedPreimageBaselineIfCurrent(
                    continuation,
                    to: &updated
                )
            } else if case .persisting(let attempt) = state.recovery,
                attempt.purpose == .persistDisplacedPreimage,
                let continuation = attempt.displacedPreimageContinuation
            {
                updated.activeTokens.removeValue(forKey: .recovery)
                updated.recoveryAccess = .ready(generation: result.generation)
                let effects = startDisplacedPreimagePersistence(
                    &updated,
                    continuation: continuation
                )
                guard !effects.isEmpty else {
                    updated.issue = issue(for: .recovery)
                    return transition(updated)
                }
                return transition(updated, effects: effects)
            }
            if case .persisting(let attempt) = state.recovery,
                attempt.purpose == .persistConflict,
                let entryID = attempt.entryID,
                let snapshot = attempt.snapshot,
                let persistedEntry = result.records.decoded.first(where: {
                    $0.id == entryID
                        && $0.documentIdentity == attempt.identity
                        && $0.snapshot == snapshot
                })
            {
                updated.pendingConflict = nil
                updated.recoveryCleanup = cleanupForPersistedConflict(
                    state: state,
                    attempt: attempt,
                    persistedEntry: persistedEntry,
                    records: result.records
                )
            }
            let effects = finishRecoveryMutation(
                &updated,
                records: result.records,
                generation: result.generation,
                recordsIdentity: result.identity
            )
            return transition(updated, effects: effects)
        case .persisted(let result):
            guard case .persisting(let attempt) = state.recovery,
                attempt.token == token,
                attempt.purpose == .persistConflict,
                result.previousGeneration == attempt.expectedStoreGeneration,
                mutationAdvanced(result),
                let entryID = attempt.entryID,
                let snapshot = attempt.snapshot,
                let expectedRecords = attempt.expectedRecords,
                recordsPreserve(expectedRecords, in: result.records),
                let persistedEntry = result.records.decoded.first(where: {
                    $0.id == entryID
                        && $0.documentIdentity == attempt.identity
                        && $0.snapshot == snapshot
                }),
                records(result.records, belongTo: .document(attempt.identity))
            else {
                return unchanged(state)
            }
            var updated = state
            updated.pendingConflict = nil
            updated.recoveryCleanup = cleanupForPersistedConflict(
                state: state,
                attempt: attempt,
                persistedEntry: persistedEntry,
                records: result.records
            )
            let effects = finishRecoveryMutation(
                &updated,
                records: result.records,
                generation: result.generation,
                recordsIdentity: attempt.identity
            )
            return transition(updated, effects: effects)
        case .rawPersisted(let result):
            return rawRecoveryPersisted(state, token: token, result: result)
        case .migrated(let result):
            guard case .migrationPending(let migration) = state.recovery,
                migration.token == token,
                result.previousGeneration == migration.expectedStoreGeneration,
                mutationAdvanced(result),
                records(
                    result.records,
                    belongTo: .document(migration.destinationIdentity)
                ),
                result.records
                    == migratedRecords(
                        from: migration.records,
                        to: migration.destinationIdentity
                    )
            else {
                return unchanged(state)
            }
            var updated = state
            if let cleanup = updated.recoveryCleanup,
                cleanup.records == migration.records
            {
                updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                    records: result.records,
                    target: migratedDiscardTarget(
                        cleanup.target,
                        to: migration.destinationIdentity
                    ),
                    discardPurpose: cleanup.discardPurpose,
                    minimumSourceRevision: cleanup.minimumSourceRevision
                )
            }
            let effects = finishRecoveryMutation(
                &updated,
                records: result.records,
                generation: result.generation,
                recordsIdentity: migration.destinationIdentity
            )
            return transition(updated, effects: effects)
        case .discarded(let result):
            guard case .persisting(let attempt) = state.recovery,
                attempt.token == token,
                attempt.purpose == .discardRaw
                    || attempt.purpose == .discardRestoredRecords
                    || attempt.purpose == .discardResolvedDisplacedPreimage,
                result.previousGeneration == attempt.expectedStoreGeneration,
                mutationAdvanced(result),
                let expectedRecords = attempt.expectedRecords,
                let discardTarget = attempt.discardTarget,
                let expectedResult = recordsAfterDiscard(
                    discardTarget,
                    from: expectedRecords
                ),
                result.records == expectedResult,
                records(result.records, belongTo: .document(attempt.identity))
            else {
                return unchanged(state)
            }
            var updated = state
            if let cleanup = updated.recoveryCleanup,
                cleanup.target == attempt.discardTarget,
                cleanup.discardPurpose == attempt.purpose
            {
                updated.recoveryCleanup = nil
            } else if let cleanup = updated.recoveryCleanup,
                let carriedRecords = recordsAfterDiscard(
                    discardTarget,
                    from: cleanup.records
                ),
                carriedRecords == result.records
            {
                updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                    records: result.records,
                    target: cleanup.target,
                    discardPurpose: cleanup.discardPurpose,
                    minimumSourceRevision: cleanup.minimumSourceRevision
                )
            }
            if let unresolved = updated.unresolvedDisplacedPreimage,
                discardTargetContainsRawEntry(
                    attempt.discardTarget,
                    containsRawEntryID: unresolved.entryID
                )
            {
                updated.unresolvedDisplacedPreimage = nil
            }
            let effects = finishRecoveryMutation(
                &updated,
                records: result.records,
                generation: result.generation,
                recordsIdentity: attempt.identity
            )
            return transition(updated, effects: effects)
        }
    }

    private static func rawRecoveryPersisted(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        result: DocumentSyncRawRecoveryPersistResult
    ) -> DocumentSyncTransition {
        guard case .persisting(let attempt) = state.recovery,
            attempt.token == token,
            attempt.purpose == .persistDisplacedPreimage,
            let entryID = attempt.entryID,
            let rawPayload = attempt.rawPayload,
            let continuation = attempt.displacedPreimageContinuation,
            entryID == continuation.entryID,
            rawPayload == continuation.rawPayload,
            result.mutation.previousGeneration
                == attempt.expectedStoreGeneration,
            mutationAdvanced(result.mutation),
            let expectedRecords = attempt.expectedRecords,
            recordsPreserve(expectedRecords, in: result.mutation.records),
            result.acknowledgedRecoveryArtifact
                == rawPayload.recoveryArtifact,
            records(
                result.mutation.records,
                belongTo: .document(attempt.identity)
            )
        else {
            return unchanged(state)
        }
        let matchingRawRecords = result.mutation.records.raw.filter {
            $0.id == entryID
        }
        guard matchingRawRecords.count == 1,
            let rawRecoveryRecord = matchingRawRecords.first,
            result.durablyPersistedRawEntryID == entryID,
            rawRecoveryRecord.documentIdentity == attempt.identity,
            rawRecoveryRecord.byteCount == rawPayload.fingerprint.byteCount,
            rawRecoveryRecord.contentDigest
                == rawPayload.fingerprint.contentDigest,
            rawRecoveryRecord.dataURL != nil
        else {
            return unchanged(state)
        }

        if let cleanup = state.recoveryCleanup,
            recordsAfterDiscard(cleanup.target, from: result.mutation.records) == nil
        {
            return failRecovery(state, failure: .recovery)
        }

        var updated = state
        if let cleanup = state.recoveryCleanup {
            updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                records: result.mutation.records,
                target: cleanup.target,
                discardPurpose: cleanup.discardPurpose,
                minimumSourceRevision: cleanup.minimumSourceRevision
            )
        }
        if updated.recoveryMutationBarrier != nil {
            updated.pendingDisplacedPreimage = nil
            updated.unresolvedDisplacedPreimage = continuation
            let effects = finishRecoveryMutation(
                &updated,
                records: result.mutation.records,
                generation: result.mutation.generation,
                recordsIdentity: attempt.identity
            )
            return transition(updated, effects: effects)
        }

        updated.activeTokens.removeValue(forKey: .recovery)
        updated.recoveryAccess = .ready(generation: result.mutation.generation)
        updated.recovery = .available(result.mutation.records)
        updated.pendingDisplacedPreimage = nil

        let canApplyContinuation = canApplyDisplacedPreimageContinuation(
            continuation,
            to: updated
        )
        applyCommittedDisplacedPreimageBaselineIfCurrent(
            continuation,
            to: &updated
        )

        guard canApplyContinuation else {
            updated.unresolvedDisplacedPreimage = continuation
            if let cleanupEffects = resumeIndependentRecoveryCleanup(
                whileRawIsUnresolved: &updated
            ) {
                return transition(updated, effects: cleanupEffects)
            }
            updated.issue = issue(for: .recovery)
            let effects = refuseCloseIfNeeded(&updated)
            return transition(updated, effects: effects)
        }

        var effects: [DocumentSyncEffect] = []
        if let merge = updated.mergeAttempt,
            merge.baseline != continuation.committedBaseline
        {
            effects += invalidateMerge(&updated)
        }
        if continuation.pendingRevision == continuation.localSourceRevision,
            continuation.localSourceRevision
                == continuation.committedBaseline.sourceRevision,
            continuation.local == continuation.committedBaseline.snapshot
        {
            updated.local = .clean(continuation.localSourceRevision)
        } else {
            updated.local = .dirty(
                DocumentSyncDirtyState(
                    revision: updated.source,
                    scheduledToken: nil
                )
            )
        }
        if updated.issue?.failure == .localSave
            || updated.issue?.failure == .closeDeadline
        {
            updated.issue = nil
        }

        switch result.decodeOutcome {
        case .undecodable:
            updated.unresolvedDisplacedPreimage = continuation
            updated.issue = issue(for: .recovery)
            effects += refuseCloseIfNeeded(&updated)
            return transition(updated, effects: effects)
        case .decoded(let external):
            guard external.identity == continuation.originIdentity,
                external.fingerprint.byteCount == rawPayload.fingerprint.byteCount,
                external.fingerprint.contentDigest
                    == rawPayload.fingerprint.contentDigest
            else {
                updated.unresolvedDisplacedPreimage = continuation
                updated.issue = issue(for: .recovery)
                effects += refuseCloseIfNeeded(&updated)
                return transition(updated, effects: effects)
            }
            updated.unresolvedDisplacedPreimage = continuation
            let mergeToken = makeToken(&updated, operation: .merge)
            let merge = DocumentSyncMergeAttempt(
                token: mergeToken,
                baseline: continuation.committedBaseline,
                base: continuation.mergeBase,
                local: continuation.local,
                localSourceRevision: continuation.localSourceRevision,
                external: external,
                origin: .displacedPreimage(
                    recoveryRecords: result.mutation.records,
                    cleanupTarget: .raw([rawRecoveryRecord]),
                    continuation: continuation
                )
            )
            updated.mergeAttempt = merge
            return transition(
                updated,
                effects: effects + [
                    .merge(
                        DocumentSyncMergeRequest(
                            token: mergeToken,
                            base: merge.base,
                            local: merge.local,
                            external: merge.external.snapshot,
                            localSourceRevision: merge.localSourceRevision
                        )
                    )
                ]
            )
        }
    }

    static func restoreLocalRecovery(
        _ state: DocumentSyncState
    ) -> DocumentSyncTransition {
        guard state.lifecycle == .active,
            case .ready = state.recoveryAccess,
            state.recoveryCleanup == nil,
            state.mergeAttempt == nil,
            !state.local.isSaveInFlight,
            state.pendingDisplacedPreimage == nil,
            state.unresolvedDisplacedPreimage == nil,
            case .available(let records) = state.recovery,
            let entry = records.latestDecoded
        else {
            return unchanged(state)
        }
        var updated = state
        updated.source = updated.source.advanced(to: entry.snapshot.text)
        updated.format = entry.snapshot.format
        updated.local = .dirty(
            DocumentSyncDirtyState(
                revision: updated.source,
                scheduledToken: nil
            )
        )
        updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
            records: records,
            target: .decoded(entry),
            minimumSourceRevision: updated.source
        )
        updated.issue = nil
        let effects = continueSynchronization(&updated)
        return transition(updated, effects: effects)
    }

    private static func cleanupForPersistedConflict(
        state: DocumentSyncState,
        attempt: DocumentSyncRecoveryAttempt,
        persistedEntry: RecoveryEntry,
        records: DocumentSyncRecoveryRecords
    ) -> DocumentSyncRecoveryCleanup? {
        if let minimumSourceRevision = attempt.cleanupMinimumSourceRevision {
            return DocumentSyncRecoveryCleanup(
                records: records,
                target: attempt.cleanupTarget,
                discardPurpose: attempt.cleanupPurpose
                    ?? .discardRestoredRecords,
                minimumSourceRevision: minimumSourceRevision
            )
        }
        guard state.local.isDirty else { return nil }
        return DocumentSyncRecoveryCleanup(
            records: records,
            target: .decoded(persistedEntry),
            minimumSourceRevision: state.source
        )
    }

    static func discardRawRecovery(
        _ state: DocumentSyncState
    ) -> DocumentSyncTransition {
        guard state.lifecycle == .active,
            case .ready = state.recoveryAccess,
            state.mergeAttempt == nil,
            case .available(let records) = state.recovery,
            !records.raw.isEmpty,
            let attachment = state.fileAttachment
        else {
            return unchanged(state)
        }
        if let cleanup = state.recoveryCleanup,
            discardTargetContainsAnyRawRecord(cleanup.target)
        {
            return unchanged(state)
        }
        var updated = state
        let effects = startRecoveryDiscard(
            &updated,
            attachment: attachment,
            target: .raw(records.raw),
            purpose: .discardRaw
        )
        return transition(updated, effects: effects)
    }
}
