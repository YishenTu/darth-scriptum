import Combine
import Foundation

struct DocumentSynchronizationStatusSnapshot: Equatable {
    let presentedState: SynchronizationState?
    let failureRequiresSaveAs: Bool
    let recoveryMigrationIsPending: Bool
    let rawRecoveryURL: URL?
    let hasLocalRecovery: Bool

    static let empty = DocumentSynchronizationStatusSnapshot(
        presentedState: nil,
        failureRequiresSaveAs: false,
        recoveryMigrationIsPending: false,
        rawRecoveryURL: nil,
        hasLocalRecovery: false
    )
}

private struct VerifiedCoordinatorAttachment: Sendable {
    let targetURL: URL
    let identity: DocumentIdentity
    let data: Data
    let sourceRevision: SourceRevision
}

private enum DocumentSyncCoordinatorAttachmentError: Error {
    case invalidSaveAsEvidence
}

@MainActor
final class DocumentSyncCoordinator: ObservableObject {
    static let localWriteDelay = DocumentSyncReducer.localSaveDelay

    private(set) var state: SynchronizationState = .idle
    @Published private(set) var statusSnapshot:
        DocumentSynchronizationStatusSnapshot = .empty
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
    private lazy var scheduler = SyncScheduler { [weak self] deadline in
        self?.dispatch(.deadlineFired(deadline))
    }

