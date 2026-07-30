import Foundation

// Recovery record validation, identity migration, and retained-mutation barriers.
// Methods without `private` are reducer-internal validation helpers used by
// recovery events/effects and other transition domains.
extension DocumentSyncReducer {
    static func recoveryBlocksAutomation(_ state: DocumentSyncState) -> Bool {
        if state.uncertainCommit != nil
            || state.pendingConflict != nil
            || state.pendingDisplacedPreimage != nil
            || state.unresolvedDisplacedPreimage != nil {
            return true
        }
        if state.recoveryMutationBarrier != nil {
            return true
        }
        switch state.recoveryAccess {
        case .ready:
            break
        case .loading, .failed:
            return true
        }
        switch state.recovery {
        case .clear:
            return false
        case .available, .persisting, .migrationPending:
            return state.recoveryCleanup == nil
        }
    }

    static func recoveryReconciliationIntent(
        for state: DocumentSyncState
    ) -> DocumentSyncRecoveryReconciliationIntent? {
        switch state.recovery {
        case .persisting(let attempt):
            switch attempt.purpose {
            case .persistConflict:
                guard let entryID = attempt.entryID,
                      let payload = attempt.payload,
                      let expectedRecords = attempt.expectedRecords else {
                    return nil
                }
                return .persist(
                    identity: attempt.identity,
                    entryID: entryID,
                    payload: payload,
                    expectedRecords: expectedRecords,
                    expectedStoreGeneration: attempt.expectedStoreGeneration,
                    purpose: attempt.purpose,
                    displacedPreimageContinuation: nil
                )
            case .persistDisplacedPreimage:
                guard let entryID = attempt.entryID,
                      let payload = attempt.payload,
                      let expectedRecords = attempt.expectedRecords,
                      let continuation = attempt.displacedPreimageContinuation,
                      payload == .raw(continuation.rawPayload) else {
                    return nil
                }
                return .persist(
                    identity: attempt.identity,
                    entryID: entryID,
                    payload: payload,
                    expectedRecords: expectedRecords,
                    expectedStoreGeneration: attempt.expectedStoreGeneration,
                    purpose: attempt.purpose,
                    displacedPreimageContinuation: continuation
                )
            case .discardRaw,
                 .discardRestoredRecords,
                 .discardResolvedDisplacedPreimage:
                guard let target = attempt.discardTarget,
                      let expectedRecords = attempt.expectedRecords else {
                    return nil
                }
                return .discard(
                    identity: attempt.identity,
                    target: target,
                    expectedRecords: expectedRecords,
                    expectedStoreGeneration: attempt.expectedStoreGeneration,
                    purpose: attempt.purpose
                )
            }
        case .migrationPending(let migration):
            guard let expectedStoreGeneration = migration.expectedStoreGeneration else {
                return nil
            }
            return .migrate(
                sourceIdentity: migration.sourceIdentity,
                destinationIdentity: migration.destinationIdentity,
                records: migration.records,
                expectedStoreGeneration: expectedStoreGeneration
            )
        case .clear, .available:
            return nil
        }
    }

    static func reconciliationResult(
        _ result: DocumentSyncRecoveryReconciliationResult,
        matches intent: DocumentSyncRecoveryReconciliationIntent
    ) -> Bool {
        switch intent {
        case .persist(
            let identity,
            let entryID,
            let payload,
            let expectedRecords,
            _,
            let purpose,
            let continuation
        ):
            guard result.identity == identity,
                  recordsPreserve(expectedRecords, in: result.records) else {
                return false
            }
            switch payload {
            case .snapshot(let snapshot):
                return purpose == .persistConflict
                    && continuation == nil
                    && result.acknowledgedRecoveryArtifact == nil
                    && (result.records == expectedRecords
                        || result.records.decoded.contains(where: {
                            $0.id == entryID && $0.snapshot == snapshot
                        }))
            case .raw(let rawPayload):
                guard purpose == .persistDisplacedPreimage,
                      let continuation,
                      continuation.entryID == entryID,
                      continuation.rawPayload == rawPayload else {
                    return false
                }
                let hasPersistedRawRecord = rawRecord(
                        with: entryID,
                        identity: identity,
                        payload: rawPayload,
                        isPresentIn: result.records
                    )
                if hasPersistedRawRecord {
                    return result.acknowledgedRecoveryArtifact
                        == rawPayload.recoveryArtifact
                }
                return result.records == expectedRecords
                    && result.acknowledgedRecoveryArtifact == nil
            }
        case .migrate(
            let sourceIdentity,
            let destinationIdentity,
            let records,
            _
        ):
            guard result.acknowledgedRecoveryArtifact == nil else {
                return false
            }
            if result.identity == sourceIdentity {
                return result.records == records
            }
            if result.identity == destinationIdentity {
                return result.records
                    == migratedRecords(from: records, to: destinationIdentity)
            }
            return false
        case .discard(let identity, let target, let expectedRecords, _, _):
            guard result.identity == identity,
                  result.acknowledgedRecoveryArtifact == nil,
                  let discardedRecords = recordsAfterDiscard(
                    target,
                    from: expectedRecords
                  ) else {
                return false
            }
            return result.records == expectedRecords
                || result.records == discardedRecords
        }
    }

