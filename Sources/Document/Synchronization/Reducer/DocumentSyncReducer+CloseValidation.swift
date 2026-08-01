import Foundation

// Deadlines, close resolution, scheduling progression, and shared validation.
// Methods without `private` are the small reducer-internal surface shared by
// the dispatcher and focused transition-domain extensions.
extension DocumentSyncReducer {
    static func deadlineFired(
        _ state: DocumentSyncState,
        deadline: SyncDeadline
    ) -> DocumentSyncTransition {
        guard deadline.kind.operation == deadline.token.operation,
            accepts(state, token: deadline.token)
        else {
            return unchanged(state)
        }

        var updated = state
        switch deadline.kind {
        case .localSave:
            guard case .dirty(let dirty) = updated.local,
                dirty.scheduledToken == deadline.token,
                let attachment = updated.fileAttachment,
                attachment.identity.matches(url: attachment.url)
            else {
                return unchanged(state)
            }
            let commitGeneration = makeCommitGeneration(&updated)
            let attempt = DocumentSyncSaveAttempt(
                token: deadline.token,
                sourceRevision: updated.source,
                snapshot: updated.snapshot,
                targetURL: attachment.url,
                identity: attachment.identity,
                expectedBaseline: updated.durableBaseline,
                commitGeneration: commitGeneration,
                pendingSave: nil
            )
            updated.local = .preparing(attempt)
            return transition(
                updated,
                effects: [
                    .prepareSave(
                        DocumentSyncSavePreparationRequest(
                            token: attempt.token,
                            sourceRevision: attempt.sourceRevision,
                            snapshot: attempt.snapshot,
                            targetURL: attempt.targetURL,
                            identity: attempt.identity,
                            attachmentEpoch: attempt.token.attachmentEpoch,
                            expectedBaseline: attempt.expectedBaseline,
                            commitGeneration: attempt.commitGeneration
                        )
                    )
                ]
            )
        case .externalRead:
            guard case .debouncing(let ticket) = updated.external,
                ticket.token == deadline.token
            else {
                return unchanged(state)
            }
            let attempt = DocumentSyncReadAttempt(
                token: ticket.token,
                targetURL: ticket.targetURL,
                identity: ticket.identity,
                expectedBaseline: ticket.expectedBaseline
            )
            updated.external = .reading(attempt)
            return transition(
                updated,
                effects: [
                    .readExternal(
                        DocumentSyncExternalReadRequest(
                            token: attempt.token,
                            targetURL: attempt.targetURL,
                            identity: attempt.identity,
                            attachmentEpoch: attempt.token.attachmentEpoch,
                            expectedBaseline: attempt.expectedBaseline
                        )
                    )
                ]
            )
        case .close:
            guard case .closing(let attempt) = updated.lifecycle,
                attempt.token == deadline.token,
                attempt.resolution == nil
            else {
                return unchanged(state)
            }
            invalidateAutomatedWork(&updated, recoveryShouldReload: true)
            updated.issue = issue(for: .closeDeadline)
            var effects: [DocumentSyncEffect] = [.cancelAllDeadlines]
            if let attachment = state.fileAttachment,
                attachment.identity.matches(url: attachment.url)
            {
                effects += stopMonitor(for: state, attachment: attachment)
                effects.append(startMonitor(&updated, attachment: attachment))
            }
            effects.append(
                .resolveClose(
                    DocumentSyncCloseResolution(
                        token: attempt.token,
                        disposition: .refuseManagedClose
                    )
                )
            )
            updated.lifecycle = .active
            return transition(updated, effects: effects)
        }
    }

    static func requestClose(
        _ state: DocumentSyncState
    ) -> DocumentSyncTransition {
        guard state.lifecycle == .active else { return unchanged(state) }
        var updated = state
        let token = makeToken(&updated, operation: .close)

        guard updated.attachment.isManagedFile else {
            updated.lifecycle = .closing(
                DocumentSyncCloseAttempt(
                    token: token,
                    sourceRevision: updated.source,
                    kind: .untitledNativeReview,
                    resolution: .deferToNativeUntitledReview
                )
            )
            return transition(
                updated,
                effects: [
                    .resolveClose(
                        DocumentSyncCloseResolution(
                            token: token,
                            disposition: .deferToNativeUntitledReview
                        )
                    )
                ]
            )
        }

        updated.lifecycle = .closing(
            DocumentSyncCloseAttempt(
                token: token,
                sourceRevision: updated.source,
                kind: .managedFile,
                resolution: nil
            )
        )
        var effects: [DocumentSyncEffect] = [
            .schedule(
                SyncDeadlineRequest(
                    deadline: SyncDeadline(kind: .close, token: token),
                    delay: closeDeadline
                )
            )
        ]
        effects += progressManagedClose(&updated)
        return transition(updated, effects: effects)
    }

