import Foundation

// Local source, save preparation/commit, and uncertain-commit transitions.
// Methods without `private` are reducer-internal boundaries used by the
// dispatcher or another transition domain.
extension DocumentSyncReducer {
    static func saveRequested(
        _ state: DocumentSyncState
    ) -> DocumentSyncTransition {
        guard canCoordinate(state), case .dirty = state.local else {
            return unchanged(state)
        }
        var updated = state
        let effects = scheduleLocalSave(&updated)
        return transition(updated, effects: effects)
    }

    static func sourceChanged(
        _ state: DocumentSyncState,
        revision: SourceRevision,
        format: TextFileFormat
    ) -> DocumentSyncTransition {
        guard canAcceptSourceChanges(state) else { return unchanged(state) }
        var updated = state
        updated.source = revision
        updated.format = format
        if !recoveryBlocksAutomation(updated),
           updated.issue?.failure != .destinationRequiresSaveAs {
            updated.issue = nil
        }
        updateClosingRevision(&updated, to: revision)

        var effects: [DocumentSyncEffect] = []
        if updated.mergeAttempt != nil {
            invalidateMerge(&updated)
        }

        switch updated.local {
        case .writing(let attempt, _):
            updated.local = .writing(attempt, pendingRevision: revision)
            if updated.externalSignalPending {
                effects += scheduleExternalRead(&updated)
            }
            return transition(updated, effects: effects)
        case .preparing, .dirty:
            effects += invalidatePendingSavePreparation(&updated)
        case .clean:
            break
        }
        updated.local = .dirty(
            DocumentSyncDirtyState(revision: revision, scheduledToken: nil)
        )

        if updated.externalSignalPending {
            effects += scheduleExternalRead(&updated)
            if !effects.isEmpty || updated.external != .idle {
                return transition(updated, effects: effects)
            }
        }
        effects += continueSynchronization(&updated)
        return transition(updated, effects: effects)
    }

    static func savePrepared(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        pendingSave: PendingSaveToken
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
              case .preparing(let attempt) = state.local,
              attempt.token == token,
              let attachment = state.fileAttachment,
              attachment.identity.matches(url: attachment.url),
              attachment.identity == attempt.identity,
              attachment.url == attempt.targetURL,
              pendingSave.sourceRevision == attempt.sourceRevision,
              pendingSave.snapshot == attempt.snapshot,
              pendingSave.targetURL == attempt.targetURL,
              pendingSave.generation == attempt.commitGeneration,
              pendingSave.expectedDurableState
                == attempt.expectedBaseline?.asDurableFileState,
              state.durableBaseline == attempt.expectedBaseline else {
            return unchanged(state)
        }

        var updated = state
        updated.activeTokens.removeValue(forKey: .savePreparation)
        let commitToken = makeToken(&updated, operation: .saveCommit)
        let writeAttempt = DocumentSyncSaveAttempt(
            token: commitToken,
            sourceRevision: attempt.sourceRevision,
            snapshot: attempt.snapshot,
            targetURL: attempt.targetURL,
            identity: attempt.identity,
            expectedBaseline: attempt.expectedBaseline,
            commitGeneration: attempt.commitGeneration,
            pendingSave: pendingSave
        )
        updated.local = .writing(
            writeAttempt,
            pendingRevision: updated.source
        )
        return transition(
            updated,
            effects: [
                .commitSave(
                    DocumentSyncSaveCommitRequest(
                        token: commitToken,
                        pendingSave: pendingSave,
                        targetURL: attempt.targetURL,
                        identity: attempt.identity,
                        attachmentEpoch: updated.attachmentEpoch,
                        expectedBaseline: attempt.expectedBaseline,
                        commitGeneration: attempt.commitGeneration
                    )
                )
            ]
        )
    }

