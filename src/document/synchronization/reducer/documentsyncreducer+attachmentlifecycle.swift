import Foundation

// Attachment replacement and lifecycle transitions. Methods without `private` are
// reducer-internal boundaries used by the dispatcher or another transition domain.
extension DocumentSyncReducer {
    static func started(_ state: DocumentSyncState) -> DocumentSyncTransition {
        guard state.lifecycle != .closed else { return unchanged(state) }
        var updated = state
        var effects: [DocumentSyncEffect] = []

        if case .loading = updated.recoveryAccess,
           updated.activeTokens[.recovery] == nil {
            let scope = recoveryLoadScope(for: updated)
            effects.append(startRecoveryLoad(&updated, scope: scope))
        }

        if let attachment = updated.fileAttachment,
           attachment.identity.matches(url: attachment.url),
           updated.activeTokens[.monitor] == nil {
            effects.append(startMonitor(&updated, attachment: attachment))
        }
        return transition(updated, effects: effects)
    }

    static func attach(
        _ state: DocumentSyncState,
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    ) -> DocumentSyncTransition {
        guard state.lifecycle == .active,
              identity.matches(url: url) else {
            return unchanged(state)
        }
        if state.local.hasUncancellableCommit || state.uncertainCommit != nil {
            return deferAttachmentTransition(
                state,
                transition: .attach(
                    identity: identity,
                    url: url,
                    durableBaseline: durableBaseline
                )
            )
        }
        if let previous = state.fileAttachment, previous.identity != identity {
            return relocate(
                state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        }

        let retainedRecoveryToken = activeRecoveryMutationToken(in: state)
        let hasRecoveryBarrier = state.recoveryMutationBarrier != nil
        let preservesDetachedRawRecoveryOrigin = preservesDetachedRawRecovery(
            in: state,
            forIncomingIdentity: identity
        )
        var updated = state
        var effects = replaceAttachment(
            &updated,
            identity: identity,
            url: url,
            durableBaseline: durableBaseline,
            preservingRecoveryToken: retainedRecoveryToken
        )
        if var pendingConflict = updated.pendingConflict {
            pendingConflict.identity = identity
            updated.pendingConflict = pendingConflict
        }
        if retainedRecoveryToken != nil {
            installRecoveryMutationBarrier(from: state, in: &updated)
            if !preservesDetachedRawRecoveryOrigin {
                retargetRecoveryMutationBarrier(&updated, to: identity)
            }
            updated.issue = nil
            return transition(updated, effects: effects)
        }
        if hasRecoveryBarrier {
            if !preservesDetachedRawRecoveryOrigin {
                retargetRecoveryMutationBarrier(&updated, to: identity)
            }
            pauseRecoveryBarrier(&updated)
            return transition(updated, effects: effects)
        }
        if case .available(let records) = updated.recovery,
           !records.isEmpty {
            guard let sourceIdentity = recoveryRecordsIdentity(records) else {
                updated.recoveryAccess = .failed(.recovery)
                updated.issue = issue(for: .recovery)
                return transition(updated, effects: effects)
            }
            if sourceIdentity != identity {
                updated.recovery = .migrationPending(
                    DocumentSyncRecoveryMigration(
                        token: nil,
                        sourceIdentity: sourceIdentity,
                        destinationIdentity: identity,
                        expectedStoreGeneration: recoveryGeneration(
                            in: updated.recoveryAccess
                        ),
                        records: records
                    )
                )
                switch updated.recoveryAccess {
                case .ready:
                    effects += startRecoveryMigration(&updated)
                case .loading:
                    effects.append(
                        startRecoveryLoad(
                            &updated,
                            scope: recoveryLoadScope(for: updated)
                        )
                    )
                case .failed:
                    break
                }
                return transition(updated, effects: effects)
            }
        }
        if case .migrationPending(var migration) = updated.recovery {
            migration.token = nil
            migration.expectedStoreGeneration = nil
            updated.recovery = .migrationPending(migration)
            switch updated.recoveryAccess {
            case .failed:
                break
            case .loading:
                let scope = recoveryLoadScope(for: updated)
                effects.append(startRecoveryLoad(&updated, scope: scope))
            case .ready:
                updated.recoveryAccess = .loading
                let scope = recoveryLoadScope(for: updated)
                effects.append(startRecoveryLoad(&updated, scope: scope))
            }
            return transition(updated, effects: effects)
        }
        switch updated.recoveryAccess {
        case .failed:
            break
        case .loading:
            effects.append(startRecoveryLoad(&updated, scope: .document(identity)))
        case .ready:
            updated.recoveryAccess = .loading
            effects.append(startRecoveryLoad(&updated, scope: .document(identity)))
        }
        return transition(updated, effects: effects)
    }

    static func relocate(
        _ state: DocumentSyncState,
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    ) -> DocumentSyncTransition {
        guard state.lifecycle == .active,
              identity.matches(url: url) else {
            return unchanged(state)
        }
        if state.local.hasUncancellableCommit || state.uncertainCommit != nil {
            return deferAttachmentTransition(
                state,
                transition: .attach(
                    identity: identity,
                    url: url,
                    durableBaseline: durableBaseline
                )
            )
        }
        guard let previous = state.fileAttachment else {
            return attach(
                state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        }
        guard previous.identity != identity else {
            return attach(
                state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        }

        let retainedRecoveryToken = activeRecoveryMutationToken(in: state)
        let hasRecoveryBarrier = state.recoveryMutationBarrier != nil
        let preservesDetachedRawRecoveryOrigin = preservesDetachedRawRecovery(
            in: state,
            forIncomingIdentity: identity
        )
        var updated = state
        var effects = replaceAttachment(
            &updated,
            identity: identity,
            url: url,
            durableBaseline: durableBaseline,
            preservingRecoveryToken: retainedRecoveryToken
        )
        if var pendingConflict = updated.pendingConflict,
           pendingConflict.identity == previous.identity {
            pendingConflict.identity = identity
            updated.pendingConflict = pendingConflict
        }
        if retainedRecoveryToken != nil {
            installRecoveryMutationBarrier(from: state, in: &updated)
            if !preservesDetachedRawRecoveryOrigin {
                retargetRecoveryMutationBarrier(&updated, to: identity)
            }
            updated.issue = nil
            return transition(updated, effects: effects)
        }
        if hasRecoveryBarrier {
            if !preservesDetachedRawRecoveryOrigin {
                retargetRecoveryMutationBarrier(&updated, to: identity)
            }
            pauseRecoveryBarrier(&updated)
            return transition(updated, effects: effects)
        }
        let priorMigration: DocumentSyncRecoveryMigration?
        if case .migrationPending(let migration) = state.recovery {
            priorMigration = migration
        } else {
            priorMigration = nil
        }
        let migration = DocumentSyncRecoveryMigration(
            token: nil,
            sourceIdentity: priorMigration?.sourceIdentity ?? previous.identity,
            destinationIdentity: identity,
            expectedStoreGeneration: recoveryGeneration(in: updated.recoveryAccess),
            records: priorMigration?.records ?? state.recoveryRecords ?? .empty
        )
        if let cleanup = updated.recoveryCleanup,
           cleanup.records != migration.records {
            updated.recoveryAccess = .failed(.recovery)
            updated.issue = issue(for: .recovery)
            return transition(updated, effects: effects)
        }
        updated.recovery = .migrationPending(migration)
        updated.issue = nil

        switch updated.recoveryAccess {
        case .ready:
            effects += startRecoveryMigration(&updated)
        case .loading:
            effects.append(
                startRecoveryLoad(
                    &updated,
                    scope: recoveryLoadScope(for: updated)
                )
            )
        case .failed:
            break
        }
        return transition(updated, effects: effects)
    }

    static func detach(_ state: DocumentSyncState) -> DocumentSyncTransition {
        guard state.lifecycle == .active else {
            return unchanged(state)
        }
        if state.local.hasUncancellableCommit || state.uncertainCommit != nil {
            return deferAttachmentTransition(state, transition: .detach)
        }
        let retainedRecoveryToken = activeRecoveryMutationToken(in: state)
        let hasRecoveryBarrier = state.recoveryMutationBarrier != nil
        var updated = state
        var effects: [DocumentSyncEffect] = [.cancelAllDeadlines]
        if let attachment = state.fileAttachment {
            effects += stopMonitor(for: state, attachment: attachment)
        }
        updated.attachmentEpoch &+= 1
        updated.attachment = .untitled
        if let pendingConflict = updated.pendingConflict,
           !updated.local.isDirty {
            updated.source = updated.source.advanced(
                to: pendingConflict.snapshot.text
            )
            updated.format = pendingConflict.snapshot.format
            updated.pendingConflict = nil
        }
        updated.durableBaseline = nil
        updated.lastCommitSafety = nil
        updated.activeTokens.removeAll()
        if let retainedRecoveryToken {
            updated.activeTokens[.recovery] = retainedRecoveryToken
            installRecoveryMutationBarrier(from: state, in: &updated)
        }
        if retainedRecoveryToken != nil || hasRecoveryBarrier {
            retargetRecoveryMutationBarrier(&updated, to: nil)
        }
        updated.external = .idle
        updated.mergeAttempt = nil
        updated.externalSignalPending = false
        if retainedRecoveryToken == nil && !hasRecoveryBarrier {
            if let unresolved = updated.unresolvedDisplacedPreimage,
               state.recoveryRecords?.raw.contains(where: {
                   $0.id == unresolved.entryID
               }) == true {
                // The recovery record is durably retained under the detached
                // document identity. Do not carry its pause latch into an
                // unrelated attachment; reopening the original document will
                // load the raw record again.
                updated.unresolvedDisplacedPreimage = nil
                if updated.issue?.failure == .recovery {
                    updated.issue = nil
                }
            }
            updated.recovery = .clear
            updated.recoveryCleanup = nil
        } else if retainedRecoveryToken == nil {
            pauseRecoveryBarrier(&updated)
        }
        updated.local = .dirty(
            DocumentSyncDirtyState(
                revision: updated.source,
                scheduledToken: nil
            )
        )
        return transition(updated, effects: effects)
    }

    private static func deferAttachmentTransition(
        _ state: DocumentSyncState,
        transition pendingTransition: DocumentSyncPendingAttachmentTransition
    ) -> DocumentSyncTransition {
        var updated = state
        // Host attachment notifications are one-shot. Coalesce to the latest
        // destination but retain any detach boundary so raw evidence cannot be
        // migrated into an unrelated subsequently attached document.
        updated.pendingAttachmentTransition = updated.pendingAttachmentTransition
            .map { $0.appending(pendingTransition) } ?? pendingTransition
        return transition(updated)
    }

    static func applyPendingAttachmentTransition(
        _ state: DocumentSyncState
    ) -> DocumentSyncTransition? {
        guard !state.local.hasUncancellableCommit,
              state.uncertainCommit == nil,
              let pendingTransition = state.pendingAttachmentTransition else {
            return nil
        }
        var updated = state
        updated.pendingAttachmentTransition = nil
        let closeEffects = refuseCloseIfNeeded(&updated)
        let applied: DocumentSyncTransition
        switch pendingTransition {
        case .attach(let identity, let url, let durableBaseline):
            applied = attach(
                updated,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        case .detach:
            applied = detach(updated)
        case .detachThenAttach(let identity, let url, let durableBaseline):
            let detached = detach(updated)
            let attached = attach(
                detached.state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
            applied = transition(
                attached.state,
                effects: detached.effects + attached.effects
            )
        }
        return transition(
            applied.state,
            effects: closeEffects + applied.effects
        )
    }

    private static func replaceAttachment(
        _ state: inout DocumentSyncState,
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?,
        preservingRecoveryToken: SyncEffectToken? = nil
    ) -> [DocumentSyncEffect] {
        let attachmentIdentityMatchesURL = identity.matches(url: url)
        let verifiedBaseline = durableBaseline.flatMap { baseline in
            attachmentIdentityMatchesURL
                && baseline.documentIdentity == identity
                ? baseline
                : nil
        }
        // A Save As baseline can describe an earlier captured revision while
        // the editor already contains newer local text. Verify that baseline
        // before any automatic write can target the newly attached file.
        let requiresExternalVerification = !attachmentIdentityMatchesURL
            || (durableBaseline != nil && verifiedBaseline == nil)
            || (verifiedBaseline?.snapshot != state.snapshot)
        var effects: [DocumentSyncEffect] = [.cancelAllDeadlines]
        if let attachment = state.fileAttachment {
            effects += stopMonitor(for: state, attachment: attachment)
        }
        state.attachmentEpoch &+= 1
        state.attachment = .file(
            DocumentSyncFileAttachment(
                identity: identity,
                url: url,
                epoch: state.attachmentEpoch
            )
        )
        state.durableBaseline = verifiedBaseline
        state.lastCommitSafety = nil
        state.activeTokens.removeAll()
        if let preservingRecoveryToken {
            state.activeTokens[.recovery] = preservingRecoveryToken
        }
        state.external = .idle
        state.mergeAttempt = nil
        state.externalSignalPending = requiresExternalVerification
        if verifiedBaseline?.sourceRevision == state.source {
            state.local = .clean(state.source)
        } else {
            state.local = .dirty(
                DocumentSyncDirtyState(
                    revision: state.source,
                    scheduledToken: nil
                )
            )
        }
        let attachment = DocumentSyncFileAttachment(
            identity: identity,
            url: url,
            epoch: state.attachmentEpoch
        )
        effects.append(startMonitor(&state, attachment: attachment))
        return effects
    }

    static func startMonitor(
        _ state: inout DocumentSyncState,
        attachment: DocumentSyncFileAttachment
    ) -> DocumentSyncEffect {
        let token = makeToken(&state, operation: .monitor)
        return .monitor(
            DocumentSyncMonitorRequest(
                token: token,
                action: .start,
                targetURL: attachment.url,
                identity: attachment.identity,
                attachmentEpoch: state.attachmentEpoch
            )
        )
    }

    static func stopMonitor(
        for state: DocumentSyncState,
        attachment: DocumentSyncFileAttachment
    ) -> [DocumentSyncEffect] {
        guard let token = state.activeTokens[.monitor] else { return [] }
        return [
            .monitor(
                DocumentSyncMonitorRequest(
                    token: token,
                    action: .stop,
                    targetURL: attachment.url,
                    identity: attachment.identity,
                    attachmentEpoch: state.attachmentEpoch
                )
            )
        ]
    }
}