    static func canApplyDisplacedPreimageContinuation(
        _ continuation: DocumentSyncDisplacedPreimageContinuation,
        to state: DocumentSyncState
    ) -> Bool {
        guard let attachment = state.fileAttachment,
              attachment.identity == continuation.originIdentity,
              attachment.epoch == continuation.originAttachmentEpoch,
              state.source == continuation.localSourceRevision,
              state.snapshot == continuation.local,
              state.durableBaseline == continuation.preCommitBaseline,
              state.pendingConflict == nil,
              state.recoveryCleanup == nil else {
            return false
        }
        return true
    }

    static func applyCommittedDisplacedPreimageBaselineIfCurrent(
        _ continuation: DocumentSyncDisplacedPreimageContinuation,
        to state: inout DocumentSyncState
    ) {
        guard let attachment = state.fileAttachment,
              attachment.identity == continuation.originIdentity,
              attachment.epoch == continuation.originAttachmentEpoch,
              state.durableBaseline == continuation.preCommitBaseline else {
            return
        }
        state.durableBaseline = continuation.committedBaseline
        state.lastCommitSafety = continuation.commitSafety == .atomicSwap
            ? nil
            : continuation.commitSafety
    }

    static func rawRecord(
        with entryID: UUID,
        identity: DocumentIdentity,
        payload: DocumentSyncRawRecoveryPayload,
        isPresentIn records: DocumentSyncRecoveryRecords
    ) -> Bool {
        let matches = records.raw.filter { $0.id == entryID }
        guard matches.count == 1,
              let record = matches.first else {
            return false
        }
        return record.documentIdentity == identity
            && record.byteCount == payload.fingerprint.byteCount
            && record.contentDigest == payload.fingerprint.contentDigest
            && record.dataURL != nil
    }

    static func recordsPreserve(
        _ expected: DocumentSyncRecoveryRecords,
        in actual: DocumentSyncRecoveryRecords
    ) -> Bool {
        expected.decoded.allSatisfy(actual.decoded.contains)
            && expected.raw.allSatisfy(actual.raw.contains)
    }

    static func recoveryLoadScope(
        for state: DocumentSyncState
    ) -> DocumentSyncRecoveryLoadScope {
        if case .migrationPending(let migration) = state.recovery {
            return .document(migration.sourceIdentity)
        }
        if case .persisting(let attempt) = state.recovery {
            return .document(attempt.identity)
        }
        if let pendingConflict = state.pendingConflict {
            return .document(pendingConflict.identity)
        }
        if let continuation = state.pendingDisplacedPreimage {
            return .document(continuation.originIdentity)
        }
        if let attachment = state.fileAttachment {
            return .document(attachment.identity)
        }
        return .unattached
    }

    static func records(
        _ records: DocumentSyncRecoveryRecords,
        belongTo scope: DocumentSyncRecoveryLoadScope
    ) -> Bool {
        switch scope {
        case .unattached:
            return records.isEmpty
        case .document(let identity):
            return recordsBelongToIdentity(records, identity: identity)
        }
    }

    static func recordsBelongToIdentity(
        _ records: DocumentSyncRecoveryRecords,
        identity: DocumentIdentity
    ) -> Bool {
        let identifiers = records.decoded.map(\.id) + records.raw.map(\.id)
        return Set(identifiers).count == identifiers.count
            && records.decoded.allSatisfy { $0.documentIdentity == identity }
            && records.raw.allSatisfy { $0.documentIdentity == identity }
    }

