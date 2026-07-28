import Combine
import Foundation

private enum ExternalReconciliation: Sendable {
    case unchanged(
        fingerprint: FileFingerprint,
        documentIdentity: DocumentIdentity
    )
    case changed(
        fingerprint: FileFingerprint,
        documentIdentity: DocumentIdentity,
        snapshot: DocumentSnapshot,
        mergeResult: ThreeWayMergeResult?
    )
}

private struct PendingRecoveryMigration: Equatable {
    let source: DocumentIdentity
    let destination: DocumentIdentity
}

private enum FailedSynchronizationOperation {
    case localWrite
    case externalRead
    case monitoring
    case destinationRequiresSaveAs
}

@MainActor
protocol DocumentSyncCoordinatorDelegate: AnyObject {
    var synchronizationFileURL: URL? { get }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave token: PendingSaveToken
    )

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    )
}

@MainActor
final class DocumentSyncCoordinator: ObservableObject {
    static let localWriteDelay: Duration = .milliseconds(100)
    static let externalEventDelay: Duration = .milliseconds(75)

    @Published private(set) var state: SynchronizationState = .idle
    @Published private(set) var format: TextFileFormat
    @Published private(set) var durableState: DurableFileState?
    @Published private(set) var fileURL: URL?

    let sourceBuffer: MarkdownSourceBuffer
    let bridge: SaveTransactionBridge
    weak var delegate: DocumentSyncCoordinatorDelegate?

    private let merger = ThreeWayTextMerger()
    private let recoveryStore: SessionRecoveryStore
    private let savePreparationHook: (@MainActor () async -> Void)?
    private let externalReadHook: (@MainActor (UInt64) async -> Void)?
    private var documentIdentity: DocumentIdentity?
    private var nextGeneration: UInt64 = 1
    private var nextPreparationGeneration: UInt64 = 1
    private var activePreparationGeneration: UInt64?
    private var nextExternalReadGeneration: UInt64 = 1
    private var activeExternalReadGeneration: UInt64?
    private var sourceObservation: UUID?
    private var localWriteTask: Task<Void, Never>?
    private var localPreparationTask: Task<Void, Never>?
    private var externalReadTask: Task<Void, Never>?
    private var externalReadPending = false
    private var monitor: DirectoryFileMonitor?
    private var saveInFlight: PendingSaveToken?
    private var externalCheckPending = false
    private var hasRecoverableLocalRevision = false
    private var synchronizationPauseIsLatched = false
    private var pendingRecoveryMigration: PendingRecoveryMigration?
    private var pendingRecoveryRemoval: RecoveryEntry?
    private var pendingRecoveryMinimumRevision: UInt64?
    private var rawRecoveryRemovalIdentity: DocumentIdentity?
    private var isClosed = false
    private var stateAfterNextSuccessfulSave: SynchronizationState?
    private var failedOperation: FailedSynchronizationOperation?
    private var saveAsRequiredFailureMessage: String?
    private var monitorFailureMessage: String?
    private var flushWaiters: [(@MainActor (Bool) -> Void)] = []

    init(
        snapshot: DocumentSnapshot,
        initialDurableState: DurableFileState? = nil,
        bridge: SaveTransactionBridge = SaveTransactionBridge(),
        recoveryStore: SessionRecoveryStore = .shared,
        savePreparationHook: (@MainActor () async -> Void)? = nil,
        externalReadHook: (@MainActor (UInt64) async -> Void)? = nil
    ) {
        sourceBuffer = MarkdownSourceBuffer(snapshot: snapshot)
        format = snapshot.format
        durableState = initialDurableState
        self.bridge = bridge
        self.recoveryStore = recoveryStore
        self.savePreparationHook = savePreparationHook
        self.externalReadHook = externalReadHook
        sourceObservation = sourceBuffer.observe { [weak self] revision, origin in
            self?.sourceDidChange(revision, origin: origin)
        }
    }

