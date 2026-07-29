import Combine
import Foundation
import XCTest
@testable import DarthScriptum

@MainActor
final class DocumentSyncCoordinatorTests: XCTestCase {
    func testSaveAsAttachmentUsesTheCurrentBytesOnDisk() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "external\n")
        defer { fixture.remove() }
        let expectedData = Data("saved\n".utf8)
        let expectedSnapshot = try TextFileCodec.decode(expectedData)
        let coordinator = DocumentSyncCoordinator(snapshot: expectedSnapshot)
        defer { coordinator.close() }

        try await coordinator.attachAfterSaveAs(
            to: fixture.url,
            expectedData: expectedData,
            expectedSnapshot: expectedSnapshot
        )

        XCTAssertEqual(coordinator.durableState?.snapshot.text, "external\n")
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "external\n")
        XCTAssertEqual(
            coordinator.durableState?.fingerprint.contentDigest,
            FileFingerprint.make(data: Data("external\n".utf8)).contentDigest
        )
    }

    func testSuccessfulSaveAsClearsResolvedMissingStatus() async throws {
        let original = try TemporaryMarkdownFile(contents: "base\n")
        let destination = try TemporaryMarkdownFile(contents: "saved\n")
        defer {
            original.remove()
            destination.remove()
        }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: original.url
        )
        defer { coordinator.close() }

        try FileManager.default.removeItem(at: original.url)
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            coordinator.state == .missing
        }
        XCTAssertEqual(coordinator.presentedState, .missing)

        let savedData = Data("saved\n".utf8)
        let savedSnapshot = try TextFileCodec.decode(savedData)
        try await coordinator.attachAfterSaveAs(
            to: destination.url,
            expectedData: savedData,
            expectedSnapshot: savedSnapshot
        )

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.presentedState)
        XCTAssertEqual(coordinator.fileURL, destination.url.standardizedFileURL)
    }

    func testRoutineSynchronizationDoesNotInvalidateCoordinatorUI() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base")
        defer { fixture.remove() }
        let snapshot = try TextFileCodec.decode(Data("base".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        coordinator.loadInitial(
            snapshot,
            data: Data("base".utf8),
            from: fixture.url
        )
        defer { coordinator.close() }
        var publicationCount = 0
        let observation = coordinator.objectWillChange.sink {
            publicationCount += 1
        }

        coordinator.sourceBuffer.replace(
            with: "local",
            origin: .localEditor(paneID: UUID())
        )
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(publicationCount, 0)
        XCTAssertNil(coordinator.presentedState)
        withExtendedLifetime(observation) {}
    }

    func testNativePeriodicAutosavingIsDisabled() {
        XCTAssertFalse(MarkdownDocument.autosavesInPlace)
        XCTAssertFalse(MarkdownDocument.preservesVersions)
        XCTAssertFalse(MarkdownDocument.autosavesDrafts)
    }

    func testUnmanagedNativeAutosaveCannotBypassSynchronizedCommit() throws {
        let fixture = try TemporaryMarkdownFile(contents: "disk\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        defer { document.syncCoordinator.close() }

        XCTAssertThrowsError(
            try document.writeSafely(
                to: fixture.url,
                ofType: "net.daringfireball.markdown",
                for: .autosaveInPlaceOperation
            )
        ) { error in
            XCTAssertEqual(
                error as? MarkdownDocumentSaveError,
                .unmanagedInPlaceSave
            )
        }
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "disk\n"
        )
    }

    func testDocumentSerializationUsesLatestSourceDuringAnInstalledAutosave() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let document = MarkdownDocument()
        let initial = DocumentSnapshot(text: "base\n", format: .newDocument)
        document.syncCoordinator.loadInitial(
            initial,
            data: Data("base\n".utf8),
            from: fixture.url
        )
        let token = PendingSaveToken(
            generation: 1,
            sourceRevision: SourceRevision(number: 1, text: "older\n"),
            snapshot: DocumentSnapshot(text: "older\n", format: .newDocument),
            encodedData: Data("older\n".utf8),
            expectedDurableState: document.syncCoordinator.durableState,
            targetURL: fixture.url
        )
        try document.syncCoordinator.bridge.install(token)
        document.syncCoordinator.sourceBuffer.replace(
            with: "newest\n",
            origin: .localEditor(paneID: UUID())
        )

        let serialized = try document.data(
            ofType: "net.daringfireball.markdown"
        )

        XCTAssertEqual(try TextFileCodec.decode(serialized).text, "newest\n")
        XCTAssertFalse(
            document.canAsynchronouslyWrite(
                to: fixture.url.appendingPathExtension("copy"),
                ofType: "net.daringfireball.markdown",
                for: .saveAsOperation
            )
        )
        document.syncCoordinator.close()
    }

    func testFlushCompletionWaitsForTheDurableWrite() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let initialData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(initialData)
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: initialData,
            from: fixture.url
        )
        var token: PendingSaveToken?
        var flushResult: Bool?
        delegate.onSave = { token = $0 }

        coordinator.sourceBuffer.replace(
            with: "flushed\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.flushNow { flushResult = $0 }
        try await waitUntil { token != nil }
        XCTAssertNil(flushResult)

        let pendingToken = try XCTUnwrap(token)
        let result = try SafeFileCommitter().commit(pendingToken)
        try coordinator.bridge.store(result)
        coordinator.handleSaveCompletion(
            generation: pendingToken.generation,
            error: nil
        )

        XCTAssertEqual(flushResult, true)
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "flushed\n"
        )
        coordinator.close()
    }

    func testAttachAssociatesFingerprintWithTheSnapshotActuallyOnDisk() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "saved-before-new-edit\n")
        defer { fixture.remove() }
        let current = DocumentSnapshot(
            text: "new-edit-during-save-as\n",
            format: .newDocument
        )
        let coordinator = DocumentSyncCoordinator(snapshot: current)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        delegate.onSave = { token in
            do {
                let result = try SafeFileCommitter().commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(generation: token.generation, error: nil)
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }

        coordinator.attach(to: fixture.url)

        XCTAssertEqual(
            coordinator.durableState?.snapshot.text,
            "saved-before-new-edit\n"
        )
        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8))
                == "new-edit-during-save-as\n"
        }
        coordinator.close()
    }

    func testLocalEditWritesThroughAndExternalEditReloads() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)
        delegate.onSave = { token in
            do {
                let result = try SafeFileCommitter().commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(generation: token.generation, error: nil)
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8)) == "local\n"
        }
        XCTAssertEqual(coordinator.state, .idle)

        try Data("external\n".utf8).write(to: fixture.url)
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "external\n"
        }
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "external\n")
        XCTAssertEqual(delegate.acceptedExternalChangeCount, 1)
        coordinator.close()
    }

    func testSameContentAtomicReplacementRefreshesIdentityBeforeSaving()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        delegate.onSave = { token in
            do {
                let result = try SafeFileCommitter().commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: nil
                )
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: fixture.url
        )
        let originalIdentifier = coordinator.durableState?
            .fingerprint.resourceIdentifier

        try originalData.write(to: fixture.url, options: [.atomic])
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            coordinator.durableState?.fingerprint.resourceIdentifier
                != originalIdentifier
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8))
                == "local\n"
        }
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.close()
    }

    func testSameContentSymlinkRetargetMigratesRecoveryAndRemainsWritable()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstReferent = directory.appendingPathComponent("first.md")
        let secondReferent = directory.appendingPathComponent("second.md")
        let link = directory.appendingPathComponent("linked.md")
        let originalData = Data("base\n".utf8)
        try originalData.write(to: firstReferent)
        try originalData.write(to: secondReferent)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: firstReferent
        )
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: recoveryStore
        )
        let delegate = TestSyncDelegate(fileURL: link)
        delegate.onSave = { token in
            do {
                let result = try SafeFileCommitter(
                    recoveryDirectory: recoveryDirectory
                ).commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: nil
                )
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: originalData, from: link)
        let oldIdentity = DocumentIdentity.make(url: link)
        try recoveryStore.add(
            snapshot: DocumentSnapshot(
                text: "recoverable\n",
                format: snapshot.format
            ),
            for: oldIdentity
        )

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: secondReferent
        )
        let newIdentity = DocumentIdentity.make(url: link)
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            recoveryStore.latest(for: newIdentity) != nil
                && recoveryStore.latest(for: oldIdentity) == nil
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil {
            (try? String(contentsOf: secondReferent, encoding: .utf8))
                == "local\n"
        }
        XCTAssertEqual(
            try String(contentsOf: firstReferent, encoding: .utf8),
            "base\n"
        )
        coordinator.close()
    }

    func testMonitorRearmsAfterAtomicExternalReplacement() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: fixture.url
        )

        try Data("replacement\n".utf8).write(
            to: fixture.url,
            options: .atomic
        )
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "replacement\n"
        }

        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("direct\n".utf8))
        try handle.close()
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "direct\n"
        }

        XCTAssertGreaterThanOrEqual(delegate.acceptedExternalChangeCount, 2)
        coordinator.close()
    }

    func testRetryAfterExternalDecodeFailureRereadsTheFile() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let gate = SuspensionGate()
        var readCount = 0
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            externalReadHook: { _ in
                readCount += 1
                if readCount == 2 {
                    await gate.wait()
                }
            }
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: fixture.url
        )
        try Data([0xFF, 0x00, 0xC0]).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            if case .failed = coordinator.state {
                return true
            }
            return false
        }
        guard case .failed = coordinator.presentedState else {
            return XCTFail("The reload failure should remain visible.")
        }

        try Data("repaired\n".utf8).write(to: fixture.url)
        coordinator.retrySynchronization()
        try await waitUntil {
            readCount == 2 && coordinator.state == .checkingExternalChange
        }
        guard case .failed = coordinator.presentedState else {
            return XCTFail(
                "The unresolved failure should remain visible during retry."
            )
        }
        await gate.open()

        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "repaired\n"
        }
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.presentedState)
        coordinator.close()
    }

    func testUnsupportedAtomicSwapStopsAutomaticRetriesAndRequiresSaveAs()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        var externalReadObserved = false
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            externalReadHook: { _ in
                externalReadObserved = true
            }
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var saveAttempts = 0
        delegate.onSave = { token in
            saveAttempts += 1
            coordinator.handleSaveCompletion(
                generation: token.generation,
                error: SafeFileCommitter.CommitError.atomicSwapUnavailable
            )
        }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: fixture.url
        )

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil {
            coordinator.failureRequiresSaveAs
        }
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            guard externalReadObserved else { return false }
            if case .failed = coordinator.state {
                return true
            }
            return false
        }

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertTrue(coordinator.failureRequiresSaveAs)
        var flushResult: Bool?
        coordinator.flushNow { flushResult = $0 }
        XCTAssertEqual(flushResult, false)
        XCTAssertEqual(saveAttempts, 1)
        if case .failed = coordinator.state {
            // Expected.
        } else {
            XCTFail("The unsupported destination should remain failed.")
        }
        coordinator.close()
    }

    func testOverlappingExternalEditShowsDiskAndKeepsRecovery() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "hello\n")
        defer { fixture.remove() }

        let snapshot = try TextFileCodec.decode(Data("hello\n".utf8))
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: recoveryStore
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var restoredToken: PendingSaveToken?
        delegate.onSave = { restoredToken = $0 }
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("hello\n".utf8), from: fixture.url)

        coordinator.sourceBuffer.replace(
            with: "hallo\n",
            origin: .localEditor(paneID: UUID())
        )
        try Data("hullo\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()

        try await waitUntil {
            coordinator.state == .recoveredConflict
        }
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "hullo\n")
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            coordinator.state == .recoveredConflict
        }
        XCTAssertEqual(coordinator.state, .recoveredConflict)

        coordinator.restoreLatestRecovery()
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "hallo\n")
        try await waitUntil { restoredToken != nil }
        let token = try XCTUnwrap(restoredToken)
        XCTAssertNotNil(
            SessionRecoveryStore(
                persistenceDirectory: recoveryDirectory
            ).latest(for: DocumentIdentity.make(url: fixture.url))
        )
        let result = try SafeFileCommitter().commit(token)
        try coordinator.bridge.store(result)
        coordinator.handleSaveCompletion(generation: token.generation, error: nil)
        XCTAssertNil(
            SessionRecoveryStore(
                persistenceDirectory: recoveryDirectory
            ).latest(for: DocumentIdentity.make(url: fixture.url))
        )
        coordinator.close()
    }

    func testAttachMigratesDecodedAndRawRecoveryToTheNewIdentity() throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let store = SessionRecoveryStore()
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let newIdentity = DocumentIdentity.make(url: newURL)
        let recovery = DocumentSnapshot(
            text: "recover\n",
            format: .newDocument
        )
        try store.add(snapshot: recovery, for: oldIdentity)
        try store.addRawData(Data([0xFF]), for: oldIdentity)
        let snapshot = try TextFileCodec.decode(Data("old\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store
        )
        coordinator.loadInitial(
            snapshot,
            data: Data("old\n".utf8),
            from: fixture.url
        )

        coordinator.attach(to: newURL, knownData: newData)

        XCTAssertNil(store.latest(for: oldIdentity))
        XCTAssertTrue(store.rawRecoveryEntries(for: oldIdentity).isEmpty)
        XCTAssertEqual(store.latest(for: newIdentity)?.snapshot, recovery)
        XCTAssertEqual(
            store.rawRecoveryEntries(for: newIdentity).first?.data,
            Data([0xFF])
        )
        coordinator.close()
    }

    func testFailedRecoveryMigrationCannotResumeWritesToTheNewPath() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let store = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory,
            migrationWriteHook: { _ in
                throw InjectedCoordinatorMigrationError.interrupted
            }
        )
        try store.add(
            snapshot: DocumentSnapshot(
                text: "recover\n",
                format: .newDocument
            ),
            for: oldIdentity
        )
        let snapshot = try TextFileCodec.decode(Data("old\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store
        )
        let delegate = TestSyncDelegate(fileURL: newURL)
        var saveRequestCount = 0
        delegate.onSave = { _ in saveRequestCount += 1 }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: Data("old\n".utf8),
            from: fixture.url
        )

        coordinator.attach(to: newURL, knownData: newData)
        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertTrue(coordinator.hasLocalRecovery)
        XCTAssertTrue(coordinator.recoveryMigrationIsPending)

        coordinator.resumeSynchronization()
        coordinator.sourceBuffer.replace(
            with: "must remain paused\n",
            origin: .localEditor(paneID: UUID())
        )
        try await Task.sleep(for: .milliseconds(175))

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertTrue(coordinator.recoveryMigrationIsPending)
        XCTAssertEqual(saveRequestCount, 0)
        XCTAssertNotNil(store.latest(for: oldIdentity))
        coordinator.close()
    }

    func testSuccessfulRecoveryMigrationRetryRestartsTheSuppressedSave() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        var shouldInterrupt = true
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.directory.appendingPathComponent(
                "recovery",
                isDirectory: true
            ),
            migrationWriteHook: { _ in
                guard shouldInterrupt else { return }
                shouldInterrupt = false
                throw InjectedCoordinatorMigrationError.interrupted
            }
        )
        try store.add(
            snapshot: DocumentSnapshot(
                text: "recover\n",
                format: .newDocument
            ),
            for: oldIdentity
        )
        let snapshot = try TextFileCodec.decode(Data("old\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store
        )
        let delegate = TestSyncDelegate(fileURL: newURL)
        var requestedToken: PendingSaveToken?
        delegate.onSave = { requestedToken = $0 }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: Data("old\n".utf8),
            from: fixture.url
        )
        coordinator.attach(to: newURL, knownData: newData)
        XCTAssertTrue(coordinator.recoveryMigrationIsPending)

        coordinator.retryRecoveryMigration()
        try await waitUntil { requestedToken != nil }

        XCTAssertFalse(coordinator.recoveryMigrationIsPending)
        XCTAssertEqual(
            requestedToken?.targetURL.standardizedFileURL,
            newURL.standardizedFileURL
        )
        XCTAssertEqual(requestedToken?.snapshot.text, "old\n")
        coordinator.close()
    }

    func testRecoveryMigrationPublishesActionsWhileStateRemainsPaused()
        throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        var shouldInterrupt = true
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.directory.appendingPathComponent(
                "recovery",
                isDirectory: true
            ),
            migrationWriteHook: { _ in
                guard shouldInterrupt else { return }
                shouldInterrupt = false
                throw InjectedCoordinatorMigrationError.interrupted
            }
        )
        try store.addRawData(
            Data([0xFF, 0x00, 0xC0]),
            for: oldIdentity
        )
        let oldData = Data("old\n".utf8)
        let snapshot = try TextFileCodec.decode(oldData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store
        )
        defer { coordinator.close() }
        let delegate = TestSyncDelegate(fileURL: newURL)
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: oldData,
            from: fixture.url
        )
        coordinator.attach(to: newURL, knownData: newData)

        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)
        XCTAssertTrue(coordinator.statusSnapshot.recoveryMigrationIsPending)
        XCTAssertNotNil(coordinator.statusSnapshot.rawRecoveryURL)
        var snapshots: [DocumentSynchronizationStatusSnapshot] = []
        let observation = coordinator.$statusSnapshot.dropFirst().sink {
            snapshots.append($0)
        }

        coordinator.retryRecoveryMigration()

        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)
        XCTAssertFalse(coordinator.statusSnapshot.recoveryMigrationIsPending)
        let rawRecoveryURL = try XCTUnwrap(
            coordinator.statusSnapshot.rawRecoveryURL
        )
        XCTAssertTrue(
            snapshots.contains(coordinator.statusSnapshot),
            "Action-driving metadata should publish even when state is unchanged."
        )
        let presentation = SynchronizationStatusPresentation.make(
            for: .synchronizationPaused,
            failureRequiresSaveAs:
                coordinator.statusSnapshot.failureRequiresSaveAs,
            recoveryMigrationIsPending:
                coordinator.statusSnapshot.recoveryMigrationIsPending,
            rawRecoveryURL: rawRecoveryURL,
            hasLocalRecovery: coordinator.statusSnapshot.hasLocalRecovery
        )
        XCTAssertEqual(
            presentation?.primaryAction,
            .showRecoveryFile(rawRecoveryURL)
        )
        XCTAssertTrue(presentation?.offersRawRecoveryDiscard == true)
        withExtendedLifetime(observation) {}
    }

    func testReopenedRawAndDecodedRecoveryPausesUntilRestoreCommits() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "disk\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let identity = DocumentIdentity.make(url: fixture.url)
        let recoveredSnapshot = DocumentSnapshot(
            text: "local recovery\n",
            format: .newDocument
        )
        let rawData = Data([0xFF, 0x00, 0xC0])
        let initialStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        try initialStore.add(
            snapshot: recoveredSnapshot,
            for: identity
        )
        try initialStore.addRawData(rawData, for: identity)

        let diskData = Data("disk\n".utf8)
        let diskSnapshot = try TextFileCodec.decode(diskData)
        let reopenedStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let coordinator = DocumentSyncCoordinator(
            snapshot: diskSnapshot,
            recoveryStore: reopenedStore
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var restoreToken: PendingSaveToken?
        delegate.onSave = { restoreToken = $0 }
        coordinator.delegate = delegate

        coordinator.loadInitial(
            diskSnapshot,
            data: diskData,
            from: fixture.url
        )

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertTrue(coordinator.hasLocalRecovery)
        XCTAssertNotNil(coordinator.latestRawRecoveryURL)

        coordinator.restoreLatestRecovery()
        XCTAssertEqual(
            coordinator.sourceBuffer.revision.text,
            recoveredSnapshot.text
        )
        try await waitUntil { restoreToken != nil }
        XCTAssertNotNil(reopenedStore.latest(for: identity))
        XCTAssertFalse(
            reopenedStore.rawRecoveryEntries(for: identity).isEmpty
        )

        let token = try XCTUnwrap(restoreToken)
        let result = try SafeFileCommitter().commit(token)
        try coordinator.bridge.store(result)
        coordinator.handleSaveCompletion(
            generation: token.generation,
            error: nil
        )

        XCTAssertNil(reopenedStore.latest(for: identity))
        XCTAssertTrue(
            reopenedStore.rawRecoveryEntries(for: identity).isEmpty
        )
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.close()
    }

    func testExternalBOMChangeIsUsedByThePendingLocalSave() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let gate = SuspensionGate()
        var preparationStarted = false
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            savePreparationHook: {
                preparationStarted = true
                await gate.wait()
            }
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var requestedToken: PendingSaveToken?
        delegate.onSave = { requestedToken = $0 }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: fixture.url
        )

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { preparationStarted }
        let bomData = Data([0xEF, 0xBB, 0xBF]) + originalData
        try bomData.write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            coordinator.durableState?.snapshot.format.encoding
                == .utf8WithBOM
        }
        await gate.open()
        try await waitUntil { requestedToken != nil }

        XCTAssertEqual(requestedToken?.snapshot.text, "local\n")
        XCTAssertEqual(
            requestedToken?.snapshot.format.encoding,
            .utf8WithBOM
        )
        coordinator.close()
    }

    func testDisplacedBOMChangeIsUsedByTheReconciliationSave() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var requestedTokens: [PendingSaveToken] = []
        delegate.onSave = { requestedTokens.append($0) }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            snapshot,
            data: originalData,
            from: fixture.url
        )

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { requestedTokens.count == 1 }
        let firstToken = requestedTokens[0]
        try firstToken.encodedData.write(to: fixture.url)
        let bomData = Data([0xEF, 0xBB, 0xBF]) + originalData
        try coordinator.bridge.store(
            FileCommitResult(
                generation: firstToken.generation,
                committedFingerprint: try SafeFileCommitter.fingerprint(
                    for: fixture.url,
                    data: firstToken.encodedData
                ),
                displacedPreimage: bomData,
                safety: .atomicSwap
            )
        )

        coordinator.handleSaveCompletion(
            generation: firstToken.generation,
            error: nil
        )
        try await waitUntil { requestedTokens.count == 2 }
        let reconciliationToken = try XCTUnwrap(
            requestedTokens.dropFirst().first
        )

        XCTAssertEqual(reconciliationToken.snapshot.text, "local\n")
        XCTAssertEqual(
            reconciliationToken.snapshot.format.encoding,
            .utf8WithBOM
        )
        coordinator.close()
    }

    func testUnexpectedAtomicPreimageIsReconciledBackToDisk() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)

        var firstToken: PendingSaveToken?
        delegate.onSave = { token in
            if firstToken == nil {
                firstToken = token
                return
            }
            do {
                let result = try SafeFileCommitter().commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(generation: token.generation, error: nil)
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { firstToken != nil }
        let token = try XCTUnwrap(firstToken)
        try token.encodedData.write(to: fixture.url)
        let external = Data("external\n".utf8)
        let result = FileCommitResult(
            generation: token.generation,
            committedFingerprint: try SafeFileCommitter.fingerprint(
                for: fixture.url,
                data: token.encodedData
            ),
            displacedPreimage: external,
            safety: .atomicSwap
        )
        try coordinator.bridge.store(result)
        coordinator.handleSaveCompletion(generation: token.generation, error: nil)

        try await waitUntil {
            coordinator.state == .recoveredConflict
                && (try? String(contentsOf: fixture.url, encoding: .utf8))
                    == "external\n"
        }
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "external\n")

        coordinator.restoreLatestRecovery()
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "local\n")
        coordinator.close()
    }

    func testUndecodableUnexpectedPreimageIsDurablyPreserved() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: recoveryStore
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)

        var pendingToken: PendingSaveToken?
        var flushResult: Bool?
        delegate.onSave = { pendingToken = $0 }
        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.flushNow { flushResult = $0 }
        try await waitUntil { pendingToken != nil }
        let token = try XCTUnwrap(pendingToken)
        try token.encodedData.write(to: fixture.url)
        let invalidExternal = Data([0xFF, 0x00, 0xC0])
        try coordinator.bridge.store(
            FileCommitResult(
                generation: token.generation,
                committedFingerprint: try SafeFileCommitter.fingerprint(
                    for: fixture.url,
                    data: token.encodedData
                ),
                displacedPreimage: invalidExternal,
                safety: .atomicSwap
            )
        )

        coordinator.handleSaveCompletion(generation: token.generation, error: nil)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertEqual(flushResult, false)
        var repeatedFlushResult: Bool?
        coordinator.flushNow { repeatedFlushResult = $0 }
        XCTAssertEqual(repeatedFlushResult, false)
        let identity = DocumentIdentity.make(url: fixture.url)
        XCTAssertEqual(
            recoveryStore.rawRecoveryEntries(for: identity).first?.data,
            invalidExternal
        )
        XCTAssertEqual(
            SessionRecoveryStore(
                persistenceDirectory: recoveryDirectory
            ).rawRecoveryEntries(for: identity).first?.data,
            invalidExternal
        )
        coordinator.sourceBuffer.replace(
            with: "edit while paused\n",
            origin: .localEditor(paneID: UUID())
        )
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "local\n"
        )
        coordinator.close()
    }

    func testUnchangedExternalSignalReschedulesCancelledLocalWrite() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)
        delegate.onSave = { token in
            do {
                let result = try SafeFileCommitter().commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(generation: token.generation, error: nil)
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.noteCoordinatedExternalChange()

        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8)) == "local\n"
        }
        coordinator.close()
    }

    func testRepeatedSiblingSignalsDoNotStarveLocalWrite() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)
        delegate.onSave = { token in
            do {
                let result = try SafeFileCommitter().commit(token)
                try coordinator.bridge.store(result)
                coordinator.handleSaveCompletion(generation: token.generation, error: nil)
            } catch {
                coordinator.handleSaveCompletion(
                    generation: token.generation,
                    error: error
                )
            }
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        for _ in 0..<8 {
            coordinator.noteCoordinatedExternalChange()
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "local\n"
        )
        coordinator.close()
    }

    func testExternalReloadCancelsAStalePreparedSave() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let gate = SuspensionGate()
        var preparationStarted = false
        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            savePreparationHook: {
                preparationStarted = true
                await gate.wait()
            }
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var requestedSaveCount = 0
        delegate.onSave = { _ in requestedSaveCount += 1 }
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { preparationStarted }

        try Data("external\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "external\n"
        }
        await gate.open()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(requestedSaveCount, 0)
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "external\n"
        )
        coordinator.close()
    }

    func testExternalChangeStartsReadingWithoutADebounce() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let initialData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(initialData)
        let gate = SuspensionGate()
        var readStarted = false
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            externalReadHook: { _ in
                readStarted = true
                await gate.wait()
            }
        )
        defer { coordinator.close() }
        coordinator.loadInitial(
            snapshot,
            data: initialData,
            from: fixture.url
        )

        try Data("external\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()

        try await waitUntil {
            readStarted && coordinator.state == .checkingExternalChange
        }
        await gate.open()
    }

    func testPendingExternalSignalRunsAfterTheActiveRead() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let gate = SuspensionGate()
        var firstReadStarted = false
        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            externalReadHook: { _ in
                guard !firstReadStarted else { return }
                firstReadStarted = true
                await gate.wait()
            }
        )
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)

        try Data("older\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()
        try await waitUntil { firstReadStarted }

        try Data("newer\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()
        await gate.open()
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "newer\n"
        }

        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "newer\n")
        coordinator.close()
    }

    func testRepeatedSiblingSignalsCannotStarveAnExternalReload() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)
        try Data("external\n".utf8).write(to: fixture.url)

        var observedDuringChurn = false
        for _ in 0..<8 {
            coordinator.noteCoordinatedExternalChange()
            try await Task.sleep(for: .milliseconds(40))
            observedDuringChurn = observedDuringChurn
                || coordinator.sourceBuffer.revision.text == "external\n"
        }

        XCTAssertTrue(observedDuringChurn)
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "external\n")
        coordinator.close()
    }

    func testSaveCompletionReportsNewerVisibleEditAsUnsynchronized() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(snapshot: snapshot)
        let delegate = TestSyncDelegate(fileURL: fixture.url)
        var tokens: [PendingSaveToken] = []
        delegate.onSave = { tokens.append($0) }
        coordinator.delegate = delegate
        coordinator.loadInitial(snapshot, data: Data("base\n".utf8), from: fixture.url)

        coordinator.sourceBuffer.replace(
            with: "first\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { tokens.count == 1 }
        let firstToken = tokens[0]
        coordinator.sourceBuffer.replace(
            with: "second\n",
            origin: .localEditor(paneID: UUID())
        )
        let firstResult = try SafeFileCommitter().commit(firstToken)
        try coordinator.bridge.store(firstResult)

        XCTAssertFalse(
            coordinator.handleSaveCompletion(
                generation: firstToken.generation,
                error: nil
            )
        )
        try await waitUntil { tokens.count >= 2 }
        let secondToken = tokens.last!
        let secondResult = try SafeFileCommitter().commit(secondToken)
        try coordinator.bridge.store(secondResult)
        XCTAssertTrue(
            coordinator.handleSaveCompletion(
                generation: secondToken.generation,
                error: nil
            )
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "second\n"
        )
        coordinator.close()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for synchronization condition.")
    }
}

private enum InjectedCoordinatorMigrationError: Error {
    case interrupted
}

private actor SuspensionGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TestSyncDelegate: DocumentSyncCoordinatorDelegate {
    let synchronizationFileURL: URL?
    var onSave: ((PendingSaveToken) -> Void)?
    private(set) var acceptedExternalChangeCount = 0

    init(fileURL: URL) {
        synchronizationFileURL = fileURL
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave token: PendingSaveToken
    ) {
        onSave?(token)
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    ) {
        acceptedExternalChangeCount += 1
    }
}

private struct TemporaryMarkdownFile {
    let directory: URL
    let url: URL

    init(contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("fixture.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
