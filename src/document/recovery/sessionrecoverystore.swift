import Foundation

enum SessionRecoveryStoreError: LocalizedError, Equatable {
    case unreadableMigrationJournal

    var errorDescription: String? {
        switch self {
        case .unreadableMigrationJournal:
            "The recovery migration journal is unreadable."
        }
    }
}

struct RecoveryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let snapshot: DocumentSnapshot
    let createdAt: Date
}

struct RawRecoveryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let documentIdentity: DocumentIdentity
    let dataURL: URL?
    let byteCount: Int
    let contentDigest: String
    let createdAt: Date
    fileprivate let residentData: Data?

    var data: Data? {
        if let residentData {
            return residentData
        }
        guard let dataURL else { return nil }
        return try? Data(contentsOf: dataURL, options: [.mappedIfSafe])
    }

    var isDataResident: Bool {
        residentData != nil
    }

    static func == (lhs: RawRecoveryEntry, rhs: RawRecoveryEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.documentIdentity == rhs.documentIdentity
            && lhs.dataURL == rhs.dataURL
            && lhs.byteCount == rhs.byteCount
            && lhs.contentDigest == rhs.contentDigest
            && lhs.createdAt == rhs.createdAt
    }
}

@MainActor
final class SessionRecoveryStore {
    private static let maximumResidentRawRecoveryBytes = 1 * 1_024 * 1_024

    static let shared: SessionRecoveryStore = {
        let root = CommitRecoveryJournalStore.defaultRecoveryDirectory
        return SessionRecoveryStore(persistenceDirectory: root)
    }()

    private let perDocumentLimit: Int
    private let totalByteLimit: Int
    private let persistenceDirectory: URL?
    private let migrationWriteHook: ((Int) throws -> Void)?
    private var entries: [RecoveryEntry] = []
    private var rawEntries: [RawRecoveryEntry] = []

    init(
        persistenceDirectory: URL? = nil,
        perDocumentLimit: Int = 5,
        totalByteLimit: Int = 10 * 1_024 * 1_024,
        migrationWriteHook: ((Int) throws -> Void)? = nil
    ) {
        self.persistenceDirectory = persistenceDirectory
        self.perDocumentLimit = perDocumentLimit
        self.totalByteLimit = totalByteLimit
        self.migrationWriteHook = migrationWriteHook
        loadPersistedEntries()
        importPendingCommitRecoveries()
    }

    func add(snapshot: DocumentSnapshot, for identity: DocumentIdentity) throws {
        let entry = RecoveryEntry(
            id: UUID(),
            documentIdentity: identity,
            snapshot: snapshot,
            createdAt: Date()
        )
        try persist(entry)
        entries.insert(entry, at: 0)
        trim()
    }

    @discardableResult
    func addRawData(
        _ data: Data,
        for identity: DocumentIdentity,
        id: UUID = UUID()
    ) throws -> RawRecoveryEntry {
        if let existing = rawEntries.first(where: { $0.id == id }) {
            return existing
        }
        let entry: RawRecoveryEntry
        if let persistenceDirectory {
            try ensurePersistenceDirectory()
            let dataURL = rawDataURL(for: id, in: persistenceDirectory)
            try DurableFileIO.writeAtomically(data, to: dataURL)
            let metadata = PersistedRawRecoveryEntry(
                id: id,
                stableKey: identity.stableKey,
                byteCount: data.count,
                contentDigest: FileFingerprint.make(
                    data: data
                ).contentDigest,
                createdAt: Date()
            )
            do {
                try DurableFileIO.writeAtomically(
                    encode(metadata),
                    to: rawMetadataURL(for: id, in: persistenceDirectory)
                )
            } catch {
                try? FileManager.default.removeItem(at: dataURL)
                throw error
            }
            entry = RawRecoveryEntry(
                id: id,
                documentIdentity: identity,
                dataURL: dataURL,
                byteCount: data.count,
                contentDigest: metadata.contentDigest
                    ?? FileFingerprint.make(data: data).contentDigest,
                createdAt: metadata.createdAt,
                residentData: shouldKeepRawDataResident(data)
                    ? data
                    : nil
            )
        } else {
            entry = RawRecoveryEntry(
                id: id,
                documentIdentity: identity,
                dataURL: nil,
                byteCount: data.count,
                contentDigest: FileFingerprint.make(
                    data: data
                ).contentDigest,
                createdAt: Date(),
                residentData: data
            )
        }
        rawEntries.insert(entry, at: 0)
        return entry
    }