    var currentSnapshot: DocumentSnapshot {
        DocumentSnapshot(text: sourceBuffer.revision.text, format: format)
    }

    var latestRawRecoveryURL: URL? {
        guard let documentIdentity else { return nil }
        return recoveryStore
            .rawRecoveryEntries(for: documentIdentity)
            .first?
            .dataURL
    }

    var hasLocalRecovery: Bool {
        hasRecoverableLocalRevision
    }

    var recoveryMigrationIsPending: Bool {
        pendingRecoveryMigration != nil
    }

    var failureRequiresSaveAs: Bool {
        failedOperation == .destinationRequiresSaveAs
    }

    func loadInitial(_ snapshot: DocumentSnapshot, data: Data, from url: URL?) {
        format = snapshot.format
        sourceBuffer.replace(with: snapshot.text, origin: .initialLoad)
        if let url {
            attach(to: url, knownData: data)
        } else {
            durableState = DurableFileState(
                snapshot: snapshot,
                fingerprint: .make(data: data),
                generation: 0
            )
        }
        if url == nil {
            state = .idle
        } else {
            settleState(default: .idle)
        }
    }

    func attach(to url: URL, knownData: Data? = nil) {
        guard !isClosed else { return }
        let previousURL = fileURL
        let previousIdentity = documentIdentity
        fileURL = url.standardizedFileURL
        if previousURL != fileURL,
           failedOperation == .destinationRequiresSaveAs {
            failedOperation = nil
            saveAsRequiredFailureMessage = nil
        }
        let data = knownData ?? (try? Data(contentsOf: url, options: [.mappedIfSafe]))
        let resolvedIdentity: DocumentIdentity
        if let data, let fingerprint = try? SafeFileCommitter.fingerprint(
            for: url,
            data: data
        ) {
            let diskSnapshot = (try? TextFileCodec.decode(data)) ?? currentSnapshot
            durableState = DurableFileState(
                snapshot: diskSnapshot,
                fingerprint: fingerprint,
                generation: durableState?.generation ?? 0
            )
            resolvedIdentity = .make(
                url: url,
                resourceIdentifier: fingerprint.resourceIdentifier
            )
        } else {
            resolvedIdentity = .make(url: url)
        }
        if let previousIdentity,
           previousIdentity != resolvedIdentity {
            do {
                try recoveryStore.moveEntries(
                    from: previousIdentity,
                    to: resolvedIdentity
                )
                documentIdentity = resolvedIdentity
                pendingRecoveryMigration = nil
                if rawRecoveryRemovalIdentity == previousIdentity {
                    rawRecoveryRemovalIdentity = resolvedIdentity
                }
            } catch {
                documentIdentity = previousIdentity
                pendingRecoveryMigration = PendingRecoveryMigration(
                    source: previousIdentity,
                    destination: resolvedIdentity
                )
                state = .synchronizationPaused
            }
        } else {
            documentIdentity = resolvedIdentity
            pendingRecoveryMigration = nil
        }
        refreshRecoveryState()
        restartMonitor()
        if currentSnapshot != durableState?.snapshot {
            scheduleLocalWrite()
        }
    }

    func updateFileURL(_ url: URL) {
        fileURL = url.standardizedFileURL
        restartMonitor()
    }

    func flushNow(completion: (@MainActor (Bool) -> Void)? = nil) {
        if let completion {
            flushWaiters.append(completion)
        }
        guard fileURL != nil,
              !synchronizationIsPaused,
              failedOperation != .destinationRequiresSaveAs,
              !isClosed else {
            resolveFlushWaiters(succeeded: false)
            return
        }
        if isFullySynchronized {
            resolveFlushWaiters(succeeded: true)
            return
        }
        localWriteTask?.cancel()
        localWriteTask = nil
        beginSaveIfNeeded()
    }

    func noteCoordinatedExternalChange() {
        scheduleExternalRead()
    }

