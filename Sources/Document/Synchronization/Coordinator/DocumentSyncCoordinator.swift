import Combine
import Foundation

struct DocumentSynchronizationStatusSnapshot: Equatable {
    let presentedState: SynchronizationState?
    let failureRequiresSaveAs: Bool
    let recoveryMigrationIsPending: Bool
    let recoveryRetryAvailable: Bool
    let rawRecoveryURL: URL?
    let hasLocalRecovery: Bool

    static let empty = DocumentSynchronizationStatusSnapshot(
        presentedState: nil,
        failureRequiresSaveAs: false,
        recoveryMigrationIsPending: false,
        recoveryRetryAvailable: false,
        rawRecoveryURL: nil,
        hasLocalRecovery: false
    )
}

private struct VerifiedCoordinatorAttachment: Sendable {
    let targetURL: URL
    let identity: DocumentIdentity
    let sourceRevision: SourceRevision
    let durableBaseline: DocumentSyncDurableBaseline?
    let dataMatchesExpectedBytes: Bool
    let verifiedExternalChange: DocumentSyncExternalChange?
}

private struct UnverifiedCoordinatorAttachment: Sendable {
    let targetURL: URL
    let identity: DocumentIdentity
    let sourceRevision: SourceRevision
}

private enum PendingVerifiedExternalReadOutcome {
    case result(DocumentSyncExternalReadResult)
    case failure
}

private struct PendingVerifiedExternalRead {
    let identity: DocumentIdentity
    let targetURL: URL
    let outcome: PendingVerifiedExternalReadOutcome
    let continuation: CheckedContinuation<Void, Error>?
}

private struct PendingInitialPresenterSignal {
    let requestID: UUID
    let attachmentEpoch: UInt64
}

private enum CoordinatorAttachmentInspection: Sendable {
    case verified(VerifiedCoordinatorAttachment)
    case unavailable(UnverifiedCoordinatorAttachment)

    var target: UnverifiedCoordinatorAttachment {
        switch self {
        case .verified(let attachment):
            UnverifiedCoordinatorAttachment(
                targetURL: attachment.targetURL,
                identity: attachment.identity,
                sourceRevision: attachment.sourceRevision
            )
        case .unavailable(let target):
            target
        }
    }

    var durableBaseline: DocumentSyncDurableBaseline? {
        if case .verified(let attachment) = self {
            return attachment.durableBaseline
        }
        return nil
    }

    var didReadData: Bool {
        if case .verified = self {
            return true
        }
        return false
    }
}

enum DocumentSyncCoordinatorAttachmentError: Error, Sendable, Equatable {
    case invalidSaveAsEvidence
    case verificationUnavailable
    case verificationInterrupted
    case recoveryBlocksVerification
}

@MainActor
final class DocumentSyncCoordinator: ObservableObject {
    static let localWriteDelay = DocumentSyncReducer.localSaveDelay

    private(set) var state: SynchronizationState = .idle
    @Published private(set) var statusSnapshot: DocumentSynchronizationStatusSnapshot = .empty
    @Published private(set) var format: TextFileFormat
    private(set) var durableState: DurableFileState?
    @Published private(set) var fileURL: URL?

    let sourceBuffer: MarkdownSourceBuffer
    let bridge: SaveTransactionBridge
    weak var delegate: DocumentSyncCoordinatorDelegate?

    /// The reducer value is the sole owner of synchronization decisions.
    private(set) var reducerState: DocumentSyncState

    private let recoveryStore: SessionRecoveryStore
    /// `DurableFileState` has no attachment identity, so it can only remain a
    /// compatibility projection until a verified file attachment replaces it.
    private var unattachedDurableState: DurableFileState?
    private let fileMonitoringEnabled: Bool
    private let effectExecutor: DocumentSyncCoordinatorEffectExecuting
    private let manualScheduler: ManualSyncScheduler?
    private let savePreparationHook: (@MainActor () async -> Void)?
    private let externalReadHook: (@MainActor (UInt64) async -> Void)?
    private let initialAttachmentFreshReadCompletedHook: (@MainActor () -> Void)?
    private let monitorStartHook: (@Sendable () throws -> Void)?
    private let monitorDescriptorClosedHook: (@Sendable (Bool) -> Void)?
    private lazy var scheduler = SyncScheduler { [weak self] deadline in
        self?.dispatch(.deadlineFired(deadline))
    }

    private var sourceObservation: UUID?
    private var attachmentTask: Task<Void, Never>?
    private var attachmentRequestID: UUID?
    private var attachmentCompletions: [UUID: (@MainActor (Bool) -> Void)] = [:]
    private var initialAttachmentPending = false
    private var initialAttachmentResult: Bool?
    private var initialAttachmentWaiters: [CheckedContinuation<Bool, Never>] = []
    private var pendingInitialPresenterSignal: PendingInitialPresenterSignal?
    private var pendingVerifiedExternalRead: PendingVerifiedExternalRead?
    private var recoveryStartupWaiters: [CheckedContinuation<DocumentSyncRecoveryAccess, Never>] =
        []
    private var recoveryOperationWaiters: [SyncEffectToken: [CheckedContinuation<Void, Never>]] =
        [:]
    private var commitReconciliationWaiters: [SyncEffectToken: [CheckedContinuation<Void, Never>]] =
        [:]
    private var monitors: [SyncEffectToken: DirectoryFileMonitor] = [:]
    private var queuedEvents: [DocumentSyncEvent] = []
    private var isDispatching = false
    private var isApplyingReducerSource = false
    private var isTornDown = false
    private var flushWaiters: [(@MainActor (Bool) -> Void)] = []

    init(
        snapshot: DocumentSnapshot,
        initialDurableState: DurableFileState? = nil,
        bridge: SaveTransactionBridge = SaveTransactionBridge(),
        recoveryStore: SessionRecoveryStore = .shared,
        fileMonitoringEnabled: Bool = true,
        savePreparationHook: (@MainActor () async -> Void)? = nil,
        externalReadHook: (@MainActor (UInt64) async -> Void)? = nil,
        effectExecutor: DocumentSyncCoordinatorEffectExecuting? = nil,
        manualScheduler: ManualSyncScheduler? = nil,
        initialAttachmentFreshReadCompletedHook:
            (@MainActor () -> Void)? = nil,
        monitorStartHook: (@Sendable () throws -> Void)? = nil,
        monitorDescriptorClosedHook: (@Sendable (Bool) -> Void)? = nil
    ) {
        sourceBuffer = MarkdownSourceBuffer(snapshot: snapshot)
        format = snapshot.format
        durableState = initialDurableState
        unattachedDurableState = initialDurableState
        self.bridge = bridge
        self.recoveryStore = recoveryStore
        self.fileMonitoringEnabled = fileMonitoringEnabled
        self.effectExecutor =
            effectExecutor
            ?? DocumentSyncDefaultEffectExecutor(recoveryStore: recoveryStore)
        self.manualScheduler = manualScheduler
        self.savePreparationHook = savePreparationHook
        self.externalReadHook = externalReadHook
        self.initialAttachmentFreshReadCompletedHook =
            initialAttachmentFreshReadCompletedHook
        self.monitorStartHook = monitorStartHook
        self.monitorDescriptorClosedHook = monitorDescriptorClosedHook
        reducerState = DocumentSyncState(
            source: sourceBuffer.revision,
            format: snapshot.format,
            // Recovery import is an explicit actor transaction. Editing stays
            // available while it loads, but automation remains gated until a
            // typed generation and complete record set arrive.
            recoveryAccess: .loading
        )
        sourceObservation = sourceBuffer.observe { [weak self] revision, origin in
            self?.sourceDidChange(revision, origin: origin)
        }
        publishCompatibility(from: reducerState, event: nil)
    }