    static func closeCommitted(
        _ state: DocumentSyncState,
        token: SyncEffectToken
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
            case .closing(let attempt) = state.lifecycle,
            attempt.token == token,
            attempt.resolution == .allowManagedClose
                || attempt.resolution == .deferToNativeUntitledReview
        else {
            return unchanged(state)
        }
        return close(state)
    }

    static func closeCancelled(
        _ state: DocumentSyncState,
        token: SyncEffectToken
    ) -> DocumentSyncTransition {
        guard accepts(state, token: token),
            case .closing(let attempt) = state.lifecycle,
            attempt.token == token
        else {
            return unchanged(state)
        }
        var updated = state
        updated.lifecycle = .active
        updated.activeTokens.removeValue(forKey: .close)
        return transition(
            updated,
            effects: [.cancelDeadline(SyncDeadline(kind: .close, token: token))]
        )
    }

    private static func close(_ state: DocumentSyncState) -> DocumentSyncTransition {
        var updated = state
        var effects: [DocumentSyncEffect] = [.cancelAllDeadlines]
        if let attachment = state.fileAttachment {
            effects += stopMonitor(for: state, attachment: attachment)
        }
        updated.lifecycle = .closed
        updated.activeTokens.removeAll()
        updated.external = .idle
        updated.mergeAttempt = nil
        updated.externalSignalPending = false
        return transition(updated, effects: effects)
    }

    static func continueSynchronization(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        if case .closing = state.lifecycle {
            return progressManagedClose(&state)
        }
        guard state.lifecycle == .active else { return [] }
        guard state.uncertainCommit == nil else { return [] }
        if let pendingConflict = state.pendingConflict {
            guard let attachment = state.fileAttachment,
                attachment.identity == pendingConflict.identity,
                state.activeTokens[.recovery] == nil
            else {
                return []
            }
            return startRecoveryPersistence(
                &state,
                attachment: attachment,
                snapshot: pendingConflict.snapshot
            )
        }
        if let continuation = state.pendingDisplacedPreimage {
            guard state.activeTokens[.recovery] == nil else {
                return []
            }
            return startDisplacedPreimagePersistence(
                &state,
                continuation: continuation
            )
        }
        if let cleanupEffects = resumeRecoveryCleanupIfNeeded(&state) {
            return cleanupEffects
        }
        guard state.mergeAttempt == nil else { return [] }
        if state.externalSignalPending {
            let effects = scheduleExternalRead(&state)
            if !effects.isEmpty || state.external != .idle {
                return effects
            }
        }
        return scheduleLocalSave(&state)
    }