    func noteFileMoved(to newURL: URL) {
        let oldIdentity = documentIdentity
        updateFileURL(newURL)
        let newIdentity = DocumentIdentity.make(url: newURL)
        if let oldIdentity, oldIdentity != newIdentity {
            do {
                try recoveryStore.moveEntries(
                    from: oldIdentity,
                    to: newIdentity
                )
                documentIdentity = newIdentity
                pendingRecoveryMigration = nil
                if rawRecoveryRemovalIdentity == oldIdentity {
                    rawRecoveryRemovalIdentity = newIdentity
                }
            } catch {
                pendingRecoveryMigration = PendingRecoveryMigration(
                    source: oldIdentity,
                    destination: newIdentity
                )
                refreshRecoveryState()
                state = .synchronizationPaused
                return
            }
        } else {
            documentIdentity = newIdentity
            pendingRecoveryMigration = nil
        }
        refreshRecoveryState()
        settleState(default: .idle)
        scheduleExternalRead()
    }

    @discardableResult
    func handleSaveCompletion(generation: UInt64, error: Error?) -> Bool {
        guard let token = saveInFlight, token.generation == generation else {
            return false
        }
        saveInFlight = nil

        if let error {
            bridge.cancel(generation: generation)
            state = .failed(error.localizedDescription)
            if let commitError = error as? SafeFileCommitter.CommitError {
                switch commitError {
                case .atomicSwapUnavailable:
                    failedOperation = .destinationRequiresSaveAs
                    saveAsRequiredFailureMessage =
                        error.localizedDescription
                case .targetChangedBeforeCommit, .targetMissingBeforeCommit:
                    failedOperation = .externalRead
                }
            } else {
                failedOperation = .localWrite
            }
            if failedOperation == .externalRead {
                externalCheckPending = false
                scheduleExternalRead()
            } else {
                finishDeferredExternalCheck()
            }
            resolveFlushWaiters(succeeded: false)
            return false
        }

        do {
            let result = try bridge.finish(generation: generation)
            restartMonitor()
            let preimageFingerprint = result.displacedPreimage.map {
                FileFingerprint.make(data: $0)
            }
            let expected = token.expectedDurableState?.fingerprint
            let unexpectedPreimage = result.displacedPreimage != nil
                && (
                    expected == nil
                        || preimageFingerprint?.contentDigest
                            != expected?.contentDigest
                )

            if unexpectedPreimage, let preimage = result.displacedPreimage {
                reconcileDisplacedExternalData(
                    preimage,
                    committedToken: token,
                    result: result
                )
            } else {
                durableState = DurableFileState(
                    snapshot: token.snapshot,
                    fingerprint: result.committedFingerprint,
                    generation: generation
                )
                if let artifact = result.recoveryArtifact {
                    try CommitRecoveryJournalStore.acknowledge(artifact)
                }
                resolveCommittedRecovery(for: token)
                let successfulState = stateAfterNextSuccessfulSave
                    ?? (result.safety == .atomicSwap ? .idle : .limitedSyncSafety)
                settleState(default: successfulState)
                stateAfterNextSuccessfulSave = nil
                if sourceBuffer.revision.number != token.sourceRevision.number {
                    scheduleLocalWrite()
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            failedOperation = .externalRead
            resolveFlushWaiters(succeeded: false)
        }
        finishDeferredExternalCheck()
        if isFullySynchronized {
            resolveFlushWaiters(succeeded: true)
        }
        return isFullySynchronized
    }

    func restoreLatestRecovery() {
        guard resolvePendingRecoveryMigration() else { return }
        guard let identity = documentIdentity,
              let entry = recoveryStore.latest(for: identity) else {
            return
        }
        pendingRecoveryRemoval = entry
        if !recoveryStore.rawRecoveryEntries(for: identity).isEmpty {
            rawRecoveryRemovalIdentity = identity
        }
        synchronizationPauseIsLatched = false
        format = entry.snapshot.format
        sourceBuffer.replace(with: entry.snapshot.text, origin: .recovery)
        pendingRecoveryMinimumRevision = sourceBuffer.revision.number
        scheduleLocalWrite()
    }

    func resumeSynchronization() {
        guard synchronizationIsPaused,
              resolvePendingRecoveryMigration() else {
            return
        }
        if let documentIdentity {
            recoveryStore.removeRawRecoveryEntries(for: documentIdentity)
        }
        synchronizationPauseIsLatched = false
        rawRecoveryRemovalIdentity = nil
        settleState(default: .idle)
        if currentSnapshot != durableState?.snapshot {
            scheduleLocalWrite()
        } else {
            scheduleExternalRead()
        }
    }

    func retryRecoveryMigration() {
        guard pendingRecoveryMigration != nil,
              resolvePendingRecoveryMigration() else {
            return
        }
        settleState(default: .idle)
        if currentSnapshot != durableState?.snapshot {
            scheduleLocalWrite()
        } else {
            scheduleExternalRead()
        }
    }

    func retrySynchronization() {
        switch failedOperation {
        case .externalRead:
            scheduleExternalRead()
        case .monitoring:
            restartMonitor()
            scheduleExternalRead()
        case .localWrite:
            flushNow()
        case .destinationRequiresSaveAs:
            break
        case nil:
            if currentSnapshot != durableState?.snapshot {
                flushNow()
            } else {
                scheduleExternalRead()
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        localWriteTask?.cancel()
        localPreparationTask?.cancel()
        localPreparationTask = nil
        activePreparationGeneration = nil
        externalReadTask?.cancel()
        externalReadTask = nil
        externalReadPending = false
        activeExternalReadGeneration = nil
        monitor?.cancel()
        monitor = nil
        resolveFlushWaiters(succeeded: false)
        if let sourceObservation {
            sourceBuffer.removeObserver(sourceObservation)
        }
        sourceObservation = nil
    }

    private func finishDeferredExternalCheck() {
        guard externalCheckPending else { return }
        externalCheckPending = false
        scheduleExternalRead()
    }

    private func sourceDidChange(
        _ revision: SourceRevision,
        origin: DocumentChangeOrigin
    ) {
        guard !isClosed else { return }
        format.hasFinalNewline = revision.text.utf16.last == 0x000A
        switch origin {
        case .localEditor, .undoRedo, .merge, .recovery:
            if fileURL == nil, let url = delegate?.synchronizationFileURL {
                attach(to: url)
            }
            scheduleLocalWrite()
        case .initialLoad, .externalReload:
            break
        }
    }

    private func scheduleLocalWrite() {
        guard fileURL != nil,
              saveInFlight == nil,
              failedOperation != .destinationRequiresSaveAs,
              !synchronizationIsPaused else {
            return
        }
        localWriteTask?.cancel()
        state = .waitingToWrite
        localWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.localWriteDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.beginSaveIfNeeded()
        }
    }

    private func beginSaveIfNeeded() {
        guard !isClosed,
              !synchronizationIsPaused,
              failedOperation != .destinationRequiresSaveAs,
              saveInFlight == nil,
              localPreparationTask == nil,
              let fileURL else {
            return
        }
        guard FileManager.default.isWritableFile(atPath: fileURL.path) else {
            state = .readOnly
            resolveFlushWaiters(succeeded: false)
            return
        }
        let revision = sourceBuffer.revision
        if currentSnapshot == durableState?.snapshot {
            settleState(default: .idle)
            resolveFlushWaiters(succeeded: true)
            return
        }
        let snapshot = currentSnapshot
        let generation = nextGeneration
        nextGeneration &+= 1
        let preparationGeneration = nextPreparationGeneration
        nextPreparationGeneration &+= 1
        let expectedDurableState = durableState
        localWriteTask = nil
        activePreparationGeneration = preparationGeneration
        state = .writing

        localPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await Task.detached(priority: .utility) {
                    try TextFileCodec.encode(snapshot)
                }.value
                if let savePreparationHook = self.savePreparationHook {
                    await savePreparationHook()
                }
                guard !Task.isCancelled,
                      !self.isClosed,
                      self.activePreparationGeneration == preparationGeneration else {
                    return
                }
                self.finishLocalPreparation(preparationGeneration)
                guard self.saveInFlight == nil,
                      self.fileURL == fileURL,
                      self.durableState == expectedDurableState else {
                    if self.currentSnapshot != self.durableState?.snapshot {
                        self.scheduleLocalWrite()
                    }
                    return
                }
                let token = PendingSaveToken(
                    generation: generation,
                    sourceRevision: revision,
                    snapshot: snapshot,
                    encodedData: data,
                    expectedDurableState: expectedDurableState,
                    targetURL: fileURL
                )
                try self.bridge.install(token)
                self.saveInFlight = token
                self.delegate?.syncCoordinator(self, requestSave: token)
            } catch {
                guard self.activePreparationGeneration == preparationGeneration else {
                    return
                }
                self.finishLocalPreparation(preparationGeneration)
                if !Task.isCancelled {
                    self.state = .failed(error.localizedDescription)
                    self.failedOperation = .localWrite
                    self.resolveFlushWaiters(succeeded: false)
                }
            }
        }
    }

    private func finishLocalPreparation(_ generation: UInt64) {
        guard activePreparationGeneration == generation else { return }
        activePreparationGeneration = nil
        localPreparationTask = nil
    }

    private func restartMonitor() {
        monitor?.cancel()
        monitor = nil
        guard let fileURL else {
            monitorFailureMessage = nil
            return
        }
        let monitor = DirectoryFileMonitor(targetURL: fileURL) { [weak self] in
            Task { @MainActor in self?.scheduleExternalRead() }
        }
        do {
            try monitor.start()
            self.monitor = monitor
            monitorFailureMessage = nil
            if failedOperation == .monitoring {
                failedOperation = nil
            }
        } catch {
            monitorFailureMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
            failedOperation = .monitoring
        }
    }

    private func scheduleExternalRead() {
        guard !isClosed, !synchronizationIsPaused else { return }
        if saveInFlight != nil {
            externalCheckPending = true
            return
        }
        guard externalReadTask == nil else {
            externalReadPending = true
            return
        }
        let generation = nextExternalReadGeneration
        nextExternalReadGeneration &+= 1
        activeExternalReadGeneration = generation
        externalReadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.externalEventDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.readExternalRevision(generation: generation)
        }
    }

