import Combine
import Foundation
import XCTest
@testable import DarthScriptum

@MainActor
final class DocumentSyncCoordinatorTests: XCTestCase {
    func testInitialLoadPreservesBOMFormatForTheNextSave() throws {
        let fixture = try TemporaryMarkdownFile(contents: "placeholder\n")
        defer { fixture.remove() }
        let loadedData = Data([0xEF, 0xBB, 0xBF])
            + Data("loaded\r\n".utf8)
        try loadedData.write(to: fixture.url)
        let loadedSnapshot = try TextFileCodec.decode(loadedData)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host

        coordinator.loadInitial(
            loadedSnapshot,
            data: loadedData,
            from: fixture.url
        )

        XCTAssertEqual(coordinator.currentSnapshot, loadedSnapshot)
        XCTAssertEqual(coordinator.format, loadedSnapshot.format)
        XCTAssertEqual(
            coordinator.durableState?.snapshot.format,
            loadedSnapshot.format
        )

        coordinator.sourceBuffer.replace(
            with: "edited\r\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .milliseconds(100))
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)

        XCTAssertEqual(preparation.snapshot.format, loadedSnapshot.format)
        XCTAssertEqual(
            try TextFileCodec.encode(preparation.snapshot),
            Data([0xEF, 0xBB, 0xBF]) + Data("edited\r\n".utf8)
        )
    }

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
        let fixture = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: original.url
        )
        defer { fixture.coordinator.close() }

        fixture.coordinator.noteCoordinatedExternalChange()
        fixture.fireExternalRead()
        let read = try XCTUnwrap(fixture.executor.externalReadRequests.last)
        XCTAssertTrue(
            fixture.executor.finishExternalRead(
                read.token,
                with: .finished(.missing)
            )
        )
        XCTAssertEqual(fixture.coordinator.presentedState, .missing)

        let savedData = Data("saved\n".utf8)
        let savedSnapshot = try TextFileCodec.decode(savedData)
        fixture.coordinator.sourceBuffer.replace(
            with: savedSnapshot.text,
            origin: .localEditor(paneID: UUID())
        )
        let savedRevision = fixture.coordinator.sourceBuffer.revision
        try await fixture.coordinator.attachAfterSaveAs(
            to: destination.url,
            expectedData: savedData,
            expectedSnapshot: savedSnapshot,
            expectedSourceRevision: savedRevision
        )

        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertNil(fixture.coordinator.presentedState)
        XCTAssertEqual(
            fixture.coordinator.fileURL,
            destination.url.standardizedFileURL
        )
    }

    func testRoutineSynchronizationDoesNotInvalidateCoordinatorUI() throws {
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
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: DocumentSnapshot(
                    text: "older\n",
                    format: .newDocument
                )
            ),
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
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: initialData,
            url: fixture.url
        )
        defer { harness.coordinator.close() }
        var flushResult: Bool?

        harness.coordinator.sourceBuffer.replace(
            with: "flushed\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.coordinator.flushNow { flushResult = $0 }
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        XCTAssertNil(flushResult)

        let commit = try XCTUnwrap(harness.host.saveRequests.last)
        let result = try SafeFileCommitter().commit(commit.pendingSave)
        try harness.coordinator.bridge.store(result, for: commit.token)
        _ = harness.coordinator.handleSaveCompletion(token: commit.token, error: nil)

        XCTAssertEqual(flushResult, true)
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "flushed\n"
        )
    }

    func testAttachAssociatesFingerprintWithTheSnapshotActuallyOnDisk() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "saved-before-new-edit\n")
        defer { fixture.remove() }
        let current = DocumentSnapshot(
            text: "new-edit-during-save-as\n",
            format: .newDocument
        )
        let data = Data("saved-before-new-edit\n".utf8)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: current,
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host

        let didAttach = await coordinator.attachAndWait(
            to: fixture.url,
            knownData: data
        )

        XCTAssertTrue(didAttach)
        XCTAssertEqual(
            coordinator.durableState?.snapshot.text,
            "saved-before-new-edit\n"
        )
        XCTAssertTrue(coordinator.hasLocalChanges)
        coordinator.advanceScheduledWork(by: .zero)
        let externalRead = try XCTUnwrap(executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: data
        )
        let observation = try TextFileCodec.externalReadObservation(
            data: data,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            executor.finishExternalRead(
                externalRead.token,
                with: .finished(.unchanged(observation))
            )
        )
        coordinator.advanceScheduledWork(by: .milliseconds(100))
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)
        XCTAssertTrue(
            executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let commit = try XCTUnwrap(host.saveRequests.last)
        XCTAssertEqual(commit.pendingSave.snapshot.text, current.text)
        let result = try SafeFileCommitter().commit(commit.pendingSave)
        try coordinator.bridge.store(result, for: commit.token)
        XCTAssertTrue(coordinator.handleSaveCompletion(token: commit.token, error: nil))
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "new-edit-during-save-as\n"
        )
    }

    func testLocalEditWritesThroughAndExternalEditReloads() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let commit = try XCTUnwrap(harness.host.saveRequests.last)
        let result = try SafeFileCommitter().commit(commit.pendingSave)
        try harness.coordinator.bridge.store(result, for: commit.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(token: commit.token, error: nil)
        )
        XCTAssertEqual(harness.coordinator.state, .idle)

        let externalData = Data("external\n".utf8)
        try externalData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: externalData
        )
        let change = try TextFileCodec.decodeExternalChange(
            data: externalData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.changed(change))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "external\n")
        XCTAssertEqual(harness.host.acceptedExternalChangeCount, 1)
    }

    func testSameContentAtomicReplacementRefreshesIdentityBeforeSaving()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: fixture.url
        )
        defer { harness.coordinator.close() }
        let originalIdentifier = harness.coordinator.durableState?
            .fingerprint.resourceIdentifier

        try originalData.write(to: fixture.url, options: [.atomic])
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let replacementFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: originalData
        )
        let replacement = try TextFileCodec.decodeExternalChange(
            data: originalData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: replacementFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.changed(replacement))
            )
        )
        XCTAssertNotEqual(
            harness.coordinator.durableState?.fingerprint.resourceIdentifier,
            originalIdentifier
        )

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertEqual(
            preparation.expectedBaseline?.fingerprint,
            harness.coordinator.reducerState.durableBaseline?.fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let commit = try XCTUnwrap(harness.host.saveRequests.last)
        let result = try SafeFileCommitter().commit(commit.pendingSave)
        try harness.coordinator.bridge.store(result, for: commit.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(token: commit.token, error: nil)
        )
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testSameContentSymlinkRetargetPreservesLegacyRecoveryAndBlocksWrites()
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
        let recoveryStore = SessionRecoveryStore()
        let snapshot = try TextFileCodec.decode(originalData)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: recoveryStore,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: link)
        coordinator.delegate = host
        let oldIdentity = DocumentIdentity.make(url: link)
        try recoveryStore.add(
            snapshot: DocumentSnapshot(
                text: "recoverable\n",
                format: snapshot.format
            ),
            for: oldIdentity
        )
        coordinator.loadInitial(snapshot, data: originalData, from: link)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: secondReferent
        )
        let newIdentity = DocumentIdentity.make(url: link)
        let didMove = await coordinator.noteFileMovedAndWait(
            to: link,
            knownData: originalData
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertNotNil(recoveryStore.latest(for: oldIdentity))
        XCTAssertNil(recoveryStore.latest(for: newIdentity))
        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertTrue(host.saveRequests.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: firstReferent, encoding: .utf8),
            "base\n"
        )
    }

    func testCoordinatorProcessesExplicitRepeatedExternalReplacements()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        let replacementData = Data("replacement\n".utf8)
        try replacementData.write(to: fixture.url, options: .atomic)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let firstRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let firstFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: replacementData
        )
        let firstChange = try TextFileCodec.decodeExternalChange(
            data: replacementData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: firstFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                firstRead.token,
                with: .finished(.changed(firstChange))
            )
        )

        let directData = Data("direct\n".utf8)
        try directData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let secondRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let secondFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: directData
        )
        let secondChange = try TextFileCodec.decodeExternalChange(
            data: directData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: secondFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                secondRead.token,
                with: .finished(.changed(secondChange))
            )
        )

        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "direct\n")
        XCTAssertEqual(harness.host.acceptedExternalChangeCount, 2)
    }

    func testRetryAfterExternalDecodeFailureRereadsTheFile() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: fixture.url
        )
        defer { harness.coordinator.close() }
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let failedRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                failedRead.token,
                with: .failed(.externalRead)
            )
        )
        guard case .failed = harness.coordinator.presentedState else {
            return XCTFail("The reload failure should remain visible.")
        }

        let repairedData = Data("repaired\n".utf8)
        try repairedData.write(to: fixture.url)
        harness.coordinator.retrySynchronization()
        harness.fireExternalRead()
        let retryRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let repairedFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: repairedData
        )
        let repairedChange = try TextFileCodec.decodeExternalChange(
            data: repairedData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: repairedFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                retryRead.token,
                with: .finished(.changed(repairedChange))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "repaired\n")
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertNil(harness.coordinator.presentedState)
    }

    func testUnsupportedAtomicSwapStopsAutomaticRetriesAndRequiresSaveAs()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let request = try XCTUnwrap(harness.host.saveRequests.last)
        _ = harness.coordinator.handleSaveCompletion(
            token: request.token,
            error: SafeFileCommitter.CommitError.atomicSwapUnavailable
        )

        XCTAssertEqual(harness.host.saveRequests.count, 1)
        XCTAssertTrue(harness.coordinator.failureRequiresSaveAs)
        var flushResult: Bool?
        harness.coordinator.flushNow { flushResult = $0 }
        XCTAssertEqual(flushResult, false)
        XCTAssertEqual(harness.host.saveRequests.count, 1)
        if case .failed = harness.coordinator.state {
            // Expected.
        } else {
            XCTFail("The unsupported destination should remain failed.")
        }
    }

    func testOverlappingExternalEditPersistsAndRestoresLegacyRecovery()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "hello\n")
        defer { fixture.remove() }

        let data = Data("hello\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let recoveryStore = SessionRecoveryStore()
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: recoveryStore
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "hallo\n",
            origin: .localEditor(paneID: UUID())
        )
        let externalData = Data("hullo\n".utf8)
        try externalData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: externalData
        )
        let change = try TextFileCodec.decodeExternalChange(
            data: externalData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.changed(change))
            )
        )
        let merge = try XCTUnwrap(harness.executor.mergeRequests.last)
        XCTAssertTrue(
            harness.executor.finishMerge(
                merge.token,
                with: .finished(ThreeWayTextMerger().result(for: merge))
            )
        )

        XCTAssertEqual(harness.coordinator.state, .recoveredConflict)
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "hullo\n")
        XCTAssertEqual(
            recoveryStore.latest(
                for: DocumentIdentity.make(url: fixture.url)
            )?.snapshot.text,
            "hallo\n"
        )
        XCTAssertTrue(harness.coordinator.hasLocalRecovery)

        harness.coordinator.restoreLatestRecovery()
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let save = try XCTUnwrap(harness.host.saveRequests.last)
        let result = try SafeFileCommitter().commit(save.pendingSave)
        try harness.coordinator.bridge.store(result, for: save.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(
                token: save.token,
                error: nil
            )
        )

        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "hallo\n"
        )
        XCTAssertNil(
            recoveryStore.latest(for: DocumentIdentity.make(url: fixture.url))
        )
        XCTAssertFalse(harness.coordinator.hasLocalRecovery)
    }

    func testFreshConflictUsesTheDestinationGenerationAfterEmptyMigration()
        throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let recoveryStore = SessionRecoveryStore()
        let destinationIdentity = DocumentIdentity.make(url: fixture.url)
        _ = try recoveryStore.advanceEmptyRecoveryMigration(
            from: DocumentIdentity(stableKey: "path:/tmp/moved-away.md"),
            to: destinationIdentity,
            expectedGeneration: 0
        )
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: recoveryStore
        )
        defer { harness.coordinator.close() }

        XCTAssertEqual(harness.coordinator.reducerState.recoveryAccess, .ready(generation: 1))
        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        let externalData = Data("external\n".utf8)
        try externalData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: externalData
        )
        let change = try TextFileCodec.decodeExternalChange(
            data: externalData,
            targetURL: fixture.url,
            identity: destinationIdentity,
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.changed(change))
            )
        )
        let merge = try XCTUnwrap(harness.executor.mergeRequests.last)
        XCTAssertTrue(
            harness.executor.finishMerge(
                merge.token,
                with: .finished(ThreeWayTextMerger().result(for: merge))
            )
        )

        XCTAssertEqual(harness.coordinator.state, .recoveredConflict)
        XCTAssertEqual(
            recoveryStore.latest(for: destinationIdentity)?.snapshot.text,
            "local\n"
        )
    }

    func testAttachPreservesDecodedAndRawRecoveryWithoutLegacyReceipts()
        async throws {
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
        let rawData = Data([0xFF])
        let rawEntry = try store.addRawData(rawData, for: oldIdentity)
        let snapshot = try TextFileCodec.decode(Data("old\n".utf8))
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: newURL)
        coordinator.delegate = host
        coordinator.loadInitial(
            snapshot,
            data: Data("old\n".utf8),
            from: fixture.url
        )

        let didAttach = await coordinator.attachAndWait(
            to: newURL,
            knownData: newData
        )

        XCTAssertTrue(didAttach)
        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertEqual(store.latest(for: oldIdentity)?.snapshot, recovery)
        XCTAssertEqual(
            store.rawRecoveryEntries(for: oldIdentity),
            [rawEntry]
        )
        XCTAssertEqual(store.rawRecoveryEntries(for: oldIdentity).first?.data, rawData)
        XCTAssertNil(store.latest(for: newIdentity))
        XCTAssertTrue(store.rawRecoveryEntries(for: newIdentity).isEmpty)
        coordinator.sourceBuffer.replace(
            with: "must-not-write\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertTrue(host.saveRequests.isEmpty)
    }

    func testFailedRecoveryMigrationCannotResumeWritesToTheNewPath() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let store = SessionRecoveryStore()
        try store.add(
            snapshot: DocumentSnapshot(
                text: "recover\n",
                format: .newDocument
            ),
            for: oldIdentity
        )
        let snapshot = try TextFileCodec.decode(Data("old\n".utf8))
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: newURL)
        coordinator.delegate = host
        coordinator.loadInitial(
            snapshot,
            data: Data("old\n".utf8),
            from: fixture.url
        )

        _ = await coordinator.attachAndWait(to: newURL, knownData: newData)
        XCTAssertEqual(coordinator.state, .synchronizationPaused)

        coordinator.resumeSynchronization()
        coordinator.sourceBuffer.replace(
            with: "must remain paused\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertTrue(host.saveRequests.isEmpty)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertNotNil(store.latest(for: oldIdentity))
    }

    func testLegacyRecoveryMigrationRetryCannotRestartTheSuppressedSave()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let store = SessionRecoveryStore()
        try store.add(
            snapshot: DocumentSnapshot(
                text: "recover\n",
                format: .newDocument
            ),
            for: oldIdentity
        )
        let snapshot = try TextFileCodec.decode(Data("old\n".utf8))
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: newURL)
        coordinator.delegate = host
        coordinator.loadInitial(
            snapshot,
            data: Data("old\n".utf8),
            from: fixture.url
        )
        _ = await coordinator.attachAndWait(to: newURL, knownData: newData)

        coordinator.retryRecoveryMigration()
        coordinator.sourceBuffer.replace(
            with: "still-paused\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertTrue(host.saveRequests.isEmpty)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertNotNil(store.latest(for: oldIdentity))
    }

    func testLegacyRecoveryPauseExposesOnlyNonDestructiveActions()
        throws {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let store = SessionRecoveryStore()
        try store.addRawData(
            Data([0xFF, 0x00, 0xC0]),
            for: oldIdentity
        )
        let oldData = Data("old\n".utf8)
        let snapshot = try TextFileCodec.decode(oldData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store,
            fileMonitoringEnabled: false,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }
        coordinator.loadInitial(
            snapshot,
            data: oldData,
            from: fixture.url
        )

        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)
        XCTAssertFalse(coordinator.statusSnapshot.recoveryMigrationIsPending)
        XCTAssertNil(coordinator.statusSnapshot.rawRecoveryURL)
        XCTAssertFalse(coordinator.statusSnapshot.hasLocalRecovery)
        let presentation = SynchronizationStatusPresentation.make(
            for: .synchronizationPaused,
            failureRequiresSaveAs:
                coordinator.statusSnapshot.failureRequiresSaveAs,
            recoveryMigrationIsPending:
                coordinator.statusSnapshot.recoveryMigrationIsPending,
            rawRecoveryURL: coordinator.statusSnapshot.rawRecoveryURL,
            hasLocalRecovery: coordinator.statusSnapshot.hasLocalRecovery
        )
        XCTAssertEqual(presentation?.primaryAction, .saveAs)
        XCTAssertFalse(presentation?.offersRawRecoveryDiscard == true)
        XCTAssertFalse(presentation?.offersLocalRevisionRestore == true)
    }

    func testReopenedRawAndDecodedRecoveryPausesWithoutMutatingEvidence()
        throws {
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
            recoveryStore: reopenedStore,
            fileMonitoringEnabled: false,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }

        coordinator.loadInitial(
            diskSnapshot,
            data: diskData,
            from: fixture.url
        )

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertFalse(coordinator.hasLocalRecovery)
        XCTAssertNil(coordinator.latestRawRecoveryURL)

        coordinator.restoreLatestRecovery()
        XCTAssertEqual(
            coordinator.sourceBuffer.revision.text,
            diskSnapshot.text
        )
        XCTAssertEqual(reopenedStore.latest(for: identity)?.snapshot, recoveredSnapshot)
        XCTAssertEqual(reopenedStore.rawRecoveryEntries(for: identity).first?.data, rawData)
        XCTAssertEqual(coordinator.state, .synchronizationPaused)
    }

    func testExternalBOMChangeIsUsedByThePendingLocalSave() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        let bomData = Data([0xEF, 0xBB, 0xBF]) + originalData
        try bomData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: bomData
        )
        let change = try TextFileCodec.decodeExternalChange(
            data: bomData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.changed(change))
            )
        )
        XCTAssertEqual(
            harness.coordinator.durableState?.snapshot.format.encoding,
            .utf8WithBOM
        )

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let requestedToken = try XCTUnwrap(harness.host.saveRequests.last)

        XCTAssertEqual(requestedToken.pendingSave.snapshot.text, "local\n")
        XCTAssertEqual(
            requestedToken.pendingSave.snapshot.format.encoding,
            .utf8WithBOM
        )
    }

    func testDisplacedBOMChangeFailsClosedWithoutALegacyRecoveryReceipt()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let originalData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(originalData)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: originalData,
            url: fixture.url,
            recoveryStore: SessionRecoveryStore(
                persistenceDirectory: fixture.directory.appendingPathComponent(
                    "recovery",
                    isDirectory: true
                )
            )
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let request = try XCTUnwrap(harness.host.saveRequests.last)
        let bomData = Data([0xEF, 0xBB, 0xBF]) + originalData
        let committer = SafeFileCommitter(
            recoveryDirectory: fixture.directory.appendingPathComponent(
                "recovery",
                isDirectory: true
            ),
            beforeAtomicSwap: {
                try bomData.write(to: fixture.url)
            }
        )
        let result = try committer.commit(request.pendingSave)
        XCTAssertEqual(result.displacedPreimage?.data, bomData)
        XCTAssertNotNil(result.recoveryArtifact)
        try harness.coordinator.bridge.store(result, for: request.token)
        _ = harness.coordinator.handleSaveCompletion(token: request.token, error: nil)

        XCTAssertEqual(harness.coordinator.state, .synchronizationPaused)
        XCTAssertEqual(
            harness.coordinator.reducerState.pendingDisplacedPreimage?
                .rawPayload.data,
            bomData
        )
        XCTAssertTrue(harness.host.saveRequests.count == 1)
    }

    func testUnexpectedAtomicPreimageFailsClosedWithAnArtifactBackedPayload()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: SessionRecoveryStore(
                persistenceDirectory: fixture.directory.appendingPathComponent(
                    "recovery",
                    isDirectory: true
                )
            )
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let request = try XCTUnwrap(harness.host.saveRequests.last)
        let external = Data("external\n".utf8)
        let committer = SafeFileCommitter(
            recoveryDirectory: fixture.directory.appendingPathComponent(
                "recovery",
                isDirectory: true
            ),
            beforeAtomicSwap: {
                try external.write(to: fixture.url)
            }
        )
        let result = try committer.commit(request.pendingSave)
        XCTAssertEqual(result.displacedPreimage?.data, external)
        XCTAssertNotNil(result.recoveryArtifact)
        try harness.coordinator.bridge.store(result, for: request.token)
        _ = harness.coordinator.handleSaveCompletion(token: request.token, error: nil)

        XCTAssertEqual(harness.coordinator.state, .synchronizationPaused)
        XCTAssertEqual(
            harness.coordinator.reducerState.pendingDisplacedPreimage?
                .rawPayload.data,
            external
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "local\n"
        )
    }

    func testUndecodableUnexpectedPreimageIsKeptInThePausedReducerPayload()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: recoveryStore
        )
        defer { harness.coordinator.close() }

        var flushResult: Bool?
        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.coordinator.flushNow { flushResult = $0 }
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let request = try XCTUnwrap(harness.host.saveRequests.last)
        let invalidExternal = Data([0xFF, 0x00, 0xC0])
        let committer = SafeFileCommitter(
            recoveryDirectory: recoveryDirectory,
            beforeAtomicSwap: {
                try invalidExternal.write(to: fixture.url)
            }
        )
        let result = try committer.commit(request.pendingSave)
        XCTAssertEqual(result.displacedPreimage?.data, invalidExternal)
        XCTAssertNotNil(result.recoveryArtifact)
        try harness.coordinator.bridge.store(result, for: request.token)
        _ = harness.coordinator.handleSaveCompletion(token: request.token, error: nil)

        XCTAssertEqual(harness.coordinator.state, .synchronizationPaused)
        XCTAssertEqual(flushResult, false)
        var repeatedFlushResult: Bool?
        harness.coordinator.flushNow { repeatedFlushResult = $0 }
        XCTAssertEqual(repeatedFlushResult, false)
        let identity = DocumentIdentity.make(url: fixture.url)
        XCTAssertTrue(recoveryStore.rawRecoveryEntries(for: identity).isEmpty)
        XCTAssertEqual(
            harness.coordinator.reducerState.pendingDisplacedPreimage?
                .rawPayload.data,
            invalidExternal
        )
        harness.coordinator.sourceBuffer.replace(
            with: "edit while paused\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.coordinator.advanceScheduledWork(by: .seconds(1))
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "local\n"
        )
    }

    func testUnchangedExternalSignalReschedulesCancelledLocalWrite() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: data
        )
        let observation = try TextFileCodec.externalReadObservation(
            data: data,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.unchanged(observation))
            )
        )

        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let request = try XCTUnwrap(harness.host.saveRequests.last)
        let result = try SafeFileCommitter().commit(request.pendingSave)
        try harness.coordinator.bridge.store(result, for: request.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(token: request.token, error: nil)
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "local\n"
        )
    }

    func testRepeatedSiblingSignalsDoNotStarveLocalWrite() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        for _ in 0..<8 {
            harness.coordinator.noteCoordinatedExternalChange()
        }

        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: data
        )
        let observation = try TextFileCodec.externalReadObservation(
            data: data,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        harness.fireExternalRead()
        let firstRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                firstRead.token,
                with: .finished(.unchanged(observation))
            )
        )
        harness.fireExternalRead()
        let secondRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        XCTAssertNotEqual(secondRead.token, firstRead.token)
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                secondRead.token,
                with: .finished(.unchanged(observation))
            )
        )

        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let request = try XCTUnwrap(harness.host.saveRequests.last)
        let result = try SafeFileCommitter().commit(request.pendingSave)
        try harness.coordinator.bridge.store(result, for: request.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(token: request.token, error: nil)
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "local\n"
        )
    }

    func testExternalReloadCancelsAStalePreparedSave() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let recoveryStore = SessionRecoveryStore()
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: recoveryStore
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let stalePreparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )

        let externalData = Data("external\n".utf8)
        try externalData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: externalData
        )
        let change = try TextFileCodec.decodeExternalChange(
            data: externalData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.changed(change))
            )
        )
        let merge = try XCTUnwrap(harness.executor.mergeRequests.last)
        XCTAssertTrue(
            harness.executor.finishMerge(
                merge.token,
                with: .finished(ThreeWayTextMerger().result(for: merge))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "external\n")

        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                stalePreparation.token,
                with: .prepared(try makePendingSave(from: stalePreparation))
            )
        )
        XCTAssertTrue(harness.host.saveRequests.isEmpty)
        XCTAssertEqual(harness.coordinator.state, .recoveredConflict)
        XCTAssertTrue(harness.coordinator.hasLocalRecovery)
        XCTAssertEqual(
            recoveryStore.latest(
                for: DocumentIdentity.make(url: fixture.url)
            )?.snapshot.text,
            "local\n"
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "external\n"
        )
    }

    func testExternalChangeStartsReadingWithoutADebounce() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        harness.coordinator.noteCoordinatedExternalChange()
        XCTAssertTrue(harness.executor.externalReadRequests.isEmpty)
        guard case .debouncing = harness.coordinator.reducerState.external else {
            return XCTFail("An external signal must schedule a zero-delay read.")
        }

        harness.fireExternalRead()
        let read = try XCTUnwrap(harness.executor.externalReadRequests.last)
        XCTAssertEqual(harness.coordinator.state, .checkingExternalChange)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: data
        )
        let observation = try TextFileCodec.externalReadObservation(
            data: data,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(.unchanged(observation))
            )
        )
    }

    func testPendingExternalSignalRunsAfterTheActiveRead() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        let olderData = Data("older\n".utf8)
        try olderData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let firstRead = try XCTUnwrap(harness.executor.externalReadRequests.last)

        let newerData = Data("newer\n".utf8)
        try newerData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()

        let olderFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: olderData
        )
        let olderChange = try TextFileCodec.decodeExternalChange(
            data: olderData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: olderFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                firstRead.token,
                with: .finished(.changed(olderChange))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "older\n")

        harness.fireExternalRead()
        let secondRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        XCTAssertNotEqual(secondRead.token, firstRead.token)
        let newerFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: newerData
        )
        let newerChange = try TextFileCodec.decodeExternalChange(
            data: newerData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: newerFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                secondRead.token,
                with: .finished(.changed(newerChange))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "newer\n")
    }

    func testRepeatedSiblingSignalsCannotStarveAnExternalReload() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }
        let externalData = Data("external\n".utf8)
        try externalData.write(to: fixture.url)

        for _ in 0..<8 {
            harness.coordinator.noteCoordinatedExternalChange()
        }
        harness.fireExternalRead()
        let firstRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        let externalFingerprint = try SafeFileCommitter.fingerprint(
            for: fixture.url,
            data: externalData
        )
        let externalChange = try TextFileCodec.decodeExternalChange(
            data: externalData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: externalFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                firstRead.token,
                with: .finished(.changed(externalChange))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "external\n")

        harness.fireExternalRead()
        let secondRead = try XCTUnwrap(harness.executor.externalReadRequests.last)
        XCTAssertNotEqual(secondRead.token, firstRead.token)
        let observation = try TextFileCodec.externalReadObservation(
            data: externalData,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: externalFingerprint
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                secondRead.token,
                with: .finished(.unchanged(observation))
            )
        )
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "external\n")
    }

    func testSaveCompletionReportsNewerVisibleEditAsUnsynchronized() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url
        )
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "first\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let firstPreparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                firstPreparation.token,
                with: .prepared(try makePendingSave(from: firstPreparation))
            )
        )
        let firstRequest = try XCTUnwrap(harness.host.saveRequests.last)

        harness.coordinator.sourceBuffer.replace(
            with: "second\n",
            origin: .localEditor(paneID: UUID())
        )
        let firstResult = try SafeFileCommitter().commit(
            firstRequest.pendingSave
        )
        try harness.coordinator.bridge.store(firstResult, for: firstRequest.token)
        XCTAssertFalse(
            harness.coordinator.handleSaveCompletion(
                token: firstRequest.token,
                error: nil
            )
        )

        harness.fireLocalSave()
        let secondPreparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertNotEqual(secondPreparation.token, firstPreparation.token)
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                secondPreparation.token,
                with: .prepared(try makePendingSave(from: secondPreparation))
            )
        )
        let secondRequest = try XCTUnwrap(harness.host.saveRequests.last)
        XCTAssertNotEqual(secondRequest.token, firstRequest.token)
        let secondResult = try SafeFileCommitter().commit(
            secondRequest.pendingSave
        )
        try harness.coordinator.bridge.store(secondResult, for: secondRequest.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(
                token: secondRequest.token,
                error: nil
            )
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "second\n"
        )
    }

    func testTypedHostReceivesOnlyTheCurrentFullCommitRequest() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let initialData = Data("base\n".utf8)
        let initialSnapshot = try TextFileCodec.decode(initialData)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: initialSnapshot,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host
        coordinator.loadInitial(initialSnapshot, data: initialData, from: fixture.url)

        coordinator.sourceBuffer.replace(
            with: "first\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .milliseconds(100))
        let stalePreparation = try XCTUnwrap(executor.savePreparationRequests.last)

        coordinator.sourceBuffer.replace(
            with: "second\n",
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertTrue(
            executor.finishSavePreparation(
                stalePreparation.token,
                with: .prepared(try makePendingSave(from: stalePreparation))
            )
        )
        XCTAssertTrue(host.saveRequests.isEmpty)

        coordinator.advanceScheduledWork(by: .milliseconds(100))
        let currentPreparation = try XCTUnwrap(executor.savePreparationRequests.last)
        XCTAssertNotEqual(currentPreparation.token, stalePreparation.token)
        XCTAssertTrue(
            executor.finishSavePreparation(
                currentPreparation.token,
                with: .prepared(try makePendingSave(from: currentPreparation))
            )
        )

        let commit = try XCTUnwrap(host.saveRequests.last)
        XCTAssertEqual(commit.token.operation, .saveCommit)
        XCTAssertEqual(commit.pendingSave.snapshot.text, "second\n")
        XCTAssertEqual(try coordinator.bridge.currentCommitRequest(), commit)

        let result = try SafeFileCommitter().commit(commit.pendingSave)
        try coordinator.bridge.store(result, for: commit.token)
        XCTAssertTrue(coordinator.handleSaveCompletion(token: commit.token, error: nil))
        XCTAssertEqual(try String(contentsOf: fixture.url, encoding: .utf8), "second\n")
    }

    func testTypedHostCloseWaitsForTheNativeCommitBoundary() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            fileMonitoringEnabled: false,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host
        coordinator.loadInitial(snapshot, data: data, from: fixture.url)

        coordinator.requestClose()

        let resolution = try XCTUnwrap(host.closeResolutions.last)
        XCTAssertEqual(resolution.disposition, .allowManagedClose)
        XCTAssertEqual(
            coordinator.reducerState.lifecycle,
            .closing(
                DocumentSyncCloseAttempt(
                    token: resolution.token,
                    sourceRevision: coordinator.reducerState.source,
                    kind: .managedFile,
                    resolution: .allowManagedClose
                )
            )
        )

        coordinator.completeClose(token: resolution.token, didCommit: false)
        XCTAssertEqual(coordinator.reducerState.lifecycle, .active)

        coordinator.requestClose()
        let committedResolution = try XCTUnwrap(host.closeResolutions.last)
        coordinator.completeClose(token: committedResolution.token, didCommit: true)
        XCTAssertEqual(coordinator.reducerState.lifecycle, .closed)
    }

    func testUntitledCloseUsesTheTypedNativeReviewBoundary() throws {
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "draft", format: .newDocument),
            fileMonitoringEnabled: false,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: nil)
        coordinator.delegate = host

        coordinator.requestClose()

        let resolution = try XCTUnwrap(host.closeResolutions.last)
        XCTAssertEqual(resolution.disposition, .deferToNativeUntitledReview)
        guard case .closing(let attempt) = coordinator.reducerState.lifecycle else {
            return XCTFail("The reducer must wait for the native close result.")
        }
        XCTAssertEqual(attempt.token, resolution.token)
        coordinator.completeClose(token: resolution.token, didCommit: true)
        XCTAssertEqual(coordinator.reducerState.lifecycle, .closed)
    }

    func testPersistedLegacyRecoveryEvidencePausesWithoutMutation() throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let store = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let identity = DocumentIdentity.make(url: fixture.url)
        let recoveredSnapshot = DocumentSnapshot(
            text: "recoverable\n",
            format: .newDocument
        )
        try store.add(snapshot: recoveredSnapshot, for: identity)
        let rawData = Data([0xFF, 0xFE, 0x00])
        let rawEntry = try store.addRawData(rawData, for: identity)
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host

        coordinator.loadInitial(snapshot, data: data, from: fixture.url)

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)
        XCTAssertFalse(coordinator.hasLocalRecovery)
        XCTAssertNil(coordinator.latestRawRecoveryURL)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)

        coordinator.sourceBuffer.replace(
            with: "must-not-write\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)

        coordinator.requestClose()
        XCTAssertEqual(
            host.closeResolutions.last?.disposition,
            .refuseManagedClose
        )
        XCTAssertEqual(store.latest(for: identity)?.snapshot, recoveredSnapshot)
        XCTAssertEqual(store.rawRecoveryEntries(for: identity), [rawEntry])
        XCTAssertEqual(store.rawRecoveryEntries(for: identity).first?.data, rawData)
    }

    func testEmptyRecoveryMoveIsAFaithfulNoOp() async throws {
        let source = try TemporaryMarkdownFile(contents: "base\n")
        let destination = try TemporaryMarkdownFile(contents: "base\n")
        defer {
            source.remove()
            destination.remove()
        }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: destination.url)
        coordinator.delegate = host
        coordinator.loadInitial(snapshot, data: data, from: source.url)
        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )

        let didMove = await coordinator.noteFileMovedAndWait(
            to: destination.url,
            knownData: data
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(coordinator.fileURL, destination.url.standardizedFileURL)
        XCTAssertNotEqual(coordinator.state, .synchronizationPaused)
        coordinator.advanceScheduledWork(by: .milliseconds(100))
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)
        XCTAssertEqual(preparation.targetURL, destination.url.standardizedFileURL)
        XCTAssertTrue(
            executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        XCTAssertEqual(host.saveRequests.last?.targetURL, destination.url.standardizedFileURL)
    }

    func testFirstAttachmentPausesForPersistedLegacyRecoveryEvidence()
        async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let store = SessionRecoveryStore()
        let identity = DocumentIdentity.make(url: fixture.url)
        try store.add(
            snapshot: DocumentSnapshot(
                text: "recoverable\n",
                format: .newDocument
            ),
            for: identity
        )
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: store,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }

        let didAttach = await coordinator.attachAndWait(
            to: fixture.url,
            knownData: data
        )
        XCTAssertTrue(didAttach)

        XCTAssertEqual(coordinator.fileURL, fixture.url.standardizedFileURL)
        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertEqual(store.latest(for: identity)?.snapshot.text, "recoverable\n")
    }

    func testSaveAsKeepsANewerLocalRevisionDirty() async throws {
        let destination = try TemporaryMarkdownFile(contents: "captured\n")
        defer { destination.remove() }
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let initial = DocumentSnapshot(text: "before\n", format: .newDocument)
        let coordinator = DocumentSyncCoordinator(
            snapshot: initial,
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: destination.url)
        coordinator.delegate = host
        coordinator.loadInitial(initial, data: Data("before\n".utf8), from: nil)
        coordinator.sourceBuffer.replace(
            with: "captured\n",
            origin: .localEditor(paneID: UUID())
        )
        let capturedRevision = coordinator.sourceBuffer.revision
        let capturedSnapshot = coordinator.currentSnapshot
        let capturedData = try TextFileCodec.encode(capturedSnapshot)
        coordinator.sourceBuffer.replace(
            with: "newer local\n",
            origin: .localEditor(paneID: UUID())
        )

        try await coordinator.attachAfterSaveAs(
            to: destination.url,
            expectedData: capturedData,
            expectedSnapshot: capturedSnapshot,
            expectedSourceRevision: capturedRevision
        )

        XCTAssertEqual(coordinator.durableState?.snapshot, capturedSnapshot)
        XCTAssertEqual(
            coordinator.reducerState.durableBaseline?.sourceRevision,
            capturedRevision
        )
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "newer local\n")
        XCTAssertTrue(coordinator.hasLocalChanges)

        guard case .debouncing = coordinator.reducerState.external else {
            return XCTFail("Save As must verify the destination before writing newer local text.")
        }
        coordinator.advanceScheduledWork(by: .zero)
        let externalRead = try XCTUnwrap(executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: destination.url,
            data: capturedData
        )
        let observation = try TextFileCodec.externalReadObservation(
            data: capturedData,
            targetURL: destination.url,
            identity: DocumentIdentity.make(url: destination.url),
            fingerprint: fingerprint
        )
        XCTAssertTrue(
            executor.finishExternalRead(
                externalRead.token,
                with: .finished(.unchanged(observation))
            )
        )
        coordinator.advanceScheduledWork(by: .milliseconds(100))
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)
        XCTAssertEqual(preparation.snapshot.text, "newer local\n")
    }

    func testInitialDurableStateSurvivesUntilAnExplicitAttachmentDecision()
        throws {
        let snapshot = DocumentSnapshot(text: "seed\n", format: .newDocument)
        let data = Data("seed\n".utf8)
        let initialDurableState = DurableFileState(
            snapshot: snapshot,
            fingerprint: FileFingerprint.make(data: data),
            generation: 7
        )
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            initialDurableState: initialDurableState,
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }

        XCTAssertEqual(coordinator.durableState, initialDurableState)
        coordinator.loadInitial(snapshot, data: data, from: nil)
        XCTAssertNil(coordinator.durableState)
    }

}