    private static func progressManagedClose(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard case .closing(let attempt) = state.lifecycle,
            attempt.kind == .managedFile,
            attempt.resolution == nil
        else {
            return []
        }
        guard state.issue == nil else {
            return refuseCloseIfNeeded(&state)
        }
        guard state.uncertainCommit == nil else {
            return refuseCloseIfNeeded(&state)
        }
        guard
            state.pendingConflict == nil
                || state.activeTokens[.recovery] != nil
        else {
            return refuseCloseIfNeeded(&state)
        }
        if let merge = state.mergeAttempt,
            case .displacedPreimage = merge.origin
        {
            return []
        }
        guard state.unresolvedDisplacedPreimage == nil else {
            return refuseCloseIfNeeded(&state)
        }
        switch state.recoveryAccess {
        case .loading:
            return []
        case .failed:
            return refuseCloseIfNeeded(&state)
        case .ready:
            break
        }
        if let continuation = state.pendingDisplacedPreimage {
            if state.activeTokens[.recovery] != nil {
                return []
            }
            let effects = startDisplacedPreimagePersistence(
                &state,
                continuation: continuation
            )
            return effects.isEmpty ? refuseCloseIfNeeded(&state) : effects
        }
        switch state.recovery {
        case .clear:
            break
        case .persisting:
            return []
        case .migrationPending:
            if state.activeTokens[.recovery] != nil {
                return []
            }
            return startRecoveryMigration(&state)
        case .available:
            guard state.recoveryCleanup != nil else {
                return refuseCloseIfNeeded(&state)
            }
        }
        if state.recoveryCleanup != nil {
            if let cleanupEffects = resumeRecoveryCleanupIfNeeded(&state) {
                return cleanupEffects
            }
            switch state.local {
            case .dirty:
                return scheduleLocalSave(&state)
            case .clean, .preparing, .writing:
                return []
            }
        }
        guard state.mergeAttempt == nil else { return [] }
        switch state.external {
        case .reading, .debouncing:
            return []
        case .idle:
            if state.externalSignalPending {
                return scheduleExternalRead(&state)
            }
        }
        switch state.local {
        case .clean(let revision):
            guard revision == state.source,
                state.durableBaseline?.sourceRevision == state.source,
                state.durableBaseline?.snapshot == state.snapshot
            else {
                return scheduleLocalSave(&state)
            }
            return allowManagedClose(&state)
        case .dirty:
            return scheduleLocalSave(&state)
        case .preparing, .writing:
            return []
        }
    }

    private static func allowManagedClose(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard case .closing(var attempt) = state.lifecycle,
            attempt.kind == .managedFile,
            attempt.resolution == nil
        else {
            return []
        }
        attempt.resolution = .allowManagedClose
        state.lifecycle = .closing(attempt)
        return [
            .cancelDeadline(SyncDeadline(kind: .close, token: attempt.token)),
            .resolveClose(
                DocumentSyncCloseResolution(
                    token: attempt.token,
                    disposition: .allowManagedClose
                )
            ),
        ]
    }

    static func refuseCloseIfNeeded(
        _ state: inout DocumentSyncState
    ) -> [DocumentSyncEffect] {
        guard case .closing(let attempt) = state.lifecycle,
            attempt.kind == .managedFile,
            attempt.resolution == nil
        else {
            return []
        }
        state.lifecycle = .active
        state.activeTokens.removeValue(forKey: .close)
        return [
            .cancelDeadline(SyncDeadline(kind: .close, token: attempt.token)),
            .resolveClose(
                DocumentSyncCloseResolution(
                    token: attempt.token,
                    disposition: .refuseManagedClose
                )
            ),
        ]
    }

    static func failRecovery(
        _ state: DocumentSyncState,
        failure: DocumentSyncFailure
    ) -> DocumentSyncTransition {
        var updated = state
        let closeAttempt: DocumentSyncCloseAttempt?
        if case .closing(let attempt) = updated.lifecycle,
            attempt.kind == .managedFile,
            attempt.resolution == nil
        {
            closeAttempt = attempt
        } else {
            closeAttempt = nil
        }
        invalidateAutomatedWork(&updated)
        if updated.recoveryMutationBarrier == nil,
            case .migrationPending(var migration) = updated.recovery
        {
            migration.token = nil
            migration.expectedStoreGeneration = nil
            updated.recovery = .migrationPending(migration)
        }
        updated.recoveryAccess = .failed(failure)
        updated.issue = issue(for: .recovery)
        var effects: [DocumentSyncEffect] = [.cancelAllDeadlines]
        if let attachment = state.fileAttachment {
            effects += stopMonitor(for: state, attachment: attachment)
        }
        if let closeAttempt {
            updated.lifecycle = .active
            effects.append(
                .resolveClose(
                    DocumentSyncCloseResolution(
                        token: closeAttempt.token,
                        disposition: .refuseManagedClose
                    )
                )
            )
        }
        return transition(updated, effects: effects)
    }