    private func readExternalRevision(generation: UInt64) async {
        guard let fileURL else {
            finishExternalRead(generation)
            return
        }
        state = .checkingExternalChange
        do {
            let data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }.value
            if let externalReadHook {
                await externalReadHook(generation)
            }
            guard isCurrentExternalRead(generation, url: fileURL) else {
                finishExternalRead(generation)
                return
            }
            await reconcileExternalData(
                data,
                from: fileURL,
                generation: generation
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard isCurrentExternalRead(generation, url: fileURL) else {
                finishExternalRead(generation)
                return
            }
            state = .missing
            finishExternalRead(generation)
        } catch {
            guard isCurrentExternalRead(generation, url: fileURL) else {
                finishExternalRead(generation)
                return
            }
            state = .failed(error.localizedDescription)
            failedOperation = .externalRead
            finishExternalRead(generation)
        }
    }

    private func reconcileExternalData(
        _ data: Data,
        from url: URL,
        generation: UInt64
    ) async {
        let capturedDurableState = durableState
        let capturedLocal = currentSnapshot
        let capturedSourceRevision = sourceBuffer.revision.number
        do {
            let merger = self.merger
            let reconciliation = try await Task.detached(priority: .utility) {
                let fingerprint = try SafeFileCommitter.fingerprint(
                    for: url,
                    data: data
                )
                let observedIdentity = DocumentIdentity.make(url: url)
                if fingerprint.contentDigest
                    == capturedDurableState?.fingerprint.contentDigest {
                    return ExternalReconciliation.unchanged(
                        fingerprint: fingerprint,
                        documentIdentity: observedIdentity
                    )
                }
                let external = try TextFileCodec.decode(data)
                let mergeResult = capturedDurableState.map {
                    merger.merge(
                        base: $0.snapshot.text,
                        local: capturedLocal.text,
                        external: external.text
                    )
                }
                return ExternalReconciliation.changed(
                    fingerprint: fingerprint,
                    documentIdentity: observedIdentity,
                    snapshot: external,
                    mergeResult: mergeResult
                )
            }.value
            guard isCurrentExternalRead(generation, url: url) else {
                finishExternalRead(generation)
                return
            }
            guard durableState == capturedDurableState,
                  sourceBuffer.revision.number == capturedSourceRevision else {
                externalReadPending = true
                finishExternalRead(generation)
                return
            }

            switch reconciliation {
            case let .unchanged(fingerprint, observedIdentity):
                guard migrateDocumentIdentityIfNeeded(
                    to: observedIdentity
                ) else {
                    finishExternalRead(generation)
                    return
                }
                restartMonitor()
                if let capturedDurableState {
                    durableState = DurableFileState(
                        snapshot: capturedDurableState.snapshot,
                        fingerprint: fingerprint,
                        generation: capturedDurableState.generation
                    )
                }
                settleState(default: .idle)
                finishExternalRead(generation)
                if currentSnapshot != durableState?.snapshot {
                    ensureLocalWriteScheduled()
                }
                return
            case let .changed(
                fingerprint,
                observedIdentity,
                external,
                mergeResult
            ):
                guard migrateDocumentIdentityIfNeeded(
                    to: observedIdentity
                ) else {
                    finishExternalRead(generation)
                    return
                }
                restartMonitor()
                applyExternalReconciliation(
                    fingerprint: fingerprint,
                    external: external,
                    mergeResult: mergeResult,
                    capturedDurableState: capturedDurableState,
                    local: capturedLocal,
                    url: url
                )
            }
            finishExternalRead(generation)
        } catch {
            guard isCurrentExternalRead(generation, url: url) else {
                finishExternalRead(generation)
                return
            }
            state = .failed(error.localizedDescription)
            failedOperation = .externalRead
            finishExternalRead(generation)
        }
    }

