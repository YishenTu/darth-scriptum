import Foundation
import XCTest

@testable import DarthScriptum

@MainActor
final class RecoveryDiskIOInterruptionTests: XCTestCase {
    func testFailedMoveKeepsEntriesUnderTheOriginalIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldIdentity = DocumentIdentity(
            stableKey: "path:/tmp/move-source.md"
        )
        let newIdentity = DocumentIdentity(
            stableKey: "path:/tmp/move-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "recover me\n",
            format: .newDocument
        )
        let rawData = Data([0xFF, 0x00])
        let store = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        _ = try await store.add(snapshot: snapshot, for: oldIdentity)
        _ = try await store.addRawData(rawData, for: oldIdentity)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)

        await assertThrowsErrorAsync(
            try await store.moveEntries(
                from: oldIdentity,
                to: newIdentity
            )
        )
        let oldLatest = try await store.latest(for: oldIdentity)
        XCTAssertEqual(oldLatest?.snapshot, snapshot)
        let oldRawEntries = try await store.rawRecoveryEntries(for: oldIdentity)
        let oldRaw = try XCTUnwrap(oldRawEntries.first)
        let oldRawData = try await oldRaw.loadData()
        XCTAssertEqual(oldRawData, rawData)
        let newLatest = try await store.latest(for: newIdentity)
        XCTAssertNil(newLatest)
        let newRaw = try await store.rawRecoveryEntries(for: newIdentity)
        XCTAssertTrue(newRaw.isEmpty)
    }

    func testInterruptedMoveRecoversOneIdentityAfterReopening() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let oldIdentity = DocumentIdentity(
            stableKey: "path:/tmp/interrupted-source.md"
        )
        let newIdentity = DocumentIdentity(
            stableKey: "path:/tmp/interrupted-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "recover after interruption\n",
            format: .newDocument
        )
        let rawData = Data([0xFF, 0x01])
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            migrationWriteHook: { completedWriteCount in
                guard completedWriteCount == 1 else { return }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: directory.path
                )
                throw InjectedMigrationError.interrupted
            }
        )
        _ = try await store.add(snapshot: snapshot, for: oldIdentity)
        _ = try await store.addRawData(rawData, for: oldIdentity)

        await assertThrowsErrorAsync(
            try await store.moveEntries(
                from: oldIdentity,
                to: newIdentity
            )
        )

        let journalURL = directory.appendingPathComponent("migration.json")
        let interruptedJournal = try Data(contentsOf: journalURL)
        let readOnlyReopen = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        await assertThrowsErrorAsync(try await readOnlyReopen.start()) { error in
            XCTAssertEqual(error as? SessionRecoveryStoreError, .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: journalURL), interruptedJournal)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let repairedReopen = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let repairedOld = try await repairedReopen.latest(for: oldIdentity)
        XCTAssertEqual(repairedOld?.snapshot, snapshot)
        let repairedNew = try await repairedReopen.latest(for: newIdentity)
        XCTAssertNil(repairedNew)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    directory
                    .appendingPathComponent("migration.json")
                    .path
            )
        )
    }

    func testSuccessfulMoveIsCommittedForTheNextStoreInstance() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldIdentity = DocumentIdentity(
            stableKey: "path:/tmp/committed-source.md"
        )
        let newIdentity = DocumentIdentity(
            stableKey: "path:/tmp/committed-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "committed recovery\n",
            format: .newDocument
        )
        let rawData = Data([0xFF, 0x02])
        let store = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        _ = try await store.add(snapshot: snapshot, for: oldIdentity)
        _ = try await store.addRawData(rawData, for: oldIdentity)

        _ = try await store.moveEntries(
            from: oldIdentity,
            to: newIdentity
        )

        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let oldLatest = try await reopened.latest(for: oldIdentity)
        XCTAssertNil(oldLatest)
        let oldRaw = try await reopened.rawRecoveryEntries(for: oldIdentity)
        XCTAssertTrue(oldRaw.isEmpty)
        let newLatest = try await reopened.latest(for: newIdentity)
        XCTAssertEqual(newLatest?.snapshot, snapshot)
        let newRawEntries = try await reopened.rawRecoveryEntries(
            for: newIdentity
        )
        let newRaw = try XCTUnwrap(newRawEntries.first)
        let newRawData = try await newRaw.loadData()
        XCTAssertEqual(newRawData, rawData)
    }

    func testAnotherMoveRepairsAnInterruptedJournalBeforeStarting() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let firstSource = DocumentIdentity(
            stableKey: "path:/tmp/first-source.md"
        )
        let firstDestination = DocumentIdentity(
            stableKey: "path:/tmp/first-destination.md"
        )
        let secondSource = DocumentIdentity(
            stableKey: "path:/tmp/second-source.md"
        )
        let secondDestination = DocumentIdentity(
            stableKey: "path:/tmp/second-destination.md"
        )
        let firstSnapshot = DocumentSnapshot(
            text: "first\n",
            format: .newDocument
        )
        let secondSnapshot = DocumentSnapshot(
            text: "second\n",
            format: .newDocument
        )
        let interruptionGate = MigrationInterruptionGate()
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            migrationWriteHook: { _ in
                guard interruptionGate.consumePendingInterruption() else { return }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: directory.path
                )
                throw InjectedMigrationError.interrupted
            }
        )
        _ = try await store.add(snapshot: firstSnapshot, for: firstSource)
        _ = try await store.add(snapshot: secondSnapshot, for: secondSource)

        await assertThrowsErrorAsync(
            try await store.moveEntries(
                from: firstSource,
                to: firstDestination
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        _ = try await store.moveEntries(
            from: secondSource,
            to: secondDestination
        )

        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let firstSourceEntry = try await reopened.latest(for: firstSource)
        XCTAssertEqual(firstSourceEntry?.snapshot, firstSnapshot)
        let firstDestinationEntry = try await reopened.latest(
            for: firstDestination
        )
        XCTAssertNil(firstDestinationEntry)
        let secondSourceEntry = try await reopened.latest(for: secondSource)
        XCTAssertNil(secondSourceEntry)
        let secondDestinationEntry = try await reopened.latest(
            for: secondDestination
        )
        XCTAssertEqual(secondDestinationEntry?.snapshot, secondSnapshot)
    }

    func testMalformedMigrationJournalBlocksAnotherMove() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldIdentity = DocumentIdentity(
            stableKey: "path:/tmp/malformed-source.md"
        )
        let newIdentity = DocumentIdentity(
            stableKey: "path:/tmp/malformed-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "do not strand me\n",
            format: .newDocument
        )
        let store = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        _ = try await store.add(snapshot: snapshot, for: oldIdentity)
        try Data("{not valid json".utf8).write(
            to: directory.appendingPathComponent("migration.json")
        )

        await assertThrowsErrorAsync(
            try await store.moveEntries(
                from: oldIdentity,
                to: newIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionRecoveryStoreError,
                .unreadableMigrationJournal
            )
        }
        let oldEntry = try await store.latest(for: oldIdentity)
        XCTAssertEqual(oldEntry?.snapshot, snapshot)
        let newEntry = try await store.latest(for: newIdentity)
        XCTAssertNil(newEntry)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(
                    "migration.json"
                ),
                encoding: .utf8
            ),
            "{not valid json"
        )
    }

    func testPendingDeletionJournalBlocksASecondDeletionWithoutOverwritingIt()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/deletion-source.md")
        let snapshot = DocumentSnapshot(
            text: "preserve this deletion evidence\n",
            format: .newDocument
        )
        let store = SessionRecoveryStore(persistenceDirectory: directory)
        let persisted = try await store.add(
            id: UUID(),
            snapshot: snapshot,
            for: identity,
            expectedRecords: .empty,
            expectedGeneration: 0
        )
        let entry = try XCTUnwrap(persisted.decodedEntries.first)
        let journalURL = directory.appendingPathComponent("recovery-deletion.json")
        let journalBytes = Data("{ malformed deletion journal".utf8)
        try journalBytes.write(to: journalURL)

        await assertThrowsErrorAsync(
            try await store.discard(
                target: .decoded(entry),
                for: identity,
                expectedRecords: DocumentSyncRecoveryRecords(
                    decoded: [entry],
                    raw: []
                ),
                expectedGeneration: persisted.generation
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionRecoveryStoreError,
                .unreadableDeletionJournal
            )
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        let retained = try await store.latest(for: identity)
        XCTAssertEqual(retained?.snapshot, snapshot)
    }

    func testMigrationJournalCannotRelabelAnUnrelatedRecoveryEntry()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DocumentIdentity(stableKey: "path:/tmp/source-a.md")
        let destination = DocumentIdentity(stableKey: "path:/tmp/destination-b.md")
        let unrelated = DocumentIdentity(stableKey: "path:/tmp/unrelated-c.md")
        let snapshot = DocumentSnapshot(
            text: "unrelated recovery evidence\n",
            format: .newDocument
        )
        let entryID = UUID()
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(
            id: entryID,
            snapshot: snapshot,
            for: unrelated,
            expectedRecords: .empty,
            expectedGeneration: 0
        )
        let snapshotURL = directory.appendingPathComponent(
            "\(entryID.uuidString.lowercased()).snapshot.json"
        )
        let snapshotBytes = try Data(contentsOf: snapshotURL)
        let journalURL = directory.appendingPathComponent("migration.json")
        let journalBytes = Data(
            """
            {"schemaVersion":2,"sourceKey":"\(source.stableKey)","destinationKey":"\(destination.stableKey)","snapshotIDs":["\(entryID.uuidString.lowercased())"],"rawIDs":[],"phase":"preparing","previousGenerations":{},"nextGenerations":{}}
            """.utf8
        )
        try journalBytes.write(to: journalURL)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        await assertThrowsErrorAsync(try await reopened.start()) { error in
            XCTAssertEqual(error as? SessionRecoveryStoreError, .malformedData)
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotBytes)
    }

    func testDeletionJournalCannotNameARecoveryArtifactAsItsTombstone()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/tombstone-target.md")
        let snapshot = DocumentSnapshot(
            text: "do not unlink this evidence\n",
            format: .newDocument
        )
        let entryID = UUID()
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(
            id: entryID,
            snapshot: snapshot,
            for: identity,
            expectedRecords: .empty,
            expectedGeneration: 0
        )
        let snapshotName = "\(entryID.uuidString.lowercased()).snapshot.json"
        let snapshotURL = directory.appendingPathComponent(snapshotName)
        let snapshotBytes = try Data(contentsOf: snapshotURL)
        let journalURL = directory.appendingPathComponent("recovery-deletion.json")
        let unrelatedSource = "\(UUID().uuidString.lowercased()).raw"
        let journalBytes = Data(
            """
            {"schemaVersion":2,"entries":[{"sourceName":"\(unrelatedSource)","tombstoneName":"\(snapshotName)"}],"phase":"committed","previousGenerations":{},"nextGenerations":{}}
            """.utf8
        )
        try journalBytes.write(to: journalURL)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        await assertThrowsErrorAsync(try await reopened.start()) { error in
            XCTAssertEqual(error as? SessionRecoveryStoreError, .malformedData)
        }

        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotBytes)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
    }

    func testCommittedMigrationJournalCannotLowerAnUnrelatedGeneration()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DocumentIdentity(stableKey: "path:/tmp/generation-source.md")
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/generation-destination.md"
        )
        let unrelated = DocumentIdentity(
            stableKey: "path:/tmp/generation-unrelated.md"
        )
        let snapshot = DocumentSnapshot(
            text: "generation evidence\n",
            format: .newDocument
        )
        let entryID = UUID()
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(
            id: entryID,
            snapshot: snapshot,
            for: source,
            expectedRecords: .empty,
            expectedGeneration: 0
        )
        _ = try await seed.add(
            id: UUID(),
            snapshot: snapshot,
            for: unrelated,
            expectedRecords: .empty,
            expectedGeneration: 0
        )

        let snapshotURL = directory.appendingPathComponent(
            "\(entryID.uuidString.lowercased()).snapshot.json"
        )
        let persistedData = try Data(contentsOf: snapshotURL)
        let migratedData = try dataByReplacingStableKey(
            in: persistedData,
            with: destination.stableKey
        )
        try migratedData.write(to: snapshotURL)
        let indexURL = directory.appendingPathComponent("recovery-index.json")
        let indexBytes = try Data(contentsOf: indexURL)
        let journalURL = directory.appendingPathComponent("migration.json")
        let journalBytes = Data(
            """
            {"schemaVersion":2,"sourceKey":"\(source.stableKey)","destinationKey":"\(destination.stableKey)","snapshotIDs":["\(entryID.uuidString.lowercased())"],"rawIDs":[],"phase":"committed","previousGenerations":{"\(source.stableKey)":1,"\(unrelated.stableKey)":1},"nextGenerations":{"\(source.stableKey)":2,"\(destination.stableKey)":2,"\(unrelated.stableKey)":0}}
            """.utf8
        )
        try journalBytes.write(to: journalURL)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        await assertThrowsErrorAsync(try await reopened.start()) { error in
            XCTAssertEqual(error as? SessionRecoveryStoreError, .malformedData)
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBytes)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), migratedData)
    }

    func testPreparingDeletionJournalCannotRemoveAnUnrelatedGeneration()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/delete-generation.md")
        let unrelated = DocumentIdentity(
            stableKey: "path:/tmp/delete-generation-unrelated.md"
        )
        let snapshot = DocumentSnapshot(
            text: "deletion generation evidence\n",
            format: .newDocument
        )
        let entryID = UUID()
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(
            id: entryID,
            snapshot: snapshot,
            for: identity,
            expectedRecords: .empty,
            expectedGeneration: 0
        )
        _ = try await seed.add(
            id: UUID(),
            snapshot: snapshot,
            for: unrelated,
            expectedRecords: .empty,
            expectedGeneration: 0
        )

        let snapshotName = "\(entryID.uuidString.lowercased()).snapshot.json"
        let snapshotURL = directory.appendingPathComponent(snapshotName)
        let tombstoneName = ".\(snapshotName).\(UUID().uuidString.lowercased()).delete"
        let tombstoneURL = directory.appendingPathComponent(tombstoneName)
        try FileManager.default.moveItem(at: snapshotURL, to: tombstoneURL)
        let tombstoneBytes = try Data(contentsOf: tombstoneURL)
        let indexURL = directory.appendingPathComponent("recovery-index.json")
        let indexBytes = try Data(contentsOf: indexURL)
        let journalURL = directory.appendingPathComponent("recovery-deletion.json")
        let journalBytes = Data(
            """
            {"schemaVersion":2,"entries":[{"sourceName":"\(snapshotName)","tombstoneName":"\(tombstoneName)"}],"phase":"preparing","previousGenerations":{"\(identity.stableKey)":1,"\(unrelated.stableKey)":1},"nextGenerations":{"\(identity.stableKey)":2}}
            """.utf8
        )
        try journalBytes.write(to: journalURL)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        await assertThrowsErrorAsync(try await reopened.start()) { error in
            XCTAssertEqual(error as? SessionRecoveryStoreError, .malformedData)
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBytes)
        XCTAssertEqual(try Data(contentsOf: tombstoneURL), tombstoneBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testPreparingDeletionWithNextGenerationIndexRestoresThePreviousIndex()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(
            stableKey: "path:/tmp/deletion-index-boundary.md"
        )
        let snapshot = DocumentSnapshot(
            text: "recover deletion boundary\n",
            format: .newDocument
        )
        let entryID = UUID()
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        let persisted = try await seed.add(
            id: entryID,
            snapshot: snapshot,
            for: identity,
            expectedRecords: .empty,
            expectedGeneration: 0
        )
        XCTAssertEqual(persisted.generation, 1)

        let snapshotName = "\(entryID.uuidString.lowercased()).snapshot.json"
        let snapshotURL = directory.appendingPathComponent(snapshotName)
        let tombstoneName = ".\(snapshotName).\(UUID().uuidString.lowercased()).delete"
        let tombstoneURL = directory.appendingPathComponent(tombstoneName)
        try FileManager.default.moveItem(at: snapshotURL, to: tombstoneURL)
        try Data(
            """
            {"schemaVersion":2,"generations":{"\(identity.stableKey)":2}}
            """.utf8
        ).write(to: directory.appendingPathComponent("recovery-index.json"))
        let journalURL = directory.appendingPathComponent("recovery-deletion.json")
        try Data(
            """
            {"schemaVersion":2,"entries":[{"sourceName":"\(snapshotName)","tombstoneName":"\(tombstoneName)"}],"phase":"preparing","previousGenerations":{"\(identity.stableKey)":1},"nextGenerations":{"\(identity.stableKey)":2}}
            """.utf8
        ).write(to: journalURL)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        let recovered = try await reopened.latest(for: identity)
        let recoveredGeneration = try await reopened.typedMutationGeneration(
            for: identity
        )

        XCTAssertEqual(recovered?.snapshot, snapshot)
        XCTAssertEqual(recoveredGeneration, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func dataByReplacingStableKey(
        in data: Data,
        with stableKey: String
    ) throws -> Data {
        guard
            var object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw RecoveryStoreIssue.malformedData
        }
        object["stableKey"] = stableKey
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }
}

private enum InjectedMigrationError: Error {
    case interrupted
}

private final class MigrationInterruptionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = true

    func consumePendingInterruption() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isPending else { return false }
        isPending = false
        return true
    }
}

@MainActor
private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: @MainActor (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error, but the operation succeeded.")
    } catch {
        handler(error)
    }
}