    private static func invalidateAutomatedWork(
        _ state: inout DocumentSyncState,
        recoveryShouldReload: Bool = false,
        preservingSaveCommit: Bool = true
    ) {
        let interruptedRecovery = state.activeTokens[.recovery] != nil
        let interruptedRecoveryBarrier =
            state.recoveryMutationBarrier
            ?? recoveryMutationBarrier(for: state)
        let retainedSaveCommit: SyncEffectToken?
        if preservingSaveCommit,
            case .writing(let attempt, _) = state.local,
            state.activeTokens[.saveCommit] == attempt.token
        {
            retainedSaveCommit = attempt.token
        } else {
            retainedSaveCommit = nil
        }
        let retainedCommitReconciliation: SyncEffectToken?
        if preservingSaveCommit,
            let uncertainCommit = state.uncertainCommit,
            let token = uncertainCommit.reconciliationToken,
            state.activeTokens[.commitReconciliation] == token
        {
            retainedCommitReconciliation = token
        } else {
            retainedCommitReconciliation = nil
        }
        state.activeTokens.removeAll()
        if let retainedSaveCommit {
            state.activeTokens[.saveCommit] = retainedSaveCommit
        }
        if let retainedCommitReconciliation {
            state.activeTokens[.commitReconciliation] =
                retainedCommitReconciliation
        }
        if state.recoveryMutationBarrier == nil {
            state.recoveryMutationBarrier = interruptedRecoveryBarrier
        }
        state.external = .idle
        state.mergeAttempt = nil
        state.externalSignalPending = true
        switch state.local {
        case .clean:
            break
        case .writing where retainedSaveCommit != nil:
            break
        case .dirty, .preparing, .writing:
            state.local = .dirty(
                DocumentSyncDirtyState(
                    revision: state.source,
                    scheduledToken: nil
                )
            )
        }
        guard recoveryShouldReload, interruptedRecovery else { return }
        resetInterruptedRecoveryForRetry(&state)
    }

    private static func resetInterruptedRecoveryForRetry(
        _ state: inout DocumentSyncState
    ) {
        if state.recoveryMutationBarrier != nil {
            state.recoveryAccess = .failed(.recovery)
            state.issue = issue(for: .recovery)
            return
        }
        switch state.recovery {
        case .persisting:
            state.recovery = .clear
        case .migrationPending(var migration):
            migration.token = nil
            migration.expectedStoreGeneration = nil
            state.recovery = .migrationPending(migration)
        case .clear, .available:
            break
        }
        state.recoveryAccess = .loading
    }

    static func updateClosingRevision(
        _ state: inout DocumentSyncState,
        to revision: SourceRevision
    ) {
        guard case .closing(var attempt) = state.lifecycle,
            attempt.resolution == nil
        else {
            return
        }
        attempt.sourceRevision = revision
        state.lifecycle = .closing(attempt)
    }

    static func canAcceptSourceChanges(_ state: DocumentSyncState) -> Bool {
        switch state.lifecycle {
        case .active:
            true
        case .closing(let attempt):
            attempt.kind == .managedFile && attempt.resolution == nil
        case .closed:
            false
        }
    }

    static func canCoordinate(_ state: DocumentSyncState) -> Bool {
        // A failed atomic replacement leaves the original destination
        // intentionally non-writable. Local edits remain valid, but no save,
        // monitor reconciliation, or close flush may resume until the user
        // explicitly selects a new Save As destination.
        guard state.issue?.failure != .destinationRequiresSaveAs else {
            return false
        }
        return canAcceptSourceChanges(state)
    }

    static func canScheduleLocalSave(_ state: DocumentSyncState) -> Bool {
        guard canCoordinate(state),
            let attachment = state.fileAttachment,
            attachment.identity.matches(url: attachment.url)
        else {
            return false
        }
        guard state.uncertainCommit == nil else { return false }
        // A queued monitor observation is not advisory: committing before it
        // is reconciled could overwrite bytes that were verified after a
        // Save As target was selected. Keep the document editable, but defer
        // every automatic write until that observation has a terminal result.
        guard !state.externalSignalPending else { return false }
        guard !recoveryBlocksAutomation(state) else { return false }
        guard case .ready = state.recoveryAccess else { return false }
        guard state.recoveryMutationBarrier == nil else { return false }
        guard state.pendingConflict == nil else { return false }
        guard state.pendingDisplacedPreimage == nil else { return false }
        guard state.unresolvedDisplacedPreimage == nil else { return false }
        switch state.recovery {
        case .clear:
            return true
        case .available(let records):
            return records.raw.isEmpty
                || recoveryCleanupResolvesAllRawRecords(
                    state.recoveryCleanup,
                    in: records
                )
                || recoveryCleanupAuthorizesDecodedRestore(
                    state.recoveryCleanup,
                    in: records
                )
        case .persisting, .migrationPending:
            return false
        }
    }