    @discardableResult
    private func migrateDocumentIdentityIfNeeded(
        to observedIdentity: DocumentIdentity
    ) -> Bool {
        guard let previousIdentity = documentIdentity,
              previousIdentity != observedIdentity else {
            documentIdentity = observedIdentity
            return true
        }
        do {
            try recoveryStore.moveEntries(
                from: previousIdentity,
                to: observedIdentity
            )
            documentIdentity = observedIdentity
            pendingRecoveryMigration = nil
            if rawRecoveryRemovalIdentity == previousIdentity {
                rawRecoveryRemovalIdentity = observedIdentity
            }
            refreshRecoveryState()
            return true
        } catch {
            pendingRecoveryMigration = PendingRecoveryMigration(
                source: previousIdentity,
                destination: observedIdentity
            )
            refreshRecoveryState()
            state = .synchronizationPaused
            return false
        }
    }

    private func applyExternalReconciliation(
        fingerprint: FileFingerprint,
        external: DocumentSnapshot,
        mergeResult: ThreeWayMergeResult?,
        capturedDurableState: DurableFileState?,
        local: DocumentSnapshot,
        url: URL
    ) {
        state = .reloading
        guard let durableState = capturedDurableState,
              let mergeResult else {
            format = external.format
            sourceBuffer.replace(with: external.text, origin: .externalReload)
            self.durableState = DurableFileState(
                snapshot: external,
                fingerprint: fingerprint,
                generation: 0
            )
            delegate?.syncCoordinator(
                self,
                acceptedExternalFileAt: url,
                hasLocalChanges: false
            )
            settleState(default: .idle)
            return
        }

        switch mergeResult {
        case let .unchanged(text):
            format = external.format
            if text == external.text {
                sourceBuffer.replace(with: external.text, origin: .externalReload)
            }
            self.durableState = DurableFileState(
                snapshot: external,
                fingerprint: fingerprint,
                generation: durableState.generation
            )
            delegate?.syncCoordinator(
                self,
                acceptedExternalFileAt: url,
                hasLocalChanges: text != external.text
            )
            settleState(default: .idle)
            if text != external.text { scheduleLocalWrite() }
        case let .merged(text):
            state = .merging
            self.durableState = DurableFileState(
                snapshot: external,
                fingerprint: fingerprint,
                generation: durableState.generation
            )
            format = external.format
            sourceBuffer.replace(with: text, origin: .merge)
            delegate?.syncCoordinator(
                self,
                acceptedExternalFileAt: url,
                hasLocalChanges: true
            )
            scheduleLocalWrite()
        case .conflict:
            guard let identity = documentIdentity else {
                state = .failed(
                    "The local revision could not be associated with this file."
                )
                failedOperation = .externalRead
                return
            }
            do {
                try recoveryStore.add(snapshot: local, for: identity)
                hasRecoverableLocalRevision = true
            } catch {
                state = .failed(
                    "The local revision could not be stored for recovery: "
                        + error.localizedDescription
                )
                failedOperation = .externalRead
                return
            }
            self.durableState = DurableFileState(
                snapshot: external,
                fingerprint: fingerprint,
                generation: durableState.generation
            )
            format = external.format
            sourceBuffer.replace(with: external.text, origin: .externalReload)
            delegate?.syncCoordinator(
                self,
                acceptedExternalFileAt: url,
                hasLocalChanges: false
            )
            state = .recoveredConflict
        }
    }