    static func saveFinished(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        completion: DocumentSyncSaveCompletion
    ) -> DocumentSyncTransition {
        let result = completion.result
        guard accepts(state, token: token),
              case .writing(let attempt, let pendingRevision) = state.local,
              attempt.token == token,
              let pendingSave = attempt.pendingSave,
              result.generation == pendingSave.generation else {
            return unchanged(state)
        }

        guard hasMatchingContentFingerprint(
            result.committedFingerprint,
            expected: pendingSave.contentFingerprint
        ) else {
            return enterUncertainCommitOutcome(state, token: token)
        }

        var updated = state
        updated.activeTokens.removeValue(forKey: .saveCommit)
        guard let committedBaseline =
            DocumentSyncDurableBaseline.fromCommittedPayload(
                pendingSave,
                documentIdentity: attempt.identity,
                committedFingerprint: result.committedFingerprint,
                sourceRevision: attempt.sourceRevision,
                commitGeneration: result.generation
            ) else {
            return enterUncertainCommitOutcome(state, token: token)
        }

        guard hasValidRecoveryArtifactCoupling(
            result,
            attempt: attempt,
            pendingSave: pendingSave
        ) else {
            return enterUncertainCommitOutcome(state, token: token)
        }
        if updated.issue?.failure == .localSave
            || updated.issue?.failure == .closeDeadline {
            updated.issue = nil
        }

        if let displacedPreimage = result.displacedPreimage,
           isUnexpectedDisplacedPreimage(
                displacedPreimage.fingerprint,
                expectedBaseline: attempt.expectedBaseline
           ) {
            guard let attachment = updated.fileAttachment,
                  attachment.identity == attempt.identity,
                  case .ready = updated.recoveryAccess,
                  updated.recoveryMutationBarrier == nil,
                  updated.activeTokens[.recovery] == nil else {
                return failRecovery(updated, failure: .recovery)
            }
            updated.local = .dirty(
                DocumentSyncDirtyState(
                    revision: updated.source,
                    scheduledToken: nil
                )
            )
            let entryID = result.recoveryArtifact?.id ?? UUID()
            let continuation = DocumentSyncDisplacedPreimageContinuation(
                entryID: entryID,
                originIdentity: attempt.identity,
                originAttachmentEpoch: token.attachmentEpoch,
                rawPayload: DocumentSyncRawRecoveryPayload(
                    data: displacedPreimage.data,
                    targetURL: attempt.targetURL,
                    resourceIdentifier:
                        displacedPreimage.fingerprint.resourceIdentifier,
                    recoveryArtifact: result.recoveryArtifact
                ),
                mergeBase: attempt.expectedBaseline?.snapshot
                    ?? pendingSave.snapshot,
                local: updated.snapshot,
                localSourceRevision: updated.source,
                pendingRevision: pendingRevision,
                preCommitBaseline: attempt.expectedBaseline,
                committedBaseline: committedBaseline,
                commitSafety: result.safety
            )
            updated.pendingDisplacedPreimage = continuation
            let effects = startDisplacedPreimagePersistence(
                &updated,
                continuation: continuation
            )
            guard !effects.isEmpty else {
                return failRecovery(updated, failure: .recovery)
            }
            if let deferred = applyPendingAttachmentTransition(updated) {
                return transition(
                    deferred.state,
                    effects: effects + deferred.effects
                )
            }
            return transition(updated, effects: effects)
        }

        updated.durableBaseline = committedBaseline
        updated.lastCommitSafety = result.safety == .atomicSwap
            ? nil
            : result.safety
        if let merge = updated.mergeAttempt,
           merge.baseline != updated.durableBaseline {
            invalidateMerge(&updated)
        }
        if pendingRevision == attempt.sourceRevision,
           updated.source == attempt.sourceRevision,
           updated.format == pendingSave.snapshot.format {
            updated.local = .clean(updated.source)
        } else {
            updated.local = .dirty(
                DocumentSyncDirtyState(
                    revision: updated.source,
                    scheduledToken: nil
                )
            )
        }
        if let deferred = applyPendingAttachmentTransition(updated) {
            return deferred
        }

        if let cleanup = updated.recoveryCleanup,
           attempt.sourceRevision.number >= cleanup.minimumSourceRevision.number,
           let attachment = updated.fileAttachment {
            let effects = startRecoveryDiscard(
                &updated,
                attachment: attachment,
                target: cleanup.target,
                purpose: cleanup.discardPurpose
            )
            return transition(updated, effects: effects)
        }

        let effects = continueSynchronization(&updated)
        return transition(updated, effects: effects)
    }

