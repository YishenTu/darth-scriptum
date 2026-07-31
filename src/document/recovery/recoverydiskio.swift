import Foundation

struct PersistedState: Sendable {
    var entries: [RecoveryEntry]
    var rawEntries: [RawRecoveryEntry]
    var generations: [String: UInt64]
    var acknowledgedArtifacts: Set<UUID>
}

extension SessionRecoveryStoreRecords {
    var asDocumentSyncRecords: DocumentSyncRecoveryRecords {
        DocumentSyncRecoveryRecords(
            decoded: decoded,
            raw: raw.map(DocumentSyncRawRecoveryReference.init)
        )
    }
}

extension SessionRecoveryStore {
    static let currentSchemaVersion = 2

    static func importPersistedState(
        from directory: URL,
        migrationWriteHook: MigrationWriteHookBox?
    ) throws -> PersistedState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return PersistedState(
                entries: [],
                rawEntries: [],
                generations: [:],
                acknowledgedArtifacts: []
            )
        }
        var state = PersistedState(
            entries: [],
            rawEntries: [],
            generations: [:],
            acknowledgedArtifacts: []
        )
        state.generations = try loadGenerationIndex(in: directory)
        try recoverPersistedDeletion(
            in: directory,
            generations: &state.generations
        )
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let rawPayloadURLs = urls.filter {
            $0.lastPathComponent.hasSuffix(".raw")
        }
        let rawMetadataNames = Set(
            urls.filter { $0.lastPathComponent.hasSuffix(".raw.json") }
                .map(\.lastPathComponent)
        )
        for url in rawPayloadURLs {
            let name = url.lastPathComponent
            let identifierText = String(name.dropLast(".raw".count))
            guard let identifier = UUID(uuidString: identifierText),
                  rawDataURL(for: identifier, in: directory).lastPathComponent
                    == name,
                  rawMetadataNames.contains(
                    rawMetadataURL(for: identifier, in: directory).lastPathComponent
                  ) else {
                // A payload without its durable metadata may be an interrupted
                // write. Keep both bytes and the recovery boundary paused so a
                // retry or newer version can resolve it explicitly.
                throw RecoveryStoreIssue.malformedData
            }
        }
        for url in urls where url.lastPathComponent.hasSuffix(".snapshot.json") {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let persisted: PersistedRecoveryEntry
            do {
                persisted = try JSONDecoder().decode(PersistedRecoveryEntry.self, from: data)
            } catch {
                throw RecoveryStoreIssue.malformedData
            }
            try persisted.validateSchema()
            let entry = try persisted.makeEntry()
            guard snapshotURL(for: entry.id, in: directory).lastPathComponent
                    == url.lastPathComponent else {
                throw RecoveryStoreIssue.malformedData
            }
            guard !state.entries.contains(where: { $0.id == entry.id }),
                  !state.rawEntries.contains(where: { $0.id == entry.id }) else {
                throw RecoveryStoreIssue.malformedData
            }
            state.entries.append(entry)
        }
        for url in urls where url.lastPathComponent.hasSuffix(".raw.json") {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let persisted: PersistedRawRecoveryEntry
            do {
                persisted = try JSONDecoder().decode(PersistedRawRecoveryEntry.self, from: data)
            } catch {
                throw RecoveryStoreIssue.malformedData
            }
            try persisted.validateSchema()
            let dataURL = rawDataURL(for: persisted.id, in: directory)
            guard rawMetadataURL(for: persisted.id, in: directory)
                    .lastPathComponent == url.lastPathComponent,
                  fileManager.fileExists(atPath: dataURL.path) else {
                throw RecoveryStoreIssue.malformedData
            }
            let values = try dataURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  persisted.byteCount == nil || persisted.byteCount == size else {
                throw RecoveryStoreIssue.malformedData
            }
            let rawData = try Data(contentsOf: dataURL, options: [.mappedIfSafe])
            let digest = persisted.contentDigest
                ?? FileFingerprint.make(data: rawData).contentDigest
            guard FileFingerprint.make(data: rawData).contentDigest == digest,
                  !state.entries.contains(where: { $0.id == persisted.id }),
                  !state.rawEntries.contains(where: { $0.id == persisted.id }) else {
                throw RecoveryStoreIssue.malformedData
            }
            state.rawEntries.append(
                RawRecoveryEntry(
                    id: persisted.id,
                    documentIdentity: DocumentIdentity(stableKey: persisted.stableKey),
                    dataURL: dataURL,
                    byteCount: persisted.byteCount ?? size,
                    contentDigest: digest,
                    createdAt: persisted.createdAt,
                    residentData: nil,
                    acknowledgedRecoveryArtifactID:
                        persisted.acknowledgedRecoveryArtifactID
                )
            )
        }
        try recoverPersistedMigration(
            state: &state,
            in: directory,
            migrationWriteHook: migrationWriteHook
        )
        try importPendingCommitRecoveries(state: &state, in: directory)
        state.entries.sort { $0.createdAt > $1.createdAt }
        state.rawEntries.sort { $0.createdAt > $1.createdAt }
        return state
    }

    static func persist(_ entry: RecoveryEntry, in directory: URL) throws {
        try DurableFileIO.createDirectory(at: directory)
        let data = try JSONEncoder.sorted.encode(PersistedRecoveryEntry(entry))
        try DurableFileIO.writeAtomically(data, to: snapshotURL(for: entry.id, in: directory))
    }

    static func persistRaw(
        _ entry: RawRecoveryEntry,
        data: Data,
        intendedArtifactID: UUID?,
        acknowledgedArtifactID: UUID?,
        in directory: URL
    ) throws {
        try DurableFileIO.createDirectory(at: directory)
        try DurableFileIO.writeAtomically(
            data,
            to: rawDataURL(for: entry.id, in: directory)
        )
        try persistRawMetadata(
            entry,
            intendedArtifactID: intendedArtifactID,
            acknowledgedArtifactID: acknowledgedArtifactID,
            in: directory
        )
    }

    static func persistRawMetadata(
        _ entry: RawRecoveryEntry,
        intendedArtifactID: UUID?,
        acknowledgedArtifactID: UUID?,
        in directory: URL
    ) throws {
        try DurableFileIO.createDirectory(at: directory)
        let persisted = PersistedRawRecoveryEntry(
            id: entry.id,
            stableKey: entry.documentIdentity.stableKey,
            byteCount: entry.byteCount,
            contentDigest: entry.contentDigest,
            createdAt: entry.createdAt,
            intendedRecoveryArtifactID: intendedArtifactID,
            acknowledgedRecoveryArtifactID: acknowledgedArtifactID
        )
        try DurableFileIO.writeAtomically(
            try JSONEncoder.sorted.encode(persisted),
            to: rawMetadataURL(for: entry.id, in: directory)
        )
    }

    static func loadGenerationIndex(in directory: URL) throws -> [String: UInt64] {
        let url = generationIndexURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let persisted: PersistedRecoveryGenerationIndex
        do {
            persisted = try JSONDecoder().decode(
                PersistedRecoveryGenerationIndex.self,
                from: data
            )
        } catch {
            throw RecoveryStoreIssue.malformedData
        }
        try persisted.validateSchema()
        return persisted.generations
    }

    static func persistGenerationIndex(
        _ generations: [String: UInt64],
        in directory: URL
    ) throws {
        try DurableFileIO.createDirectory(at: directory)
        try DurableFileIO.writeAtomically(
            try JSONEncoder.sorted.encode(
                PersistedRecoveryGenerationIndex(generations: generations)
            ),
            to: generationIndexURL(in: directory)
        )
    }

    static func persistMigration(
        _ migration: PersistedRecoveryMigration,
        in directory: URL
    ) throws {
        try DurableFileIO.createDirectory(at: directory)
        try DurableFileIO.writeAtomically(
            try JSONEncoder.sorted.encode(migration),
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
              persistedRawIDs.isSuperset(of: rawIDs) else {
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
        guard state.entries
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

    static func importPendingCommitRecoveries(
        state: inout PersistedState,
        in directory: URL
    ) throws {
        for pending in try CommitRecoveryJournalStore.pendingRecoveries(in: directory) {
            let existing = state.rawEntries.first { $0.id == pending.artifact.id }
            if pending.swapCompleted {
                let data: Data
                if let existing {
                    data = try Data(
                        contentsOf: try required(existing.dataURL),
                        options: [.mappedIfSafe]
                    )
                } else {
                    data = try Data(
                        contentsOf: pending.artifact.candidateURL,
                        options: [.mappedIfSafe]
                    )
                }
                if FileFingerprint.make(data: data).contentDigest
                    != pending.expectedContentDigest {
                    let entry = existing ?? RawRecoveryEntry(
                        id: pending.artifact.id,
                        documentIdentity: pending.documentIdentity,
                        dataURL: rawDataURL(for: pending.artifact.id, in: directory),
                        byteCount: data.count,
                        contentDigest: FileFingerprint.make(data: data).contentDigest,
                        createdAt: Date(),
                        residentData: nil,
                        acknowledgedRecoveryArtifactID: nil
                    )
                    if existing?.acknowledgedRecoveryArtifactID
                        != pending.artifact.id {
                        try persistRaw(
                            entry,
                            data: data,
                            intendedArtifactID: pending.artifact.id,
                            acknowledgedArtifactID: nil,
                            in: directory
                        )
                        // The raw acknowledgement is the durable proof that
                        // consuming this journal will not strand the recovery
                        // evidence. Keep the journal until that proof exists.
                        try persistRawMetadata(
                            entry,
                            intendedArtifactID: pending.artifact.id,
                            acknowledgedArtifactID: pending.artifact.id,
                            in: directory
                        )
                    }
                    try CommitRecoveryJournalStore.acknowledge(pending.artifact)
                    state.rawEntries.removeAll { $0.id == entry.id }
                    state.rawEntries.append(
                        RawRecoveryEntry(
                            id: entry.id,
                            documentIdentity: entry.documentIdentity,
                            dataURL: entry.dataURL,
                            byteCount: entry.byteCount,
                            contentDigest: entry.contentDigest,
                            createdAt: entry.createdAt,
                            residentData: nil,
                            acknowledgedRecoveryArtifactID: pending.artifact.id
                        )
                    )
                    state.acknowledgedArtifacts.insert(pending.artifact.id)
                    continue
                }
            }
            try CommitRecoveryJournalStore.acknowledge(pending.artifact)
            if let existing,
               existing.acknowledgedRecoveryArtifactID == pending.artifact.id {
                state.acknowledgedArtifacts.insert(pending.artifact.id)
            }
        }
    }

    static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw RecoveryStoreIssue.malformedData }
        return value
    }

    static func commitDeletion(
        of urls: [URL],
        in directory: URL,
        previousGenerations: [String: UInt64],
        nextGenerations: [String: UInt64]
    ) throws {
        let existingURLs = urls.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existingURLs.isEmpty else {
            try persistGenerationIndex(nextGenerations, in: directory)
            return
        }
        let transaction = PersistedRecoveryDeletion(
            entries: existingURLs.map {
                PersistedRecoveryDeletion.Entry(
                    sourceName: $0.lastPathComponent,
                    tombstoneName: ".\($0.lastPathComponent).\(UUID().uuidString.lowercased()).delete"
                )
            },
            phase: .preparing,
            previousGenerations: previousGenerations,
            nextGenerations: nextGenerations
        )
        try persistDeletion(transaction, in: directory)
        for entry in transaction.entries {
            try DurableFileIO.moveAtomically(
                from: directory.appendingPathComponent(entry.sourceName),
                to: directory.appendingPathComponent(entry.tombstoneName)
            )
        }
        try persistGenerationIndex(nextGenerations, in: directory)
        try persistDeletion(transaction.committed, in: directory)
        for entry in transaction.entries {
            try DurableFileIO.removeDurably(
                at: directory.appendingPathComponent(entry.tombstoneName)
            )
        }
        try removeDeletion(in: directory)
    }

    private static func persistDeletion(
        _ deletion: PersistedRecoveryDeletion,
        in directory: URL
    ) throws {
        try DurableFileIO.writeAtomically(
            try JSONEncoder.sorted.encode(deletion),
            to: deletionURL(in: directory)
        )
    }

    static func removeDeletion(in directory: URL) throws {
        let url = deletionURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try DurableFileIO.removeDurably(at: url)
    }

    static func recoverPersistedDeletion(
        in directory: URL,
        generations: inout [String: UInt64]
    ) throws {
        let url = deletionURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let deletion: PersistedRecoveryDeletion
        do {
            deletion = try JSONDecoder().decode(PersistedRecoveryDeletion.self, from: data)
        } catch {
            throw RecoveryStoreIssue.malformedData
        }
        try deletion.validateSchema()
        let recoveredGenerations = try deletion.recoveredGenerations(
            from: generations
        )
        if let recoveredGenerations,
           recoveredGenerations.requiresArtifactIdentityBinding {
            let artifactIdentityKeys = try deletion.artifactIdentityKeys(
                in: directory
            )
            guard artifactIdentityKeys == recoveredGenerations.changedKeys else {
                throw RecoveryStoreIssue.malformedData
            }
        }
        switch deletion.phase {
        case .preparing:
            for entry in deletion.entries {
                let source = directory.appendingPathComponent(entry.sourceName)
                let tombstone = directory.appendingPathComponent(entry.tombstoneName)
                if FileManager.default.fileExists(atPath: tombstone.path) {
                    guard !FileManager.default.fileExists(atPath: source.path) else {
                        throw RecoveryStoreIssue.malformedData
                    }
                    try DurableFileIO.moveAtomically(from: tombstone, to: source)
                } else if !FileManager.default.fileExists(atPath: source.path) {
                    // A preparing transaction owns one durable copy of every
                    // selected artifact. If neither name exists, it cannot be
                    // safely classified as an interrupted deletion.
                    throw RecoveryStoreIssue.malformedData
                }
            }
            if let recoveredGenerations {
                generations = recoveredGenerations.target
                try persistGenerationIndex(generations, in: directory)
            }
            try removeDeletion(in: directory)
        case .committed:
            for entry in deletion.entries {
                let source = directory.appendingPathComponent(entry.sourceName)
                let tombstone = directory.appendingPathComponent(entry.tombstoneName)
                guard !FileManager.default.fileExists(atPath: source.path) else {
                    throw RecoveryStoreIssue.malformedData
                }
                if FileManager.default.fileExists(atPath: tombstone.path) {
                    try DurableFileIO.removeDurably(at: tombstone)
                }
            }
            if let recoveredGenerations {
                generations = recoveredGenerations.target
                try persistGenerationIndex(generations, in: directory)
            }
            try removeDeletion(in: directory)
        }
    }

    static func trim(
        _ candidates: [RecoveryEntry],
        perDocumentLimit: Int,
        totalByteLimit: Int
    ) -> (entries: [RecoveryEntry], removed: [RecoveryEntry]) {
        var perDocumentCounts: [String: Int] = [:]
        var kept: [RecoveryEntry] = []
        var removed: [RecoveryEntry] = []
        for entry in candidates {
            let count = perDocumentCounts[entry.documentIdentity.stableKey, default: 0]
            if count < perDocumentLimit {
                kept.append(entry)
                perDocumentCounts[entry.documentIdentity.stableKey] = count + 1
            } else {
                removed.append(entry)
            }
        }
        var pinnedIdentities: Set<String> = []
        var historicalBytes = 0
        var byteLimited: [RecoveryEntry] = []
        for entry in kept {
            if pinnedIdentities.insert(entry.documentIdentity.stableKey).inserted {
                byteLimited.append(entry)
                continue
            }
            if historicalBytes + entry.snapshot.text.utf8.count <= totalByteLimit {
                historicalBytes += entry.snapshot.text.utf8.count
                byteLimited.append(entry)
            } else {
                removed.append(entry)
            }
        }
        return (byteLimited, removed)
    }

    static func recordsAfterDiscard(
        _ target: DocumentSyncRecoveryDiscardTarget,
        from records: DocumentSyncRecoveryRecords
    ) -> DocumentSyncRecoveryRecords? {
        let removeDecoded: Set<UUID>
        let removeRaw: Set<UUID>
        switch target {
        case .decoded(let entry):
            removeDecoded = [entry.id]
            removeRaw = []
        case .raw(let entries):
            removeDecoded = []
            removeRaw = Set(entries.map(\.id))
        case .selected(let selected):
            removeDecoded = Set(selected.decoded.map(\.id))
            removeRaw = Set(selected.raw.map(\.id))
        case .records(let selected):
            removeDecoded = Set(selected.decoded.map(\.id))
            removeRaw = Set(selected.raw.map(\.id))
        }
        guard !removeDecoded.isEmpty || !removeRaw.isEmpty,
              records.decoded.contains(where: { removeDecoded.contains($0.id) })
                || records.raw.contains(where: { removeRaw.contains($0.id) }) else {
            return nil
        }
        return DocumentSyncRecoveryRecords(
            decoded: records.decoded.filter { !removeDecoded.contains($0.id) },
            raw: records.raw.filter { !removeRaw.contains($0.id) }
        )
    }

    static func migratedRecords(
        _ records: DocumentSyncRecoveryRecords,
        to identity: DocumentIdentity
    ) -> DocumentSyncRecoveryRecords {
        DocumentSyncRecoveryRecords(
            decoded: records.decoded.map {
                RecoveryEntry(
                    id: $0.id,
                    documentIdentity: identity,
                    snapshot: $0.snapshot,
                    createdAt: $0.createdAt
                )
            },
            raw: records.raw.map {
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
    }

    static func snapshotURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).snapshot.json")
    }

    static func rawDataURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).raw")
    }

    static func rawMetadataURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).raw.json")
    }

    static func migrationURL(in directory: URL) -> URL {
        directory.appendingPathComponent("migration.json")
    }

    static func generationIndexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recovery-index.json")
    }

    static func deletionURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recovery-deletion.json")
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct PersistedRecoveryEntry: Codable {
    let schemaVersion: Int?
    let id: UUID
    let stableKey: String
    let text: String
    let encoding: String
    let newline: String
    let hasFinalNewline: Bool
    let createdAt: Date

    init(_ entry: RecoveryEntry) {
        schemaVersion = SessionRecoveryStore.currentSchemaVersion
        id = entry.id
        stableKey = entry.documentIdentity.stableKey
        text = entry.snapshot.text
        encoding = entry.snapshot.format.encoding.rawValue
        newline = entry.snapshot.format.dominantNewline.rawValue
        hasFinalNewline = entry.snapshot.format.hasFinalNewline
        createdAt = entry.createdAt
    }

    func validateSchema() throws {
        if let schemaVersion,
           schemaVersion > SessionRecoveryStore.currentSchemaVersion {
            throw RecoveryStoreIssue.unsupportedSchema
        }
    }

    func makeEntry() throws -> RecoveryEntry {
        guard let encoding = TextEncoding(rawValue: encoding),
              let newline = NewlineStyle(rawValue: newline) else {
            throw RecoveryStoreIssue.malformedData
        }
        return RecoveryEntry(
            id: id,
            documentIdentity: DocumentIdentity(stableKey: stableKey),
            snapshot: DocumentSnapshot(
                text: text,
                format: TextFileFormat(
                    encoding: encoding,
                    dominantNewline: newline,
                    hasFinalNewline: hasFinalNewline
                )
            ),
            createdAt: createdAt
        )
    }
}