    private func isCurrentExternalRead(_ generation: UInt64, url: URL) -> Bool {
        !Task.isCancelled
            && !isClosed
            && activeExternalReadGeneration == generation
            && fileURL == url
    }

    private func finishExternalRead(_ generation: UInt64) {
        guard activeExternalReadGeneration == generation else { return }
        activeExternalReadGeneration = nil
        externalReadTask = nil
        if externalReadPending {
            externalReadPending = false
            scheduleExternalRead()
        }
    }

    private func ensureLocalWriteScheduled() {
        guard localWriteTask == nil,
              localPreparationTask == nil,
              saveInFlight == nil else {
            return
        }
        scheduleLocalWrite()
    }

    private func resolveFlushWaiters(succeeded: Bool) {
        guard !flushWaiters.isEmpty else { return }
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters {
            waiter(succeeded)
        }
    }

    private func refreshRecoveryState() {
        guard let documentIdentity else {
            hasRecoverableLocalRevision = false
            return
        }
        hasRecoverableLocalRevision =
            recoveryStore.latest(for: documentIdentity) != nil
        if !recoveryStore.rawRecoveryEntries(for: documentIdentity).isEmpty {
            synchronizationPauseIsLatched = true
        }
    }

    private func settleState(default defaultState: SynchronizationState) {
        if synchronizationIsPaused {
            state = .synchronizationPaused
        } else if hasRecoverableLocalRevision {
            state = .recoveredConflict
        } else if failedOperation == .destinationRequiresSaveAs,
                  currentSnapshot != durableState?.snapshot {
            state = .failed(
                saveAsRequiredFailureMessage
                    ?? SafeFileCommitter.CommitError
                        .atomicSwapUnavailable.localizedDescription
            )
        } else if let monitorFailureMessage {
            failedOperation = .monitoring
            state = .failed(monitorFailureMessage)
        } else {
            failedOperation = nil
            saveAsRequiredFailureMessage = nil
            state = defaultState
        }
    }