    private var sourceObservation: UUID?
    private var attachmentTask: Task<Void, Never>?
    private var attachmentRequestID: UUID?
    private var attachmentCompletions: [UUID: (@MainActor (Bool) -> Void)] = [:]
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
        effectExecutor: DocumentSyncCoordinatorEffectExecuting =
            DocumentSyncDefaultEffectExecutor(),
        manualScheduler: ManualSyncScheduler? = nil
    ) {
        sourceBuffer = MarkdownSourceBuffer(snapshot: snapshot)
        format = snapshot.format
        durableState = initialDurableState
        unattachedDurableState = initialDurableState
        self.bridge = bridge
        self.recoveryStore = recoveryStore
        self.fileMonitoringEnabled = fileMonitoringEnabled
        self.effectExecutor = effectExecutor
        self.manualScheduler = manualScheduler
        self.savePreparationHook = savePreparationHook
        self.externalReadHook = externalReadHook
        reducerState = DocumentSyncState(
            source: sourceBuffer.revision,
            format: snapshot.format,
            // The legacy store cannot mint frozen recovery receipts. Normal
            // synchronization therefore starts ready, while every recovery
            // mutation remains fail-closed until P1 supplies the actor API.
            recoveryAccess: .ready(generation: 0)
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
            resolveFlushWaitersIfPossible()
        }
    }

    func loadInitial(_ snapshot: DocumentSnapshot, data: Data, from url: URL?) {
        cancelPendingAttachmentRequest()
        replaceSource(snapshot.text, origin: .initialLoad)
        guard let url else {
            reducerState = DocumentSyncState(
                lifetime: reducerState.lifetime,
                source: sourceBuffer.revision,
                format: snapshot.format,
                recoveryAccess: .ready(generation: 0),
                nextAttempt: reducerState.nextAttempt,
                nextCommitGeneration: reducerState.nextCommitGeneration
            )
            unattachedDurableState = nil
            publishCompatibility(from: reducerState, event: nil)
            dispatch(.started)
            return
        }

        installInitialAttachment(
            targetURL: url.standardizedFileURL,
            data: data,
            sourceRevision: sourceBuffer.revision,
            initialFormat: snapshot.format
        )
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
        if let knownData {
            completeAttachment(
                requestID: requestID,
                event: .attach,
                targetURL: targetURL,
                data: knownData,
                sourceRevision: capturedSource
            )
            return
        }

        attachmentTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try Self.readAttachment(
                    at: targetURL,
                    sourceRevision: capturedSource
                )
            }.result
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let attachment):
                self.completeAttachment(
                    requestID: requestID,
                    event: .attach,
                    targetURL: attachment.targetURL,
                    data: attachment.data,
                    sourceRevision: attachment.sourceRevision
                )
            case .failure:
                self.completeAttachment(
                    requestID: requestID,
                    event: .attach,
                    targetURL: targetURL,
                    data: nil,
                    sourceRevision: capturedSource
                )
            }
        }
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
        guard try TextFileCodec.decode(expectedData) == expectedSnapshot else {
            throw DocumentSyncCoordinatorAttachmentError.invalidSaveAsEvidence
        }
        let capturedSource = reducerState.source
        let verification = try await Task.detached(priority: .utility) {
            try Self.readAttachment(
                at: targetURL,
                sourceRevision: capturedSource
            )
        }.value
        guard !isTornDown else { return }

        let requestID = beginAttachmentRequest(completion: nil)
        completeAttachment(
            requestID: requestID,
            event: .saveAsAttached,
            targetURL: targetURL,
            data: expectedData,
            sourceRevision: capturedSource,
            baselineSourceRevision: expectedSourceRevision
        )
        guard verification.data != expectedData else { return }

        applyVerifiedSaveAsReplacement(
            data: verification.data,
            targetURL: targetURL,
            identity: verification.identity
        )
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
        if let knownData {
            completeAttachment(
                requestID: requestID,
                event: .fileMoved,
                targetURL: targetURL,
                data: knownData,
                sourceRevision: capturedSource
            )
            return
        }

        attachmentTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try Self.readAttachment(
                    at: targetURL,
                    sourceRevision: capturedSource
                )
            }.result
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let attachment):
                self.completeAttachment(
                    requestID: requestID,
                    event: .fileMoved,
                    targetURL: attachment.targetURL,
                    data: attachment.data,
                    sourceRevision: attachment.sourceRevision
                )
            case .failure:
                self.completeAttachment(
                    requestID: requestID,
                    event: .fileMoved,
                    targetURL: targetURL,
                    data: nil,
                    sourceRevision: capturedSource
                )
            }
        }
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
                case .invalidPreparedPayload:
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
              request.pendingSave.generation == generation else {
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
                || attempt.resolution == .deferToNativeUntitledReview {
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
        if reducerState.fileAttachment == nil,
           let hostURL = delegate?.synchronizationFileURL {
            attach(to: hostURL)
        }
        _ = origin
    }

    private func installInitialAttachment(
        targetURL: URL,
        data: Data?,
        sourceRevision: SourceRevision,
        baselineSourceRevision: SourceRevision? = nil,
        initialFormat: TextFileFormat? = nil
    ) {
        let previous = reducerState
        let source = sourceRevision
        let baselineSource = baselineSourceRevision ?? source
        let identity = DocumentIdentity.make(url: targetURL)
        let baseline = data.flatMap {
            makeBaseline(
                data: $0,
                targetURL: targetURL,
                identity: identity,
                sourceRevision: baselineSource
            )
        }
        let format = initialFormat ?? baseline?.snapshot.format ?? previous.format
        let recoveryIssue = legacyRecoveryIssue(for: identity)
        let requiresExternalVerification = baseline?.snapshot
            != DocumentSnapshot(text: source.text, format: format)
        reducerState = DocumentSyncState(
            lifetime: previous.lifetime,
            source: source,
            format: format,
            attachment: .file(
                DocumentSyncFileAttachment(
                    identity: identity,
                    url: targetURL,
                    epoch: previous.attachmentEpoch + 1
                )
            ),
            attachmentEpoch: previous.attachmentEpoch + 1,
            durableBaseline: baseline,
            recoveryAccess: recoveryIssue == nil
                ? .ready(
                    generation: recoveryStore.typedMutationGeneration(
                        for: identity
                    )
                )
                : .failed(.recovery),
            issue: recoveryIssue,
            nextAttempt: previous.nextAttempt,
            nextCommitGeneration: previous.nextCommitGeneration,
            externalSignalPending: requiresExternalVerification
        )
        unattachedDurableState = nil
        publishCompatibility(from: previous, event: nil)
        dispatch(.started)
        guard recoveryIssue == nil,
              requiresExternalVerification,
              let monitorToken = reducerState.activeTokens[.monitor] else {
            return
        }
        dispatch(.monitorSignaled(monitorToken))
    }

    private func beginAttachmentRequest(
        completion: (@MainActor (Bool) -> Void)?
    ) -> UUID {
        cancelPendingAttachmentRequest()
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
        }
        attachmentRequestID = nil
    }

    private func completeAttachment(
        requestID: UUID,
        event: AttachmentEvent,
        targetURL: URL,
        data: Data?,
        sourceRevision: SourceRevision,
        baselineSourceRevision: SourceRevision? = nil
    ) {
        guard !isTornDown, attachmentRequestID == requestID else { return }
        attachmentTask = nil
        attachmentRequestID = nil
        let identity = DocumentIdentity.make(url: targetURL)
        let baseline = data.flatMap {
            makeBaseline(
                data: $0,
                targetURL: targetURL,
                identity: identity,
                sourceRevision: baselineSourceRevision ?? reducerState.source
            )
        }

        if reducerState.fileAttachment == nil,
           reducerState.recoveryRecords == nil,
           event != .fileMoved {
            // Initial document attachment is construction, not a relocation.
            // It keeps ordinary editing usable while P1 replaces the legacy
            // recovery store with exact typed receipts.
            installInitialAttachment(
                targetURL: targetURL,
                data: data,
                sourceRevision: sourceRevision,
                baselineSourceRevision: baselineSourceRevision
            )
            finishAttachmentRequest(requestID, didAttach: data != nil)
            return
        }

        unattachedDurableState = nil
        switch event {
        case .attach:
            dispatch(.attach(identity: identity, url: targetURL, durableBaseline: baseline))
        case .fileMoved:
            dispatch(.fileMoved(identity: identity, url: targetURL, durableBaseline: baseline))
        case .saveAsAttached:
            dispatch(.saveAsAttached(identity: identity, url: targetURL, durableBaseline: baseline))
        }
        finishAttachmentRequest(requestID, didAttach: data != nil)
    }

    private func finishAttachmentRequest(
        _ requestID: UUID,
        didAttach: Bool
    ) {
        attachmentCompletions.removeValue(forKey: requestID)?(didAttach)
    }

    private func legacyRecoveryIssue(
        for identity: DocumentIdentity
    ) -> DocumentSyncIssue? {
        guard recoveryStore.latest(for: identity) != nil
            || !recoveryStore.rawRecoveryEntries(for: identity).isEmpty else {
            return nil
        }

        // We deliberately retain no partial `DocumentSyncRecoveryRecords`
        // here. The legacy store exposes only one decoded entry and no
        // generation, so presenting that subset as a complete mutable record
        // set could authorize an unsafe restore, discard, or migration.
        return DocumentSyncIssue(
            failure: .recovery,
            retryable: false,
            requiresSaveAs: false,
            rawRecoveryURL: nil
        )
    }

    /// Save As has already captured the target bytes off the main actor. If
    /// those bytes changed before verification completed, feed the immutable
    /// observation straight back through the reducer so this async API does
    /// not return with a stale baseline. The concurrently started executor
    /// completion is harmless: its token is stale after this result wins.
    private func applyVerifiedSaveAsReplacement(
        data: Data,
        targetURL: URL,
        identity: DocumentIdentity
    ) {
        guard let monitorToken = reducerState.activeTokens[.monitor] else {
            return
        }
        dispatch(.monitorSignaled(monitorToken))
        guard case .debouncing(let ticket) = reducerState.external else {
            return
        }
        dispatch(
            .deadlineFired(
                SyncDeadline(kind: .externalRead, token: ticket.token)
            )
        )
        guard case .reading(let read) = reducerState.external,
              read.token == ticket.token else {
            return
        }

        do {
            let fingerprint = try SafeFileCommitter.fingerprint(
                for: targetURL,
                data: data
            )
            let change = try TextFileCodec.decodeExternalChange(
                data: data,
                targetURL: targetURL,
                identity: identity,
                fingerprint: fingerprint
            )
            dispatch(
                .externalReadFinished(token: read.token, result: .changed(change))
            )
        } catch {
            dispatch(.operationFailed(token: read.token, failure: .externalRead))
        }
    }

    private func publishCompatibility(
        from previous: DocumentSyncState,
        event: DocumentSyncEvent?
    ) {
        let next = reducerState
        if previous.source != next.source,
           sourceBuffer.revision != next.source {
            replaceSource(next.source.text, origin: sourceReplacementOrigin(for: event))
        }
        if format != next.format {
            format = next.format
        }
        durableState = next.durableBaseline?.asDurableFileState
            ?? unattachedDurableState
        let nextURL = next.fileAttachment?.url.standardizedFileURL
        if fileURL != nextURL {
            fileURL = nextURL
        }

        let projection = next.statusProjection
        let nextStatus = DocumentSynchronizationStatusSnapshot(
            presentedState: projection.presentedState,
            failureRequiresSaveAs: projection.failureRequiresSaveAs,
            recoveryMigrationIsPending: projection.recoveryMigrationIsPending,
            rawRecoveryURL: projection.rawRecoveryURL,
            hasLocalRecovery: projection.hasLocalRecovery
        )
        if statusSnapshot != nextStatus {
            statusSnapshot = nextStatus
        }
        state = synchronizationState(for: next, status: nextStatus)

        if didAcceptExternalSource(event, previous: previous, next: next),
           let url = next.fileAttachment?.url {
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
            executeLegacyRecovery(request)
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
            monitors.values.forEach { $0.cancel() }
            monitors.removeAll()
            guard fileMonitoringEnabled else { return }
            let token = request.token
            let monitor = DirectoryFileMonitor(targetURL: request.targetURL) {
                Task { @MainActor [weak self] in
                    self?.dispatch(.monitorSignaled(token))
                }
            }
            do {
                try monitor.start()
                monitors[token] = monitor
            } catch {
                dispatch(.operationFailed(token: token, failure: .monitor))
            }
        case .stop:
            monitors.removeValue(forKey: request.token)?.cancel()
        }
    }

    private func executeLegacyRecovery(_ request: DocumentSyncRecoveryRequest) {
        if case .migrate(let migration) = request,
           migration.records.isEmpty,
           legacyRecoveryIssue(for: migration.sourceIdentity) == nil,
           legacyRecoveryIssue(for: migration.destinationIdentity) == nil {
            // Recordless migration changes no recovery file, but it still
            // advances the reducer's receipt generation. Keep that generation
            // in the store so a later fresh conflict cannot be rejected as a
            // fabricated coordinator completion.
            do {
                let receipt = try recoveryStore.advanceEmptyRecoveryMigration(
                    from: migration.sourceIdentity,
                    to: migration.destinationIdentity,
                    expectedGeneration: migration.expectedStoreGeneration
                )
                dispatch(
                    .recoveryFinished(
                        token: migration.token,
                        result: .migrated(
                            DocumentSyncRecoveryMutationResult(
                                previousGeneration: receipt.previousGeneration,
                                generation: receipt.generation,
                                records: recoveryRecords(from: receipt)
                            )
                        )
                    )
                )
            } catch {
                dispatch(
                    .operationFailed(token: migration.token, failure: .recovery)
                )
            }
            return
        }

        switch request {
        case .persist(let persistence):
            executeLegacyConflictPersistence(persistence)
        case .discard(let discard):
            executeLegacyDecodedRecoveryDiscard(discard)
        case .load, .reconcile, .migrate:
            // P1 owns complete record loading, reconciliation, and
            // cross-identity FIFO migration. Until then, unknown legacy
            // evidence remains paused rather than being reconstructed from a
            // partial store view.
            dispatch(.operationFailed(token: request.token, failure: .recovery))
        }
    }

    private func executeLegacyConflictPersistence(
        _ request: DocumentSyncRecoveryPersistRequest
    ) {
        guard request.purpose == .persistConflict,
              request.expectedRecords.isEmpty,
              request.displacedPreimageContinuation == nil,
              case .snapshot(let snapshot) = request.payload else {
            dispatch(.operationFailed(token: request.token, failure: .recovery))
            return
        }

        do {
            let receipt = try recoveryStore.persistFreshDecodedConflict(
                id: request.entryID,
                snapshot: snapshot,
                for: request.identity,
                expectedGeneration: request.expectedStoreGeneration
            )
            dispatch(
                .recoveryFinished(
                    token: request.token,
                    result: .persisted(
                        DocumentSyncRecoveryMutationResult(
                            previousGeneration: receipt.previousGeneration,
                            generation: receipt.generation,
                            records: recoveryRecords(from: receipt)
                        )
                    )
                )
            )
        } catch {
            dispatch(.operationFailed(token: request.token, failure: .recovery))
        }
    }

    private func executeLegacyDecodedRecoveryDiscard(
        _ request: DocumentSyncRecoveryDiscardRequest
    ) {
        guard case .decoded(let entry) = request.target,
              entry.documentIdentity == request.identity else {
            dispatch(.operationFailed(token: request.token, failure: .recovery))
            return
        }

        do {
            let receipt = try recoveryStore.discardExactDecodedConflict(
                entry,
                for: request.identity,
                expectedGeneration: request.expectedStoreGeneration
            )
            dispatch(
                .recoveryFinished(
                    token: request.token,
                    result: .discarded(
                        DocumentSyncRecoveryMutationResult(
                            previousGeneration: receipt.previousGeneration,
                            generation: receipt.generation,
                            records: recoveryRecords(from: receipt)
                        )
                    )
                )
            )
        } catch {
            dispatch(.operationFailed(token: request.token, failure: .recovery))
        }
    }

    private func recoveryRecords(
        from receipt: SessionRecoveryStoreMutationReceipt
    ) -> DocumentSyncRecoveryRecords {
        DocumentSyncRecoveryRecords(
            decoded: receipt.decodedEntries,
            raw: receipt.rawEntries.map {
                DocumentSyncRawRecoveryReference(entry: $0)
            }
        )
    }

    private func resolveFlushWaitersIfPossible() {
        guard !flushWaiters.isEmpty else { return }
        if isFullySynchronized {
            resolveFlushWaiters(succeeded: true)
        } else if reducerState.issue != nil
                    || reducerState.lifecycle == .closed {
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

    private var isFullySynchronized: Bool {
        guard case .clean(let revision) = reducerState.local,
              revision == reducerState.source,
              reducerState.durableBaseline?.sourceRevision == revision,
              reducerState.durableBaseline?.snapshot == reducerState.snapshot,
              reducerState.external == .idle,
              reducerState.mergeAttempt == nil,
              reducerState.issue == nil else {
            return false
        }
        return true
    }

    private func tearDown() {
        isTornDown = true
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
    }

    private func replaceSource(_ text: String, origin: DocumentChangeOrigin) {
        isApplyingReducerSource = true
        sourceBuffer.replace(with: text, origin: origin)
        isApplyingReducerSource = false
    }

    private func makeBaseline(
        data: Data,
        targetURL: URL,
        identity: DocumentIdentity,
        sourceRevision: SourceRevision
    ) -> DocumentSyncDurableBaseline? {
        guard let snapshot = try? TextFileCodec.decode(data) else {
            return nil
        }
        guard let fingerprint = try? SafeFileCommitter.fingerprint(
            for: targetURL,
            data: data
        ) else {
            return nil
        }
        let baselineSourceRevision: SourceRevision
        if snapshot == DocumentSnapshot(
            text: sourceRevision.text,
            format: reducerState.format
        ) {
            baselineSourceRevision = sourceRevision
        } else {
            // A baseline must never claim a newer local source revision was
            // persisted simply because it was current when the file read
            // completed. Keep the same revision number only as an ordering
            // anchor; the differing text makes the state unambiguously dirty.
            baselineSourceRevision = SourceRevision(
                number: sourceRevision.number,
                text: snapshot.text
            )
        }
        return try? TextFileCodec.durableBaseline(
            data: data,
            targetURL: targetURL,
            fingerprint: fingerprint,
            documentIdentity: identity,
            sourceRevision: baselineSourceRevision,
            commitGeneration: reducerState.durableBaseline?.commitGeneration ?? 0
        )
    }

    private nonisolated static func readAttachment(
        at targetURL: URL,
        sourceRevision: SourceRevision
    ) throws -> VerifiedCoordinatorAttachment {
        let data = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
        return VerifiedCoordinatorAttachment(
            targetURL: targetURL,
            identity: DocumentIdentity.make(url: targetURL),
            data: data,
            sourceRevision: sourceRevision
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
