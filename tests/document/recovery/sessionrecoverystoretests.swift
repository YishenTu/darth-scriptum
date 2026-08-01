import Foundation
import XCTest
@testable import DarthScriptum

@MainActor
final class SessionRecoveryStoreTests: XCTestCase {
    func testSnapshotRecoverySurvivesStoreRecreation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/persistent.md")
        let snapshot = DocumentSnapshot(
            text: "recover me\n",
            format: TextFileFormat(
                encoding: .utf8WithBOM,
                dominantNewline: .lf,
                hasFinalNewline: true
            )
        )

        let firstStore = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        _ = try await firstStore.add(snapshot: snapshot, for: identity)

        let reopenedStore = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let recoveredValue = try await reopenedStore.latest(for: identity)
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.snapshot, snapshot)

        try await reopenedStore.remove(recovered)
        let afterRemoval = try await SessionRecoveryStore(
            persistenceDirectory: directory
        ).latest(for: identity)
        XCTAssertNil(afterRemoval)
    }

    func testFreshConflictReceiptUsesStoreGenerationAndDurablyRemovesExactEntry()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/exact-id.md")
        let snapshot = DocumentSnapshot(
            text: "exact recovery\n",
            format: .newDocument
        )
        let entryID = UUID()
        let store = SessionRecoveryStore(persistenceDirectory: directory)

        await XCTAssertThrowsErrorAsync(
            try await store.persistFreshDecodedConflict(
                id: entryID,
                snapshot: snapshot,
                for: identity,
                expectedGeneration: 1
            )
        )

        let persisted = try await store.persistFreshDecodedConflict(
            id: entryID,
            snapshot: snapshot,
            for: identity,
            expectedGeneration: 0
        )
        let entry = try XCTUnwrap(persisted.decodedEntries.first)

        XCTAssertEqual(persisted.previousGeneration, 0)
        XCTAssertEqual(persisted.generation, 1)
        XCTAssertEqual(entry.id, entryID)
        XCTAssertEqual(persisted.decodedEntries, [entry])
        XCTAssertTrue(persisted.rawEntries.isEmpty)
        let latest = try await store.latest(for: identity)
        XCTAssertEqual(latest, entry)

        let discarded = try await store.discardExactDecodedConflict(
            entry,
            for: identity,
            expectedGeneration: persisted.generation
        )

        XCTAssertEqual(discarded.previousGeneration, 1)
        XCTAssertEqual(discarded.generation, 2)
        XCTAssertTrue(discarded.decodedEntries.isEmpty)
        XCTAssertTrue(discarded.rawEntries.isEmpty)
        let removed = try await store.latest(for: identity)
        XCTAssertNil(removed)
        let reopened = try await SessionRecoveryStore(
            persistenceDirectory: directory
        ).latest(for: identity)
        XCTAssertNil(reopened)
    }

    func testEmptyMigrationAdvancesTheDestinationGenerationForFreshConflict()
        async throws {
        let source = DocumentIdentity(stableKey: "path:/tmp/empty-source.md")
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/empty-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "fresh conflict\n",
            format: .newDocument
        )
        let store = SessionRecoveryStore()

        let migration = try await store.advanceEmptyRecoveryMigration(
            from: source,
            to: destination,
            expectedGeneration: 0
        )

        XCTAssertEqual(migration.previousGeneration, 0)
        XCTAssertEqual(migration.generation, 1)
        XCTAssertTrue(migration.decodedEntries.isEmpty)
        XCTAssertTrue(migration.rawEntries.isEmpty)

        let persisted = try await store.persistFreshDecodedConflict(
            id: UUID(),
            snapshot: snapshot,
            for: destination,
            expectedGeneration: migration.generation
        )

        XCTAssertEqual(persisted.previousGeneration, 1)
        XCTAssertEqual(persisted.generation, 2)
        XCTAssertEqual(persisted.decodedEntries.first?.snapshot, snapshot)
    }

    func testMigrationNeverRegressesAnEmptyDestinationGeneration() async throws {
        let source = DocumentIdentity(stableKey: "path:/tmp/fresh-source.md")
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/advanced-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "generation evidence\n",
            format: .newDocument
        )
        let store = SessionRecoveryStore()
        var destinationGeneration: UInt64 = 0

        for _ in 0 ..< 4 {
            let persisted = try await store.persistFreshDecodedConflict(
                id: UUID(),
                snapshot: snapshot,
                for: destination,
                expectedGeneration: destinationGeneration
            )
            let entry = try XCTUnwrap(persisted.decodedEntries.first)
            let discarded = try await store.discardExactDecodedConflict(
                entry,
                for: destination,
                expectedGeneration: persisted.generation
            )
            destinationGeneration = discarded.generation
        }

        XCTAssertEqual(destinationGeneration, 8)
        let migration = try await store.advanceEmptyRecoveryMigration(
            from: source,
            to: destination,
            expectedGeneration: 0
        )

        XCTAssertEqual(migration.previousGeneration, 0)
        XCTAssertEqual(migration.generation, 9)
        await XCTAssertThrowsErrorAsync(
            try await store.persistFreshDecodedConflict(
                id: UUID(),
                snapshot: snapshot,
                for: destination,
                expectedGeneration: destinationGeneration
            )
        )
    }

    func testMigrationAdvancesTheSourceTombstoneToRejectStaleSourceMutation()
        async throws {
        let source = DocumentIdentity(stableKey: "path:/tmp/stale-source.md")
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/stale-destination.md"
        )
        let snapshot = DocumentSnapshot(
            text: "stale source mutation\n",
            format: .newDocument
        )
        let store = SessionRecoveryStore()

        _ = try await store.advanceEmptyRecoveryMigration(
            from: source,
            to: destination,
            expectedGeneration: 0
        )

        let sourceGeneration = try await store.typedMutationGeneration(for: source)
        XCTAssertEqual(sourceGeneration, 1)
        await XCTAssertThrowsErrorAsync(
            try await store.persistFreshDecodedConflict(
                id: UUID(),
                snapshot: snapshot,
                for: source,
                expectedGeneration: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionRecoveryStoreError,
                .unexpectedMutationGeneration
            )
        }
    }

    func testTypedConflictGenerationsAreIndependentPerDocumentIdentity()
        async throws {
        let firstIdentity = DocumentIdentity(stableKey: "path:/tmp/first.md")
        let secondIdentity = DocumentIdentity(stableKey: "path:/tmp/second.md")
        let store = SessionRecoveryStore()

        let first = try await store.persistFreshDecodedConflict(
            id: UUID(),
            snapshot: DocumentSnapshot(text: "first\n", format: .newDocument),
            for: firstIdentity,
            expectedGeneration: 0
        )
        let second = try await store.persistFreshDecodedConflict(
            id: UUID(),
            snapshot: DocumentSnapshot(text: "second\n", format: .newDocument),
            for: secondIdentity,
            expectedGeneration: 0
        )

        XCTAssertEqual(first.previousGeneration, 0)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(second.previousGeneration, 0)
        XCTAssertEqual(second.generation, 1)
    }

    func testRawRecoverySurvivesStoreRecreationWithoutDecoding() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/invalid.md")
        let invalidBytes = Data([0xFF, 0xFE, 0x00])
        let firstStore = SessionRecoveryStore(
            persistenceDirectory: directory
        )

        let entry = try await firstStore.addRawData(
            invalidBytes,
            for: identity
        )

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(entry.dataURL)), invalidBytes)
        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let reopenedRawEntries = try await reopened.rawRecoveryEntries(
            for: identity
        )
        let reopenedEntry = try XCTUnwrap(reopenedRawEntries.first)
        let reopenedData = try await reopenedEntry.loadData()
        XCTAssertEqual(reopenedData, invalidBytes)
    }

    func testRawAcknowledgementMetadataFailureLeavesJournalReplayable()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("managed.md")
        let original = Data("base\n".utf8)
        let local = Data("local\n".utf8)
        let displaced = Data([0xFF, 0x00, 0xC0])
        try original.write(to: documentURL)
        let interruptedStore = SessionRecoveryStore(
            persistenceDirectory: directory,
            rawPersistenceHook: { phase in
                guard phase == .beforeAcknowledgementMetadata else { return }
                throw InjectedRawPersistenceError.interrupted
            }
        )
        _ = try await interruptedStore.start()
        let token = PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: "local\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(local)
            ),
            expectedDurableState: DurableFileState(
                snapshot: try TextFileCodec.decode(original),
                fingerprint: try SafeFileCommitter.fingerprint(
                    for: documentURL,
                    data: original
                ),
                generation: 1
            ),
            targetURL: documentURL
        )
        let result = try SafeFileCommitter(
            recoveryDirectory: directory,
            beforeAtomicSwap: {
                try displaced.write(to: documentURL)
            }
        ).commit(token)
        let artifact = try XCTUnwrap(result.recoveryArtifact)
        let rawData = try XCTUnwrap(result.displacedPreimage?.data)
        let identity = DocumentIdentity.make(url: documentURL)

        await XCTAssertThrowsErrorAsync(
            try await interruptedStore.persistRawData(
                rawData,
                for: identity,
                id: artifact.id,
                expectedRecords: nil,
                expectedGeneration: nil,
                recoveryArtifact: artifact
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionRecoveryStoreError,
                .unavailable
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "\(artifact.id.uuidString.lowercased()).raw"
                ).path
            )
        )

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        let rawEntries = try await reopened.rawRecoveryEntries(for: identity)
        let entry = try XCTUnwrap(rawEntries.first)
        let reopenedData = try await entry.loadData()
        XCTAssertEqual(reopenedData, displaced)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
    }

    func testReopenedRawRecoveryRemainsURLBackedUntilRead() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(
            stableKey: "path:/tmp/lazy-recovery.md"
        )
        let rawData = Data(repeating: 0xA5, count: 5 * 1_024 * 1_024)
        let store = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        _ = try await store.addRawData(rawData, for: identity)

        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let rawEntries = try await reopened.rawRecoveryEntries(for: identity)
        let entry = try XCTUnwrap(rawEntries.first)

        XCTAssertFalse(entry.isDataResident)
        XCTAssertEqual(entry.byteCount, rawData.count)
        let loadedRawData = try await entry.loadData()
        XCTAssertEqual(loadedRawData, rawData)
        XCTAssertFalse(entry.isDataResident)
    }

    func testNewestRecoveryIsPinnedOutsideTheHistoricalByteLimit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/large.md")
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            totalByteLimit: 8
        )
        let snapshot = DocumentSnapshot(
            text: String(repeating: "x", count: 32),
            format: .newDocument
        )

        _ = try await store.add(snapshot: snapshot, for: identity)

        let latest = try await store.latest(for: identity)
        XCTAssertEqual(latest?.snapshot, snapshot)
        let reopenedLatest = try await SessionRecoveryStore(
            persistenceDirectory: directory,
            totalByteLimit: 8
        ).latest(for: identity)
        XCTAssertEqual(reopenedLatest?.snapshot, snapshot)
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
}
private enum InjectedRawPersistenceError: Error, Equatable {
    case interrupted
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
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