    private var synchronizationIsPaused: Bool {
        synchronizationPauseIsLatched || pendingRecoveryMigration != nil
    }

    @discardableResult
    private func resolvePendingRecoveryMigration() -> Bool {
        guard let migration = pendingRecoveryMigration else { return true }
        do {
            try recoveryStore.moveEntries(
                from: migration.source,
                to: migration.destination
            )
            documentIdentity = migration.destination
            if rawRecoveryRemovalIdentity == migration.source {
                rawRecoveryRemovalIdentity = migration.destination
            }
            pendingRecoveryMigration = nil
            refreshRecoveryState()
            return true
        } catch {
            state = .synchronizationPaused
            return false
        }
    }

    private func resolveCommittedRecovery(for token: PendingSaveToken) {
        if let entry = pendingRecoveryRemoval,
           let minimumRevision = pendingRecoveryMinimumRevision,
           token.sourceRevision.number >= minimumRevision {
            recoveryStore.remove(entry)
            pendingRecoveryRemoval = nil
            pendingRecoveryMinimumRevision = nil
        }
        if let identity = rawRecoveryRemovalIdentity {
            recoveryStore.removeRawRecoveryEntries(for: identity)
            rawRecoveryRemovalIdentity = nil
        }
        refreshRecoveryState()
    }