    static func operationFailed(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        failure: DocumentSyncFailure
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
              accepts(failure, for: token.operation) else {
            return unchanged(state)
        }
        if token.operation == .recovery {
            return failRecovery(state, failure: failure)
        }
        // A generic commit executor failure cannot prove that the durable
        // replacement did not cross its point of no return. Only an executor
        // that has positively established that no write began may emit
        // `.commitFailed(_, .notStarted)` and take the ordinary retry path.
        // Retain the original attachment and deferred transitions until a
        // reconciliation effect establishes the target's outcome.
        if token.operation == .saveCommit {
            return enterUncertainCommitOutcome(state, token: token)
        }
        var updated = state
        updated.activeTokens.removeValue(forKey: token.operation)
        var effects: [DocumentSyncEffect] = []
        switch token.operation {
        case .saveCommit:
            return unchanged(state)
        case .savePreparation:
            updated.local = .dirty(
                DocumentSyncDirtyState(
                    revision: updated.source,
                    scheduledToken: nil
                )
            )
            updated.issue = issue(for: failure)
            effects += refuseCloseIfNeeded(&updated)
        case .commitReconciliation:
            guard var uncertainCommit = updated.uncertainCommit,
                  uncertainCommit.reconciliationToken == token else {
                return unchanged(state)
            }
            uncertainCommit.reconciliationToken = nil
            updated.uncertainCommit = uncertainCommit
            updated.issue = issue(for: .recovery)
            effects += refuseCloseIfNeeded(&updated)
        case .externalRead:
            updated.external = .idle
            updated.issue = issue(for: failure)
            effects += refuseCloseIfNeeded(&updated)
        case .merge:
            if let merge = updated.mergeAttempt {
                updated.mergeAttempt = nil
                if case .displacedPreimage = merge.origin {
                    updated.issue = issue(for: .recovery)
                    effects += refuseCloseIfNeeded(&updated)
                    return transition(updated, effects: effects)
                }
                guard let conflictEffects = persistLocalConflict(
                    &updated,
                    external: merge.external,
                    local: merge.local
                ) else {
                    return failRecovery(updated, failure: .recovery)
                }
                effects += conflictEffects
            } else {
                updated.issue = issue(for: failure)
                effects += refuseCloseIfNeeded(&updated)
            }
        case .monitor:
            updated.issue = issue(for: .monitor)
        case .close:
            updated.issue = issue(for: failure)
            effects += refuseCloseIfNeeded(&updated)
        case .recovery:
            return failRecovery(updated, failure: failure)
        }
        return transition(updated, effects: effects)
    }

    static func commitFailed(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        disposition: DocumentSyncCommitFailureDisposition
    ) -> DocumentSyncTransition {
        guard token.operation == .saveCommit else { return unchanged(state) }
        switch disposition {
        case .notStarted:
            return commitProvenNotStarted(
                state,
                token: token,
                failure: .localSave
            )
        case .destinationRequiresSaveAs:
            return commitProvenNotStarted(
                state,
                token: token,
                failure: .destinationRequiresSaveAs
            )
        case .outcomeUnknown:
            return enterUncertainCommitOutcome(state, token: token)
        }
    }

