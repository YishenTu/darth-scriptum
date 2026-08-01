import Foundation

extension SessionRecoveryStore {
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
                || records.raw.contains(where: { removeRaw.contains($0.id) })
        else {
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
}
