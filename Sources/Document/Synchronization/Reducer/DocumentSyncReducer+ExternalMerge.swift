import Foundation

// File-monitor, external-read, and merge transitions. Methods without `private`
// are reducer-internal boundaries used by the dispatcher or another domain.
extension DocumentSyncReducer {
    static func monitorSignaled(
        _ state: DocumentSyncState,
        token: SyncEffectToken
    ) -> DocumentSyncTransition {
        guard token.operation == .monitor,
            accepts(state, token: token),
            canCoordinate(state)
        else {
            return unchanged(state)
        }
        var updated = state
        if updated.mergeAttempt != nil {
            updated.externalSignalPending = true
            return transition(updated)
        }
        switch updated.external {
        case .reading, .debouncing:
            updated.externalSignalPending = true
            return transition(updated)
        case .idle:
            let effects = scheduleExternalRead(&updated)
            return transition(updated, effects: effects)
        }
    }

    static func externalReadFinished(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        result: DocumentSyncExternalReadResult
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
            case .reading(let attempt) = state.external,
            attempt.token == token
        else {
            return unchanged(state)
        }

        var updated = state
        updated.activeTokens.removeValue(forKey: .externalRead)
        updated.external = .idle
        guard attempt.expectedBaseline == state.durableBaseline else {
            updated.externalSignalPending = true
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        }

        switch result {
        case .unchanged(let observation):
            guard let expectedBaseline = attempt.expectedBaseline,
                observation.identity == attempt.identity,
                matchesTargetURL(observation.targetURL, attempt.targetURL),
                observation.fingerprint == expectedBaseline.fingerprint
            else {
                updated.issue = issue(for: .externalRead)
                let effects = refuseCloseIfNeeded(&updated)
                return transition(updated, effects: effects)
            }
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        case .missing:
            updated.issue = issue(for: .attachment)
            var effects: [DocumentSyncEffect] = []
            effects += refuseCloseIfNeeded(&updated)
            return transition(updated, effects: effects)
        case .changed(let externalChange):
            guard externalChange.identity == attempt.identity,
                matchesTargetURL(
                    externalChange.targetURL,
                    attempt.targetURL
                )
            else {
                updated.issue = issue(for: .externalRead)
                let effects = refuseCloseIfNeeded(&updated)
                return transition(updated, effects: effects)
            }
            switch updated.local {
            case .writing:
                updated.externalSignalPending = true
                return transition(updated)
            case .preparing, .dirty:
                var effects = invalidatePendingSavePreparation(&updated)
                guard updated.durableBaseline != nil else {
                    let localSnapshot = updated.snapshot
                    guard
                        let conflictEffects = persistLocalConflict(
                            &updated,
                            external: externalChange,
                            local: localSnapshot
                        )
                    else {
                        return failRecovery(updated, failure: .recovery)
                    }
                    effects += conflictEffects
                    return transition(updated, effects: effects)
                }
                let mergeToken = makeToken(&updated, operation: .merge)
                let merge = DocumentSyncMergeAttempt(
                    token: mergeToken,
                    baseline: updated.durableBaseline,
                    base: updated.durableBaseline?.snapshot,
                    local: updated.snapshot,
                    localSourceRevision: updated.source,
                    external: externalChange,
                    origin: .externalRead
                )
                updated.mergeAttempt = merge
                effects.append(
                    .merge(
                        DocumentSyncMergeRequest(
                            token: mergeToken,
                            base: merge.base,
                            local: merge.local,
                            external: merge.external.snapshot,
                            localSourceRevision: merge.localSourceRevision
                        )
                    )
                )
                return transition(updated, effects: effects)
            case .clean:
                let revision = updated.source.advanced(
                    to: externalChange.snapshot.text
                )
                updated.source = revision
                updated.format = externalChange.snapshot.format
                updated.durableBaseline =
                    DocumentSyncDurableBaseline.fromExternalChange(
                        externalChange,
                        sourceRevision: revision,
                        commitGeneration:
                            updated.durableBaseline?.commitGeneration ?? 0
                    )
                updated.lastCommitSafety = nil
                updated.local = .clean(revision)
                updated.issue = nil
                let effects = continueSynchronization(&updated)
                return transition(updated, effects: effects)
            }
        }
    }