    private static func recoveryCleanupAuthorizesDecodedRestore(
        _ cleanup: DocumentSyncRecoveryCleanup?,
        in records: DocumentSyncRecoveryRecords
    ) -> Bool {
        guard let cleanup,
            cleanup.discardPurpose == .discardRestoredRecords,
            cleanup.records == records,
            case .decoded(let restoredEntry) = cleanup.target,
            records.decoded.contains(restoredEntry),
            recordsAfterDiscard(cleanup.target, from: records) != nil
        else {
            return false
        }
        return true
    }

    static func canScheduleExternalRead(_ state: DocumentSyncState) -> Bool {
        guard canCoordinate(state),
            let attachment = state.fileAttachment,
            attachment.identity.matches(url: attachment.url)
        else {
            return false
        }
        guard state.uncertainCommit == nil else { return false }
        guard case .ready = state.recoveryAccess else { return false }
        guard state.recoveryMutationBarrier == nil else { return false }
        guard state.pendingConflict == nil else { return false }
        guard state.pendingDisplacedPreimage == nil else { return false }
        guard state.unresolvedDisplacedPreimage == nil else { return false }
        switch state.recovery {
        case .clear:
            guard state.recoveryCleanup == nil else { return false }
        case .available(let records):
            guard let cleanup = state.recoveryCleanup,
                cleanup.records == records,
                recordsAfterDiscard(cleanup.target, from: records) != nil
            else {
                return false
            }
        case .persisting, .migrationPending:
            return false
        }
        return true
    }

    static func matchesTargetURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL
            == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    static func accepts(
        _ state: DocumentSyncState,
        token: SyncEffectToken
    ) -> Bool {
        state.lifecycle != .closed
            && token.lifetime == state.lifetime
            && state.activeTokens[token.operation] == token
            && (token.attachmentEpoch == state.attachmentEpoch
                || acceptsRetainedRecoveryMutation(state, token: token))
    }

    private static func acceptsRetainedRecoveryMutation(
        _ state: DocumentSyncState,
        token: SyncEffectToken
    ) -> Bool {
        guard token.operation == .recovery,
            state.recoveryMutationBarrier != nil,
            state.activeTokens[.recovery] == token
        else {
            return false
        }
        return true
    }

    static func accepts(
        _ failure: DocumentSyncFailure,
        for operation: SyncOperationKind
    ) -> Bool {
        switch operation {
        case .savePreparation:
            failure == .localSave
        case .saveCommit:
            failure == .localSave || failure == .destinationRequiresSaveAs
        case .commitReconciliation:
            failure == .recovery
        case .externalRead:
            failure == .externalRead || failure == .attachment
        case .merge:
            failure == .merge
        case .recovery:
            failure == .recovery
        case .monitor:
            failure == .monitor
        case .close:
            failure == .closeDeadline
        }
    }

    static func makeToken(
        _ state: inout DocumentSyncState,
        operation: SyncOperationKind
    ) -> SyncEffectToken {
        let token = SyncEffectToken(
            lifetime: state.lifetime,
            attachmentEpoch: state.attachmentEpoch,
            operation: operation,
            attempt: state.nextAttempt
        )
        state.nextAttempt &+= 1
        state.activeTokens[operation] = token
        return token
    }

    private static func makeCommitGeneration(
        _ state: inout DocumentSyncState
    ) -> UInt64 {
        let baselineGeneration = state.durableBaseline?.commitGeneration ?? 0
        let generation = max(
            state.nextCommitGeneration,
            baselineGeneration &+ 1
        )
        state.nextCommitGeneration = generation &+ 1
        return generation
    }

    static func issue(
        for failure: DocumentSyncFailure
    ) -> DocumentSyncIssue {
        DocumentSyncIssue(
            failure: failure,
            retryable: failure != .destinationRequiresSaveAs,
            requiresSaveAs: failure == .destinationRequiresSaveAs,
            rawRecoveryURL: nil
        )
    }

    static func unchanged(
        _ state: DocumentSyncState
    ) -> DocumentSyncTransition {
        transition(state)
    }

    static func transition(
        _ state: DocumentSyncState,
        effects: [DocumentSyncEffect] = []
    ) -> DocumentSyncTransition {
        DocumentSyncTransition(state: state, effects: effects)
    }
}
