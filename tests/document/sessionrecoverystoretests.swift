import Foundation
import XCTest
@testable import DarthMD

@MainActor
final class SessionRecoveryStoreTests: XCTestCase {
    func testSnapshotRecoverySurvivesStoreRecreation() throws {
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
        try firstStore.add(snapshot: snapshot, for: identity)

        let reopenedStore = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let recovered = try XCTUnwrap(reopenedStore.latest(for: identity))
        XCTAssertEqual(recovered.snapshot, snapshot)

        reopenedStore.remove(recovered)
        XCTAssertNil(
            SessionRecoveryStore(
                persistenceDirectory: directory
            ).latest(for: identity)
        )
    }

    func testRawRecoverySurvivesStoreRecreationWithoutDecoding() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/invalid.md")
        let invalidBytes = Data([0xFF, 0xFE, 0x00])
        let firstStore = SessionRecoveryStore(
            persistenceDirectory: directory
        )

        let entry = try firstStore.addRawData(
            invalidBytes,
            for: identity
        )

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(entry.dataURL)), invalidBytes)
        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        XCTAssertEqual(
            reopened.rawRecoveryEntries(for: identity).first?.data,
            invalidBytes
        )
    }

    func testReopenedRawRecoveryRemainsURLBackedUntilRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(
            stableKey: "path:/tmp/lazy-recovery.md"
        )
        let rawData = Data(repeating: 0xA5, count: 5 * 1_024 * 1_024)
        let store = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        try store.addRawData(rawData, for: identity)

        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        let entry = try XCTUnwrap(
            reopened.rawRecoveryEntries(for: identity).first
        )

        XCTAssertFalse(entry.isDataResident)
        XCTAssertEqual(entry.byteCount, rawData.count)
        XCTAssertEqual(entry.data, rawData)
        XCTAssertFalse(entry.isDataResident)
    }

    func testNewestRecoveryIsPinnedOutsideTheHistoricalByteLimit() throws {
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

        try store.add(snapshot: snapshot, for: identity)

        XCTAssertEqual(store.latest(for: identity)?.snapshot, snapshot)
        XCTAssertEqual(
            SessionRecoveryStore(
                persistenceDirectory: directory,
                totalByteLimit: 8
            ).latest(for: identity)?.snapshot,
            snapshot
        )
    }

    func testFailedMoveKeepsEntriesUnderTheOriginalIdentity() throws {
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
        try store.add(snapshot: snapshot, for: oldIdentity)
        try store.addRawData(rawData, for: oldIdentity)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)

        XCTAssertThrowsError(
            try store.moveEntries(
                from: oldIdentity,
                to: newIdentity
            )
        )
        XCTAssertEqual(store.latest(for: oldIdentity)?.snapshot, snapshot)
        XCTAssertEqual(
            store.rawRecoveryEntries(for: oldIdentity).first?.data,
            rawData
        )
        XCTAssertNil(store.latest(for: newIdentity))
        XCTAssertTrue(store.rawRecoveryEntries(for: newIdentity).isEmpty)
    }

    func testInterruptedMoveRecoversOneIdentityAfterReopening() throws {
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
        try store.add(snapshot: snapshot, for: oldIdentity)
        try store.addRawData(rawData, for: oldIdentity)

        XCTAssertThrowsError(
            try store.moveEntries(
                from: oldIdentity,
                to: newIdentity
            )
        )

        let readOnlyReopen = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        XCTAssertEqual(
            readOnlyReopen.latest(for: oldIdentity)?.snapshot,
            snapshot
        )
        XCTAssertEqual(
            readOnlyReopen.rawRecoveryEntries(for: oldIdentity).first?.data,
            rawData
        )
        XCTAssertNil(readOnlyReopen.latest(for: newIdentity))
        XCTAssertTrue(
            readOnlyReopen.rawRecoveryEntries(for: newIdentity).isEmpty
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let repairedReopen = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        XCTAssertEqual(
            repairedReopen.latest(for: oldIdentity)?.snapshot,
            snapshot
        )
        XCTAssertNil(repairedReopen.latest(for: newIdentity))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("migration.json")
                    .path
            )
        )
    }

    func testSuccessfulMoveIsCommittedForTheNextStoreInstance() throws {
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
        try store.add(snapshot: snapshot, for: oldIdentity)
        try store.addRawData(rawData, for: oldIdentity)

        try store.moveEntries(
            from: oldIdentity,
            to: newIdentity
        )

        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        XCTAssertNil(reopened.latest(for: oldIdentity))
        XCTAssertTrue(
            reopened.rawRecoveryEntries(for: oldIdentity).isEmpty
        )
        XCTAssertEqual(
            reopened.latest(for: newIdentity)?.snapshot,
            snapshot
        )
        XCTAssertEqual(
            reopened.rawRecoveryEntries(for: newIdentity).first?.data,
            rawData
        )
    }

    func testAnotherMoveRepairsAnInterruptedJournalBeforeStarting() throws {
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
        var shouldInterrupt = true
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            migrationWriteHook: { _ in
                guard shouldInterrupt else { return }
                shouldInterrupt = false
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: directory.path
                )
                throw InjectedMigrationError.interrupted
            }
        )
        try store.add(snapshot: firstSnapshot, for: firstSource)
        try store.add(snapshot: secondSnapshot, for: secondSource)

        XCTAssertThrowsError(
            try store.moveEntries(
                from: firstSource,
                to: firstDestination
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        try store.moveEntries(
            from: secondSource,
            to: secondDestination
        )

        let reopened = SessionRecoveryStore(
            persistenceDirectory: directory
        )
        XCTAssertEqual(
            reopened.latest(for: firstSource)?.snapshot,
            firstSnapshot
        )
        XCTAssertNil(reopened.latest(for: firstDestination))
        XCTAssertNil(reopened.latest(for: secondSource))
        XCTAssertEqual(
            reopened.latest(for: secondDestination)?.snapshot,
            secondSnapshot
        )
    }

    func testMalformedMigrationJournalBlocksAnotherMove() throws {
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
        try store.add(snapshot: snapshot, for: oldIdentity)
        try Data("{not valid json".utf8).write(
            to: directory.appendingPathComponent("migration.json")
        )

        XCTAssertThrowsError(
            try store.moveEntries(
                from: oldIdentity,
                to: newIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionRecoveryStoreError,
                .unreadableMigrationJournal
            )
        }
        XCTAssertEqual(store.latest(for: oldIdentity)?.snapshot, snapshot)
        XCTAssertNil(store.latest(for: newIdentity))
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

private enum InjectedMigrationError: Error {
    case interrupted
}
