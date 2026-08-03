import Foundation

enum SessionRecoveryStoreStatus: Sendable, Equatable {
    case loading
    case ready(generation: UInt64)
    case failed(RecoveryStoreIssue)
}

/// Test-observable command categories for the store's FIFO boundary. Production
/// code does not branch on these values; they make queued reentrancy assertions
/// possible without timing-based tests.
enum SessionRecoveryStoreCommandKind: Sendable, Equatable {
    case startup
    case waitForStartup
    case load
    case persistSnapshot
    case persistRaw
    case migrate
    case discard
    case reconcile
    case reconcileCommit
}

/// Test-observable fault boundaries around the durable acknowledgement that
/// links raw recovery evidence to a commit-recovery journal.
enum SessionRecoveryStoreRawPersistencePhase: Sendable, Equatable {
    case beforeRawPersistence
    case beforeAcknowledgementMetadata
    case afterAcknowledgementMetadata
}

final class MigrationWriteHookBox: @unchecked Sendable {
    let hook: @Sendable (Int) throws -> Void

    init(_ hook: @escaping @Sendable (Int) throws -> Void) {
        self.hook = hook
    }
}

private final class StartupReadHookBox: @unchecked Sendable {
    let hook: @Sendable () throws -> Void

    init(_ hook: @escaping @Sendable () throws -> Void) {
        self.hook = hook
    }
}

private final class StartupCompletionHookBox: @unchecked Sendable {
    let hook: @Sendable () throws -> Void

    init(_ hook: @escaping @Sendable () throws -> Void) {
        self.hook = hook
    }
}

private final class CommandEnqueueHookBox: @unchecked Sendable {
    let hook: @Sendable (SessionRecoveryStoreCommandKind) -> Void

    init(
        _ hook: @escaping @Sendable (SessionRecoveryStoreCommandKind) -> Void
    ) {
        self.hook = hook
    }
}

private final class RawPersistenceHookBox: @unchecked Sendable {
    let hook: @Sendable (SessionRecoveryStoreRawPersistencePhase) throws -> Void

    init(
        _ hook:
            @escaping @Sendable (
                SessionRecoveryStoreRawPersistencePhase
            ) throws -> Void
    ) {
        self.hook = hook
    }
}

enum PendingRecoveryJournal: Sendable {
    case migration
    case deletion
}