    private static func commitProvenNotStarted(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        failure: DocumentSyncFailure
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
              case .writing = state.local else {
            return unchanged(state)
        }
        var updated = state
        updated.activeTokens.removeValue(forKey: .saveCommit)
        updated.local = .dirty(
            DocumentSyncDirtyState(
                revision: updated.source,
                scheduledToken: nil
            )
        )
        updated.issue = issue(for: failure)
        if let deferred = applyPendingAttachmentTransition(updated) {
            return deferred
        }
        let effects = refuseCloseIfNeeded(&updated)
        return transition(updated, effects: effects)
    }

    private static func enterUncertainCommitOutcome(
        _ state: DocumentSyncState,
        token: SyncEffectToken
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
              case .writing(let attempt, let pendingRevision) = state.local,
              attempt.token == token,
              attempt.pendingSave != nil,
              let attachment = state.fileAttachment,
              attachment.identity == attempt.identity,
              attachment.url == attempt.targetURL else {
            return unchanged(state)
        }
        var updated = state
        updated.activeTokens.removeValue(forKey: .saveCommit)
        updated.local = .dirty(
            DocumentSyncDirtyState(
                revision: updated.source,
                scheduledToken: nil
            )
        )
        updated.uncertainCommit = DocumentSyncUncertainCommit(
            attempt: attempt,
            pendingRevision: pendingRevision,
            originalAttachment: attachment,
            reconciliationToken: nil
        )
        updated.issue = issue(for: .recovery)
        let effects = startCommitReconciliation(&updated)
            + refuseCloseIfNeeded(&updated)
        return transition(updated, effects: effects)
    }

    static func commitReconciliationFinished(
        _ state: DocumentSyncState,
        token: SyncEffectToken,
        result: DocumentSyncCommitReconciliationResult
    ) -> DocumentSyncTransition {
        guard token.operation == .commitReconciliation,
              accepts(state, token: token),
              var uncertainCommit = state.uncertainCommit,
              uncertainCommit.reconciliationToken == token else {
            return unchanged(state)
        }

        var updated = state
        updated.activeTokens.removeValue(forKey: .commitReconciliation)
        switch result {
        case .notCommitted(let observation):
            switch uncertainCommit.attempt.expectedBaseline {
            case .some(let baseline):
                guard let observation,
                      observation.identity == uncertainCommit.originalAttachment.identity,
                      matchesTargetURL(
                        observation.targetURL,
                        uncertainCommit.attempt.targetURL
                      ),
                      observation.fingerprint == baseline.fingerprint else {
                    uncertainCommit.reconciliationToken = nil
                    updated.uncertainCommit = uncertainCommit
                    updated.issue = issue(for: .recovery)
                    let effects = refuseCloseIfNeeded(&updated)
                    return transition(updated, effects: effects)
                }
            case .none:
                guard observation == nil else {
                    uncertainCommit.reconciliationToken = nil
                    updated.uncertainCommit = uncertainCommit
                    updated.issue = issue(for: .recovery)
                    let effects = refuseCloseIfNeeded(&updated)
                    return transition(updated, effects: effects)
                }
            }
            updated.uncertainCommit = nil
            updated.local = .dirty(
                DocumentSyncDirtyState(
                    revision: updated.source,
                    scheduledToken: nil
                )
            )
            updated.issue = nil
            if let deferred = applyPendingAttachmentTransition(updated) {
                return deferred
            }
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        case .committed(let completion, let targetObservation):
            guard targetObservation.identity
                    == uncertainCommit.originalAttachment.identity,
                  matchesTargetURL(
                    targetObservation.targetURL,
                    uncertainCommit.attempt.targetURL
                  ),
                  let pendingSave = uncertainCommit.attempt.pendingSave,
                  completion.result.generation == pendingSave.generation,
                  hasMatchingContentFingerprint(
                    targetObservation.fingerprint,
                    expected: pendingSave.contentFingerprint
                  ),
                  completion.result.committedFingerprint
                    == targetObservation.fingerprint else {
                uncertainCommit.reconciliationToken = nil
                updated.uncertainCommit = uncertainCommit
                updated.issue = issue(for: .recovery)
                let effects = refuseCloseIfNeeded(&updated)
                return transition(updated, effects: effects)
            }
            updated.uncertainCommit = nil
            updated.local = .writing(
                uncertainCommit.attempt,
                pendingRevision: uncertainCommit.pendingRevision
            )
            updated.activeTokens[.saveCommit] = uncertainCommit.attempt.token
            return saveFinished(
                updated,
                token: uncertainCommit.attempt.token,
                completion: completion
            )
        case .unresolved:
            uncertainCommit.reconciliationToken = nil
            updated.uncertainCommit = uncertainCommit
            updated.issue = issue(for: .recovery)
            let effects = refuseCloseIfNeeded(&updated)
            return transition(updated, effects: effects)
        }
    }