    private func shouldKeepRawDataResident(_ data: Data) -> Bool {
        let residentBytes = rawEntries.reduce(into: 0) { total, entry in
            total += entry.residentData?.count ?? 0
        }
        return residentBytes + data.count
            <= Self.maximumResidentRawRecoveryBytes
    }

    private func importPendingCommitRecoveries() {
        guard let persistenceDirectory else { return }
        for pending in CommitRecoveryJournalStore.pendingRecoveries(
            in: persistenceDirectory
        ) {
            do {
                if pending.swapCompleted,
                   let data = try? Data(
                    contentsOf: pending.artifact.candidateURL,
                    options: [.mappedIfSafe]
                   ),
                   FileFingerprint.make(data: data).contentDigest
                        != pending.expectedContentDigest {
                    try addRawData(
                        data,
                        for: pending.documentIdentity,
                        id: pending.artifact.id
                    )
                }
                try CommitRecoveryJournalStore.acknowledge(
                    pending.artifact
                )
            } catch {
                continue
            }
        }
    }

    func latest(for identity: DocumentIdentity) -> RecoveryEntry? {
        entries.first { $0.documentIdentity == identity }
    }

    func rawRecoveryEntries(
        for identity: DocumentIdentity
    ) -> [RawRecoveryEntry] {
        rawEntries.filter { $0.documentIdentity == identity }
    }

    func remove(_ entry: RecoveryEntry) {
        entries.removeAll { $0.id == entry.id }
        removePersistedSnapshot(id: entry.id)
    }

    func removeRawRecoveryEntries(for identity: DocumentIdentity) {
        let removed = rawEntries.filter {
            $0.documentIdentity == identity
        }
        rawEntries.removeAll {
            $0.documentIdentity == identity
        }
        for entry in removed {
            removePersistedRawRecovery(id: entry.id)
        }
    }

    func moveEntries(
        from oldIdentity: DocumentIdentity,
        to newIdentity: DocumentIdentity
    ) throws {
        guard oldIdentity != newIdentity else { return }
        try recoverPersistedMigration()
        let originalEntries = entries
        let originalRawEntries = rawEntries
        let movingEntryIDs = Set(
            entries.lazy
                .filter { $0.documentIdentity == oldIdentity }
                .map(\.id)
        )
        let movingRawEntryIDs = Set(
            rawEntries.lazy
                .filter { $0.documentIdentity == oldIdentity }
                .map(\.id)
        )
        guard !movingEntryIDs.isEmpty || !movingRawEntryIDs.isEmpty else {
            return
        }
        let movedEntries = entries.map { entry in
            guard entry.documentIdentity == oldIdentity else { return entry }
            return RecoveryEntry(
                id: entry.id,
                documentIdentity: newIdentity,
                snapshot: entry.snapshot,
                createdAt: entry.createdAt
            )
        }
        let movedRawEntries = rawEntries.map { entry in
            guard entry.documentIdentity == oldIdentity else { return entry }
            return RawRecoveryEntry(
                id: entry.id,
                documentIdentity: newIdentity,
                dataURL: entry.dataURL,
                byteCount: entry.byteCount,
                contentDigest: entry.contentDigest,
                createdAt: entry.createdAt,
                residentData: entry.residentData
            )
        }
        guard persistenceDirectory != nil else {
            entries = movedEntries
            rawEntries = movedRawEntries
            trim()
            return
        }
        let migration = PersistedRecoveryMigration(
            sourceKey: oldIdentity.stableKey,
            destinationKey: newIdentity.stableKey,
            snapshotIDs: Array(movingEntryIDs),
            rawIDs: Array(movingRawEntryIDs),
            phase: .preparing
        )
        try persistMigration(migration)
        var completedWriteCount = 0
        do {
            for entry in movedEntries
            where movingEntryIDs.contains(entry.id) {
                try persist(entry)
                completedWriteCount += 1
                try migrationWriteHook?(completedWriteCount)
            }
            for entry in movedRawEntries
            where movingRawEntryIDs.contains(entry.id) {
                try persistRawMetadata(entry)
                completedWriteCount += 1
                try migrationWriteHook?(completedWriteCount)
            }
            try persistMigration(migration.committed)
        } catch {
            for entry in originalEntries
            where entry.documentIdentity == oldIdentity {
                try? persist(entry)
            }
            for entry in originalRawEntries
            where entry.documentIdentity == oldIdentity {
                try? persistRawMetadata(entry)
            }
            throw error
        }
        entries = movedEntries
        rawEntries = movedRawEntries
        try? removePersistedMigration()
        trim()
    }