    private var isFullySynchronized: Bool {
        saveInFlight == nil
            && localPreparationTask == nil
            && currentSnapshot == durableState?.snapshot
    }

    private func reconcileDisplacedExternalData(
        _ data: Data,
        committedToken token: PendingSaveToken,
        result: FileCommitResult
    ) {
        do {
            guard let documentIdentity else {
                synchronizationPauseIsLatched = true
                state = .synchronizationPaused
                resolveFlushWaiters(succeeded: false)
                return
            }
            if let artifact = result.recoveryArtifact {
                try recoveryStore.addRawData(
                    data,
                    for: documentIdentity,
                    id: artifact.id
                )
                try CommitRecoveryJournalStore.acknowledge(artifact)
            } else {
                try recoveryStore.addRawData(data, for: documentIdentity)
            }
            let external = try TextFileCodec.decode(data)
            rawRecoveryRemovalIdentity = documentIdentity
            let local = currentSnapshot
            let base = token.expectedDurableState?.snapshot ?? token.snapshot
            durableState = DurableFileState(
                snapshot: token.snapshot,
                fingerprint: result.committedFingerprint,
                generation: token.generation
            )
            format = external.format

            switch merger.merge(
                base: base.text,
                local: local.text,
                external: external.text
            ) {
            case let .unchanged(text):
                if text == external.text {
                    sourceBuffer.replace(with: external.text, origin: .externalReload)
                } else if text != local.text {
                    sourceBuffer.replace(with: text, origin: .merge)
                }
                state = .merging
            case let .merged(text):
                sourceBuffer.replace(with: text, origin: .merge)
                state = .merging
            case .conflict:
                try recoveryStore.add(
                    snapshot: local,
                    for: documentIdentity
                )
                hasRecoverableLocalRevision = true
                sourceBuffer.replace(with: external.text, origin: .externalReload)
                stateAfterNextSuccessfulSave = .recoveredConflict
                state = .recoveredConflict
            }

            if currentSnapshot != token.snapshot {
                scheduleLocalWrite()
            } else if let stateAfterNextSuccessfulSave {
                if let identity = rawRecoveryRemovalIdentity {
                    recoveryStore.removeRawRecoveryEntries(for: identity)
                    rawRecoveryRemovalIdentity = nil
                }
                refreshRecoveryState()
                settleState(default: stateAfterNextSuccessfulSave)
                self.stateAfterNextSuccessfulSave = nil
            } else {
                if let identity = rawRecoveryRemovalIdentity {
                    recoveryStore.removeRawRecoveryEntries(for: identity)
                    rawRecoveryRemovalIdentity = nil
                }
                refreshRecoveryState()
                settleState(
                    default: result.safety == .atomicSwap
                        ? .idle
                        : .limitedSyncSafety
                )
            }
        } catch {
            synchronizationPauseIsLatched = true
            state = .synchronizationPaused
            resolveFlushWaiters(succeeded: false)
        }
    }
}
