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
                )
            else {
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
            guard
                snapshotURL(for: entry.id, in: directory).lastPathComponent
                    == url.lastPathComponent
            else {
                throw RecoveryStoreIssue.malformedData
            }
            guard !state.entries.contains(where: { $0.id == entry.id }),
                !state.rawEntries.contains(where: { $0.id == entry.id })
            else {
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
            guard
                rawMetadataURL(for: persisted.id, in: directory)
                    .lastPathComponent == url.lastPathComponent,
                fileManager.fileExists(atPath: dataURL.path)
            else {
                throw RecoveryStoreIssue.malformedData
            }
            let values = try dataURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                let size = values.fileSize,
                persisted.byteCount == nil || persisted.byteCount == size
            else {
                throw RecoveryStoreIssue.malformedData
            }
            let rawData = try Data(contentsOf: dataURL, options: [.mappedIfSafe])
            let digest =
                persisted.contentDigest
                ?? FileFingerprint.make(data: rawData).contentDigest
            guard FileFingerprint.make(data: rawData).contentDigest == digest,
                !state.entries.contains(where: { $0.id == persisted.id }),
                !state.rawEntries.contains(where: { $0.id == persisted.id })
            else {
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
        let data = try RecoveryJSONEncoding.encode(PersistedRecoveryEntry(entry))
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
            try RecoveryJSONEncoding.encode(persisted),
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
            try RecoveryJSONEncoding.encode(
                PersistedRecoveryGenerationIndex(generations: generations)
            ),
            to: generationIndexURL(in: directory)
        )
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
                    != pending.expectedContentDigest
                {
                    let entry =
                        existing
                        ?? RawRecoveryEntry(
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
                        != pending.artifact.id
                    {
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
                existing.acknowledgedRecoveryArtifactID == pending.artifact.id
            {
                state.acknowledgedArtifacts.insert(pending.artifact.id)
            }
        }
    }

    static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw RecoveryStoreIssue.malformedData }
        return value
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

    static func persistedRecoveryIdentityKey(
        from data: Data,
        sourceName: String
    ) throws -> String {
        do {
            if sourceName.hasSuffix(".snapshot.json") {
                let persisted = try JSONDecoder().decode(
                    PersistedRecoveryEntry.self,
                    from: data
                )
                try persisted.validateSchema()
                guard
                    sourceName
                        == "\(persisted.id.uuidString.lowercased()).snapshot.json"
                else {
                    throw RecoveryStoreIssue.malformedData
                }
                return persisted.stableKey
            }
            if sourceName.hasSuffix(".raw.json") {
                let persisted = try JSONDecoder().decode(
                    PersistedRawRecoveryEntry.self,
                    from: data
                )
                try persisted.validateSchema()
                guard
                    sourceName
                        == "\(persisted.id.uuidString.lowercased()).raw.json"
                else {
                    throw RecoveryStoreIssue.malformedData
                }
                return persisted.stableKey
            }
            throw RecoveryStoreIssue.malformedData
        } catch let issue as RecoveryStoreIssue {
            throw issue
        } catch {
            throw RecoveryStoreIssue.malformedData
        }
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
            schemaVersion > SessionRecoveryStore.currentSchemaVersion
        {
            throw RecoveryStoreIssue.unsupportedSchema
        }
    }

    func makeEntry() throws -> RecoveryEntry {
        guard let encoding = TextEncoding(rawValue: encoding),
            let newline = NewlineStyle(rawValue: newline)
        else {
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
            schemaVersion > SessionRecoveryStore.currentSchemaVersion
        {
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
            schemaVersion > SessionRecoveryStore.currentSchemaVersion
        {
            throw RecoveryStoreIssue.unsupportedSchema
        }
    }
}