    static func retry(_ state: DocumentSyncState) -> DocumentSyncTransition {
        var updated = state

        if updated.uncertainCommit != nil {
            let effects = startCommitReconciliation(&updated)
            guard !effects.isEmpty else { return unchanged(state) }
            updated.issue = nil
            return transition(updated, effects: effects)
        }

        guard let currentIssue = state.issue else { return unchanged(state) }

        if let barrier = updated.recoveryMutationBarrier {
            guard let effect = startRecoveryReconciliation(
                &updated,
                barrier: barrier
            ) else {
                return unchanged(state)
            }
            updated.issue = nil
            updated.recoveryAccess = .loading
            return transition(updated, effects: [effect])
        }
        if case .loading = updated.recoveryAccess,
           updated.activeTokens[.recovery] == nil {
            updated.issue = nil
            let scope = recoveryLoadScope(for: updated)
            let effect = startRecoveryLoad(&updated, scope: scope)
            return transition(updated, effects: [effect])
        }
        if case .failed = updated.recoveryAccess {
            updated.issue = nil
            updated.recoveryAccess = .loading
            let scope = recoveryLoadScope(for: updated)
            let effect = startRecoveryLoad(
                &updated,
                scope: scope
            )
            return transition(updated, effects: [effect])
        }
        if case .migrationPending = updated.recovery {
            updated.issue = nil
            let effects = startRecoveryMigration(&updated)
            return transition(updated, effects: effects)
        }
        if let continuation = updated.pendingDisplacedPreimage,
           updated.activeTokens[.recovery] == nil,
           case .ready = updated.recoveryAccess {
            updated.issue = nil
            let effects = startDisplacedPreimagePersistence(
                &updated,
                continuation: continuation
            )
            return transition(updated, effects: effects)
        }

        switch currentIssue.failure {
        case .localSave:
            updated.issue = nil
            let effects = scheduleLocalSave(&updated)
            return transition(updated, effects: effects)
        case .externalRead, .attachment:
            updated.issue = nil
            let effects = scheduleExternalRead(&updated)
            return transition(updated, effects: effects)
        case .merge:
            updated.issue = nil
            updated.externalSignalPending = true
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        case .monitor:
            updated.issue = nil
            var effects: [DocumentSyncEffect] = []
            if let attachment = updated.fileAttachment,
               attachment.identity.matches(url: attachment.url) {
                effects.append(startMonitor(&updated, attachment: attachment))
            }
            effects += scheduleExternalRead(&updated)
            return transition(updated, effects: effects)
        case .recovery:
            return unchanged(state)
        case .closeDeadline:
            updated.issue = nil
            let effects = continueSynchronization(&updated)
            return transition(updated, effects: effects)
        case .destinationRequiresSaveAs:
            return unchanged(state)
        }
    }

