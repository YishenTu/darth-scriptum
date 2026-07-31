import Foundation
import XCTest
@testable import DarthScriptum

@MainActor
final class SessionRecoveryStoreAsyncTests: XCTestCase {
    func testStartupImportsExistingRecoveryAndTransitionsFromLoadingToReady()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/startup-import.md")
        let snapshot = DocumentSnapshot(
            text: "existing recovery\n",
            format: .newDocument
        )

        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(snapshot: snapshot, for: identity)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        let loadingStatus = await store.status()
        XCTAssertEqual(loadingStatus, .loading)

        let imported = try await store.start()

        let readyStatus = await store.status()
        XCTAssertEqual(readyStatus, .ready(generation: 1))
        XCTAssertEqual(imported.records(for: identity).decoded.first?.snapshot, snapshot)
    }

    func testFailedStartupPreservesMalformedEvidenceUntilRetrySucceeds()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let migrationURL = directory.appendingPathComponent("migration.json")
        try Data("{ malformed".utf8).write(to: migrationURL)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await store.start()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .malformedData)
        }
        let failedStatus = await store.status()
        XCTAssertEqual(failedStatus, .failed(.malformedData))
        XCTAssertEqual(try Data(contentsOf: migrationURL), Data("{ malformed".utf8))

        try FileManager.default.removeItem(at: migrationURL)
        let imported = try await store.retryStartup()

        XCTAssertTrue(imported.records.isEmpty)
        let readyStatus = await store.status()
        XCTAssertEqual(readyStatus, .ready(generation: 0))
    }

    func testQueuedMutationWaitsForStartupImportAndUsesTheImportedGeneration()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/queued-intent.md")
        let importedSnapshot = DocumentSnapshot(
            text: "imported\n",
            format: .newDocument
        )
        let newSnapshot = DocumentSnapshot(
            text: "queued\n",
            format: .newDocument
        )

        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(snapshot: importedSnapshot, for: identity)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        async let queued = store.add(
            snapshot: newSnapshot,
            for: identity,
            expectedGeneration: 1
        )
        let receipt = try await queued

        XCTAssertEqual(receipt.previousGeneration, 1)
        XCTAssertEqual(receipt.generation, 2)
        XCTAssertEqual(receipt.decodedEntries.map(\.snapshot), [newSnapshot, importedSnapshot])
    }

    func testFIFOQueueSerializesCrossDocumentMigrationTrimAndDeletion()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DocumentIdentity(stableKey: "path:/tmp/fifo-source.md")
        let destination = DocumentIdentity(
            stableKey: "path:/tmp/fifo-destination.md"
        )
        let sibling = DocumentIdentity(stableKey: "path:/tmp/fifo-sibling.md")
        let sourceSnapshot = DocumentSnapshot(
            text: "source recovery\n",
            format: .newDocument
        )
        let initialSiblingSnapshot = DocumentSnapshot(
            text: "first sibling recovery\n",
            format: .newDocument
        )
        let trimmedSiblingSnapshot = DocumentSnapshot(
            text: "second sibling recovery\n",
            format: .newDocument
        )
        let migrationGate = BlockingRecoveryIOGate()
        let commandRecorder = RecoveryCommandEnqueueRecorder()
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            perDocumentLimit: 1,
            migrationWriteHook: { writeCount in
                guard writeCount == 1 else { return }
                migrationGate.blockUntilReleased()
            },
            commandEnqueueHook: { kind in
                commandRecorder.record(kind)
            }
        )
        defer { migrationGate.release() }

        let sourceSeed = try await store.add(
            snapshot: sourceSnapshot,
            for: source
        )
        let sourceEntry = try XCTUnwrap(sourceSeed.decodedEntries.first)
        let siblingSeed = try await store.add(
            snapshot: initialSiblingSnapshot,
            for: sibling
        )
        XCTAssertEqual(sourceSeed.generation, 1)
        XCTAssertEqual(siblingSeed.generation, 1)

        let migration = Task {
            try await store.moveEntries(
                from: source,
                to: destination,
                expectedRecords: DocumentSyncRecoveryRecords(
                    decoded: [sourceEntry],
                    raw: []
                ),
                expectedGeneration: sourceSeed.generation
            )
        }
        await migrationGate.waitUntilBlocked()
        XCTAssertEqual(commandRecorder.count(of: .migrate), 1)

        let snapshotCommandsBeforeSibling = commandRecorder.count(
            of: .persistSnapshot
        )
        let siblingCompletion = RecoveryTaskCompletionProbe()
        let siblingWrite = Task {
            defer { siblingCompletion.markCompleted() }
            return try await store.add(
                snapshot: trimmedSiblingSnapshot,
                for: sibling
            )
        }
        await commandRecorder.waitForCount(
            of: .persistSnapshot,
            atLeast: snapshotCommandsBeforeSibling + 1
        )
        XCTAssertFalse(siblingCompletion.isCompleted)

        migrationGate.release()
        let migrationReceipt = try await migration.value
        let siblingReceipt = try await siblingWrite.value

        XCTAssertEqual(migrationReceipt.previousGeneration, sourceSeed.generation)
        XCTAssertEqual(migrationReceipt.generation, 2)
        XCTAssertEqual(
            migrationReceipt.decodedEntries.map(\.snapshot),
            [sourceSnapshot]
        )
        XCTAssertEqual(siblingReceipt.previousGeneration, siblingSeed.generation)
        XCTAssertEqual(siblingReceipt.generation, 2)
        XCTAssertEqual(
            siblingReceipt.decodedEntries.map(\.snapshot),
            [trimmedSiblingSnapshot]
        )

        let retainedSibling = try XCTUnwrap(siblingReceipt.decodedEntries.first)
        let deletionReceipt = try await store.discardExactDecodedConflict(
            retainedSibling,
            for: sibling,
            expectedGeneration: siblingReceipt.generation
        )
        XCTAssertEqual(deletionReceipt.previousGeneration, siblingReceipt.generation)
        XCTAssertEqual(deletionReceipt.generation, 3)
        XCTAssertTrue(deletionReceipt.decodedEntries.isEmpty)
        XCTAssertEqual(commandRecorder.count(of: .discard), 1)

        let reopened = SessionRecoveryStore(persistenceDirectory: directory)
        let sourceAfterMove = try await reopened.latest(for: source)
        XCTAssertNil(sourceAfterMove)
        let destinationAfterMove = try await reopened.latest(for: destination)
        XCTAssertEqual(destinationAfterMove?.snapshot, sourceSnapshot)
        let siblingAfterDeletion = try await reopened.latest(for: sibling)
        XCTAssertNil(siblingAfterDeletion)
    }

    func testLargeRecoveryStartupDoesNotBlockTheMainActor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DocumentIdentity(stableKey: "path:/tmp/large-startup.md")
        let snapshot = DocumentSnapshot(
            text: String(repeating: "x", count: 2 * 1_024 * 1_024),
            format: .newDocument
        )
        let seed = SessionRecoveryStore(persistenceDirectory: directory)
        _ = try await seed.add(snapshot: snapshot, for: identity)

        let startupGate = BlockingRecoveryIOGate()
        let store = SessionRecoveryStore(
            persistenceDirectory: directory,
            startupReadHook: {
                startupGate.blockUntilReleased()
            }
        )
        defer { startupGate.release() }

        let startup = Task { try await store.start() }
        await startupGate.waitUntilBlocked()

        let heartbeat = MainActorHeartbeat()
        Task { @MainActor in
            heartbeat.record()
        }
        await heartbeat.waitForRecord()
        XCTAssertTrue(heartbeat.didRecord)
        let statusWhileBlocked = await store.status()
        XCTAssertEqual(statusWhileBlocked, .loading)

        startupGate.release()
        let imported = try await startup.value
        XCTAssertEqual(imported.records(for: identity).decoded.first?.snapshot, snapshot)
    }

    func testNewerSchemaFailsClosedWithoutReplacingThePersistedPayload()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entryID = UUID().uuidString.lowercased()
        let snapshotURL = directory.appendingPathComponent("\(entryID).snapshot.json")
        let newerPayload = Data(
            """
            {"schemaVersion":999,"id":"\(entryID)","stableKey":"path:/tmp/newer.md","text":"preserve","encoding":"utf8","newline":"lf","hasFinalNewline":false,"createdAt":0}
            """.utf8
        )
        try newerPayload.write(to: snapshotURL)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await store.start()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .unsupportedSchema)
        }
        let failedStatus = await store.status()
        XCTAssertEqual(failedStatus, .failed(.unsupportedSchema))
        XCTAssertEqual(try Data(contentsOf: snapshotURL), newerPayload)
    }

    func testOrphanRawPayloadFailsClosedWithoutDiscardingItsBytes()
        async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadURL = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).raw"
        )
        let payload = Data([0xFF, 0x00, 0xC0])
        try payload.write(to: payloadURL)

        let store = SessionRecoveryStore(persistenceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await store.start()) { error in
            XCTAssertEqual(error as? RecoveryStoreIssue, .malformedData)
        }

        XCTAssertEqual(try Data(contentsOf: payloadURL), payload)
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

