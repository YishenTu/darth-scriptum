import Foundation

extension SessionRecoveryStore {
    static func persistMigration(
        _ migration: PersistedRecoveryMigration,
        in directory: URL
    ) throws {
        try DurableFileIO.createDirectory(at: directory)
        try DurableFileIO.writeAtomically(
            try RecoveryJSONEncoding.encode(migration),
            to: migrationURL(in: directory)
        )
    }

    static func removeMigration(in directory: URL) throws {
        let url = migrationURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try DurableFileIO.removeDurably(at: url)
    }

    static func recoverPersistedMigration(
        state: inout PersistedState,
        in directory: URL,
        migrationWriteHook: MigrationWriteHookBox?
    ) throws {
        let url = migrationURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let migration: PersistedRecoveryMigration
        do {
            migration = try JSONDecoder().decode(PersistedRecoveryMigration.self, from: data)
        } catch {
            throw RecoveryStoreIssue.malformedData
        }
        try migration.validateSchema()
        let recoveredGenerations = try migration.recoveredGenerations(
            from: state.generations
        )
        let snapshotIDs = Set(migration.snapshotIDs)
        let rawIDs = Set(migration.rawIDs)
        let persistedSnapshotIDs = Set(state.entries.map(\.id))
        let persistedRawIDs = Set(state.rawEntries.map(\.id))
        guard persistedSnapshotIDs.isSuperset(of: snapshotIDs),
            persistedRawIDs.isSuperset(of: rawIDs)
        else {
            throw RecoveryStoreIssue.malformedData
        }
        let permittedKeys: Set<String>
        switch migration.phase {
        case .preparing:
            // A crash may occur after only some metadata writes, so selected
            // records may be under the source or destination identity. Any
            // third identity is unrelated evidence and must never be relabeled.
            permittedKeys = [migration.sourceKey, migration.destinationKey]
        case .committed:
            // The committed marker is written only after every selected record
            // has been durably rewritten for the destination.
            permittedKeys = [migration.destinationKey]
        }
        guard
            state.entries
                .filter({ snapshotIDs.contains($0.id) })
                .allSatisfy({ permittedKeys.contains($0.documentIdentity.stableKey) }),
            state.rawEntries
                .filter({ rawIDs.contains($0.id) })
                .allSatisfy({ permittedKeys.contains($0.documentIdentity.stableKey) })
        else {
            throw RecoveryStoreIssue.malformedData
        }
        let identity = DocumentIdentity(
            stableKey: migration.phase == .committed
                ? migration.destinationKey
                : migration.sourceKey
        )
        state.entries = state.entries.map { entry in
            guard snapshotIDs.contains(entry.id) else { return entry }
            return RecoveryEntry(
                id: entry.id,
                documentIdentity: identity,
                snapshot: entry.snapshot,
                createdAt: entry.createdAt
            )
        }
        state.rawEntries = state.rawEntries.map { entry in
            guard rawIDs.contains(entry.id) else { return entry }
            return RawRecoveryEntry(
                id: entry.id,
                documentIdentity: identity,
                dataURL: entry.dataURL,
                byteCount: entry.byteCount,
                contentDigest: entry.contentDigest,
                createdAt: entry.createdAt,
                residentData: entry.residentData,
                acknowledgedRecoveryArtifactID: entry.acknowledgedRecoveryArtifactID
            )
        }
        var writeCount = 0
        for entry in state.entries where snapshotIDs.contains(entry.id) {
            try persist(entry, in: directory)
            writeCount += 1
            try migrationWriteHook?.hook(writeCount)
        }
        for entry in state.rawEntries where rawIDs.contains(entry.id) {
            try persistRawMetadata(
                entry,
                intendedArtifactID: entry.acknowledgedRecoveryArtifactID,
                acknowledgedArtifactID: entry.acknowledgedRecoveryArtifactID,
                in: directory
            )
            writeCount += 1
            try migrationWriteHook?.hook(writeCount)
        }
        if let generations = recoveredGenerations {
            state.generations = generations
            try persistGenerationIndex(generations, in: directory)
        }
        try removeMigration(in: directory)
    }
}