    var currentSnapshot: DocumentSnapshot {
        reducerState.snapshot
    }

    var hasLocalChanges: Bool {
        reducerState.local.isDirty
    }

    var presentedState: SynchronizationState? {
        statusSnapshot.presentedState
    }

    var latestRawRecoveryURL: URL? {
        statusSnapshot.rawRecoveryURL
    }

    var hasLocalRecovery: Bool {
        statusSnapshot.hasLocalRecovery
    }

    var recoveryMigrationIsPending: Bool {
        statusSnapshot.recoveryMigrationIsPending
    }

    var failureRequiresSaveAs: Bool {
        statusSnapshot.failureRequiresSaveAs
    }

    /// Main-actor event serialization boundary. Effects can enqueue a newer
    /// event synchronously, but only this loop applies reducer transitions.
    func dispatch(_ event: DocumentSyncEvent) {
        guard !isTornDown else { return }
        queuedEvents.append(event)
        guard !isDispatching else { return }

        isDispatching = true
        defer { isDispatching = false }
        while !queuedEvents.isEmpty {
            let nextEvent = queuedEvents.removeFirst()
            let previous = reducerState
            let transition = DocumentSyncReducer.reduce(
                previous,
                event: nextEvent
            )
            reducerState = transition.state
            publishCompatibility(from: previous, event: nextEvent)
            for effect in transition.effects {
                execute(effect)
            }
            if case .recoveryFinished(let token, _) = nextEvent {
                resolveRecoveryOperationWaiters(for: token)
            }
            switch nextEvent {
            case .commitReconciliationFinished(let token, _):
                resolveCommitReconciliationWaiters(for: token)
            case .operationFailed(let token, _)
            where token.operation == .commitReconciliation:
                resolveCommitReconciliationWaiters(for: token)
            default:
                break
            }
            resolveFlushWaitersIfPossible()
        }
        resolveRecoveryStartupWaitersIfPossible()
    }

    func loadInitial(_ snapshot: DocumentSnapshot, data: Data, from url: URL?) {
        cancelPendingAttachmentRequest()
        initialAttachmentPending = false
        initialAttachmentResult = nil
        let previous = reducerState
        replaceSource(snapshot.text, origin: .initialLoad)
        installLoadingInitialSource(
            snapshot,
            targetURL: url?.standardizedFileURL,
            previous: previous
        )
        guard let url else {
            resolveInitialAttachmentWaiters(didAttach: false)
            dispatch(.started)
            return
        }
        let targetURL = url.standardizedFileURL
        let capturedSource = sourceBuffer.revision
        initialAttachmentPending = true
        let requestID = beginAttachmentRequest { [weak self] didAttach in
            self?.resolveInitialAttachmentWaiters(didAttach: didAttach)
        }
        scheduleAttachmentInspection(
            requestID: requestID,
            event: .attach,
            targetURL: targetURL,
            knownData: data,
            sourceRevision: capturedSource,
            sourceFormat: snapshot.format,
            baselineSourceRevision: capturedSource,
            initialFormat: snapshot.format,
            requiresFreshTargetObservation: true
        )
    }

    /// Loading text is not a filesystem decision: the caller already owns
    /// these immutable bytes. Install that source immediately so a Save or
    /// serialization request cannot observe the constructor snapshot while
    /// attachment identity, fingerprint, and recovery import remain pending.
    private func installLoadingInitialSource(
        _ snapshot: DocumentSnapshot,
        targetURL: URL?,
        previous: DocumentSyncState
    ) {
        let attachment: DocumentSyncAttachment =
            if let targetURL {
                .provisional(
                    DocumentSyncProvisionalFileAttachment(
                        url: targetURL,
                        epoch: previous.attachmentEpoch + 1
                    )
                )
            } else {
                .untitled
            }
        reducerState = DocumentSyncState(
            lifetime: previous.lifetime,
            source: sourceBuffer.revision,
            format: snapshot.format,
            attachment: attachment,
            attachmentEpoch: targetURL == nil
                ? previous.attachmentEpoch
                : previous.attachmentEpoch + 1,
            recoveryAccess: .loading,
            nextAttempt: previous.nextAttempt,
            nextCommitGeneration: previous.nextCommitGeneration
        )
        unattachedDurableState = nil
        publishCompatibility(from: previous, event: nil)
    }

    /// Recovery reads are intentionally asynchronous. Hosts that need a
    /// stable recovery decision (rather than merely editable source text)
    /// can await this boundary without blocking the main actor.
    func waitForRecoveryStartup() async -> DocumentSyncRecoveryAccess {
        switch reducerState.recoveryAccess {
        case .loading:
            return await withCheckedContinuation { continuation in
                recoveryStartupWaiters.append(continuation)
            }
        case .ready, .failed:
            return reducerState.recoveryAccess
        }
    }

    /// Awaits the exact recovery operation that is active when this method is
    /// called. It is intentionally token-specific so tests and hosts cannot
    /// mistake an earlier or later recovery transaction for this one.
    func waitForCurrentRecoveryOperation() async {
        guard let token = reducerState.activeTokens[.recovery] else { return }
        await withCheckedContinuation { continuation in
            guard reducerState.activeTokens[.recovery] == token else {
                continuation.resume()
                return
            }
            recoveryOperationWaiters[token, default: []].append(continuation)
        }
    }

    /// Awaits the exact uncertain-commit reconciliation active at call time.
    /// The token check prevents a retry from satisfying an older waiter.
    func waitForCurrentCommitReconciliation() async {
        guard let token = reducerState.activeTokens[.commitReconciliation] else {
            return
        }
        await withCheckedContinuation { continuation in
            guard reducerState.activeTokens[.commitReconciliation] == token else {
                continuation.resume()
                return
            }
            commitReconciliationWaiters[token, default: []].append(continuation)
        }
    }