private struct PersistedRawRecoveryEntry: Codable {
    let schemaVersion: Int?
    let id: UUID
    let stableKey: String
    let byteCount: Int?
    let contentDigest: String?
    let createdAt: Date
    let intendedRecoveryArtifactID: UUID?
    let acknowledgedRecoveryArtifactID: UUID?

    init(
        id: UUID,
        stableKey: String,
        byteCount: Int,
        contentDigest: String,
        createdAt: Date,
        intendedRecoveryArtifactID: UUID?,
        acknowledgedRecoveryArtifactID: UUID?
    ) {
        schemaVersion = SessionRecoveryStore.currentSchemaVersion
        self.id = id
        self.stableKey = stableKey
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.createdAt = createdAt
        self.intendedRecoveryArtifactID = intendedRecoveryArtifactID
        self.acknowledgedRecoveryArtifactID = acknowledgedRecoveryArtifactID
    }

    func validateSchema() throws {
        if let schemaVersion,
           schemaVersion > SessionRecoveryStore.currentSchemaVersion {
            throw RecoveryStoreIssue.unsupportedSchema
        }
    }
}

private struct PersistedRecoveryGenerationIndex: Codable {
    let schemaVersion: Int?
    let generations: [String: UInt64]

    init(generations: [String: UInt64]) {
        schemaVersion = SessionRecoveryStore.currentSchemaVersion
        self.generations = generations
    }