    private func loadPersistedEntries() {
        guard let persistenceDirectory else { return }
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: persistenceDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls where url.lastPathComponent.hasSuffix(".snapshot.json") {
            guard let data = try? Data(contentsOf: url),
                  let persisted = try? JSONDecoder().decode(
                    PersistedRecoveryEntry.self,
                    from: data
                  ),
                  let entry = persisted.entry else {
                continue
            }
            entries.append(entry)
        }
        for url in urls where url.lastPathComponent.hasSuffix(".raw.json") {
            guard let data = try? Data(contentsOf: url),
                  let persisted = try? JSONDecoder().decode(
                    PersistedRawRecoveryEntry.self,
                    from: data
                  ) else {
                continue
            }
            let dataURL = rawDataURL(for: persisted.id, in: persistenceDirectory)
            guard let values = try? dataURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            persisted.byteCount == nil || persisted.byteCount == fileSize else {
                continue
            }
            rawEntries.append(
                RawRecoveryEntry(
                    id: persisted.id,
                    documentIdentity: DocumentIdentity(
                        stableKey: persisted.stableKey
                    ),
                    dataURL: dataURL,
                    byteCount: persisted.byteCount ?? fileSize,
                    contentDigest: persisted.contentDigest ?? "",
                    createdAt: persisted.createdAt,
                    residentData: nil
                )
            )
        }
        try? recoverPersistedMigration()
        entries.sort { $0.createdAt > $1.createdAt }
        rawEntries.sort { $0.createdAt > $1.createdAt }
        trim()
    }

    private func persist(_ entry: RecoveryEntry) throws {
        guard let persistenceDirectory else { return }
        try ensurePersistenceDirectory()
        let persisted = PersistedRecoveryEntry(entry)
        try DurableFileIO.writeAtomically(
            encode(persisted),
            to: snapshotURL(for: entry.id, in: persistenceDirectory)
        )
    }

    private func persistRawMetadata(_ entry: RawRecoveryEntry) throws {
        guard let persistenceDirectory else { return }
        try ensurePersistenceDirectory()
        let persisted = PersistedRawRecoveryEntry(
            id: entry.id,
            stableKey: entry.documentIdentity.stableKey,
            byteCount: entry.byteCount,
            contentDigest: entry.contentDigest,
            createdAt: entry.createdAt
        )
        try DurableFileIO.writeAtomically(
            encode(persisted),
            to: rawMetadataURL(for: entry.id, in: persistenceDirectory)
        )
    }

    private func persistMigration(
        _ migration: PersistedRecoveryMigration
    ) throws {
        guard let persistenceDirectory else { return }
        try ensurePersistenceDirectory()
        try DurableFileIO.writeAtomically(
            encode(migration),
            to: migrationURL(in: persistenceDirectory)
        )
    }