    /// Waits for the verification request originally scheduled by
    /// `loadInitial`. Unlike `attachAndWait`, this never replaces that
    /// in-flight request, which lets a host distinguish loaded source from a
    /// verified file attachment without cancelling either operation.
    func waitForInitialAttachment() async -> Bool {
        if let initialAttachmentResult {
            return initialAttachmentResult
        }
        guard initialAttachmentPending else { return false }
        return await withCheckedContinuation { continuation in
            initialAttachmentWaiters.append(continuation)
        }
    }

    func attach(
        to url: URL,
        knownData: Data? = nil,
        knownSnapshot: DocumentSnapshot? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        _ = knownSnapshot
        guard !isTornDown else { return }
        let targetURL = url.standardizedFileURL
        let requestID = beginAttachmentRequest(completion: completion)

        let capturedSource = reducerState.source
        scheduleAttachmentInspection(
            requestID: requestID,
            event: .attach,
            targetURL: targetURL,
            knownData: knownData,
            sourceRevision: capturedSource,
            sourceFormat: reducerState.format,
            baselineSourceRevision: capturedSource
        )
    }

    /// Attachment reads happen off the main actor. Consumers that need the
    /// verified attachment state must await this boundary instead of observing
    /// the legacy fire-and-forget call synchronously.
    func attachAndWait(
        to url: URL,
        knownData: Data? = nil,
        knownSnapshot: DocumentSnapshot? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            attach(
                to: url,
                knownData: knownData,
                knownSnapshot: knownSnapshot
            ) { didAttach in
                continuation.resume(returning: didAttach)
            }
        }
    }

    func attachAfterSaveAs(
        to url: URL,
        expectedData: Data,
        expectedSnapshot: DocumentSnapshot,
        expectedSourceRevision: SourceRevision? = nil
    ) async throws {
        guard !isTornDown else { return }
        let targetURL = url.standardizedFileURL
        let capturedSource = reducerState.source
        let requestID = beginAttachmentRequest(completion: nil)
        let sourceFormat = reducerState.format
        let baselineSourceRevision = expectedSourceRevision ?? capturedSource
        let commitGeneration = reducerState.durableBaseline?.commitGeneration ?? 0
        let verification: CoordinatorAttachmentInspection
        do {
            verification = try await DocumentFileAccess.perform {
                try Self.inspectSaveAsAttachment(
                    at: targetURL,
                    expectedData: expectedData,
                    expectedSnapshot: expectedSnapshot,
                    sourceRevision: capturedSource,
                    sourceFormat: sourceFormat,
                    baselineSourceRevision: baselineSourceRevision,
                    commitGeneration: commitGeneration
                )
            }
        } catch {
            guard attachmentRequestID == requestID else { return }
            attachmentRequestID = nil
            throw error
        }
        guard !isTornDown, attachmentRequestID == requestID else { return }
        completeAttachment(
            requestID: requestID,
            event: .saveAsAttached,
            inspection: verification
        )
        guard case .verified(let attachment) = verification,
            !attachment.dataMatchesExpectedBytes
        else { return }
        try await applyVerifiedSaveAsReplacement(attachment.verifiedExternalChange)
    }

    func updateFileURL(_ url: URL) {
        attach(to: url)
    }

    func noteFileMoved(
        to newURL: URL,
        knownData: Data? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isTornDown else { return }
        let targetURL = newURL.standardizedFileURL
        let requestID = beginAttachmentRequest(completion: completion)
        let capturedSource = reducerState.source
        scheduleAttachmentInspection(
            requestID: requestID,
            event: .fileMoved,
            targetURL: targetURL,
            knownData: knownData,
            sourceRevision: capturedSource,
            sourceFormat: reducerState.format,
            baselineSourceRevision: capturedSource
        )
    }

    /// The file-move counterpart to `attachAndWait`. It gives hosts that must
    /// preserve the verified move state an explicit boundary instead of
    /// observing a fire-and-forget filesystem task.
    func noteFileMovedAndWait(
        to newURL: URL,
        knownData: Data? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            noteFileMoved(to: newURL, knownData: knownData) { didMove in
                continuation.resume(returning: didMove)
            }
        }
    }

    func noteCoordinatedExternalChange() {
        guard let monitorToken = reducerState.activeTokens[.monitor] else {
            guard initialAttachmentPending,
                let requestID = attachmentRequestID,
                case .provisional(let attachment) = reducerState.attachment
            else {
                return
            }
            pendingInitialPresenterSignal = PendingInitialPresenterSignal(
                requestID: requestID,
                attachmentEpoch: attachment.epoch
            )
            return
        }
        dispatch(.monitorSignaled(monitorToken))
    }

    func flushNow(completion: (@MainActor (Bool) -> Void)? = nil) {
        if let completion {
            flushWaiters.append(completion)
        }
        guard reducerState.fileAttachment != nil, !isTornDown else {
            resolveFlushWaiters(succeeded: false)
            return
        }
        dispatch(.saveRequested)
        resolveFlushWaitersIfPossible()
    }

    func restoreLatestRecovery() {
        dispatch(.restoreLocalRecovery)
    }

    func resumeSynchronization() {
        dispatch(.discardRawRecovery)
    }

    func retryRecoveryMigration() {
        dispatch(.retry)
    }

    func retrySynchronization() {
        dispatch(.retry)
    }

    func requestClose() {
        dispatch(.requestClose)
    }

    func completeClose(token: SyncEffectToken, didCommit: Bool) {
        dispatch(didCommit ? .closeCommitted(token) : .closeCancelled(token))
    }

    @discardableResult
    func handleSaveCompletion(
        token: SyncEffectToken,
        error: Error?
    ) -> Bool {
        if let error {
            bridge.cancel(token: token)
            if let commitError = error as? SafeFileCommitter.CommitError {
                switch commitError {
                case .atomicSwapUnavailable:
                    dispatch(
                        .commitFailed(
                            token: token,
                            disposition: .destinationRequiresSaveAs
                        )
                    )
                case .atomicSwapFailed, .invalidPreparedPayload:
                    dispatch(.commitFailed(token: token, disposition: .notStarted))
                case .targetMissingBeforeCommit:
                    dispatch(.commitFailed(token: token, disposition: .notStarted))
                    noteCoordinatedExternalChange()
                case .targetChangedBeforeCommit:
                    dispatch(.commitFailed(token: token, disposition: .notStarted))
                    // The committer proved no replacement began, but it also
                    // proved that the expected durable preimage changed.
                    // Request a fresh immutable observation before any retry.
                    noteCoordinatedExternalChange()
                }
            } else {
                dispatch(.operationFailed(token: token, failure: .localSave))
            }
            return isFullySynchronized
        }

        do {
            let result = try bridge.finish(token: token)
            dispatch(.saveFinished(token: token, completion: .init(result: result)))
        } catch {
            dispatch(.operationFailed(token: token, failure: .localSave))
        }
        return isFullySynchronized
    }

    /// Legacy delegate completion remains only for existing integrations. It
    /// resolves the immutable bridge request first, then delegates validation
    /// to the full token path above.
    @discardableResult
    func handleSaveCompletion(generation: UInt64, error: Error?) -> Bool {
        guard let request = try? bridge.currentCommitRequest(),
            request.pendingSave.generation == generation
        else {
            return false
        }
        return handleSaveCompletion(token: request.token, error: error)
    }

    func advanceScheduledWork(by duration: Duration) {
        guard let manualScheduler else { return }
        for deadline in manualScheduler.advance(by: duration) {
            dispatch(.deadlineFired(deadline))
        }
    }

    func close() {
        guard !isTornDown else { return }
        if case .closing(let attempt) = reducerState.lifecycle,
            attempt.resolution == .allowManagedClose
                || attempt.resolution == .deferToNativeUntitledReview
        {
            dispatch(.closed(attempt.token))
        }
        tearDown()
    }

    private func sourceDidChange(
        _ revision: SourceRevision,
        origin: DocumentChangeOrigin
    ) {
        guard !isTornDown, !isApplyingReducerSource else { return }
        var updatedFormat = reducerState.format
        updatedFormat.hasFinalNewline = revision.text.utf16.last == 0x000A
        dispatch(.sourceChanged(revision, format: updatedFormat))
        if !reducerState.attachment.isManagedFile,
            let hostURL = delegate?.synchronizationFileURL
        {
            attach(to: hostURL)
        }
        _ = origin
    }

    private func installInitialAttachment(
        target: UnverifiedCoordinatorAttachment,
        durableBaseline: DocumentSyncDurableBaseline?,
        initialFormat: TextFileFormat? = nil,
        requiresExternalVerification: Bool = false
    ) {
        let previous = reducerState
        // A source edit can occur while the file queue verifies the initial
        // attachment. Keep that newer source revision authoritative; the
        // baseline remains stamped to the captured on-disk revision so the
        // reducer correctly treats the newer edit as dirty.
        let source = sourceBuffer.revision
        let format =
            initialFormat
            ?? durableBaseline?.snapshot.format
            ?? previous.format
        let attachmentEpoch: UInt64
        if case .provisional(let provisional) = previous.attachment {
            attachmentEpoch = provisional.epoch
        } else {
            attachmentEpoch = previous.attachmentEpoch + 1
        }
        let mustVerifyExternalState =
            requiresExternalVerification
            || durableBaseline?.snapshot
                != DocumentSnapshot(text: source.text, format: format)
        reducerState = DocumentSyncState(
            lifetime: previous.lifetime,
            source: source,
            format: format,
            attachment: .file(
                DocumentSyncFileAttachment(
                    identity: target.identity,
                    url: target.targetURL,
                    epoch: attachmentEpoch
                )
            ),
            attachmentEpoch: attachmentEpoch,
            durableBaseline: durableBaseline,
            recoveryAccess: .loading,
            lifecycle: previous.lifecycle,
            issue: nil,
            nextAttempt: previous.nextAttempt,
            nextCommitGeneration: previous.nextCommitGeneration,
            activeTokens: previous.activeTokens,
            externalSignalPending: mustVerifyExternalState
        )
        unattachedDurableState = nil
        publishCompatibility(from: previous, event: nil)
        dispatch(.started)
        guard mustVerifyExternalState,
            let monitorToken = reducerState.activeTokens[.monitor]
        else {
            return
        }
        dispatch(.monitorSignaled(monitorToken))
    }

    private func beginAttachmentRequest(
        completion: (@MainActor (Bool) -> Void)?
    ) -> UUID {
        cancelPendingAttachmentRequest()
        resolvePendingVerifiedExternalRead(throwing: .verificationInterrupted)
        let requestID = UUID()
        attachmentRequestID = requestID
        if let completion {
            attachmentCompletions[requestID] = completion
        }
        return requestID
    }

    private func cancelPendingAttachmentRequest() {
        attachmentTask?.cancel()
        attachmentTask = nil
        if let requestID = attachmentRequestID {
            attachmentCompletions.removeValue(forKey: requestID)?(false)
            if pendingInitialPresenterSignal?.requestID == requestID {
                pendingInitialPresenterSignal = nil
            }
        }
        attachmentRequestID = nil
    }

    private func scheduleAttachmentInspection(
        requestID: UUID,
        event: AttachmentEvent,
        targetURL: URL,
        knownData: Data?,
        sourceRevision: SourceRevision,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        initialFormat: TextFileFormat? = nil,
        requiresFreshTargetObservation: Bool = false
    ) {
        let commitGeneration = reducerState.durableBaseline?.commitGeneration ?? 0
        attachmentTask = Task { [weak self] in
            let inspection: CoordinatorAttachmentInspection
            do {
                inspection = try await DocumentFileAccess.perform {
                    Self.inspectAttachment(
                        at: targetURL,
                        knownData: knownData,
                        sourceRevision: sourceRevision,
                        sourceFormat: sourceFormat,
                        baselineSourceRevision: baselineSourceRevision,
                        commitGeneration: commitGeneration,
                        requiresFreshTargetObservation:
                            requiresFreshTargetObservation
                    )
                }
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            if requiresFreshTargetObservation {
                self.initialAttachmentFreshReadCompletedHook?()
            }
            self.completeAttachment(
                requestID: requestID,
                event: event,
                inspection: inspection,
                initialFormat: initialFormat
            )
        }
    }

    private func completeAttachment(
        requestID: UUID,
        event: AttachmentEvent,
        inspection: CoordinatorAttachmentInspection,
        initialFormat: TextFileFormat? = nil
    ) {
        guard !isTornDown, attachmentRequestID == requestID else { return }
        attachmentTask = nil
        attachmentRequestID = nil
        let target = inspection.target
        let baseline = inspection.durableBaseline
        let pendingPresenterSignal = pendingInitialPresenterSignal
        let replaysPresenterSignal =
            pendingPresenterSignal?.requestID == requestID
            && pendingPresenterSignal?.attachmentEpoch
                == reducerState.attachmentEpoch
        if pendingPresenterSignal?.requestID == requestID {
            pendingInitialPresenterSignal = nil
        }

        if case .attach = event,
            reducerState.fileAttachment == nil,
            reducerState.recoveryRecords == nil
        {
            // Initial document attachment is construction, not a relocation.
            // It keeps ordinary editing usable while P1 replaces the legacy
            // recovery store with exact typed receipts.
            let requiresFreshTargetObservation =
                queueFreshInitialTargetObservation(from: inspection)
            installInitialAttachment(
                target: target,
                durableBaseline: baseline,
                initialFormat: initialFormat,
                requiresExternalVerification:
                    requiresFreshTargetObservation || replaysPresenterSignal
            )
            finishAttachmentRequest(requestID, didAttach: inspection.didReadData)
            if !inspection.didReadData {
                noteCoordinatedExternalChange()
            }
            return
        }

        unattachedDurableState = nil
        switch event {
        case .attach:
            dispatch(
                .attach(
                    identity: target.identity,
                    url: target.targetURL,
                    durableBaseline: baseline
                )
            )
        case .fileMoved:
            dispatch(
                .fileMoved(
                    identity: target.identity,
                    url: target.targetURL,
                    durableBaseline: baseline
                )
            )
        case .saveAsAttached:
            dispatch(
                .saveAsAttached(
                    identity: target.identity,
                    url: target.targetURL,
                    durableBaseline: baseline
                )
            )
        }
        finishAttachmentRequest(requestID, didAttach: inspection.didReadData)
        if !inspection.didReadData {
            // The host has already chosen this URL (notably after Save As),
            // so do not leave the old attachment live. A fresh monitor read
            // projects the missing/unreadable target without authorizing an
            // unchecked write.
            noteCoordinatedExternalChange()
        }
    }

    private func finishAttachmentRequest(
        _ requestID: UUID,
        didAttach: Bool
    ) {
        attachmentCompletions.removeValue(forKey: requestID)?(didAttach)
    }

    private func resolveInitialAttachmentWaiters(didAttach: Bool) {
        initialAttachmentPending = false
        initialAttachmentResult = didAttach
        let waiters = initialAttachmentWaiters
        initialAttachmentWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: didAttach)
        }
    }

    private func resolvePendingVerifiedExternalRead(
        throwing error: DocumentSyncCoordinatorAttachmentError? = nil
    ) {
        guard let pending = pendingVerifiedExternalRead else { return }
        pendingVerifiedExternalRead = nil
        if let error {
            pending.continuation?.resume(throwing: error)
        } else {
            pending.continuation?.resume()
        }
    }

    /// The NSDocument read is immutable source input, not proof that the
    /// target still contains those bytes. Queue the separate observation
    /// captured by initial inspection so recovery readiness and the monitor
    /// token gate it ahead of every local save.
    private func queueFreshInitialTargetObservation(
        from inspection: CoordinatorAttachmentInspection
    ) -> Bool {
        guard case .verified(let attachment) = inspection,
            !attachment.dataMatchesExpectedBytes
        else {
            return false
        }
        let outcome: PendingVerifiedExternalReadOutcome =
            if let change = attachment.verifiedExternalChange {
                .result(.changed(change))
            } else {
                .failure
            }
        pendingVerifiedExternalRead = PendingVerifiedExternalRead(
            identity: attachment.identity,
            targetURL: attachment.targetURL,
            outcome: outcome,
            continuation: nil
        )
        return true
    }

    private func resolvePendingVerifiedExternalReadIfBlocked() {
        guard let pending = pendingVerifiedExternalRead else { return }
        guard let attachment = reducerState.fileAttachment,
            attachment.identity == pending.identity,
            attachment.url.standardizedFileURL
                == pending.targetURL.standardizedFileURL
        else {
            resolvePendingVerifiedExternalRead(throwing: .verificationInterrupted)
            return
        }
        switch reducerState.recoveryAccess {
        case .loading:
            return
        case .failed:
            resolvePendingVerifiedExternalRead(throwing: .recoveryBlocksVerification)
        case .ready:
            guard
                DocumentSyncReducer.canScheduleExternalRead(reducerState)
                    || reducerState.external != .idle
            else {
                resolvePendingVerifiedExternalRead(
                    throwing: .recoveryBlocksVerification
                )
                return
            }
        }
    }

    /// Save As has already captured the target bytes off the main actor. If
    /// those bytes changed before verification completed, feed the immutable
    /// observation straight back through the reducer so this async API does
    /// not return with a stale baseline. The concurrently started executor
    /// completion is harmless: its token is stale after this result wins.
    private func applyVerifiedSaveAsReplacement(
        _ change: DocumentSyncExternalChange?
    ) async throws {
        guard let monitorToken = reducerState.activeTokens[.monitor] else {
            throw DocumentSyncCoordinatorAttachmentError.verificationInterrupted
        }
        guard let attachment = reducerState.fileAttachment else {
            throw DocumentSyncCoordinatorAttachmentError.verificationInterrupted
        }
        let outcome: PendingVerifiedExternalReadOutcome =
            if let change {
                .result(.changed(change))
            } else {
                .failure
            }
        try await withCheckedThrowingContinuation { continuation in
            pendingVerifiedExternalRead = PendingVerifiedExternalRead(
                identity: attachment.identity,
                targetURL: attachment.url,
                outcome: outcome,
                continuation: continuation
            )
            dispatch(.monitorSignaled(monitorToken))
            resolvePendingVerifiedExternalReadIfBlocked()
        }
    }

    private func publishCompatibility(
        from previous: DocumentSyncState,
        event: DocumentSyncEvent?
    ) {
        let next = reducerState
        if previous.source != next.source,
            sourceBuffer.revision != next.source
        {
            replaceSource(next.source.text, origin: sourceReplacementOrigin(for: event))
        }
        if format != next.format {
            format = next.format
        }
        durableState =
            next.durableBaseline?.asDurableFileState
            ?? unattachedDurableState
        let nextURL = next.attachment.managedFileURL?.standardizedFileURL
        if fileURL != nextURL {
            fileURL = nextURL
        }

        let projection = next.statusProjection
        let nextStatus = DocumentSynchronizationStatusSnapshot(
            presentedState: projection.presentedState,
            failureRequiresSaveAs: projection.failureRequiresSaveAs,
            recoveryMigrationIsPending: projection.recoveryMigrationIsPending,
            recoveryRetryAvailable: projection.recoveryRetryAvailable,
            rawRecoveryURL: projection.rawRecoveryURL,
            hasLocalRecovery: projection.hasLocalRecovery
        )
        if statusSnapshot != nextStatus {
            statusSnapshot = nextStatus
        }
        state = synchronizationState(for: next, status: nextStatus)

        if didAcceptExternalSource(event, previous: previous, next: next),
            let url = next.fileAttachment?.url
        {
            delegate?.syncCoordinator(
                self,
                acceptedExternalFileAt: url,
                hasLocalChanges: next.local.isDirty
            )
        }
    }

    private func execute(_ effect: DocumentSyncEffect) {
        switch effect {
        case .schedule(let request):
            if let manualScheduler {
                manualScheduler.schedule(request.deadline, after: request.delay)
            } else {
                scheduler.schedule(request)
            }
        case .cancelDeadline(let deadline):
            if let manualScheduler {
                manualScheduler.cancel(deadline)
            } else {
                scheduler.cancel(deadline)
            }
        case .cancelAllDeadlines:
            if let manualScheduler {
                manualScheduler.cancelAll()
            } else {
                scheduler.cancelAll()
            }
        case .prepareSave(let request):
            executeSavePreparation(request)
        case .commitSave(let request):
            executeSaveCommit(request)
        case .reconcileCommit(let request):
            effectExecutor.reconcileCommit(request) { [weak self] result in
                self?.dispatch(
                    .commitReconciliationFinished(
                        token: request.token,
                        result: result
                    )
                )
            }
        case .readExternal(let request):
            executeExternalRead(request)
        case .merge(let request):
            effectExecutor.merge(request) { [weak self] execution in
                guard let self else { return }
                switch execution {
                case .finished(let result):
                    self.dispatch(.mergeFinished(token: request.token, result: result))
                case .failed(let failure):
                    self.dispatch(.operationFailed(token: request.token, failure: failure))
                }
            }
        case .recovery(let request):
            executeRecovery(request)
        case .monitor(let request):
            executeMonitor(request)
        case .resolveClose(let resolution):
            (delegate as? DocumentSyncCoordinatorHost)?.syncCoordinator(
                self,
                resolveClose: resolution
            )
        }
    }

    private func executeSavePreparation(
        _ request: DocumentSyncSavePreparationRequest
    ) {
        guard let savePreparationHook else {
            beginSavePreparationEffect(request)
            return
        }

        Task { @MainActor [weak self] in
            await savePreparationHook()
            guard let self, !self.isTornDown else { return }
            self.beginSavePreparationEffect(request)
        }
    }

    private func beginSavePreparationEffect(
        _ request: DocumentSyncSavePreparationRequest
    ) {
        effectExecutor.prepareSave(request) { [weak self] execution in
            guard let self else { return }
            switch execution {
            case .prepared(let pendingSave):
                self.dispatch(
                    .savePrepared(
                        token: request.token,
                        pendingSave: pendingSave
                    )
                )
            case .failed(let failure):
                self.dispatch(
                    .operationFailed(token: request.token, failure: failure)
                )
            }
        }
    }

    private func executeSaveCommit(_ request: DocumentSyncSaveCommitRequest) {
        do {
            try bridge.install(request)
        } catch {
            dispatch(.operationFailed(token: request.token, failure: .localSave))
            return
        }
        if let host = delegate as? DocumentSyncCoordinatorHost {
            host.syncCoordinator(self, requestSave: request)
        } else {
            delegate?.syncCoordinator(self, requestSave: request.pendingSave)
        }
    }

    private func executeExternalRead(_ request: DocumentSyncExternalReadRequest) {
        if let pending = pendingVerifiedExternalRead,
            pending.identity == request.identity,
            pending.targetURL.standardizedFileURL
                == request.targetURL.standardizedFileURL
        {
            pendingVerifiedExternalRead = nil
            switch pending.outcome {
            case .result(let result):
                dispatch(.externalReadFinished(token: request.token, result: result))
                pending.continuation?.resume()
            case .failure:
                dispatch(.operationFailed(token: request.token, failure: .externalRead))
                pending.continuation?.resume(
                    throwing: DocumentSyncCoordinatorAttachmentError
                        .verificationUnavailable
                )
            }
            return
        }
        guard let externalReadHook else {
            beginExternalReadEffect(request)
            return
        }

        Task { @MainActor [weak self] in
            await externalReadHook(request.token.attempt)
            guard let self, !self.isTornDown else { return }
            self.beginExternalReadEffect(request)
        }
    }

    private func beginExternalReadEffect(
        _ request: DocumentSyncExternalReadRequest
    ) {
        effectExecutor.readExternal(request) { [weak self] execution in
            guard let self else { return }
            switch execution {
            case .finished(let result):
                self.dispatch(
                    .externalReadFinished(token: request.token, result: result)
                )
            case .failed(let failure):
                self.dispatch(
                    .operationFailed(token: request.token, failure: failure)
                )
            }
        }
    }

    private func executeMonitor(_ request: DocumentSyncMonitorRequest) {
        switch request.action {
        case .start:
            for monitor in monitors.values {
                monitor.cancel()
            }
            monitors.removeAll()
            guard fileMonitoringEnabled else { return }
            let token = request.token
            let monitor = DirectoryFileMonitor(
                targetURL: request.targetURL,
                onChange: {
                    Task { @MainActor [weak self] in
                        self?.dispatch(.monitorSignaled(token))
                    }
                },
                onDescriptorClosed: monitorDescriptorClosedHook,
                startupHook: monitorStartHook
            )
            Task { [weak self] in
                do {
                    try await DocumentFileAccess.perform {
                        try monitor.start()
                    }
                    guard let self,
                        !self.isTornDown,
                        self.reducerState.activeTokens[.monitor] == token
                    else {
                        monitor.cancel()
                        return
                    }
                    self.monitors[token] = monitor
                } catch {
                    guard let self,
                        !self.isTornDown,
                        self.reducerState.activeTokens[.monitor] == token
                    else {
                        return
                    }
                    self.dispatch(.operationFailed(token: token, failure: .monitor))
                }
            }
        case .stop:
            monitors.removeValue(forKey: request.token)?.cancel()
        }
    }

    /// Recovery effects execute only their immutable request. The actor owns
    /// the FIFO index and all blocking I/O, while this main-actor coordinator
    /// only echoes the original reducer token with a typed result.
    private func executeRecovery(_ request: DocumentSyncRecoveryRequest) {
        let recoveryStore = recoveryStore
        Task { [weak self] in
            let result: DocumentSyncRecoveryResult
            do {
                switch request {
                case .load(let load):
                    if load.retriesStartup {
                        _ = try await recoveryStore.retryStartup()
                    }
                    let receipt = try await recoveryStore.load(scope: load.scope)
                    result = .loaded(
                        DocumentSyncRecoveryLoadResult(
                            scope: receipt.scope,
                            generation: receipt.generation,
                            records: self?.recoveryRecords(from: receipt.records)
                                ?? .empty
                        )
                    )
                case .reconcile(let reconciliation):
                    let receipt = try await recoveryStore.reconcile(
                        reconciliation.intent
                    )
                    result = .reconciled(
                        DocumentSyncRecoveryReconciliationResult(
                            identity: receipt.identity,
                            generation: receipt.generation,
                            records: self?.recoveryRecords(from: receipt.records)
                                ?? .empty,
                            acknowledgedRecoveryArtifact:
                                receipt.acknowledgedRecoveryArtifact
                        )
                    )
                case .persist(let persistence):
                    switch persistence.payload {
                    case .snapshot(let snapshot):
                        let receipt = try await recoveryStore.add(
                            id: persistence.entryID,
                            snapshot: snapshot,
                            for: persistence.identity,
                            expectedRecords: persistence.expectedRecords,
                            expectedGeneration:
                                persistence.expectedStoreGeneration
                        )
                        result = .persisted(
                            self?.mutationResult(from: receipt)
                                ?? DocumentSyncRecoveryMutationResult(
                                    previousGeneration: 0,
                                    generation: 0,
                                    records: .empty
                                )
                        )
                    case .raw(let payload):
                        let receipt = try await recoveryStore.persistRawData(
                            payload.data,
                            for: persistence.identity,
                            id: persistence.entryID,
                            expectedRecords: persistence.expectedRecords,
                            expectedGeneration:
                                persistence.expectedStoreGeneration,
                            recoveryArtifact: payload.recoveryArtifact
                        )
                        let decodeOutcome = await Self.decodeRawRecovery(
                            payload,
                            identity: persistence.identity
                        )
                        let mutation =
                            self?.mutationResult(from: receipt.mutation)
                            ?? DocumentSyncRecoveryMutationResult(
                                previousGeneration: 0,
                                generation: 0,
                                records: .empty
                            )
                        result = .rawPersisted(
                            DocumentSyncRawRecoveryPersistResult(
                                mutation: mutation,
                                durablyPersistedRawEntryID: receipt.entry.id,
                                acknowledgedRecoveryArtifact:
                                    receipt.acknowledgedRecoveryArtifact,
                                decodeOutcome: decodeOutcome
                            )
                        )
                    }
                case .migrate(let migration):
                    let receipt = try await recoveryStore.moveEntries(
                        from: migration.sourceIdentity,
                        to: migration.destinationIdentity,
                        expectedRecords: migration.records,
                        expectedGeneration: migration.expectedStoreGeneration
                    )
                    result = .migrated(
                        self?.mutationResult(from: receipt)
                            ?? DocumentSyncRecoveryMutationResult(
                                previousGeneration: 0,
                                generation: 0,
                                records: .empty
                            )
                    )
                case .discard(let discard):
                    let receipt = try await recoveryStore.discard(
                        target: discard.target,
                        for: discard.identity,
                        expectedRecords: discard.expectedRecords,
                        expectedGeneration: discard.expectedStoreGeneration
                    )
                    result = .discarded(
                        self?.mutationResult(from: receipt)
                            ?? DocumentSyncRecoveryMutationResult(
                                previousGeneration: 0,
                                generation: 0,
                                records: .empty
                            )
                    )
                }
            } catch {
                result = .failed(.recovery)
            }
            guard !Task.isCancelled else { return }
            self?.dispatch(.recoveryFinished(token: request.token, result: result))
            if case .failed = result {
                self?.resolvePendingVerifiedExternalRead(
                    throwing: .recoveryBlocksVerification
                )
            } else {
                self?.resolvePendingVerifiedExternalReadIfBlocked()
            }
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

    private func resolveFlushWaitersIfPossible() {
        guard !flushWaiters.isEmpty else { return }
        if isFullySynchronized {
            resolveFlushWaiters(succeeded: true)
        } else if reducerState.issue != nil
            || reducerState.lifecycle == .closed
        {
            resolveFlushWaiters(succeeded: false)
        }
    }

    private func resolveFlushWaiters(succeeded: Bool) {
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters {
            waiter(succeeded)
        }
    }

    private func resolveRecoveryStartupWaitersIfPossible() {
        guard case .loading = reducerState.recoveryAccess else {
            let waiters = recoveryStartupWaiters
            recoveryStartupWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: reducerState.recoveryAccess)
            }
            return
        }
    }

    private func resolveRecoveryOperationWaiters(for token: SyncEffectToken) {
        let waiters = recoveryOperationWaiters.removeValue(forKey: token) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resolveCommitReconciliationWaiters(
        for token: SyncEffectToken
    ) {
        let waiters =
            commitReconciliationWaiters.removeValue(forKey: token)
            ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private var isFullySynchronized: Bool {
        guard case .clean(let revision) = reducerState.local,
            case .ready = reducerState.recoveryAccess,
            case .clear = reducerState.recovery,
            reducerState.recoveryMutationBarrier == nil,
            reducerState.recoveryCleanup == nil,
            revision == reducerState.source,
            reducerState.durableBaseline?.sourceRevision == revision,
            reducerState.durableBaseline?.snapshot == reducerState.snapshot,
            reducerState.external == .idle,
            reducerState.mergeAttempt == nil,
            reducerState.issue == nil
        else {
            return false
        }
        return true
    }

    private func tearDown() {
        isTornDown = true
        pendingInitialPresenterSignal = nil
        resolvePendingVerifiedExternalRead(throwing: .verificationInterrupted)
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentRequestID = nil
        let completions = attachmentCompletions.values
        attachmentCompletions.removeAll()
        for completion in completions {
            completion(false)
        }
        scheduler.cancelAll()
        manualScheduler?.cancelAll()
        for monitor in monitors.values {
            monitor.cancel()
        }
        monitors.removeAll()
        if let sourceObservation {
            sourceBuffer.removeObserver(sourceObservation)
        }
        sourceObservation = nil
        resolveFlushWaiters(succeeded: false)
        let recoveryWaiters = recoveryStartupWaiters
        recoveryStartupWaiters.removeAll()
        for waiter in recoveryWaiters {
            waiter.resume(returning: .failed(.recovery))
        }
        let pendingRecoveryOperationWaiters = recoveryOperationWaiters.values
        self.recoveryOperationWaiters.removeAll()
        for waiters in pendingRecoveryOperationWaiters {
            for waiter in waiters {
                waiter.resume()
            }
        }
        let pendingCommitReconciliationWaiters =
            commitReconciliationWaiters.values
        commitReconciliationWaiters.removeAll()
        for waiters in pendingCommitReconciliationWaiters {
            for waiter in waiters {
                waiter.resume()
            }
        }
        resolveInitialAttachmentWaiters(didAttach: false)
    }

    private func replaceSource(_ text: String, origin: DocumentChangeOrigin) {
        isApplyingReducerSource = true
        sourceBuffer.replace(with: text, origin: origin)
        isApplyingReducerSource = false
    }

    private nonisolated static func inspectAttachment(
        at targetURL: URL,
        knownData: Data?,
        sourceRevision: SourceRevision,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64,
        requiresFreshTargetObservation: Bool = false
    ) -> CoordinatorAttachmentInspection {
        let target = attachmentTarget(
            at: targetURL,
            sourceRevision: sourceRevision
        )
        do {
            if requiresFreshTargetObservation, let knownData {
                return .verified(
                    try verifiedInitialAttachment(
                        target: target,
                        knownData: knownData,
                        sourceFormat: sourceFormat,
                        baselineSourceRevision: baselineSourceRevision,
                        commitGeneration: commitGeneration
                    )
                )
            }
            let data =
                try knownData
                ?? Data(
                    contentsOf: targetURL,
                    options: [.mappedIfSafe]
                )
            return .verified(
                try verifiedAttachment(
                    target: target,
                    data: data,
                    sourceFormat: sourceFormat,
                    baselineSourceRevision: baselineSourceRevision,
                    commitGeneration: commitGeneration
                )
            )
        } catch {
            return .unavailable(target)
        }
    }

    private nonisolated static func verifiedInitialAttachment(
        target: UnverifiedCoordinatorAttachment,
        knownData: Data,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> VerifiedCoordinatorAttachment {
        let currentData = try Data(
            contentsOf: target.targetURL,
            options: [.mappedIfSafe]
        )
        let currentFingerprint = try SafeFileCommitter.fingerprint(
            for: target.targetURL,
            data: currentData
        )
        if currentData == knownData {
            return try verifiedAttachment(
                target: target,
                data: currentData,
                fingerprint: currentFingerprint,
                sourceFormat: sourceFormat,
                baselineSourceRevision: baselineSourceRevision,
                commitGeneration: commitGeneration
            )
        }

        // The captured bytes predate this inspection, so they cannot safely
        // inherit the target's current resource identifier. Keep their
        // intrinsic fingerprint as the provisional baseline and carry the
        // current target as a separate immutable external observation.
        let expected = try verifiedAttachment(
            target: target,
            data: knownData,
            fingerprint: FileFingerprint.make(data: knownData),
            sourceFormat: sourceFormat,
            baselineSourceRevision: baselineSourceRevision,
            commitGeneration: commitGeneration
        )
        let currentChange = try? TextFileCodec.decodeExternalChange(
            data: currentData,
            targetURL: target.targetURL,
            identity: target.identity,
            fingerprint: currentFingerprint
        )
        return VerifiedCoordinatorAttachment(
            targetURL: target.targetURL,
            identity: target.identity,
            sourceRevision: target.sourceRevision,
            durableBaseline: expected.durableBaseline,
            dataMatchesExpectedBytes: false,
            verifiedExternalChange: currentChange
        )
    }

    private nonisolated static func inspectSaveAsAttachment(
        at targetURL: URL,
        expectedData: Data,
        expectedSnapshot: DocumentSnapshot,
        sourceRevision: SourceRevision,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> CoordinatorAttachmentInspection {
        guard try TextFileCodec.decode(expectedData) == expectedSnapshot else {
            throw DocumentSyncCoordinatorAttachmentError.invalidSaveAsEvidence
        }
        let target = attachmentTarget(
            at: targetURL,
            sourceRevision: sourceRevision
        )
        do {
            // Save As owns the immutable bytes passed by NSDocument. Use those
            // bytes for the initial durable baseline, then separately verify
            // the current target bytes before this async API returns.
            let expected = try verifiedAttachment(
                target: target,
                data: expectedData,
                sourceFormat: sourceFormat,
                baselineSourceRevision: baselineSourceRevision,
                commitGeneration: commitGeneration
            )
            let currentData = try Data(
                contentsOf: targetURL,
                options: [.mappedIfSafe]
            )
            let currentFingerprint = try SafeFileCommitter.fingerprint(
                for: targetURL,
                data: currentData
            )
            let dataMatchesExpectedBytes = currentData == expectedData
            let verifiedExternalChange =
                dataMatchesExpectedBytes
                ? nil
                : try? TextFileCodec.decodeExternalChange(
                    data: currentData,
                    targetURL: targetURL,
                    identity: target.identity,
                    fingerprint: currentFingerprint
                )
            return .verified(
                VerifiedCoordinatorAttachment(
                    targetURL: target.targetURL,
                    identity: target.identity,
                    sourceRevision: target.sourceRevision,
                    durableBaseline: expected.durableBaseline,
                    dataMatchesExpectedBytes: dataMatchesExpectedBytes,
                    verifiedExternalChange: verifiedExternalChange
                )
            )
        } catch {
            return .unavailable(target)
        }
    }

    private nonisolated static func attachmentTarget(
        at targetURL: URL,
        sourceRevision: SourceRevision
    ) -> UnverifiedCoordinatorAttachment {
        UnverifiedCoordinatorAttachment(
            targetURL: targetURL,
            identity: DocumentIdentity.make(url: targetURL),
            sourceRevision: sourceRevision
        )
    }

    private nonisolated static func verifiedAttachment(
        target: UnverifiedCoordinatorAttachment,
        data: Data,
        fingerprint: FileFingerprint? = nil,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> VerifiedCoordinatorAttachment {
        let verifiedFingerprint: FileFingerprint
        if let fingerprint {
            verifiedFingerprint = fingerprint
        } else {
            verifiedFingerprint = try SafeFileCommitter.fingerprint(
                for: target.targetURL,
                data: data
            )
        }
        let snapshot = try? TextFileCodec.decode(data)
        let stampedSourceRevision: SourceRevision?
        if let snapshot {
            stampedSourceRevision =
                snapshot
                    == DocumentSnapshot(
                        text: baselineSourceRevision.text,
                        format: sourceFormat
                    )
                ? baselineSourceRevision
                : SourceRevision(
                    number: baselineSourceRevision.number,
                    text: snapshot.text
                )
        } else {
            stampedSourceRevision = nil
        }
        let durableBaseline = stampedSourceRevision.flatMap { revision in
            try? TextFileCodec.durableBaseline(
                data: data,
                targetURL: target.targetURL,
                fingerprint: verifiedFingerprint,
                documentIdentity: target.identity,
                sourceRevision: revision,
                commitGeneration: commitGeneration
            )
        }
        return VerifiedCoordinatorAttachment(
            targetURL: target.targetURL,
            identity: target.identity,
            sourceRevision: target.sourceRevision,
            durableBaseline: durableBaseline,
            dataMatchesExpectedBytes: true,
            verifiedExternalChange: nil
        )
    }

    private func sourceReplacementOrigin(
        for event: DocumentSyncEvent?
    ) -> DocumentChangeOrigin {
        switch event {
        case .restoreLocalRecovery:
            .recovery
        case .mergeFinished:
            .merge
        case .externalReadFinished:
            .externalReload
        default:
            .externalReload
        }
    }

    private func didAcceptExternalSource(
        _ event: DocumentSyncEvent?,
        previous: DocumentSyncState,
        next: DocumentSyncState
    ) -> Bool {
        guard previous.source != next.source else { return false }
        return switch event {
        case .externalReadFinished, .mergeFinished:
            true
        default:
            false
        }
    }

    private func synchronizationState(
        for state: DocumentSyncState,
        status: DocumentSynchronizationStatusSnapshot
    ) -> SynchronizationState {
        if let presented = status.presentedState {
            return presented
        }
        if state.mergeAttempt != nil {
            return .merging
        }
        switch state.external {
        case .reading, .debouncing:
            return .checkingExternalChange
        case .idle:
            break
        }
        switch state.local {
        case .preparing, .writing:
            return .writing
        case .dirty(let dirty) where dirty.scheduledToken != nil:
            return .waitingToWrite
        case .clean, .dirty:
            return .idle
        }
    }
}

private enum AttachmentEvent {
    case attach
    case fileMoved
    case saveAsAttached
}