    static func recoveryRecordsIdentity(
        _ records: DocumentSyncRecoveryRecords
    ) -> DocumentIdentity? {
        let identities = records.decoded.map(\.documentIdentity)
            + records.raw.map(\.documentIdentity)
        guard let identity = identities.first,
              identities.allSatisfy({ $0 == identity }) else {
            return nil
        }
        return identity
    }

    static func mutationAdvanced(
        _ result: DocumentSyncRecoveryMutationResult
    ) -> Bool {
        result.generation > result.previousGeneration
    }

    static func migratedRecords(
        from records: DocumentSyncRecoveryRecords,
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

    static func migratedDiscardTarget(
        _ target: DocumentSyncRecoveryDiscardTarget,
        to identity: DocumentIdentity
    ) -> DocumentSyncRecoveryDiscardTarget {
        switch target {
        case .decoded(let decoded):
            return .decoded(
                RecoveryEntry(
                    id: decoded.id,
                    documentIdentity: identity,
                    snapshot: decoded.snapshot,
                    createdAt: decoded.createdAt
                )
            )
        case .raw(let raw):
            return .raw(
                raw.map {
                    DocumentSyncRawRecoveryReference(
                        id: $0.id,
                        documentIdentity: identity,
                        dataURL: $0.dataURL,
                        byteCount: $0.byteCount,
                        contentDigest: $0.contentDigest,
                        createdAt: $0.createdAt
                    )
                }
            )
        case .selected(let records):
            return .selected(migratedRecords(from: records, to: identity))
        case .records(let records):
            return .records(migratedRecords(from: records, to: identity))
        }
    }

    static func recordsAfterDiscard(
        _ target: DocumentSyncRecoveryDiscardTarget,
        from records: DocumentSyncRecoveryRecords
    ) -> DocumentSyncRecoveryRecords? {
        switch target {
        case .decoded(let decoded):
            guard records.decoded.contains(decoded) else { return nil }
            return DocumentSyncRecoveryRecords(
                decoded: records.decoded.filter { $0.id != decoded.id },
                raw: records.raw
            )
        case .raw(let raw):
            let targetIDs = Set(raw.map(\.id))
            guard !raw.isEmpty,
                  targetIDs.count == raw.count,
                  raw.allSatisfy(records.raw.contains) else {
                return nil
            }
            return DocumentSyncRecoveryRecords(
                decoded: records.decoded,
                raw: records.raw.filter { !targetIDs.contains($0.id) }
            )
        case .selected(let selectedRecords):
            guard selectedRecoveryRecordsAreValid(
                selectedRecords,
                in: records
            ) else {
                return nil
            }
            let decodedIDs = Set(selectedRecords.decoded.map(\.id))
            let rawIDs = Set(selectedRecords.raw.map(\.id))
            return DocumentSyncRecoveryRecords(
                decoded: records.decoded.filter { !decodedIDs.contains($0.id) },
                raw: records.raw.filter { !rawIDs.contains($0.id) }
            )
        case .records(let targetRecords):
            guard targetRecords == records else { return nil }
            return .empty
        }
    }

    private static func selectedRecoveryRecordsAreValid(
        _ selected: DocumentSyncRecoveryRecords,
        in records: DocumentSyncRecoveryRecords
    ) -> Bool {
        guard !selected.isEmpty else { return false }
        let selectedIDs = selected.decoded.map(\.id) + selected.raw.map(\.id)
        guard Set(selectedIDs).count == selectedIDs.count else {
            return false
        }
        return selected.decoded.allSatisfy(records.decoded.contains)
            && selected.raw.allSatisfy(records.raw.contains)
    }

    static func discardTargetContainsRawEntry(
        _ target: DocumentSyncRecoveryDiscardTarget?,
        containsRawEntryID entryID: UUID
    ) -> Bool {
        guard let target else { return false }
        switch target {
        case .decoded(_):
            return false
        case .raw(let raw):
            return raw.contains { $0.id == entryID }
        case .selected(let records):
            return records.raw.contains { $0.id == entryID }
        case .records(let records):
            return records.raw.contains { $0.id == entryID }
        }
    }

    static func discardTargetContainsAnyRawRecord(
        _ target: DocumentSyncRecoveryDiscardTarget
    ) -> Bool {
        switch target {
        case .decoded:
            return false
        case .raw(let raw):
            return !raw.isEmpty
        case .selected(let records), .records(let records):
            return !records.raw.isEmpty
        }
    }

    static func recoveryCleanupResolvesAllRawRecords(
        _ cleanup: DocumentSyncRecoveryCleanup?,
        in records: DocumentSyncRecoveryRecords
    ) -> Bool {
        guard let cleanup else { return false }
        switch cleanup.target {
        case .decoded:
            return false
        case .raw(let raw):
            return records.raw.allSatisfy(raw.contains)
        case .selected(let selectedRecords):
            return records.raw.allSatisfy(selectedRecords.raw.contains)
        case .records(let targetRecords):
            return records.raw.allSatisfy(targetRecords.raw.contains)
        }
    }

    static func detachedRecoveryMutationContainsRawEvidence(
        _ state: DocumentSyncState,
        records: DocumentSyncRecoveryRecords
    ) -> Bool {
        if !records.raw.isEmpty
            || state.pendingDisplacedPreimage != nil
            || state.unresolvedDisplacedPreimage != nil {
            return true
        }
        switch state.recovery {
        case .clear, .available:
            return false
        case .migrationPending(let migration):
            return !migration.records.raw.isEmpty
        case .persisting(let attempt):
            if attempt.rawPayload != nil
                || !(attempt.expectedRecords?.raw.isEmpty ?? true) {
                return true
            }
            guard let discardTarget = attempt.discardTarget else {
                return false
            }
            switch discardTarget {
            case .decoded:
                return false
            case .raw(let raw):
                return !raw.isEmpty
            case .selected(let selectedRecords):
                return !selectedRecords.raw.isEmpty
            case .records(let targetRecords):
                return !targetRecords.raw.isEmpty
            }
        }
    }

    static func preservesDetachedRawRecovery(
        in state: DocumentSyncState,
        forIncomingIdentity identity: DocumentIdentity
    ) -> Bool {
        guard let barrier = state.recoveryMutationBarrier,
              barrier.relocationDestination == nil else {
            return false
        }
        return barrier.committedIdentity != identity
            && detachedRecoveryMutationContainsRawEvidence(
                state,
                records: .empty
            )
    }

    static func activeRecoveryMutationToken(
        in state: DocumentSyncState
    ) -> SyncEffectToken? {
        if state.recoveryMutationBarrier != nil,
           let token = state.activeTokens[.recovery] {
            return token
        }
        switch state.recovery {
        case .persisting(let attempt):
            guard state.activeTokens[.recovery] == attempt.token else {
                return nil
            }
            return attempt.token
        case .migrationPending(let migration):
            guard let token = migration.token,
                  state.activeTokens[.recovery] == token else {
                return nil
            }
            return token
        case .clear, .available:
            return nil
        }
    }

    static func recoveryMutationBarrier(
        for state: DocumentSyncState
    ) -> DocumentSyncRecoveryMutationBarrier? {
        guard activeRecoveryMutationToken(in: state) != nil else {
            return nil
        }
        switch state.recovery {
        case .persisting(let attempt):
            return DocumentSyncRecoveryMutationBarrier(
                originalIdentity: attempt.identity,
                committedIdentity: attempt.identity,
                relocationDestination: state.fileAttachment?.identity
                    ?? attempt.identity
            )
        case .migrationPending(let migration):
            return DocumentSyncRecoveryMutationBarrier(
                originalIdentity: migration.sourceIdentity,
                committedIdentity: migration.destinationIdentity,
                relocationDestination: state.fileAttachment?.identity
                    ?? migration.destinationIdentity
            )
        case .clear, .available:
            return nil
        }
    }

    static func installRecoveryMutationBarrier(
        from state: DocumentSyncState,
        in updated: inout DocumentSyncState
    ) {
        guard updated.recoveryMutationBarrier == nil,
              let barrier = recoveryMutationBarrier(for: state) else {
            return
        }
        updated.recoveryMutationBarrier = barrier
    }

    static func retargetRecoveryMutationBarrier(
        _ state: inout DocumentSyncState,
        to identity: DocumentIdentity?
    ) {
        guard var barrier = state.recoveryMutationBarrier else { return }
        barrier.relocationDestination = identity
        state.recoveryMutationBarrier = barrier
    }

    static func pauseRecoveryBarrier(
        _ state: inout DocumentSyncState
    ) {
        state.activeTokens.removeValue(forKey: .recovery)
        state.recoveryAccess = .failed(.recovery)
        state.issue = issue(for: .recovery)
    }

    static func recoveryGeneration(
        in access: DocumentSyncRecoveryAccess
    ) -> UInt64? {
        guard case .ready(let generation) = access else { return nil }
        return generation
    }
}