    private func recoverPersistedMigration() throws {
        guard let persistenceDirectory else { return }
        let url = migrationURL(in: persistenceDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let data: Data
        let migration: PersistedRecoveryMigration
        do {
            data = try Data(contentsOf: url)
            migration = try JSONDecoder().decode(
                PersistedRecoveryMigration.self,
                from: data
            )
        } catch {
            throw SessionRecoveryStoreError.unreadableMigrationJournal
        }
        let snapshotIDs = Set(migration.snapshotIDs)
        let rawIDs = Set(migration.rawIDs)
        let resolvedIdentity = DocumentIdentity(
            stableKey: migration.phase == .committed
                ? migration.destinationKey
                : migration.sourceKey
        )
        entries = entries.map { entry in
            guard snapshotIDs.contains(entry.id) else { return entry }
            return RecoveryEntry(
                id: entry.id,
                documentIdentity: resolvedIdentity,
                snapshot: entry.snapshot,
                createdAt: entry.createdAt
            )
        }
        rawEntries = rawEntries.map { entry in
            guard rawIDs.contains(entry.id) else { return entry }
            return RawRecoveryEntry(
                id: entry.id,
                documentIdentity: resolvedIdentity,
                dataURL: entry.dataURL,
                byteCount: entry.byteCount,
                contentDigest: entry.contentDigest,
                createdAt: entry.createdAt,
                residentData: entry.residentData
            )
        }
        do {
            for entry in entries where snapshotIDs.contains(entry.id) {
                try persist(entry)
            }
            for entry in rawEntries where rawIDs.contains(entry.id) {
                try persistRawMetadata(entry)
            }
            try removePersistedMigration()
        } catch {
            throw error
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func ensurePersistenceDirectory() throws {
        guard let persistenceDirectory else { return }
        try DurableFileIO.createDirectory(at: persistenceDirectory)
    }

    private func trim() {
        var counts: [DocumentIdentity: Int] = [:]
        var removed: [RecoveryEntry] = []
        entries = entries.filter { entry in
            counts[entry.documentIdentity, default: 0] += 1
            let keep = counts[entry.documentIdentity, default: 0]
                <= perDocumentLimit
            if !keep { removed.append(entry) }
            return keep
        }
        var pinnedDocuments: Set<DocumentIdentity> = []
        let pinnedEntryIDs = Set(
            entries.compactMap { entry -> UUID? in
                guard pinnedDocuments.insert(entry.documentIdentity).inserted else {
                    return nil
                }
                return entry.id
            }
        )
        var historicalBytes = 0
        entries = entries.filter { entry in
            if pinnedEntryIDs.contains(entry.id) {
                return true
            }
            historicalBytes += entry.snapshot.text.utf8.count
            let keep = historicalBytes <= totalByteLimit
            if !keep { removed.append(entry) }
            return keep
        }
        for entry in removed {
            removePersistedSnapshot(id: entry.id)
        }
    }

    private func removePersistedSnapshot(id: UUID) {
        guard let persistenceDirectory else { return }
        try? FileManager.default.removeItem(
            at: snapshotURL(for: id, in: persistenceDirectory)
        )
    }

    private func removePersistedRawRecovery(id: UUID) {
        guard let persistenceDirectory else { return }
        try? FileManager.default.removeItem(
            at: rawDataURL(for: id, in: persistenceDirectory)
        )
        try? FileManager.default.removeItem(
            at: rawMetadataURL(for: id, in: persistenceDirectory)
        )
    }

    private func removePersistedMigration() throws {
        guard let persistenceDirectory else { return }
        let url = migrationURL(in: persistenceDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func snapshotURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(id.uuidString.lowercased()).snapshot.json"
        )
    }

    private func rawDataURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(id.uuidString.lowercased()).raw"
        )
    }

    private func rawMetadataURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(id.uuidString.lowercased()).raw.json"
        )
    }

    private func migrationURL(in directory: URL) -> URL {
        directory.appendingPathComponent("migration.json")
    }
}

private struct PersistedRecoveryEntry: Codable {
    let id: UUID
    let stableKey: String
    let text: String
    let encoding: String
    let newline: String
    let hasFinalNewline: Bool
    let createdAt: Date

    init(_ entry: RecoveryEntry) {
        id = entry.id
        stableKey = entry.documentIdentity.stableKey
        text = entry.snapshot.text
        encoding = entry.snapshot.format.encoding.rawValue
        newline = entry.snapshot.format.dominantNewline.rawValue
        hasFinalNewline = entry.snapshot.format.hasFinalNewline
        createdAt = entry.createdAt
    }

    var entry: RecoveryEntry? {
        guard let encoding = TextEncoding(rawValue: encoding),
              let newline = NewlineStyle(rawValue: newline) else {
            return nil
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
    let id: UUID
    let stableKey: String
    let byteCount: Int?
    let contentDigest: String?
    let createdAt: Date
}

private struct PersistedRecoveryMigration: Codable {
    enum Phase: String, Codable {
        case preparing
        case committed
    }

    let sourceKey: String
    let destinationKey: String
    let snapshotIDs: [UUID]
    let rawIDs: [UUID]
    let phase: Phase

    var committed: PersistedRecoveryMigration {
        PersistedRecoveryMigration(
            sourceKey: sourceKey,
            destinationKey: destinationKey,
            snapshotIDs: snapshotIDs,
            rawIDs: rawIDs,
            phase: .committed
        )
    }
}
