import Foundation

extension SessionRecoveryStore {
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
                    tombstoneName:
                        ".\($0.lastPathComponent).\(UUID().uuidString.lowercased()).delete"
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
            try RecoveryJSONEncoding.encode(deletion),
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
        let data = try TextFileCodec.readSupportedData(
            at: url,
            followingSymbolicLinks: false
        )
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
            recoveredGenerations.requiresArtifactIdentityBinding
        {
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
            schemaVersion > SessionRecoveryStore.currentSchemaVersion
        {
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
            })
        else {
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
        case (.some(let previous), .some(let next)):
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
                    nextValue == previousValue + 1
                else {
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
            guard
                entry.sourceName.hasSuffix(".snapshot.json")
                    || entry.sourceName.hasSuffix(".raw.json")
            else {
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
                identityKeys.insert(
                    try SessionRecoveryStore.persistedRecoveryIdentityKey(
                        from: data,
                        sourceName: entry.sourceName
                    )
                )
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

}