@MainActor
private final class TypedCoordinatorTestHost: DocumentSyncCoordinatorHost {
    let synchronizationFileURL: URL?
    private(set) var saveRequests: [DocumentSyncSaveCommitRequest] = []
    private(set) var closeResolutions: [DocumentSyncCloseResolution] = []
    private(set) var acceptedExternalChangeCount = 0

    init(fileURL: URL?) {
        synchronizationFileURL = fileURL
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave request: DocumentSyncSaveCommitRequest
    ) {
        saveRequests.append(request)
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        resolveClose resolution: DocumentSyncCloseResolution
    ) {
        closeResolutions.append(resolution)
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    ) {
        acceptedExternalChangeCount += 1
    }
}

@MainActor
private final class ControllableCoordinatorEffectExecutor:
    DocumentSyncCoordinatorEffectExecuting {
    private(set) var savePreparationRequests:
        [DocumentSyncSavePreparationRequest] = []
    private(set) var externalReadRequests: [DocumentSyncExternalReadRequest] = []
    private(set) var mergeRequests: [DocumentSyncMergeRequest] = []
    private(set) var reconciliationRequests:
        [DocumentSyncCommitReconciliationRequest] = []

    private var savePreparationCompletions: [
        SyncEffectToken: @MainActor (DocumentSyncSavePreparationExecution) -> Void
    ] = [:]
    private var externalReadCompletions: [
        SyncEffectToken: @MainActor (DocumentSyncExternalReadExecution) -> Void
    ] = [:]
    private var mergeCompletions: [
        SyncEffectToken: @MainActor (DocumentSyncMergeExecution) -> Void
    ] = [:]
    private var reconciliationCompletions: [
        SyncEffectToken: @MainActor (DocumentSyncCommitReconciliationResult) -> Void
    ] = [:]

    func prepareSave(
        _ request: DocumentSyncSavePreparationRequest,
        completion: @escaping @MainActor (DocumentSyncSavePreparationExecution) -> Void
    ) {
        savePreparationRequests.append(request)
        savePreparationCompletions[request.token] = completion
    }

    func readExternal(
        _ request: DocumentSyncExternalReadRequest,
        completion: @escaping @MainActor (DocumentSyncExternalReadExecution) -> Void
    ) {
        externalReadRequests.append(request)
        externalReadCompletions[request.token] = completion
    }

    func merge(
        _ request: DocumentSyncMergeRequest,
        completion: @escaping @MainActor (DocumentSyncMergeExecution) -> Void
    ) {
        mergeRequests.append(request)
        mergeCompletions[request.token] = completion
    }

    func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest,
        completion: @escaping @MainActor (DocumentSyncCommitReconciliationResult) -> Void
    ) {
        reconciliationRequests.append(request)
        reconciliationCompletions[request.token] = completion
    }

    @discardableResult
    func finishSavePreparation(
        _ token: SyncEffectToken,
        with result: DocumentSyncSavePreparationExecution
    ) -> Bool {
        guard let completion = savePreparationCompletions.removeValue(forKey: token) else {
            return false
        }
        completion(result)
        return true
    }

    @discardableResult
    func finishExternalRead(
        _ token: SyncEffectToken,
        with result: DocumentSyncExternalReadExecution
    ) -> Bool {
        guard let completion = externalReadCompletions.removeValue(forKey: token) else {
            return false
        }
        completion(result)
        return true
    }

    @discardableResult
    func finishMerge(
        _ token: SyncEffectToken,
        with result: DocumentSyncMergeExecution
    ) -> Bool {
        guard let completion = mergeCompletions.removeValue(forKey: token) else {
            return false
        }
        completion(result)
        return true
    }

    @discardableResult
    func finishReconciliation(
        _ token: SyncEffectToken,
        with result: DocumentSyncCommitReconciliationResult
    ) -> Bool {
        guard let completion = reconciliationCompletions.removeValue(forKey: token) else {
            return false
        }
        completion(result)
        return true
    }
}