    static func mergeFinished(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        result: DocumentSyncMergeResult
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
            let merge = state.mergeAttempt,
            merge.token == token,
            result.token == token,
            result.request
                == DocumentSyncMergeRequest(
                    token: merge.token,
                    base: merge.base,
                    local: merge.local,
                    external: merge.external.snapshot,
                    localSourceRevision: merge.localSourceRevision
                )
        else {
            return unchanged(state)
        }

        var updated = state
        updated.activeTokens.removeValue(forKey: .merge)
        updated.mergeAttempt = nil
        guard updated.source == merge.localSourceRevision,
            updated.snapshot == merge.local,
            updated.durableBaseline == merge.baseline
        else {
            if case .displacedPreimage(_, _, let continuation) = merge.origin {
                updated.unresolvedDisplacedPreimage = continuation
                updated.issue = issue(for: .recovery)
                let effects = refuseCloseIfNeeded(&updated)
                return transition(updated, effects: effects)
            }
            updated.externalSignalPending = true
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        }

        switch result.outcome {
        case .merged(let snapshot):
            updated.source = updated.source.advanced(to: snapshot.text)
            updated.format = snapshot.format
            if case .externalRead = merge.origin {
                // The merge result is not yet durable. The verified external
                // observation remains the only valid preimage for the next
                // commit, even though the in-memory source now contains the
                // merged text.
                let externalRevision = SourceRevision(
                    number: merge.localSourceRevision.number,
                    text: merge.external.snapshot.text
                )
                updated.durableBaseline =
                    DocumentSyncDurableBaseline.fromExternalChange(
                        merge.external,
                        sourceRevision: externalRevision,
                        commitGeneration:
                            merge.baseline?.commitGeneration ?? 0
                    )
                updated.lastCommitSafety = nil
            }
            updated.local = .dirty(
                DocumentSyncDirtyState(
                    revision: updated.source,
                    scheduledToken: nil
                )
            )
            updated.issue = nil
            if case .displacedPreimage(
                let records,
                let cleanupTarget,
                _
            ) = merge.origin {
                guard case .available(let availableRecords) = updated.recovery,
                    availableRecords == records
                else {
                    return failRecovery(updated, failure: .recovery)
                }
                updated.recoveryCleanup = DocumentSyncRecoveryCleanup(
                    records: records,
                    target: cleanupTarget,
                    discardPurpose: .discardResolvedDisplacedPreimage,
                    minimumSourceRevision: updated.source
                )
                updated.unresolvedDisplacedPreimage = nil
            }
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        case .conflict:
            if case .displacedPreimage(
                let records,
                let cleanupTarget,
                _
            ) = merge.origin {
                guard
                    let effects = persistDisplacedPreimageConflict(
                        &updated,
                        merge: merge,
                        recoveryRecords: records,
                        cleanupTarget: cleanupTarget
                    )
                else {
                    return failRecovery(updated, failure: .recovery)
                }
                updated.unresolvedDisplacedPreimage = nil
                return transition(updated, effects: effects)
            }
            guard
                let effects = persistLocalConflict(
                    &updated,
                    external: merge.external,
                    local: merge.local
                )
            else {
                return failRecovery(updated, failure: .recovery)
            }
            return transition(updated, effects: effects)
        }
    }

    static func scheduleExternalRead(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard canScheduleExternalRead(state),
            let attachment = state.fileAttachment
        else {
            state.externalSignalPending = true
            return []
        }
        guard case .idle = state.external, state.mergeAttempt == nil else {
            state.externalSignalPending = true
            return []
        }
        let token = makeToken(&state, operation: .externalRead)
        state.external = .debouncing(
            DocumentSyncReadTicket(
                token: token,
                targetURL: attachment.url,
                identity: attachment.identity,
                expectedBaseline: state.durableBaseline
            )
        )
        state.externalSignalPending = false
        return [
            .schedule(
                SyncDeadlineRequest(
                    deadline: SyncDeadline(kind: .externalRead, token: token),
                    delay: externalReadDelay
                )
            )
        ]
    }

    static func persistLocalConflict(
        _ state: inout DocumentSyncState,
        external: DocumentSyncExternalChange,
        local: DocumentSnapshot
    ) -> [DocumentSyncEffect]? {
        guard let attachment = state.fileAttachment,
            case .ready = state.recoveryAccess
        else {
            return nil
        }
        let revision = state.source.advanced(to: external.snapshot.text)
        state.source = revision
        state.format = external.snapshot.format
        state.durableBaseline = DocumentSyncDurableBaseline.fromExternalChange(
            external,
            sourceRevision: revision,
            commitGeneration: state.durableBaseline?.commitGeneration ?? 0
        )
        state.lastCommitSafety = nil
        state.local = .clean(revision)
        state.issue = nil
        return startRecoveryPersistence(
            &state,
            attachment: attachment,
            snapshot: local
        )
    }

    private static func persistDisplacedPreimageConflict(
        _ state: inout DocumentSyncState,
        merge: DocumentSyncMergeAttempt,
        recoveryRecords: DocumentSyncRecoveryRecords,
        cleanupTarget: DocumentSyncRecoveryDiscardTarget
    ) -> [DocumentSyncEffect]? {
        guard case .available(let availableRecords) = state.recovery,
            availableRecords == recoveryRecords,
            let attachment = state.fileAttachment,
            case .ready = state.recoveryAccess
        else {
            return nil
        }
        let revision = state.source.advanced(to: merge.external.snapshot.text)
        state.source = revision
        state.format = merge.external.snapshot.format
        state.local = .dirty(
            DocumentSyncDirtyState(
                revision: revision,
                scheduledToken: nil
            )
        )
        state.issue = nil
        return startRecoveryPersistence(
            &state,
            attachment: attachment,
            snapshot: merge.local,
            cleanupMinimumSourceRevision: revision,
            cleanupTarget: cleanupTarget,
            cleanupPurpose: .discardResolvedDisplacedPreimage
        )
    }

    static func invalidateMerge(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard let merge = state.mergeAttempt else { return [] }
        if case .displacedPreimage(_, _, let continuation) = merge.origin {
            state.unresolvedDisplacedPreimage = continuation
            state.issue = issue(for: .recovery)
        }
        state.activeTokens.removeValue(forKey: .merge)
        state.mergeAttempt = nil
        state.externalSignalPending = true
        return [.cancelOperation(merge.token)]
    }
}