/// The recovery boundary owns all mutable recovery state and serializes every
/// mutation through one FIFO drain. The actor may reenter while a command is
/// awaiting `DocumentFileAccess`, but only the drain resumes with authority to
/// transition the index.
actor SessionRecoveryStore {
    private static let maximumResidentRawRecoveryBytes = 1 * 1_024 * 1_024

    static let shared: SessionRecoveryStore = {
        SessionRecoveryStore(
            persistenceDirectory: CommitRecoveryJournalStore.defaultRecoveryDirectory
        )
    }()

    private let perDocumentLimit: Int
    private let totalByteLimit: Int
    private let persistenceDirectory: URL?
    private let fileAccessLane: DocumentFileAccessLane
    private let migrationWriteHook: MigrationWriteHookBox?
    private let startupReadHook: StartupReadHookBox?
    private let startupCompletionHook: StartupCompletionHookBox?
    private let commandEnqueueHook: CommandEnqueueHookBox?
    private let rawPersistenceHook: RawPersistenceHookBox?

    private var startupStatus: SessionRecoveryStoreStatus = .loading
    private var startupCommandQueued = false
    private var entries: [RecoveryEntry] = []
    private var rawEntries: [RawRecoveryEntry] = []
    private var mutationGenerations: [String: UInt64] = [:]
    private var commands: [Command] = []
    private var isDraining = false

    init(
        persistenceDirectory: URL? = nil,
        fileAccessLane: DocumentFileAccessLane = DocumentFileAccess.recovery,
        perDocumentLimit: Int = 5,
        totalByteLimit: Int = 10 * 1_024 * 1_024,
        migrationWriteHook: (@Sendable (Int) throws -> Void)? = nil,
        startupReadHook: (@Sendable () throws -> Void)? = nil,
        startupCompletionHook: (@Sendable () throws -> Void)? = nil,
        commandEnqueueHook: (@Sendable (SessionRecoveryStoreCommandKind) -> Void)? = nil,
        rawPersistenceHook: (
            @Sendable (
                SessionRecoveryStoreRawPersistencePhase
            ) throws -> Void
        )? = nil
    ) {
        self.persistenceDirectory = persistenceDirectory
        self.fileAccessLane = fileAccessLane
        self.perDocumentLimit = perDocumentLimit
        self.totalByteLimit = totalByteLimit
        self.migrationWriteHook = migrationWriteHook.map(MigrationWriteHookBox.init)
        self.startupReadHook = startupReadHook.map(StartupReadHookBox.init)
        self.startupCompletionHook = startupCompletionHook.map(
            StartupCompletionHookBox.init
        )
        self.commandEnqueueHook = commandEnqueueHook.map(
            CommandEnqueueHookBox.init
        )
        self.rawPersistenceHook = rawPersistenceHook.map(
            RawPersistenceHookBox.init
        )
    }

    func status() -> SessionRecoveryStoreStatus {
        startupStatus
    }

    /// Explicitly starts durable recovery import. The store remains `.loading`
    /// until its first FIFO transaction finishes.
    func start() async throws -> SessionRecoveryStoreSnapshot {
        switch startupStatus {
        case .ready:
            return snapshot()
        case .failed(let issue):
            throw issue
        case .loading:
            return try await withCheckedThrowingContinuation { continuation in
                if startupCommandQueued {
                    appendCommand(.waitForStartup(continuation))
                } else {
                    startupCommandQueued = true
                    appendCommand(.startup(continuation))
                }
                beginDrainIfNeeded()
            }
        }
    }

    /// Replaces only failed startup work. FIFO mutation intent enqueued while
    /// loading or failed remains retained behind the new startup transaction.
    func retryStartup() async throws -> SessionRecoveryStoreSnapshot {
        switch startupStatus {
        case .ready:
            return snapshot()
        case .loading:
            return try await start()
        case .failed:
            startupStatus = .loading
            startupCommandQueued = true
            return try await withCheckedThrowingContinuation { continuation in
                insertCommand(.waitForStartup(continuation), at: 0)
                insertCommand(.startup(nil), at: 0)
                beginDrainIfNeeded()
            }
        }
    }

    func load(
        scope: DocumentSyncRecoveryLoadScope
    ) async throws -> SessionRecoveryStoreLoadReceipt {
        switch startupStatus {
        case .ready:
            return loadReceipt(scope: scope)
        case .failed(let issue):
            throw issue
        case .loading:
            return try await withCheckedThrowingContinuation { continuation in
                enqueueStartupIfNeeded()
                appendCommand(.load(scope, continuation))
                beginDrainIfNeeded()
            }
        }
    }

    func records(
        for identity: DocumentIdentity
    ) async throws -> SessionRecoveryStoreRecords {
        try await load(scope: .document(identity)).records
    }

    func latest(for identity: DocumentIdentity) async throws -> RecoveryEntry? {
        try await records(for: identity).decoded.first
    }

    func rawRecoveryEntries(
        for identity: DocumentIdentity
    ) async throws -> [RawRecoveryEntry] {
        try await records(for: identity).raw
    }

    func typedMutationGeneration(for identity: DocumentIdentity) async throws -> UInt64 {
        try await load(scope: .document(identity)).generation
    }

    func add(
        snapshot: DocumentSnapshot,
        for identity: DocumentIdentity
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await add(
            id: UUID(),
            snapshot: snapshot,
            for: identity,
            expectedRecords: nil,
            expectedGeneration: nil
        )
    }

    func add(
        snapshot: DocumentSnapshot,
        for identity: DocumentIdentity,
        expectedGeneration: UInt64
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await add(
            id: UUID(),
            snapshot: snapshot,
            for: identity,
            expectedRecords: nil,
            expectedGeneration: expectedGeneration
        )
    }

    func add(
        id: UUID,
        snapshot: DocumentSnapshot,
        for identity: DocumentIdentity,
        expectedRecords: DocumentSyncRecoveryRecords? = nil,
        expectedGeneration: UInt64?
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await enqueueSnapshotPersistence(
            SnapshotPersistenceCommand(
                id: id,
                snapshot: snapshot,
                identity: identity,
                expectedRecords: expectedRecords,
                expectedGeneration: expectedGeneration
            )
        )
    }

    func persistFreshDecodedConflict(
        id: UUID,
        snapshot: DocumentSnapshot,
        for identity: DocumentIdentity,
        expectedGeneration: UInt64
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await add(
            id: id,
            snapshot: snapshot,
            for: identity,
            expectedRecords: .empty,
            expectedGeneration: expectedGeneration
        )
    }

    func addRawData(
        _ data: Data,
        for identity: DocumentIdentity,
        id: UUID = UUID()
    ) async throws -> RawRecoveryEntry {
        let receipt = try await persistRawData(
            data,
            for: identity,
            id: id,
            expectedRecords: nil,
            expectedGeneration: nil,
            recoveryArtifact: nil
        )
        return receipt.entry
    }

    func persistRawData(
        _ data: Data,
        for identity: DocumentIdentity,
        id: UUID,
        expectedRecords: DocumentSyncRecoveryRecords?,
        expectedGeneration: UInt64?,
        recoveryArtifact: CommitRecoveryArtifact?
    ) async throws -> SessionRecoveryStoreRawMutationReceipt {
        try await enqueueRawPersistence(
            RawPersistenceCommand(
                id: id,
                data: data,
                identity: identity,
                expectedRecords: expectedRecords,
                expectedGeneration: expectedGeneration,
                recoveryArtifact: recoveryArtifact
            )
        )
    }

    func discard(
        target: DocumentSyncRecoveryDiscardTarget,
        for identity: DocumentIdentity,
        expectedRecords: DocumentSyncRecoveryRecords,
        expectedGeneration: UInt64
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await enqueueDiscard(
            DiscardCommand(
                target: target,
                identity: identity,
                expectedRecords: expectedRecords,
                expectedGeneration: expectedGeneration
            )
        )
    }

    func discardExactDecodedConflict(
        _ entry: RecoveryEntry,
        for identity: DocumentIdentity,
        expectedGeneration: UInt64
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        let expected = try await records(for: identity).asDocumentSyncRecords
        return try await discard(
            target: .decoded(entry),
            for: identity,
            expectedRecords: expected,
            expectedGeneration: expectedGeneration
        )
    }

    func remove(_ entry: RecoveryEntry) async throws {
        let loaded = try await load(scope: .document(entry.documentIdentity))
        _ = try await discard(
            target: .decoded(entry),
            for: entry.documentIdentity,
            expectedRecords: loaded.records.asDocumentSyncRecords,
            expectedGeneration: loaded.generation
        )
    }

    func removeRawRecoveryEntries(for identity: DocumentIdentity) async throws {
        let loaded = try await load(scope: .document(identity))
        guard !loaded.records.raw.isEmpty else { return }
        _ = try await discard(
            target: .raw(loaded.records.raw.map(DocumentSyncRawRecoveryReference.init)),
            for: identity,
            expectedRecords: loaded.records.asDocumentSyncRecords,
            expectedGeneration: loaded.generation
        )
    }

    func moveEntries(
        from sourceIdentity: DocumentIdentity,
        to destinationIdentity: DocumentIdentity
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        let source = try await load(scope: .document(sourceIdentity))
        return try await moveEntries(
            from: sourceIdentity,
            to: destinationIdentity,
            expectedRecords: source.records.asDocumentSyncRecords,
            expectedGeneration: source.generation
        )
    }

    func moveEntries(
        from sourceIdentity: DocumentIdentity,
        to destinationIdentity: DocumentIdentity,
        expectedRecords: DocumentSyncRecoveryRecords,
        expectedGeneration: UInt64
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await enqueueMigration(
            MigrationCommand(
                sourceIdentity: sourceIdentity,
                destinationIdentity: destinationIdentity,
                expectedRecords: expectedRecords,
                expectedGeneration: expectedGeneration
            )
        )
    }

    func advanceEmptyRecoveryMigration(
        from sourceIdentity: DocumentIdentity,
        to destinationIdentity: DocumentIdentity,
        expectedGeneration: UInt64
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await moveEntries(
            from: sourceIdentity,
            to: destinationIdentity,
            expectedRecords: .empty,
            expectedGeneration: expectedGeneration
        )
    }

    func reconcile(
        _ intent: DocumentSyncRecoveryReconciliationIntent
    ) async throws -> SessionRecoveryStoreReconciliationReceipt {
        try await enqueueReconciliation(intent)
    }

    /// Reconciles one uncertain commit through the recovery owner's FIFO.
    /// The result is authoritative only when the bound durable journal proves
    /// the request's exact commit identity and irreversible swap state.
    func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest
    ) async -> DocumentSyncCommitReconciliationResult {
        if case .failed = startupStatus {
            return .unresolved
        }
        return await withCheckedContinuation { continuation in
            enqueueStartupForPendingMutationIfNeeded()
            appendCommand(.reconcileCommit(request, continuation))
            beginDrainUnlessStartupFailed()
        }
    }

    private enum Command {
        case startup(CheckedContinuation<SessionRecoveryStoreSnapshot, Error>?)
        case waitForStartup(CheckedContinuation<SessionRecoveryStoreSnapshot, Error>)
        case load(
            DocumentSyncRecoveryLoadScope,
            CheckedContinuation<SessionRecoveryStoreLoadReceipt, Error>
        )
        case persistSnapshot(
            SnapshotPersistenceCommand,
            CheckedContinuation<SessionRecoveryStoreMutationReceipt, Error>
        )
        case persistRaw(
            RawPersistenceCommand,
            CheckedContinuation<SessionRecoveryStoreRawMutationReceipt, Error>
        )
        case migrate(
            MigrationCommand,
            CheckedContinuation<SessionRecoveryStoreMutationReceipt, Error>
        )
        case discard(
            DiscardCommand,
            CheckedContinuation<SessionRecoveryStoreMutationReceipt, Error>
        )
        case reconcile(
            DocumentSyncRecoveryReconciliationIntent,
            CheckedContinuation<SessionRecoveryStoreReconciliationReceipt, Error>
        )
        case reconcileCommit(
            DocumentSyncCommitReconciliationRequest,
            CheckedContinuation<DocumentSyncCommitReconciliationResult, Never>
        )

        var kind: SessionRecoveryStoreCommandKind {
            switch self {
            case .startup:
                .startup
            case .waitForStartup:
                .waitForStartup
            case .load:
                .load
            case .persistSnapshot:
                .persistSnapshot
            case .persistRaw:
                .persistRaw
            case .migrate:
                .migrate
            case .discard:
                .discard
            case .reconcile:
                .reconcile
            case .reconcileCommit:
                .reconcileCommit
            }
        }
    }

    private struct SnapshotPersistenceCommand: Sendable {
        let id: UUID
        let snapshot: DocumentSnapshot
        let identity: DocumentIdentity
        let expectedRecords: DocumentSyncRecoveryRecords?
        let expectedGeneration: UInt64?
    }

    private struct RawPersistenceCommand: Sendable {
        let id: UUID
        let data: Data
        let identity: DocumentIdentity
        let expectedRecords: DocumentSyncRecoveryRecords?
        let expectedGeneration: UInt64?
        let recoveryArtifact: CommitRecoveryArtifact?
    }

    private struct MigrationCommand: Sendable {
        let sourceIdentity: DocumentIdentity
        let destinationIdentity: DocumentIdentity
        let expectedRecords: DocumentSyncRecoveryRecords
        let expectedGeneration: UInt64
    }

    private struct DiscardCommand: Sendable {
        let target: DocumentSyncRecoveryDiscardTarget
        let identity: DocumentIdentity
        let expectedRecords: DocumentSyncRecoveryRecords
        let expectedGeneration: UInt64
    }

    private func enqueueStartupIfNeeded() {
        guard !startupCommandQueued else { return }
        startupCommandQueued = true
        appendCommand(.startup(nil))
    }

    private func appendCommand(_ command: Command) {
        commands.append(command)
        commandEnqueueHook?.hook(command.kind)
    }

    private func insertCommand(_ command: Command, at index: Int) {
        commands.insert(command, at: index)
        commandEnqueueHook?.hook(command.kind)
    }

    private func beginDrainIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !commands.isEmpty {
            let command = commands.removeFirst()
            switch command {
            case .startup(let continuation):
                startupCommandQueued = false
                do {
                    let imported = try await importStartupState()
                    try startupCompletionHook?.hook()
                    entries = imported.entries
                    rawEntries = imported.rawEntries
                    mutationGenerations = imported.generations
                    startupStatus = .ready(generation: currentGeneration)
                    continuation?.resume(returning: snapshot())
                } catch {
                    let issue = recoveryIssue(from: error)
                    startupStatus = .failed(issue)
                    continuation?.resume(throwing: issue)
                    failQueuedReadCommands(with: issue)
                    isDraining = false
                    return
                }
            case .waitForStartup(let continuation):
                switch startupStatus {
                case .ready:
                    continuation.resume(returning: snapshot())
                case .failed(let issue):
                    continuation.resume(throwing: issue)
                case .loading:
                    insertCommand(.waitForStartup(continuation), at: 0)
                    isDraining = false
                    return
                }
            case .load(let scope, let continuation):
                guard case .ready = startupStatus else {
                    let issue = failedIssueOrUnavailable()
                    continuation.resume(throwing: issue)
                    continue
                }
                continuation.resume(returning: loadReceipt(scope: scope))
            case .persistSnapshot(let request, let continuation):
                await resume(continuation) {
                    try await self.persistSnapshot(request)
                }
            case .persistRaw(let request, let continuation):
                await resume(continuation) {
                    try await self.persistRaw(request)
                }
            case .migrate(let request, let continuation):
                await resume(continuation) {
                    try await self.migrate(request)
                }
            case .discard(let request, let continuation):
                await resume(continuation) {
                    try await self.discard(request)
                }
            case .reconcile(let intent, let continuation):
                await resume(continuation) {
                    try await self.reconcileFromDisk(intent)
                }
            case .reconcileCommit(let request, let continuation):
                do {
                    continuation.resume(
                        returning: try await reconcileCommitFromDisk(request)
                    )
                } catch {
                    continuation.resume(returning: .unresolved)
                }
            }
        }
        isDraining = false
    }

    private func resume<Value>(
        _ continuation: CheckedContinuation<Value, Error>,
        operation: () async throws -> Value
    ) async {
        do {
            continuation.resume(returning: try await operation())
        } catch {
            continuation.resume(throwing: recoveryIssue(from: error))
        }
    }

    private func failQueuedReadCommands(with issue: RecoveryStoreIssue) {
        var retained: [Command] = []
        for command in commands {
            switch command {
            case .waitForStartup(let continuation):
                continuation.resume(throwing: issue)
            case .load(_, let continuation):
                continuation.resume(throwing: issue)
            case .startup(let continuation):
                continuation?.resume(throwing: issue)
            case .reconcileCommit(_, let continuation):
                continuation.resume(returning: .unresolved)
            case .persistSnapshot, .persistRaw, .migrate, .discard, .reconcile:
                retained.append(command)
            }
        }
        commands = retained
    }

    private func enqueueSnapshotPersistence(
        _ request: SnapshotPersistenceCommand
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await withCheckedThrowingContinuation { continuation in
            enqueueStartupForPendingMutationIfNeeded()
            appendCommand(.persistSnapshot(request, continuation))
            beginDrainUnlessStartupFailed()
        }
    }

    private func enqueueRawPersistence(
        _ request: RawPersistenceCommand
    ) async throws -> SessionRecoveryStoreRawMutationReceipt {
        try await withCheckedThrowingContinuation { continuation in
            enqueueStartupForPendingMutationIfNeeded()
            appendCommand(.persistRaw(request, continuation))
            beginDrainUnlessStartupFailed()
        }
    }

    private func enqueueMigration(
        _ request: MigrationCommand
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await withCheckedThrowingContinuation { continuation in
            enqueueStartupForPendingMutationIfNeeded()
            appendCommand(.migrate(request, continuation))
            beginDrainUnlessStartupFailed()
        }
    }

    private func enqueueDiscard(
        _ request: DiscardCommand
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try await withCheckedThrowingContinuation { continuation in
            enqueueStartupForPendingMutationIfNeeded()
            appendCommand(.discard(request, continuation))
            beginDrainUnlessStartupFailed()
        }
    }

    private func enqueueReconciliation(
        _ intent: DocumentSyncRecoveryReconciliationIntent
    ) async throws -> SessionRecoveryStoreReconciliationReceipt {
        try await withCheckedThrowingContinuation { continuation in
            enqueueStartupForPendingMutationIfNeeded()
            appendCommand(.reconcile(intent, continuation))
            beginDrainUnlessStartupFailed()
        }
    }

    /// A failed import deliberately leaves mutation intent suspended until an
    /// explicit retry. Re-enqueuing startup here would silently erase the
    /// user's retry boundary and could keep touching malformed evidence.
    private func enqueueStartupForPendingMutationIfNeeded() {
        guard case .loading = startupStatus else { return }
        enqueueStartupIfNeeded()
    }

    private func beginDrainUnlessStartupFailed() {
        guard case .failed = startupStatus else {
            beginDrainIfNeeded()
            return
        }
    }

    private func importStartupState() async throws -> PersistedState {
        let migrationHook = migrationWriteHook
        let startupHook = startupReadHook
        let persistenceDirectory = persistenceDirectory
        return try await fileAccessLane.perform {
            try startupHook?.hook()
            guard let persistenceDirectory else {
                return PersistedState(
                    entries: [],
                    rawEntries: [],
                    generations: [:],
                    acknowledgedArtifacts: []
                )
            }
            return try Self.importPersistedState(
                from: persistenceDirectory,
                migrationWriteHook: migrationHook
            )
        }
    }

    private func persistSnapshot(
        _ request: SnapshotPersistenceCommand
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try requireReady()
        try await reconcilePendingTransactionsIfNeeded()
        try validateMutation(
            identity: request.identity,
            expectedGeneration: request.expectedGeneration,
            expectedRecords: request.expectedRecords
        )
        guard !entries.contains(where: { $0.id == request.id }),
            !rawEntries.contains(where: { $0.id == request.id })
        else {
            throw RecoveryStoreIssue.conflictingEntryID
        }
        guard perDocumentLimit > 0 else {
            throw RecoveryStoreIssue.recoveryEntryEvicted
        }

        let entry = RecoveryEntry(
            id: request.id,
            documentIdentity: request.identity,
            snapshot: request.snapshot,
            createdAt: Date()
        )
        let proposedEntries = [entry] + entries
        let trim = Self.trim(
            proposedEntries,
            perDocumentLimit: perDocumentLimit,
            totalByteLimit: totalByteLimit
        )
        guard trim.entries.contains(entry) else {
            throw RecoveryStoreIssue.recoveryEntryEvicted
        }
        let affectedIdentities = Set(
            trim.removed.map(\.documentIdentity) + [request.identity]
        )
        let previousGenerations = mutationGenerations
        let previousGeneration = currentGeneration(for: request.identity)
        let nextGenerations = try advancingGenerations(
            for: affectedIdentities,
            from: previousGenerations
        )

        if let persistenceDirectory {
            let removedURLs = trim.removed.map {
                Self.snapshotURL(for: $0.id, in: persistenceDirectory)
            }
            try await fileAccessLane.perform {
                try Self.persist(entry, in: persistenceDirectory)
                try Self.commitDeletion(
                    of: removedURLs,
                    in: persistenceDirectory,
                    previousGenerations: previousGenerations,
                    nextGenerations: nextGenerations
                )
            }
        }
        entries = trim.entries
        mutationGenerations = nextGenerations
        return mutationReceipt(for: request.identity, previous: previousGeneration)
    }

    private func persistRaw(
        _ request: RawPersistenceCommand
    ) async throws -> SessionRecoveryStoreRawMutationReceipt {
        try requireReady()
        try TextFileCodec.validateSupportedSize(request.data)
        try await reconcilePendingTransactionsIfNeeded()
        try validateMutation(
            identity: request.identity,
            expectedGeneration: request.expectedGeneration,
            expectedRecords: request.expectedRecords
        )
        guard !entries.contains(where: { $0.id == request.id }),
            !rawEntries.contains(where: { $0.id == request.id })
        else {
            throw RecoveryStoreIssue.conflictingEntryID
        }

        let createdAt = Date()
        let fingerprint = FileFingerprint.make(data: request.data)
        let entry = RawRecoveryEntry(
            id: request.id,
            documentIdentity: request.identity,
            dataURL: persistenceDirectory.map {
                Self.rawDataURL(for: request.id, in: $0)
            },
            byteCount: request.data.count,
            contentDigest: fingerprint.contentDigest,
            createdAt: createdAt,
            residentData: shouldKeepRawDataResident(request.data)
                ? request.data
                : nil,
            acknowledgedRecoveryArtifactID: request.recoveryArtifact?.id
        )
        let previousGeneration = currentGeneration(for: request.identity)
        let nextGenerations = try advancingGenerations(
            for: [request.identity],
            from: mutationGenerations
        )

        if let persistenceDirectory {
            let artifact = request.recoveryArtifact
            let rawPersistenceHook = rawPersistenceHook
            try await fileAccessLane.perform {
                try rawPersistenceHook?.hook(.beforeRawPersistence)
                try Self.persistRaw(
                    entry,
                    data: request.data,
                    intendedArtifactID: artifact?.id,
                    acknowledgedArtifactID: nil,
                    in: persistenceDirectory
                )
                if let artifact {
                    try rawPersistenceHook?.hook(
                        .beforeAcknowledgementMetadata
                    )
                    try Self.persistRawMetadata(
                        entry,
                        intendedArtifactID: artifact.id,
                        acknowledgedArtifactID: artifact.id,
                        in: persistenceDirectory
                    )
                    try rawPersistenceHook?.hook(
                        .afterAcknowledgementMetadata
                    )
                    try CommitRecoveryJournalStore.acknowledge(artifact)
                }
                try Self.persistGenerationIndex(
                    nextGenerations,
                    in: persistenceDirectory
                )
            }
        }
        rawEntries.insert(entry, at: 0)
        mutationGenerations = nextGenerations
        let receipt = mutationReceipt(
            for: request.identity,
            previous: previousGeneration
        )
        return SessionRecoveryStoreRawMutationReceipt(
            mutation: receipt,
            entry: entry,
            acknowledgedRecoveryArtifact: request.recoveryArtifact
        )
    }

    private func migrate(
        _ request: MigrationCommand
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try requireReady()
        try await reconcilePendingTransactionsIfNeeded()
        guard request.sourceIdentity != request.destinationIdentity else {
            try validateMutation(
                identity: request.sourceIdentity,
                expectedGeneration: request.expectedGeneration,
                expectedRecords: request.expectedRecords
            )
            let nextGenerations = try advancingGenerations(
                for: [request.sourceIdentity],
                from: mutationGenerations
            )
            let previous = currentGeneration(for: request.sourceIdentity)
            if let persistenceDirectory {
                try await fileAccessLane.perform {
                    try Self.persistGenerationIndex(
                        nextGenerations,
                        in: persistenceDirectory
                    )
                }
            }
            mutationGenerations = nextGenerations
            return mutationReceipt(for: request.sourceIdentity, previous: previous)
        }

        try validateMutation(
            identity: request.sourceIdentity,
            expectedGeneration: request.expectedGeneration,
            expectedRecords: request.expectedRecords
        )
        guard storedRecords(for: request.destinationIdentity).isEmpty else {
            throw RecoveryStoreIssue.unexpectedRecoveryRecords
        }
        let movingEntries = entries.filter {
            $0.documentIdentity == request.sourceIdentity
        }
        let movingRawEntries = rawEntries.filter {
            $0.documentIdentity == request.sourceIdentity
        }
        let movedEntries = entries.map { entry in
            guard entry.documentIdentity == request.sourceIdentity else {
                return entry
            }
            return RecoveryEntry(
                id: entry.id,
                documentIdentity: request.destinationIdentity,
                snapshot: entry.snapshot,
                createdAt: entry.createdAt
            )
        }
        let movedRawEntries = rawEntries.map { entry in
            guard entry.documentIdentity == request.sourceIdentity else {
                return entry
            }
            return RawRecoveryEntry(
                id: entry.id,
                documentIdentity: request.destinationIdentity,
                dataURL: entry.dataURL,
                byteCount: entry.byteCount,
                contentDigest: entry.contentDigest,
                createdAt: entry.createdAt,
                residentData: entry.residentData,
                acknowledgedRecoveryArtifactID: entry.acknowledgedRecoveryArtifactID
            )
        }
        let previousGeneration = currentGeneration(for: request.sourceIdentity)
        let destinationPreviousGeneration = currentGeneration(
            for: request.destinationIdentity
        )
        // Migration consumes the source's compare-and-swap generation, while
        // the returned generation belongs to the destination identity. A
        // destination can be empty yet have a higher historical generation;
        // allocating from both counters keeps stale destination effects
        // permanently invalid after a relocation.
        let destinationNextGeneration = max(
            previousGeneration,
            destinationPreviousGeneration
        )
        guard destinationNextGeneration < UInt64.max else {
            throw RecoveryStoreIssue.mutationGenerationExhausted
        }
        let previousGenerations = mutationGenerations
        let nextGenerations: [String: UInt64] = {
            var values = previousGenerations
            // Preserve a source tombstone generation. Removing the key would
            // recreate generation zero and allow a stale source mutation to
            // become valid after its recovery records moved away.
            values[request.sourceIdentity.stableKey] = previousGeneration + 1
            values[request.destinationIdentity.stableKey] =
                destinationNextGeneration + 1
            return values
        }()

        if let persistenceDirectory {
            let migration = PersistedRecoveryMigration(
                sourceKey: request.sourceIdentity.stableKey,
                destinationKey: request.destinationIdentity.stableKey,
                snapshotIDs: movingEntries.map(\.id),
                rawIDs: movingRawEntries.map(\.id),
                phase: .preparing,
                previousGenerations: previousGenerations,
                nextGenerations: nextGenerations
            )
            let hook = migrationWriteHook
            try await fileAccessLane.perform {
                try Self.persistMigration(migration, in: persistenceDirectory)
                var writeCount = 0
                for entry in movedEntries
                where entry.documentIdentity == request.destinationIdentity {
                    try Self.persist(entry, in: persistenceDirectory)
                    writeCount += 1
                    try hook?.hook(writeCount)
                }
                for entry in movedRawEntries
                where entry.documentIdentity == request.destinationIdentity {
                    try Self.persistRawMetadata(
                        entry,
                        intendedArtifactID: entry.acknowledgedRecoveryArtifactID,
                        acknowledgedArtifactID: entry.acknowledgedRecoveryArtifactID,
                        in: persistenceDirectory
                    )
                    writeCount += 1
                    try hook?.hook(writeCount)
                }
                try Self.persistMigration(migration.committed, in: persistenceDirectory)
                try Self.persistGenerationIndex(nextGenerations, in: persistenceDirectory)
                try Self.removeMigration(in: persistenceDirectory)
            }
        }
        entries = movedEntries
        rawEntries = movedRawEntries
        mutationGenerations = nextGenerations
        return mutationReceipt(
            for: request.destinationIdentity,
            previous: previousGeneration
        )
    }

    private func discard(
        _ request: DiscardCommand
    ) async throws -> SessionRecoveryStoreMutationReceipt {
        try requireReady()
        try await reconcilePendingTransactionsIfNeeded()
        try validateMutation(
            identity: request.identity,
            expectedGeneration: request.expectedGeneration,
            expectedRecords: request.expectedRecords
        )
        let currentRecords = storedRecords(for: request.identity)
            .asDocumentSyncRecords
        guard
            let remaining = Self.recordsAfterDiscard(
                request.target,
                from: currentRecords
            )
        else {
            throw RecoveryStoreIssue.missingRecoveryEntry
        }
        let removingDecoded = Set(currentRecords.decoded.map(\.id)).subtracting(
            Set(remaining.decoded.map(\.id))
        )
        let removingRaw = Set(currentRecords.raw.map(\.id)).subtracting(
            Set(remaining.raw.map(\.id))
        )
        let nextEntries = entries.filter { !removingDecoded.contains($0.id) }
        let nextRawEntries = rawEntries.filter { !removingRaw.contains($0.id) }
        let previousGeneration = currentGeneration(for: request.identity)
        let previousGenerations = mutationGenerations
        let nextGenerations = try advancingGenerations(
            for: [request.identity],
            from: previousGenerations
        )
        if let persistenceDirectory {
            let deletionURLs =
                removingDecoded.map {
                    Self.snapshotURL(for: $0, in: persistenceDirectory)
                }
                + removingRaw.flatMap { id in
                    [
                        Self.rawDataURL(for: id, in: persistenceDirectory),
                        Self.rawMetadataURL(for: id, in: persistenceDirectory),
                    ]
                }
            try await fileAccessLane.perform {
                try Self.commitDeletion(
                    of: deletionURLs,
                    in: persistenceDirectory,
                    previousGenerations: previousGenerations,
                    nextGenerations: nextGenerations
                )
            }
        }
        entries = nextEntries
        rawEntries = nextRawEntries
        mutationGenerations = nextGenerations
        return mutationReceipt(for: request.identity, previous: previousGeneration)
    }

    private func reconcileFromDisk(
        _ intent: DocumentSyncRecoveryReconciliationIntent
    ) async throws -> SessionRecoveryStoreReconciliationReceipt {
        guard let persistenceDirectory else {
            return reconciliationReceipt(for: intent, acknowledgedArtifact: nil)
        }
        let hook = migrationWriteHook
        let imported = try await fileAccessLane.perform {
            try Self.importPersistedState(
                from: persistenceDirectory,
                migrationWriteHook: hook
            )
        }
        entries = imported.entries
        rawEntries = imported.rawEntries
        mutationGenerations = imported.generations
        let acknowledgedArtifact: CommitRecoveryArtifact?
        if case .persist(_, _, let payload, _, _, _, _) = intent,
            case .raw(let rawPayload) = payload,
            let artifact = rawPayload.recoveryArtifact,
            imported.acknowledgedArtifacts.contains(artifact.id)
                || rawEntries.contains(where: {
                    $0.id == artifact.id
                        && $0.acknowledgedRecoveryArtifactID == artifact.id
                })
        {
            acknowledgedArtifact = artifact
        } else {
            acknowledgedArtifact = nil
        }
        return reconciliationReceipt(
            for: intent,
            acknowledgedArtifact: acknowledgedArtifact
        )
    }

    private func reconcileCommitFromDisk(
        _ request: DocumentSyncCommitReconciliationRequest
    ) async throws -> DocumentSyncCommitReconciliationResult {
        try requireReady()
        guard let persistenceDirectory else {
            return .unresolved
        }
        return try await fileAccessLane.perform {
            try CommitRecoveryJournalStore.reconcileCommit(
                request,
                in: persistenceDirectory
            )
        }
    }

    /// A failed migration or deletion can leave its journal and partially
    /// applied filesystem state on disk while the actor still holds an older
    /// index. No later command may overwrite either journal. Re-importing
    /// through the same durable recovery routine either repairs it before
    /// this command runs or fails closed with the original bytes intact.
    private func reconcilePendingTransactionsIfNeeded() async throws {
        guard let persistenceDirectory else { return }
        let migrationURL = Self.migrationURL(in: persistenceDirectory)
        let deletionURL = Self.deletionURL(in: persistenceDirectory)
        let pendingJournal: PendingRecoveryJournal? =
            try await fileAccessLane.perform {
                if FileManager.default.fileExists(atPath: migrationURL.path) {
                    return PendingRecoveryJournal.migration
                }
                if FileManager.default.fileExists(atPath: deletionURL.path) {
                    return PendingRecoveryJournal.deletion
                }
                return nil as PendingRecoveryJournal?
            }
        guard let pendingJournal else { return }

        let hook = migrationWriteHook
        do {
            let imported = try await fileAccessLane.perform {
                try Self.importPersistedState(
                    from: persistenceDirectory,
                    migrationWriteHook: hook
                )
            }
            entries = imported.entries
            rawEntries = imported.rawEntries
            mutationGenerations = imported.generations
        } catch let issue as RecoveryStoreIssue where issue == .malformedData {
            switch pendingJournal {
            case .migration:
                throw RecoveryStoreIssue.unreadableMigrationJournal
            case .deletion:
                throw RecoveryStoreIssue.unreadableDeletionJournal
            }
        }
    }

    private func reconciliationReceipt(
        for intent: DocumentSyncRecoveryReconciliationIntent,
        acknowledgedArtifact: CommitRecoveryArtifact?
    ) -> SessionRecoveryStoreReconciliationReceipt {
        let identity: DocumentIdentity
        switch intent {
        case .persist(let identityValue, _, _, _, _, _, _),
            .discard(let identityValue, _, _, _, _):
            identity = identityValue
        case .migrate(let source, let destination, let expectedRecords, _):
            let destinationRecords = storedRecords(for: destination)
                .asDocumentSyncRecords
            let moved = Self.migratedRecords(
                expectedRecords,
                to: destination
            )
            identity = destinationRecords == moved ? destination : source
        }
        let resultRecords = storedRecords(for: identity)
        return SessionRecoveryStoreReconciliationReceipt(
            identity: identity,
            generation: currentGeneration(for: identity),
            records: resultRecords,
            acknowledgedRecoveryArtifact: acknowledgedArtifact
        )
    }

    private func requireReady() throws {
        guard case .ready = startupStatus else {
            throw failedIssueOrUnavailable()
        }
    }

    private func failedIssueOrUnavailable() -> RecoveryStoreIssue {
        if case .failed(let issue) = startupStatus {
            return issue
        }
        return .unavailable
    }

    private func validateMutation(
        identity: DocumentIdentity,
        expectedGeneration: UInt64?,
        expectedRecords: DocumentSyncRecoveryRecords?
    ) throws {
        if let expectedGeneration,
            currentGeneration(for: identity) != expectedGeneration
        {
            throw RecoveryStoreIssue.unexpectedMutationGeneration
        }
        if let expectedRecords,
            storedRecords(for: identity).asDocumentSyncRecords != expectedRecords
        {
            throw RecoveryStoreIssue.unexpectedRecoveryRecords
        }
    }

    private func storedRecords(
        for identity: DocumentIdentity
    ) -> SessionRecoveryStoreRecords {
        SessionRecoveryStoreRecords(
            decoded: entries.filter { $0.documentIdentity == identity },
            raw: rawEntries.filter { $0.documentIdentity == identity }
        )
    }

    private func loadReceipt(
        scope: DocumentSyncRecoveryLoadScope
    ) -> SessionRecoveryStoreLoadReceipt {
        switch scope {
        case .unattached:
            SessionRecoveryStoreLoadReceipt(
                scope: scope,
                generation: 0,
                records: .empty
            )
        case .document(let identity):
            SessionRecoveryStoreLoadReceipt(
                scope: scope,
                generation: currentGeneration(for: identity),
                records: storedRecords(for: identity)
            )
        }
    }

    private func snapshot() -> SessionRecoveryStoreSnapshot {
        SessionRecoveryStoreSnapshot(
            decodedEntries: entries,
            rawEntries: rawEntries,
            generations: mutationGenerations
        )
    }

    private var currentGeneration: UInt64 {
        mutationGenerations.values.max() ?? 0
    }

    private func currentGeneration(for identity: DocumentIdentity) -> UInt64 {
        mutationGenerations[identity.stableKey, default: 0]
    }

    private func mutationReceipt(
        for identity: DocumentIdentity,
        previous: UInt64
    ) -> SessionRecoveryStoreMutationReceipt {
        let records = storedRecords(for: identity)
        return SessionRecoveryStoreMutationReceipt(
            previousGeneration: previous,
            generation: currentGeneration(for: identity),
            decodedEntries: records.decoded,
            rawEntries: records.raw
        )
    }

    private func shouldKeepRawDataResident(_ data: Data) -> Bool {
        let residentBytes = rawEntries.reduce(into: 0) { total, entry in
            total += entry.residentData?.count ?? 0
        }
        return residentBytes + data.count <= Self.maximumResidentRawRecoveryBytes
    }

    private func advancingGenerations(
        for identities: Set<DocumentIdentity>,
        from current: [String: UInt64]
    ) throws -> [String: UInt64] {
        var next = current
        for identity in identities {
            let generation = current[identity.stableKey, default: 0]
            guard generation < UInt64.max else {
                throw RecoveryStoreIssue.mutationGenerationExhausted
            }
            next[identity.stableKey] = generation + 1
        }
        return next
    }

    private func recoveryIssue(from error: Error) -> RecoveryStoreIssue {
        if let issue = error as? RecoveryStoreIssue {
            return issue
        }
        if let error = error as? CommitRecoveryJournalStore.JournalError {
            switch error {
            case .malformedJournal:
                return .malformedData
            case .unsupportedSchema:
                return .unsupportedSchema
            case .invalidArtifactPath, .unownedReplacementDirectory:
                return .unavailable
            }
        }
        return .unavailable
    }
}