private final class BlockingRecoveryIOGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var hasEntered = false
    private var hasReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() {
        let waiters: [CheckedContinuation<Void, Never>]
        let shouldBlock: Bool
        lock.lock()
        hasEntered = true
        waiters = entryWaiters
        entryWaiters.removeAll()
        shouldBlock = !hasReleased
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
                return
            }
            entryWaiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        let shouldSignal: Bool
        lock.lock()
        if hasReleased {
            lock.unlock()
            return
        }
        hasReleased = true
        shouldSignal = hasEntered
        lock.unlock()

        if shouldSignal {
            releaseSemaphore.signal()
        }
    }
}

private final class RecoveryCommandEnqueueRecorder: @unchecked Sendable {
    private struct Waiter {
        let kind: SessionRecoveryStoreCommandKind
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var kinds: [SessionRecoveryStoreCommandKind] = []
    private var waiters: [Waiter] = []

    func record(_ kind: SessionRecoveryStoreCommandKind) {
        var readyWaiters: [Waiter] = []
        var remainingWaiters: [Waiter] = []
        lock.lock()
        kinds.append(kind)
        let currentCount = count(of: kind, in: kinds)
        for waiter in waiters {
            if waiter.kind == kind && currentCount >= waiter.minimumCount {
                readyWaiters.append(waiter)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        waiters = remainingWaiters
        lock.unlock()

        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func count(of kind: SessionRecoveryStoreCommandKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count(of: kind, in: kinds)
    }

    func waitForCount(
        of kind: SessionRecoveryStoreCommandKind,
        atLeast minimumCount: Int
    ) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count(of: kind, in: kinds) >= minimumCount {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(
                Waiter(
                    kind: kind,
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            )
            lock.unlock()
        }
    }

    private func count(
        of kind: SessionRecoveryStoreCommandKind,
        in recordedKinds: [SessionRecoveryStoreCommandKind]
    ) -> Int {
        recordedKinds.filter { $0 == kind }.count
    }
}

private final class RecoveryTaskCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

@MainActor
private final class MainActorHeartbeat {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didRecord = false

    func record() {
        didRecord = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitForRecord() async {
        if didRecord { return }
        await withCheckedContinuation { continuation in
            if didRecord {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
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