    func validateSchema() throws {
        if let schemaVersion,
           schemaVersion > SessionRecoveryStore.currentSchemaVersion {
            throw RecoveryStoreIssue.unsupportedSchema
        }
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
           schemaVersion > SessionRecoveryStore.currentSchemaVersion {
            throw RecoveryStoreIssue.unsupportedSchema
        }
        let snapshotIDSet = Set(snapshotIDs)
        let rawIDSet = Set(rawIDs)
        guard sourceKey != destinationKey,
              snapshotIDSet.count == snapshotIDs.count,
              Set(rawIDs).count == rawIDs.count,
              snapshotIDSet.isDisjoint(with: rawIDSet),
              !sourceKey.isEmpty,
              !destinationKey.isEmpty else {
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
        case let (.some(previous), .some(next)):
            let sourceGeneration = previous[sourceKey, default: 0]
            let destinationGeneration = previous[destinationKey, default: 0]
            let destinationBase = max(sourceGeneration, destinationGeneration)
            guard sourceGeneration < UInt64.max,
                  destinationBase < UInt64.max else {
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

private struct PersistedRecoveryDeletion: Codable {
    enum Phase: String, Codable {
        case preparing
        case committed
    }

    struct Entry: Codable, Equatable {
        let sourceName: String
        let tombstoneName: String
    }

    let schemaVersion: Int?
    let entries: [Entry]
    let phase: Phase
    let previousGenerations: [String: UInt64]?
    let nextGenerations: [String: UInt64]?

    init(
        entries: [Entry],
        phase: Phase,
        previousGenerations: [String: UInt64]?,
        nextGenerations: [String: UInt64]?
    ) {
        schemaVersion = SessionRecoveryStore.currentSchemaVersion
        self.entries = entries
        self.phase = phase
        self.previousGenerations = previousGenerations
        self.nextGenerations = nextGenerations
    }

    var committed: PersistedRecoveryDeletion {
        PersistedRecoveryDeletion(
            entries: entries,
            phase: .committed,
            previousGenerations: previousGenerations,
            nextGenerations: nextGenerations
        )
    }

    func validateSchema() throws {
        if let schemaVersion,
           schemaVersion > SessionRecoveryStore.currentSchemaVersion {
            throw RecoveryStoreIssue.unsupportedSchema
        }
        guard !entries.isEmpty,
              Set(entries.map(\.sourceName)).count == entries.count,
              Set(entries.map(\.tombstoneName)).count == entries.count,
              Set(entries.map(\.sourceName)).isDisjoint(
                with: Set(entries.map(\.tombstoneName))
              ),
              entries.allSatisfy({ entry in
                  isRecoveryArtifactName(entry.sourceName)
                      && isTombstoneName(
                          entry.tombstoneName,
                          for: entry.sourceName
                      )
              }) else {
            throw RecoveryStoreIssue.malformedData
        }
        let sourceNames = Set(entries.map(\.sourceName))
        for sourceName in sourceNames where sourceName.hasSuffix(".raw") {
            let metadataName = String(sourceName.dropLast(4)) + ".raw.json"
            guard sourceNames.contains(metadataName) else {
                throw RecoveryStoreIssue.malformedData
            }
        }
        for sourceName in sourceNames where sourceName.hasSuffix(".raw.json") {
            let payloadName = String(sourceName.dropLast(5))
            guard sourceNames.contains(payloadName) else {
                throw RecoveryStoreIssue.malformedData
            }
        }
    }

    struct RecoveredGenerations {
        let target: [String: UInt64]
        let changedKeys: Set<String>
        let requiresArtifactIdentityBinding: Bool
    }

    func recoveredGenerations(
        from current: [String: UInt64]
    ) throws -> RecoveredGenerations? {
        switch (previousGenerations, nextGenerations) {
        case (nil, nil):
            guard let schemaVersion,
                  schemaVersion < SessionRecoveryStore.currentSchemaVersion
            else {
                throw RecoveryStoreIssue.malformedData
            }
            return nil
        case let (.some(previous), .some(next)):
            let allKeys = Set(previous.keys).union(next.keys)
            var changedKeys: Set<String> = []
            for key in allKeys {
                let previousValue = previous[key, default: 0]
                guard let nextValue = next[key] else {
                    throw RecoveryStoreIssue.malformedData
                }
                if previousValue == nextValue {
                    // A new zero-value key is not a mutation and therefore
                    // cannot be journaled as part of a deletion transition.
                    guard previous[key] != nil else {
                        throw RecoveryStoreIssue.malformedData
                    }
                    continue
                }
                guard previousValue < UInt64.max,
                      nextValue == previousValue + 1 else {
                    throw RecoveryStoreIssue.malformedData
                }
                changedKeys.insert(key)
            }
            guard !changedKeys.isEmpty else {
                throw RecoveryStoreIssue.malformedData
            }
            switch phase {
            case .preparing:
                // Deletion writes its next-generation index before the
                // committed marker. A crash in that narrow interval is a
                // normal preparing journal with either durable map; replay
                // restores the artifacts and rolls the index back exactly.
                guard current == previous || current == next else {
                    throw RecoveryStoreIssue.malformedData
                }
                return RecoveredGenerations(
                    target: previous,
                    changedKeys: changedKeys,
                    requiresArtifactIdentityBinding: true
                )
            case .committed:
                guard current == previous || current == next else {
                    throw RecoveryStoreIssue.malformedData
                }
                return RecoveredGenerations(
                    target: next,
                    changedKeys: changedKeys,
                    requiresArtifactIdentityBinding: current == previous
                )
            }
        case (.some, nil), (nil, .some):
            throw RecoveryStoreIssue.malformedData
        }
    }

    func artifactIdentityKeys(in directory: URL) throws -> Set<String> {
        var identityKeys: Set<String> = []
        for entry in entries {
            guard entry.sourceName.hasSuffix(".snapshot.json")
                || entry.sourceName.hasSuffix(".raw.json") else {
                continue
            }
            let source = directory.appendingPathComponent(entry.sourceName)
            let tombstone = directory.appendingPathComponent(entry.tombstoneName)
            let artifactURL: URL
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: source.path) {
                guard !fileManager.fileExists(atPath: tombstone.path) else {
                    throw RecoveryStoreIssue.malformedData
                }
                artifactURL = source
            } else if fileManager.fileExists(atPath: tombstone.path) {
                artifactURL = tombstone
            } else {
                throw RecoveryStoreIssue.malformedData
            }
            do {
                let data = try Data(
                    contentsOf: artifactURL,
                    options: [.mappedIfSafe]
                )
                if entry.sourceName.hasSuffix(".snapshot.json") {
                    let persisted = try JSONDecoder().decode(
                        PersistedRecoveryEntry.self,
                        from: data
                    )
                    try persisted.validateSchema()
                    guard snapshotFileName(for: persisted.id) == entry.sourceName else {
                        throw RecoveryStoreIssue.malformedData
                    }
                    identityKeys.insert(persisted.stableKey)
                } else {
                    let persisted = try JSONDecoder().decode(
                        PersistedRawRecoveryEntry.self,
                        from: data
                    )
                    try persisted.validateSchema()
                    guard rawMetadataFileName(for: persisted.id)
                            == entry.sourceName else {
                        throw RecoveryStoreIssue.malformedData
                    }
                    identityKeys.insert(persisted.stableKey)
                }
            } catch let issue as RecoveryStoreIssue {
                throw issue
            } catch {
                throw RecoveryStoreIssue.malformedData
            }
        }
        return identityKeys
    }

    private func isRecoveryArtifactName(_ name: String) -> Bool {
        let suffixes = [".snapshot.json", ".raw.json", ".raw"]
        guard let suffix = suffixes.first(where: name.hasSuffix) else {
            return false
        }
        let identifierText = String(name.dropLast(suffix.count))
        guard let identifier = UUID(uuidString: identifierText) else {
            return false
        }
        return name == "\(identifier.uuidString.lowercased())\(suffix)"
    }

    private func isTombstoneName(_ name: String, for sourceName: String) -> Bool {
        let prefix = ".\(sourceName)."
        let suffix = ".delete"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return false
        }
        let identifierText = String(
            name.dropFirst(prefix.count).dropLast(suffix.count)
        )
        guard let identifier = UUID(uuidString: identifierText) else {
            return false
        }
        return name == "\(prefix)\(identifier.uuidString.lowercased())\(suffix)"
    }

    private func snapshotFileName(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).snapshot.json"
    }

    private func rawMetadataFileName(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).raw.json"
    }
}
