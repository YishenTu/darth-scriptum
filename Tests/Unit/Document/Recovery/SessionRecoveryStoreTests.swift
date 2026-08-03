import Darwin
import Foundation
import XCTest

@testable import DarthScriptum

@MainActor
final class SessionRecoveryStoreTests: XCTestCase {
    func testRawPersistenceRejectsArtifactThatStartupCannotRead()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/oversized-raw.md")
        let oversizedData = Data(
            count: TextFileCodec.maximumDocumentByteCount + 1
        )
        let store = SessionRecoveryStore(persistenceDirectory: directory)

        do {
            _ = try await store.addRawData(oversizedData, for: identity)
            XCTFail("Expected raw persistence to reject an unreadable artifact")
        } catch {
            XCTAssertEqual(error as? RecoveryStoreIssue, .unavailable)
        }

        let persistedRawArtifacts = try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.lastPathComponent.hasSuffix(".raw")
                    || $0.lastPathComponent.hasSuffix(".raw.json")
            }
        XCTAssertTrue(persistedRawArtifacts.isEmpty)
    }

    func testSnapshotPersistenceRejectsArtifactThatStartupCannotRead()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/escaped.md")
        let escapeHeavyText = String(
            repeating: "\n",
            count: TextFileCodec.maximumDocumentByteCount / 2 + 1
        )
        let snapshot = DocumentSnapshot(
            text: escapeHeavyText,
            format: .newDocument
        )
        let store = SessionRecoveryStore(persistenceDirectory: directory)

        do {
            _ = try await store.add(snapshot: snapshot, for: identity)
            XCTFail("Expected persistence to reject an unreadable artifact")
        } catch {
            XCTAssertEqual(
                error as? RecoveryStoreIssue,
                .unavailable
            )
        }

        let persistedSnapshots = try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.hasSuffix(".snapshot.json") }
        XCTAssertTrue(persistedSnapshots.isEmpty)
    }

    func testStartupRejectsFIFOSnapshotWithoutWaitingForWriter() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).snapshot.json"
        )
        XCTAssertEqual(
            snapshotURL.path.withCString {
                Darwin.mkfifo($0, mode_t(0o600))
            },
            0
        )
        let completion = DispatchSemaphore(value: 0)
        let resultRecorder = RecoveryImportResultRecorder()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                _ = try SessionRecoveryStore.importPersistedState(
                    from: directory,
                    migrationWriteHook: nil
                )
                resultRecorder.recordRejected(false)
            } catch {
                resultRecorder.recordRejected(true)
            }
        }

        let initialWait = completion.wait(
            timeout: .now() + .milliseconds(250)
        )
        if initialWait == .timedOut {
            let writer = snapshotURL.path.withCString {
                Darwin.open($0, O_RDWR | O_NONBLOCK)
            }
            if writer >= 0 {
                Darwin.close(writer)
            }
            XCTAssertEqual(
                completion.wait(timeout: .now() + 2),
                .success
            )
        }

        XCTAssertEqual(initialWait, .success)
        XCTAssertTrue(resultRecorder.wasRejected)
    }

    func testStartupRejectsOversizedSnapshotBeforeDecoding() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).snapshot.json"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: snapshotURL.path,
                contents: nil
            )
        )
        let handle = try FileHandle(forWritingTo: snapshotURL)
        let oversizedByteCount = TextFileCodec.maximumDocumentByteCount + 1
        try handle.truncate(atOffset: UInt64(oversizedByteCount))
        try handle.close()

        XCTAssertThrowsError(
            try SessionRecoveryStore.importPersistedState(
                from: directory,
                migrationWriteHook: nil
            )
        ) { error in
            guard
                case .documentTooLarge(let byteCount, let maximumByteCount) =
                    error as? TextFileCodec.CodecError
            else {
                return XCTFail("Expected a size-limit error, got \(error)")
            }
            XCTAssertEqual(byteCount, oversizedByteCount)
            XCTAssertEqual(
                maximumByteCount,
                TextFileCodec.maximumDocumentByteCount
            )
        }
    }

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
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/exact-id.md")
        let snapshot = DocumentSnapshot(
            text: "exact recovery\n",
            format: .newDocument
        )
        let entryID = UUID()
        let store = SessionRecoveryStore(persistenceDirectory: directory)

        await assertThrowsErrorAsync(
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
        async throws
    {
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

        for _ in 0..<4 {
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
        await assertThrowsErrorAsync(
            try await store.persistFreshDecodedConflict(
                id: UUID(),
                snapshot: snapshot,
                for: destination,
                expectedGeneration: destinationGeneration
            )
        )
    }

    func testMigrationAdvancesTheSourceTombstoneToRejectStaleSourceMutation()
        async throws
    {
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
        await assertThrowsErrorAsync(
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
        async throws
    {
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
        async throws
    {
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

        await assertThrowsErrorAsync(
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

    func testLoadDataWhenURLBackedPayloadChangesAtSameLengthRejectsRecovery()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(
            stableKey: "path:/tmp/mutated-recovery.md"
        )
        let byteCount = 1 * 1_024 * 1_024 + 1
        let originalData = Data(repeating: 0xA5, count: byteCount)
        let store = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await store.addRawData(originalData, for: identity)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        let rawEntries = try await reopened.rawRecoveryEntries(for: identity)
        let entry = try XCTUnwrap(rawEntries.first)
        let dataURL = try XCTUnwrap(entry.dataURL)
        try Data(repeating: 0x5A, count: byteCount).write(
            to: dataURL,
            options: .atomic
        )

        await assertThrowsErrorAsync(try await entry.loadData()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .malformedData)
        }
    }

    func testLoadDataWhenURLBackedPayloadLengthChangesRejectsRecovery()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataURL = directory.appendingPathComponent("length-changed.raw")
        let originalData = Data("recovery".utf8)
        try Data("changed recovery".utf8).write(to: dataURL)
        let entry = RawRecoveryEntry(
            id: UUID(),
            documentIdentity: DocumentIdentity(
                stableKey: "path:/tmp/length-changed.md"
            ),
            dataURL: dataURL,
            byteCount: originalData.count,
            contentDigest: FileFingerprint.make(data: originalData).contentDigest,
            createdAt: Date(),
            residentData: nil
        )

        await assertThrowsErrorAsync(try await entry.loadData()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .malformedData)
        }
    }

    func testURLBackedRawRecoveryRejectsOversizedPayload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataURL = directory.appendingPathComponent("oversized.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: dataURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: dataURL)
        try handle.truncate(
            atOffset: UInt64(TextFileCodec.maximumDocumentByteCount + 1)
        )
        try handle.close()
        let entry = RawRecoveryEntry(
            id: UUID(),
            documentIdentity: DocumentIdentity(stableKey: "path:/tmp/oversized.md"),
            dataURL: dataURL,
            byteCount: TextFileCodec.maximumDocumentByteCount + 1,
            contentDigest: "unused",
            createdAt: Date(),
            residentData: nil
        )

        await assertThrowsErrorAsync(try await entry.loadData()) { error in
            guard
                case .documentTooLarge(let byteCount, let maximumByteCount) =
                    error as? TextFileCodec.CodecError
            else {
                return XCTFail("Expected an oversized-document error, got \(error)")
            }
            XCTAssertEqual(
                byteCount,
                TextFileCodec.maximumDocumentByteCount + 1
            )
            XCTAssertEqual(
                maximumByteCount,
                TextFileCodec.maximumDocumentByteCount
            )
        }
    }

    func testURLBackedRawRecoveryRejectsSymbolicLinkPayload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let referentURL = directory.appendingPathComponent("referent.raw")
        let dataURL = directory.appendingPathComponent("recovery.raw")
        let data = Data("recovery".utf8)
        try data.write(to: referentURL)
        try FileManager.default.createSymbolicLink(
            at: dataURL,
            withDestinationURL: referentURL
        )
        let entry = RawRecoveryEntry(
            id: UUID(),
            documentIdentity: DocumentIdentity(stableKey: "path:/tmp/symlink.md"),
            dataURL: dataURL,
            byteCount: data.count,
            contentDigest: FileFingerprint.make(data: data).contentDigest,
            createdAt: Date(),
            residentData: nil
        )

        await assertThrowsErrorAsync(try await entry.loadData()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ELOOP)
        }
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

private final class RecoveryImportResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    var wasRejected: Bool {
        lock.withLock { rejected }
    }

    func recordRejected(_ rejected: Bool) {
        lock.withLock {
            self.rejected = rejected
        }
    }
}
private enum InjectedRawPersistenceError: Error, Equatable {
    case interrupted
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
