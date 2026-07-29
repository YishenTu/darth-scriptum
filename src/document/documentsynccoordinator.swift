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

private struct VerifiedAttachment: Sendable {
    let data: Data
    let matchesExpectedData: Bool
}

private enum FailedSynchronizationOperation {
    case localWrite
    case externalRead
    case monitoring
    case destinationRequiresSaveAs
}

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

    private(set) var state: SynchronizationState = .idle {
        didSet {
            if let persistentState = Self.persistentPresentedState(
                for: state
            ) {
                if presentedStateValue != persistentState {
                    presentedStateValue = persistentState
                }
            } else if state == .idle, presentedStateValue != nil {
                presentedStateValue = nil
            }
            refreshStatusSnapshot()
        }
    }
    private var presentedStateValue: SynchronizationState?
    @Published private(set) var statusSnapshot:
        DocumentSynchronizationStatusSnapshot = .empty
    @Published private(set) var format: TextFileFormat
    private(set) var durableState: DurableFileState?
    /// Source revision represented by `durableState`. Keeping this identity
    /// avoids comparing the entire document on every autosave/status check.
    private var durableSourceRevision: UInt64?
    @Published private(set) var fileURL: URL?

    let sourceBuffer: MarkdownSourceBuffer
    let bridge: SaveTransactionBridge
    weak var delegate: DocumentSyncCoordinatorDelegate?

    private let merger = ThreeWayTextMerger()
    private let recoveryStore: SessionRecoveryStore
    private let savePreparationHook: (@MainActor () async -> Void)?
    private let externalReadHook: (@MainActor (UInt64) async -> Void)?
    private var documentIdentity: DocumentIdentity? {
        didSet { refreshStatusSnapshot() }
    }
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
    private var attachmentVerificationInProgress = false
    private var monitor: DirectoryFileMonitor?
    private var saveInFlight: PendingSaveToken?
    private var externalCheckPending = false
    private var hasRecoverableLocalRevision = false {
        didSet { refreshStatusSnapshot() }
    }
    private var synchronizationPauseIsLatched = false
    private var pendingRecoveryMigration: PendingRecoveryMigration? {
        didSet { refreshStatusSnapshot() }
    }
    private var pendingRecoveryRemoval: RecoveryEntry?
    private var pendingRecoveryMinimumRevision: UInt64?
    private var rawRecoveryRemovalIdentity: DocumentIdentity?
    private var isClosed = false
    private var stateAfterNextSuccessfulSave: SynchronizationState?
    private var failedOperation: FailedSynchronizationOperation? {
        didSet { refreshStatusSnapshot() }
    }
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
        durableSourceRevision =
            initialDurableState?.snapshot == snapshot ? 0 : nil
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

    var hasLocalChanges: Bool {
        guard let durableState else { return true }
        return durableSourceRevision != sourceBuffer.revision.number
            || durableState.snapshot.format != format
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

    func loadInitial(_ snapshot: DocumentSnapshot, data: Data, from url: URL?) {
        format = snapshot.format
        sourceBuffer.replace(with: snapshot.text, origin: .initialLoad)
        if let url {
            attach(
                to: url,
                knownData: data,
                knownSnapshot: snapshot
            )
        } else {
            durableState = DurableFileState(
                snapshot: snapshot,
                fingerprint: .make(data: data),
                generation: 0
            )
            durableSourceRevision = sourceBuffer.revision.number
        }
        if url == nil {
            state = .idle
        } else {
            settleState(default: .idle)
        }
    }

    func attach(
        to url: URL,
        knownData: Data? = nil,
        knownSnapshot: DocumentSnapshot? = nil
    ) {
        guard !isClosed else { return }
        let previousURL = fileURL
        let previousIdentity = documentIdentity
        fileURL = url.standardizedFileURL
        let monitorNeedsRestart = previousURL != fileURL || monitor == nil
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
            let diskSnapshot = knownSnapshot
                ?? (try? TextFileCodec.decode(data))
                ?? currentSnapshot
            durableState = DurableFileState(
                snapshot: diskSnapshot,
                fingerprint: fingerprint,
                generation: durableState?.generation ?? 0
            )
            durableSourceRevision =
                currentSnapshot == diskSnapshot
                    ? sourceBuffer.revision.number
                    : nil
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
        if monitorNeedsRestart {
            restartMonitor()
        }
        if hasLocalChanges {
            scheduleLocalWrite()
        }
    }

    func attachAfterSaveAs(
        to url: URL,
        expectedData: Data,
        expectedSnapshot: DocumentSnapshot
    ) async throws {
        guard !isClosed else { return }
        let targetURL = url.standardizedFileURL

        // Monitor before verifying the bytes so a replacement racing the read
        // cannot fall into a gap between verification and event observation.
        attachmentVerificationInProgress = true
        defer {
            attachmentVerificationInProgress = false
            if externalReadPending, externalReadTask == nil {
                externalReadPending = false
                scheduleExternalRead()
            }
        }
        updateFileURL(targetURL)
        let verified = try await Task.detached(priority: .utility) {
            let data = try Data(
                contentsOf: targetURL,
                options: [.mappedIfSafe]
            )
            return VerifiedAttachment(
                data: data,
                matchesExpectedData: data == expectedData
            )
        }.value
        guard !isClosed, fileURL == targetURL else { return }

        attach(
            to: targetURL,
            knownData: expectedData,
            knownSnapshot: expectedSnapshot
        )
        guard !verified.matchesExpectedData else {
            settleState(default: .idle)
            return
        }

        // The Save As bytes became the merge base. Reconcile the replacement
        // observed on disk before reporting save completion, so it is never
        // overwritten as though it were an ordinary newer local revision.
        localWriteTask?.cancel()
        localWriteTask = nil
        let generation = nextExternalReadGeneration
        nextExternalReadGeneration &+= 1
        activeExternalReadGeneration = generation
        await reconcileExternalData(
            verified.data,
            from: targetURL,
            generation: generation
        )
        if case let .failed(message) = state {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
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
                durableSourceRevision = token.sourceRevision.number
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
        durableSourceRevision = nil
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
        if hasLocalChanges {
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
        if hasLocalChanges {
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
            if hasLocalChanges {
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
        let hasFinalNewline = revision.text.utf16.last == 0x000A
        if format.hasFinalNewline != hasFinalNewline {
            format.hasFinalNewline = hasFinalNewline
        }
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
        if !hasLocalChanges {
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
                      self.matchesDurableState(expectedDurableState) else {
                    if self.hasLocalChanges {
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
        if attachmentVerificationInProgress {
            externalReadPending = true
            return
        }
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
            guard !Task.isCancelled else { return }
            await self?.readExternalRevision(generation: generation)
        }
    }

    private func readExternalRevision(generation: UInt64) async {
        guard let fileURL else {
            finishExternalRead(generation)
            return
        }
        // Signals delivered before this read starts are already represented by
        // the bytes it is about to load. Only retain signals that arrive while
        // the read is in flight.
        externalReadPending = false
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
            guard matchesDurableState(capturedDurableState),
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
                if fingerprint.resourceIdentifier
                    != capturedDurableState?.fingerprint.resourceIdentifier {
                    restartMonitor()
                }
                if let capturedDurableState {
                    durableState = DurableFileState(
                        snapshot: capturedDurableState.snapshot,
                        fingerprint: fingerprint,
                        generation: capturedDurableState.generation
                    )
                }
                settleState(default: .idle)
                finishExternalRead(generation)
                if hasLocalChanges {
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
                if fingerprint.resourceIdentifier
                    != capturedDurableState?.fingerprint.resourceIdentifier {
                    restartMonitor()
                }
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
            durableSourceRevision = sourceBuffer.revision.number
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
            durableSourceRevision =
                text == external.text
                    ? sourceBuffer.revision.number
                    : nil
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
            durableSourceRevision = nil
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
            durableSourceRevision = sourceBuffer.revision.number
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
            refreshStatusSnapshot()
            return
        }
        hasRecoverableLocalRevision =
            recoveryStore.latest(for: documentIdentity) != nil
        if !recoveryStore.rawRecoveryEntries(for: documentIdentity).isEmpty {
            synchronizationPauseIsLatched = true
        }
        refreshStatusSnapshot()
    }

    private func refreshStatusSnapshot() {
        let rawRecoveryURL: URL?
        if let documentIdentity {
            rawRecoveryURL = recoveryStore
                .rawRecoveryEntries(for: documentIdentity)
                .first?
                .dataURL
        } else {
            rawRecoveryURL = nil
        }
        let snapshot = DocumentSynchronizationStatusSnapshot(
            presentedState: presentedStateValue,
            failureRequiresSaveAs:
                failedOperation == .destinationRequiresSaveAs,
            recoveryMigrationIsPending: pendingRecoveryMigration != nil,
            rawRecoveryURL: rawRecoveryURL,
            hasLocalRecovery: hasRecoverableLocalRevision
        )
        if snapshot != statusSnapshot {
            statusSnapshot = snapshot
        }
    }

    private func settleState(default defaultState: SynchronizationState) {
        if synchronizationIsPaused {
            state = .synchronizationPaused
        } else if hasRecoverableLocalRevision {
            state = .recoveredConflict
        } else if failedOperation == .destinationRequiresSaveAs,
                  hasLocalChanges {
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

    private static func persistentPresentedState(
        for state: SynchronizationState
    ) -> SynchronizationState? {
        switch state {
        case .idle,
             .waitingToWrite,
             .writing,
             .checkingExternalChange,
             .reloading,
             .merging:
            nil
        case .recoveredConflict,
             .readOnly,
             .missing,
             .failed,
             .limitedSyncSafety,
             .synchronizationPaused:
            state
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
            && !hasLocalChanges
    }

    private func matchesDurableState(
        _ expected: DurableFileState?
    ) -> Bool {
        switch (durableState, expected) {
        case (nil, nil):
            return true
        case let (current?, expected?):
            return current.generation == expected.generation
                && current.fingerprint == expected.fingerprint
        case (.some, nil), (nil, .some):
            return false
        }
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
            durableSourceRevision = token.sourceRevision.number
            format = external.format

            switch merger.merge(
                base: base.text,
                local: local.text,
                external: external.text
            ) {
            case let .unchanged(text):
                if text == external.text {
                    sourceBuffer.replace(with: external.text, origin: .externalReload)
                    durableSourceRevision = nil
                } else if text != local.text {
                    sourceBuffer.replace(with: text, origin: .merge)
                    durableSourceRevision = nil
                }
                state = .merging
            case let .merged(text):
                sourceBuffer.replace(with: text, origin: .merge)
                durableSourceRevision = nil
                state = .merging
            case .conflict:
                try recoveryStore.add(
                    snapshot: local,
                    for: documentIdentity
                )
                hasRecoverableLocalRevision = true
                sourceBuffer.replace(with: external.text, origin: .externalReload)
                // The just-committed bytes are still `token.snapshot`; the
                // displaced external text is now visible but must be written
                // back before it becomes durable.
                durableSourceRevision = nil
                stateAfterNextSuccessfulSave = .recoveredConflict
                state = .recoveredConflict
            }

            if hasLocalChanges {
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