private func makePendingSave(
    from request: DocumentSyncSavePreparationRequest
) throws -> PendingSaveToken {
    PendingSaveToken(
        generation: request.commitGeneration,
        sourceRevision: request.sourceRevision,
        preparedPayload: try TextFileCodec.prepareSavePayload(
            for: request.snapshot
        ),
        expectedDurableState: request.expectedBaseline?.asDurableFileState,
        targetURL: request.targetURL
    )
}

@MainActor
private final class DeterministicCoordinatorFixture {
    let scheduler: ManualSyncScheduler
    let executor: ControllableCoordinatorEffectExecutor
    let host: TypedCoordinatorTestHost
    let coordinator: DocumentSyncCoordinator

    init(
        snapshot: DocumentSnapshot,
        data: Data,
        url: URL,
        recoveryStore: SessionRecoveryStore = SessionRecoveryStore()
    ) {
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let host = TypedCoordinatorTestHost(fileURL: url)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: recoveryStore,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        coordinator.delegate = host
        coordinator.loadInitial(snapshot, data: data, from: url)
        self.scheduler = scheduler
        self.executor = executor
        self.host = host
        self.coordinator = coordinator
    }

    func fireLocalSave() {
        coordinator.advanceScheduledWork(by: .milliseconds(100))
    }

    func fireExternalRead() {
        coordinator.advanceScheduledWork(by: .zero)
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