struct PersistedRecoveryMigration: Codable {
    enum Phase: String, Codable {
        case preparing
        case committed
    }

    let schemaVersion: Int?
    let sourceKey: String
    let destinationKey: String
    let snapshotIDs: [UUID]
    let rawIDs: [UUID]
    let phase: Phase
    let previousGenerations: [String: UInt64]?
    let nextGenerations: [String: UInt64]?

    init(
        sourceKey: String,
        destinationKey: String,
        snapshotIDs: [UUID],
        rawIDs: [UUID],
        phase: Phase,
        previousGenerations: [String: UInt64]?,
        nextGenerations: [String: UInt64]?
    ) {
        schemaVersion = SessionRecoveryStore.currentSchemaVersion
        self.sourceKey = sourceKey
        self.destinationKey = destinationKey
        self.snapshotIDs = snapshotIDs
        self.rawIDs = rawIDs
        self.phase = phase
        self.previousGenerations = previousGenerations
        self.nextGenerations = nextGenerations
    }

    var committed: PersistedRecoveryMigration {
        PersistedRecoveryMigration(
            sourceKey: sourceKey,
            destinationKey: destinationKey,
            snapshotIDs: snapshotIDs,
            rawIDs: rawIDs,
            phase: .committed,
            previousGenerations: previousGenerations,
            nextGenerations: nextGenerations
        )
    }

    func validateSchema() throws {
        if let schemaVersion,
            schemaVersion > SessionRecoveryStore.currentSchemaVersion
        {
            throw RecoveryStoreIssue.unsupportedSchema
        }
        let snapshotIDSet = Set(snapshotIDs)
        let rawIDSet = Set(rawIDs)
        guard sourceKey != destinationKey,
            snapshotIDSet.count == snapshotIDs.count,
            Set(rawIDs).count == rawIDs.count,
            snapshotIDSet.isDisjoint(with: rawIDSet),
            !sourceKey.isEmpty,
            !destinationKey.isEmpty
        else {
            throw RecoveryStoreIssue.malformedData
        }
    }

    /// Current-schema migration journals carry a complete generation index.
    /// Replaying one must be an exact transition from the durable index, never
    /// an authority to replace unrelated counters with journal-provided data.
    func recoveredGenerations(
        from current: [String: UInt64]
    ) throws -> [String: UInt64]? {
        switch (previousGenerations, nextGenerations) {
        case (nil, nil):
            // The first journal format predates durable mutation generations.
            // Preserve that compatibility only for explicitly older formats;
            // a current-schema omission is malformed rather than ambiguous.
            guard let schemaVersion,
                schemaVersion < SessionRecoveryStore.currentSchemaVersion
            else {
                throw RecoveryStoreIssue.malformedData
            }
            return nil
        case (.some(let previous), .some(let next)):
            let sourceGeneration = previous[sourceKey, default: 0]
            let destinationGeneration = previous[destinationKey, default: 0]
            let destinationBase = max(sourceGeneration, destinationGeneration)
            guard sourceGeneration < UInt64.max,
                destinationBase < UInt64.max
            else {
                throw RecoveryStoreIssue.malformedData
            }
            var expectedNext = previous
            expectedNext[sourceKey] = sourceGeneration + 1
            expectedNext[destinationKey] = destinationBase + 1
            guard next == expectedNext else {
                throw RecoveryStoreIssue.malformedData
            }
            switch phase {
            case .preparing:
                guard current == previous else {
                    throw RecoveryStoreIssue.malformedData
                }
                return previous
            case .committed:
                guard current == previous || current == next else {
                    throw RecoveryStoreIssue.malformedData
                }
                return next
            }
        case (.some, nil), (nil, .some):
            throw RecoveryStoreIssue.malformedData
        }
    }
}