    private static func startCommitReconciliation(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard var uncertainCommit = state.uncertainCommit,
              uncertainCommit.reconciliationToken == nil,
              let pendingSave = uncertainCommit.attempt.pendingSave,
              let attachment = state.fileAttachment,
              attachment.identity.matches(url: attachment.url),
              attachment == uncertainCommit.originalAttachment,
              attachment.identity == uncertainCommit.attempt.identity,
              attachment.url == uncertainCommit.attempt.targetURL else {
            return []
        }
        let token = makeToken(&state, operation: .commitReconciliation)
        uncertainCommit.reconciliationToken = token
        state.uncertainCommit = uncertainCommit
        return [
            .reconcileCommit(
                DocumentSyncCommitReconciliationRequest(
                    token: token,
                    originalCommitToken: uncertainCommit.attempt.token,
                    pendingSave: pendingSave,
                    targetURL: uncertainCommit.attempt.targetURL,
                    identity: uncertainCommit.attempt.identity,
                    attachmentEpoch: attachment.epoch,
                    expectedBaseline: uncertainCommit.attempt.expectedBaseline,
                    commitGeneration: uncertainCommit.attempt.commitGeneration
                )
            )
        ]
    }

    static func scheduleLocalSave(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard canScheduleLocalSave(state), case .dirty(let dirty) = state.local else {
            return []
        }
        guard dirty.scheduledToken == nil else { return [] }
        let token = makeToken(&state, operation: .savePreparation)
        state.local = .dirty(
            DocumentSyncDirtyState(
                revision: state.source,
                scheduledToken: token
            )
        )
        return [
            .schedule(
                SyncDeadlineRequest(
                    deadline: SyncDeadline(kind: .localSave, token: token),
                    delay: localSaveDelay
                )
            )
        ]
    }

    static func invalidatePendingSavePreparation(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        switch state.local {
        case .dirty(let dirty):
            state.local = .dirty(
                DocumentSyncDirtyState(
                    revision: state.source,
                    scheduledToken: nil
                )
            )
            guard let token = dirty.scheduledToken else { return [] }
            state.activeTokens.removeValue(forKey: .savePreparation)
            return [.cancelDeadline(SyncDeadline(kind: .localSave, token: token))]
        case .preparing:
            state.activeTokens.removeValue(forKey: .savePreparation)
            state.local = .dirty(
                DocumentSyncDirtyState(
                    revision: state.source,
                    scheduledToken: nil
                )
            )
            return []
        case .clean, .writing:
            return []
        }
    }

    private static func hasMatchingContentFingerprint(
        _ observed: FileFingerprint,
        expected: FileFingerprint
    ) -> Bool {
        observed.byteCount == expected.byteCount
            && observed.contentDigest == expected.contentDigest
    }

    private static func hasValidRecoveryArtifactCoupling(
        _ result: FileCommitResult,
        attempt: DocumentSyncSaveAttempt,
        pendingSave: PendingSaveToken
    ) -> Bool {
        guard let displacedPreimage = result.displacedPreimage else {
            return result.recoveryArtifact == nil
        }
        guard isUnexpectedDisplacedPreimage(
            displacedPreimage.fingerprint,
            expectedBaseline: attempt.expectedBaseline
        ) else {
            return result.recoveryArtifact == nil
        }
        guard let expectedBaseline = attempt.expectedBaseline,
              let artifact = result.recoveryArtifact,
              let binding = artifact.binding else {
            return false
        }
        return binding.documentIdentity == attempt.identity
            && binding.targetURL.resolvingSymlinksInPath().standardizedFileURL
                == attempt.targetURL.resolvingSymlinksInPath().standardizedFileURL
            && binding.expectedPreimageFingerprint
                == expectedBaseline.fingerprint
            && hasMatchingContentFingerprint(
                binding.committedPayloadFingerprint,
                expected: pendingSave.contentFingerprint
            )
    }

    private static func isUnexpectedDisplacedPreimage(
        _ fingerprint: FileFingerprint,
        expectedBaseline: DocumentSyncDurableBaseline?
    ) -> Bool {
        guard let expectedBaseline else { return true }
        return fingerprint.contentDigest
            != expectedBaseline.fingerprint.contentDigest
    }
}
