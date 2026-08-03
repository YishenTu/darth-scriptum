import Combine
import Darwin
import Foundation
import XCTest

@testable import DarthScriptum

@MainActor
final class DocumentSyncCoordinatorTests: XCTestCase {
    func testDefaultExecutorRejectsFIFOReadWithoutWaitingForWriter()
        async throws
    {
        let fifoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("darth-scriptum-\(UUID().uuidString).fifo")
        XCTAssertEqual(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)
        defer { try? FileManager.default.removeItem(at: fifoURL) }

        let executor = DocumentSyncDefaultEffectExecutor(
            recoveryStore: SessionRecoveryStore()
        )
        let token = SyncEffectToken(
            lifetime: UUID(),
            attachmentEpoch: 1,
            operation: .externalRead,
            attempt: 1
        )
        let request = DocumentSyncExternalReadRequest(
            token: token,
            targetURL: fifoURL,
            identity: DocumentIdentity.make(url: fifoURL),
            attachmentEpoch: 1,
            expectedBaseline: nil
        )
        var completion: DocumentSyncExternalReadExecution?

        executor.readExternal(request) { completion = $0 }
        try await Task.sleep(for: .milliseconds(100))
        let completedBeforeWriter = completion != nil

        if !completedBeforeWriter {
            let descriptor = fifoURL.path.withCString {
                Darwin.open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            }
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            for _ in 0..<50 where completion == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        XCTAssertTrue(
            completedBeforeWriter,
            "A document read must reject special files before waiting for a writer."
        )
        guard case .failed(.externalRead)? = completion else {
            return XCTFail("A FIFO must be rejected as an external-read failure.")
        }
    }

    func testDefaultExecutorCancellationDropsCompletionAndClearsTask()
        async throws
    {
        let gate = BlockingRecoveryIOGate()
        let executor = DocumentSyncDefaultEffectExecutor(
            recoveryStore: SessionRecoveryStore(),
            cpuOperationStartedHook: { _ in
                gate.blockUntilReleased()
            }
        )
        let targetURL = URL(fileURLWithPath: "/tmp/cancelled-save.md")
        let token = SyncEffectToken(
            lifetime: UUID(),
            attachmentEpoch: 1,
            operation: .savePreparation,
            attempt: 1
        )
        let request = DocumentSyncSavePreparationRequest(
            token: token,
            sourceRevision: SourceRevision(number: 1, text: "payload"),
            snapshot: DocumentSnapshot(text: "payload", format: .newDocument),
            targetURL: targetURL,
            identity: DocumentIdentity.make(url: targetURL),
            attachmentEpoch: 1,
            expectedBaseline: nil,
            commitGeneration: 1
        )
        var receivedCompletion = false
        defer { gate.release() }

        executor.prepareSave(request) { _ in
            receivedCompletion = true
        }
        await gate.waitUntilBlocked()
        XCTAssertEqual(executor.activeCPUOperationTokens, [token])

        executor.cancel(token: token)
        gate.release()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(executor.activeCPUOperationTokens.isEmpty)
        XCTAssertFalse(receivedCompletion)
    }

    func testCloseCancelsEveryExecutorCPUOperation() {
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: ManualSyncScheduler()
        )

        coordinator.close()

        XCTAssertEqual(executor.cancelAllCallCount, 1)
    }

    func testInitialLoadPreservesBOMFormatForTheNextSave() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "placeholder\n")
        defer { fixture.remove() }
        let loadedData =
            Data([0xEF, 0xBB, 0xBF])
            + Data("loaded\r\n".utf8)
        try loadedData.write(to: fixture.url)
        let loadedSnapshot = try TextFileCodec.decode(loadedData)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            recoveryStore: SessionRecoveryStore(),
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
        XCTAssertNil(coordinator.durableState)

        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()
        XCTAssertEqual(
            coordinator.durableState?.snapshot.format,
            loadedSnapshot.format
        )

        coordinator.sourceBuffer.replace(
            with: "edited\r\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)

        XCTAssertEqual(preparation.snapshot.format, loadedSnapshot.format)
        XCTAssertEqual(
            try TextFileCodec.encode(preparation.snapshot),
            Data([0xEF, 0xBB, 0xBF]) + Data("edited\r\n".utf8)
        )
    }

    func testInitialAttachmentObservesCurrentTargetBeforeStartingALocalSave()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "alpha\nbeta\n")
        defer { fixture.remove() }
        let capturedData = Data("alpha\nbeta\n".utf8)
        let capturedSnapshot = try TextFileCodec.decode(capturedData)
        let inspectionGate = BlockingRecoveryIOGate()
        let blockedFileAccess = Task {
            try await DocumentFileAccess.perform {
                inspectionGate.blockUntilReleased()
            }
        }
        await inspectionGate.waitUntilBlocked()

        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer {
            inspectionGate.release()
            coordinator.close()
        }
        coordinator.loadInitial(
            capturedSnapshot,
            data: capturedData,
            from: fixture.url
        )

        let externalData = Data("ALPHA\nbeta\n".utf8)
        try externalData.write(to: fixture.url)
        inspectionGate.release()
        try await blockedFileAccess.value
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        guard case .debouncing = coordinator.reducerState.external else {
            return XCTFail(
                "Fresh initial target bytes must be queued before local saving."
            )
        }
        XCTAssertEqual(coordinator.currentSnapshot, capturedSnapshot)
        XCTAssertEqual(
            coordinator.durableState?.snapshot,
            capturedSnapshot
        )

        coordinator.sourceBuffer.replace(
            with: "alpha\nBETA\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)

        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertTrue(executor.externalReadRequests.isEmpty)
        let merge = try XCTUnwrap(executor.mergeRequests.last)
        XCTAssertEqual(merge.base, capturedSnapshot)
        XCTAssertEqual(merge.local.text, "alpha\nBETA\n")
        XCTAssertEqual(merge.external.text, "ALPHA\nbeta\n")
        XCTAssertTrue(
            executor.finishMerge(
                merge.token,
                with: .finished(ThreeWayTextMerger().result(for: merge))
            )
        )

        XCTAssertEqual(coordinator.currentSnapshot.text, "ALPHA\nBETA\n")
        XCTAssertEqual(
            coordinator.durableState?.snapshot.text,
            "ALPHA\nbeta\n"
        )
        XCTAssertEqual(
            coordinator.reducerState.fileAttachment?.identity,
            DocumentIdentity.make(url: fixture.url)
        )
        XCTAssertEqual(
            coordinator.durableState?.fingerprint.contentDigest,
            FileFingerprint.make(data: externalData).contentDigest
        )
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)

        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)
        XCTAssertEqual(preparation.snapshot.text, "ALPHA\nBETA\n")
        XCTAssertEqual(
            preparation.expectedBaseline?.snapshot.text,
            "ALPHA\nbeta\n"
        )
    }

    func testInitialAttachmentReplaysPresenterSignalAfterFreshReadBeforeMonitor()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "captured\n")
        defer { fixture.remove() }
        let capturedData = Data("captured\n".utf8)
        let capturedSnapshot = try TextFileCodec.decode(capturedData)
        let externalData = Data("external\n".utf8)
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        weak var weakCoordinator: DocumentSyncCoordinator?
        var freshReadCompletionCount = 0
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler,
            initialAttachmentFreshReadCompletedHook: {
                freshReadCompletionCount += 1
                do {
                    try externalData.write(to: fixture.url)
                } catch {
                    XCTFail("The external write failed: \(error)")
                }
                weakCoordinator?.noteCoordinatedExternalChange()
            }
        )
        weakCoordinator = coordinator
        defer { coordinator.close() }

        coordinator.loadInitial(
            capturedSnapshot,
            data: capturedData,
            from: fixture.url
        )
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        XCTAssertEqual(freshReadCompletionCount, 1)
        XCTAssertEqual(coordinator.currentSnapshot, capturedSnapshot)
        guard case .debouncing = coordinator.reducerState.external else {
            return XCTFail(
                "The pre-monitor presenter signal must schedule a fresh read."
            )
        }
        XCTAssertTrue(executor.externalReadRequests.isEmpty)

        coordinator.advanceScheduledWork(by: .milliseconds(0))
        let read = try XCTUnwrap(executor.externalReadRequests.last)
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
            executor.finishExternalRead(
                read.token,
                with: .finished(.changed(change))
            )
        )

        XCTAssertEqual(coordinator.currentSnapshot.text, "external\n")
        XCTAssertEqual(
            coordinator.durableState?.fingerprint.contentDigest,
            FileFingerprint.make(data: externalData).contentDigest
        )
    }

    func testDocumentReadSerializesLoadedSnapshotBeforeAttachmentVerification()
        throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "placeholder\n")
        defer { fixture.remove() }
        let loadedData =
            Data([0xEF, 0xBB, 0xBF])
            + Data("loaded\r\n".utf8)
        let document = MarkdownDocument()
        document.fileURL = fixture.url
        defer { document.syncCoordinator.close() }

        try document.read(
            from: loadedData,
            ofType: "net.daringfireball.markdown"
        )

        let serialized = try document.data(
            ofType: "net.daringfireball.markdown"
        )

        XCTAssertEqual(serialized, loadedData)
        XCTAssertEqual(
            document.syncCoordinator.currentSnapshot,
            try TextFileCodec.decode(loadedData)
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

    func testSaveAsWithDestinationRecoveryFailsClosedBeforeAnyLocalWrite()
        async throws
    {
        let destination = try TemporaryMarkdownFile(contents: "external\n")
        defer { destination.remove() }
        let expectedData = Data("saved\n".utf8)
        let expectedSnapshot = try TextFileCodec.decode(expectedData)
        let recoveryStore = SessionRecoveryStore()
        let destinationIdentity = DocumentIdentity.make(url: destination.url)
        _ = try await recoveryStore.add(
            snapshot: DocumentSnapshot(text: "recover me\n", format: .newDocument),
            for: destinationIdentity
        )
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let coordinator = DocumentSyncCoordinator(
            snapshot: expectedSnapshot,
            recoveryStore: recoveryStore,
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }

        do {
            try await coordinator.attachAfterSaveAs(
                to: destination.url,
                expectedData: expectedData,
                expectedSnapshot: expectedSnapshot
            )
            XCTFail("Save As must not claim verified attachment while recovery blocks it.")
        } catch let error as DocumentSyncCoordinatorAttachmentError {
            XCTAssertEqual(error, .recoveryBlocksVerification)
        }

        XCTAssertTrue(coordinator.reducerState.externalSignalPending)
        XCTAssertTrue(coordinator.hasLocalChanges == false)
        coordinator.sourceBuffer.replace(
            with: "newer local\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))

        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: destination.url, encoding: .utf8),
            "external\n"
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
        await assertInitialAttachment(fixture)

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
        await fixture.coordinator.waitForCurrentRecoveryOperation()
        _ = await fixture.coordinator.waitForRecoveryStartup()

        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertNil(fixture.coordinator.presentedState)
        XCTAssertEqual(
            fixture.coordinator.fileURL,
            destination.url.standardizedFileURL
        )
    }

    func testVerifiedSaveAsAfterManagedSaveFailureRestoresPresentationAndClose()
        async throws
    {
        let original = try TemporaryMarkdownFile(contents: "base\n")
        let destination = try TemporaryMarkdownFile(contents: "local\n")
        defer {
            original.remove()
            destination.remove()
        }
        let initialData = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(initialData)
        let fixture = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: initialData,
            url: original.url
        )
        defer { fixture.coordinator.close() }
        await assertInitialAttachment(fixture)

        fixture.coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        let savedRevision = fixture.coordinator.sourceBuffer.revision
        let savedSnapshot = fixture.coordinator.currentSnapshot
        let savedData = try TextFileCodec.encode(savedSnapshot)
        try savedData.write(to: destination.url)
        fixture.fireLocalSave()
        let preparation = try XCTUnwrap(
            fixture.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            fixture.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makePendingSave(from: preparation))
            )
        )
        let commit = try XCTUnwrap(fixture.host.saveRequests.last)
        _ = fixture.coordinator.handleSaveCompletion(
            token: commit.token,
            error: CocoaError(.fileWriteUnknown)
        )
        let staleReconciliation = try XCTUnwrap(
            fixture.executor.reconciliationRequests.last
        )
        XCTAssertEqual(
            fixture.coordinator.presentedState,
            .synchronizationPaused
        )
        fixture.coordinator.requestClose()
        XCTAssertEqual(
            fixture.host.closeResolutions.last?.disposition,
            .refuseManagedClose
        )

        let didObserveMove = await fixture.coordinator.noteFileMovedAndWait(
            to: destination.url,
            knownData: savedData
        )
        XCTAssertTrue(didObserveMove)
        XCTAssertEqual(
            fixture.coordinator.fileURL,
            original.url.standardizedFileURL
        )
        XCTAssertNotNil(
            fixture.coordinator.reducerState.pendingAttachmentTransition
        )

        try await fixture.coordinator.attachAfterSaveAs(
            to: destination.url,
            expectedData: savedData,
            expectedSnapshot: savedSnapshot,
            expectedSourceRevision: savedRevision
        )
        await fixture.coordinator.waitForCurrentRecoveryOperation()

        XCTAssertEqual(
            try Data(contentsOf: destination.url),
            savedData
        )
        XCTAssertEqual(
            fixture.coordinator.fileURL,
            destination.url.standardizedFileURL
        )
        XCTAssertEqual(
            fixture.coordinator.durableState?.snapshot,
            savedSnapshot
        )
        XCTAssertNil(fixture.coordinator.reducerState.uncertainCommit)
        XCTAssertNil(
            fixture.coordinator.reducerState.pendingAttachmentTransition
        )
        XCTAssertNil(fixture.coordinator.presentedState)
        XCTAssertEqual(fixture.coordinator.state, .idle)

        XCTAssertTrue(
            fixture.executor.finishReconciliation(
                staleReconciliation.token,
                with: .unresolved
            )
        )
        XCTAssertEqual(
            fixture.coordinator.fileURL,
            destination.url.standardizedFileURL
        )
        XCTAssertNil(fixture.coordinator.presentedState)

        fixture.coordinator.requestClose()
        XCTAssertEqual(
            fixture.host.closeResolutions.last?.disposition,
            .allowManagedClose
        )
    }

    func testDefaultExecutorReconcilesPostSwapFailureAndAllowsManagedClose()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let scheduler = ManualSyncScheduler()
        let initialData = Data("base\n".utf8)
        let initialSnapshot = try TextFileCodec.decode(initialData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            recoveryStore: recoveryStore,
            fileMonitoringEnabled: false,
            manualScheduler: scheduler
        )
        defer { coordinator.close() }
        let host = AwaitingCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host
        coordinator.loadInitial(
            initialSnapshot,
            data: initialData,
            from: fixture.url
        )
        await assertInitialAttachment(coordinator)
        guard case .ready = await coordinator.waitForRecoveryStartup() else {
            return XCTFail("Recovery must be ready before the commit fault.")
        }

        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.requestClose()
        coordinator.advanceScheduledWork(by: .seconds(1))
        let request = await host.nextSaveRequest()

        let injectedError: Error
        do {
            _ = try await DocumentFileAccess.perform {
                try SafeFileCommitter(
                    recoveryDirectory: recoveryDirectory,
                    afterAtomicSwap: {
                        throw CoordinatorPostSwapError.injected
                    }
                ).commit(request.pendingSave)
            }
            return XCTFail("The post-swap fault must interrupt completion.")
        } catch {
            injectedError = error
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), Data("local\n".utf8))
        let duplicateReplacementDirectory =
            fixture.directory.appendingPathComponent(
                "duplicate-replacement",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: duplicateReplacementDirectory,
            withIntermediateDirectories: true
        )
        let duplicateCandidate =
            duplicateReplacementDirectory
            .appendingPathComponent("candidate")
        try request.pendingSave.encodedData.write(to: duplicateCandidate)
        let duplicateArtifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: duplicateCandidate,
            replacementDirectoryURL: duplicateReplacementDirectory,
            targetURL: request.targetURL.resolvingSymlinksInPath(),
            requestedTargetURL: request.targetURL,
            documentIdentity: request.identity,
            commitGeneration: request.commitGeneration,
            expectedPreimageFingerprint: try XCTUnwrap(
                request.expectedBaseline
            ).fingerprint,
            committedPayloadFingerprint:
                request.pendingSave.contentFingerprint,
            recoveryDirectory: recoveryDirectory
        )
        XCTAssertFalse(
            coordinator.handleSaveCompletion(
                token: request.token,
                error: injectedError
            )
        )
        let refused = await host.nextCloseResolution()
        XCTAssertEqual(refused.disposition, .refuseManagedClose)

        await coordinator.waitForCurrentCommitReconciliation()
        XCTAssertNotNil(coordinator.reducerState.uncertainCommit)
        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)

        try CommitRecoveryJournalStore.acknowledge(duplicateArtifact)
        coordinator.retrySynchronization()
        await coordinator.waitForCurrentCommitReconciliation()
        XCTAssertNil(coordinator.reducerState.uncertainCommit)
        XCTAssertNil(coordinator.presentedState)
        XCTAssertFalse(coordinator.hasLocalChanges)
        XCTAssertEqual(
            coordinator.durableState?.snapshot.text,
            "local\n"
        )
        coordinator.requestClose()
        let resolution = await host.nextCloseResolution()

        XCTAssertEqual(resolution.disposition, .allowManagedClose)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(
            try Data(contentsOf: fixture.url),
            Data("local\n".utf8)
        )
        XCTAssertTrue(
            try CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            ).isEmpty
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

    func testDocumentAllowsConcurrentReadsForSupportedTypes() {
        XCTAssertTrue(
            MarkdownDocument.canConcurrentlyReadDocuments(
                ofType: "net.daringfireball.markdown"
            )
        )
        XCTAssertTrue(
            MarkdownDocument.canConcurrentlyReadDocuments(
                ofType: "public.plain-text"
            )
        )
        XCTAssertFalse(
            MarkdownDocument.canConcurrentlyReadDocuments(
                ofType: "com.example.unsupported"
            )
        )
    }

    func testBackgroundReadStagesContentBeforeMainActorInstallation() async throws {
        let document = MarkdownDocument()
        let documentBox = UncheckedDocumentBox(document)
        let data = Data("background\r\n".utf8)

        XCTAssertFalse(document.hasInitializedSynchronization)
        let didRead = await Task.detached {
            do {
                try documentBox.value.read(
                    from: data,
                    ofType: "net.daringfireball.markdown"
                )
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(didRead)
        XCTAssertFalse(document.hasInitializedSynchronization)
        XCTAssertEqual(
            document.syncCoordinator.currentSnapshot,
            try TextFileCodec.decode(data)
        )
        XCTAssertTrue(document.hasInitializedSynchronization)
        document.syncCoordinator.close()
    }

    func testUndoAndRedoUpdateNativeDocumentChangeDirection() {
        let document = MarkdownDocument()
        defer { document.syncCoordinator.close() }

        document.syncCoordinator.sourceBuffer.replace(
            with: "edited",
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertTrue(document.isDocumentEdited)

        XCTAssertTrue(document.syncCoordinator.sourceBuffer.undo())
        XCTAssertFalse(document.isDocumentEdited)

        XCTAssertTrue(document.syncCoordinator.sourceBuffer.redo())
        XCTAssertTrue(document.isDocumentEdited)
    }

    func testFailedManagedSaveDoesNotAddANativeChangeBeyondTheSourceEdit()
        async throws
    {
        let document = MarkdownDocument(
            recoveryStore: SessionRecoveryStore(),
            fileCommitter: FailingDocumentFileCommitter()
        )
        defer { document.syncCoordinator.close() }
        document.syncCoordinator.sourceBuffer.replace(
            with: "edited",
            origin: .localEditor(paneID: UUID())
        )
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        let pendingSave = PendingSaveToken(
            generation: 1,
            sourceRevision: document.syncCoordinator.sourceBuffer.revision,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: document.syncCoordinator.currentSnapshot
            ),
            expectedDurableState: nil,
            targetURL: targetURL
        )
        let request = DocumentSyncSaveCommitRequest(
            token: SyncEffectToken(
                lifetime: document.syncCoordinator.reducerState.lifetime,
                attachmentEpoch: 0,
                operation: .saveCommit,
                attempt: 1
            ),
            pendingSave: pendingSave,
            targetURL: targetURL,
            identity: DocumentIdentity.make(url: targetURL),
            attachmentEpoch: 0,
            expectedBaseline: nil,
            commitGeneration: 1
        )
        try document.syncCoordinator.bridge.install(request)

        document.syncCoordinator(
            document.syncCoordinator,
            requestSave: request
        )
        for _ in 0..<200 {
            if (try? document.syncCoordinator.bridge.currentCommitRequest()) == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertThrowsError(
            try document.syncCoordinator.bridge.currentCommitRequest()
        )

        XCTAssertTrue(document.syncCoordinator.sourceBuffer.undo())
        XCTAssertFalse(document.isDocumentEdited)
    }

    func testDelayedExternalMetadataRefreshCannotClearANewerNativeEdit()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "external\n")
        defer { fixture.remove() }
        let lane = DocumentFileAccess.makeDocumentLane()
        let gate = BlockingRecoveryIOGate()
        defer { gate.release() }
        let blocker = Task.detached {
            try await lane.perform {
                gate.blockUntilReleased()
            }
        }
        await gate.waitUntilBlocked()
        let document = MarkdownDocument(
            recoveryStore: SessionRecoveryStore(),
            fileAccessLane: lane
        )
        defer { document.syncCoordinator.close() }
        document.fileURL = fixture.url
        document.fileModificationDate = nil
        document.updateChangeCount(.changeDone)

        document.syncCoordinator(
            document.syncCoordinator,
            acceptedExternalFileAt: fixture.url,
            hasLocalChanges: false
        )
        XCTAssertFalse(document.isDocumentEdited)

        document.syncCoordinator.sourceBuffer.replace(
            with: "newer local edit",
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertTrue(document.isDocumentEdited)
        await Task.yield()
        gate.release()
        _ = try await blocker.value
        for _ in 0..<200 where document.fileModificationDate == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNotNil(document.fileModificationDate)
        XCTAssertTrue(document.isDocumentEdited)
    }

    func testManagedWriteUnblocksInteractionBeforeCommitStarts() async throws {
        let order = StringRecorder()
        let committer = RecordingDocumentFileCommitter(order: order)
        let document = MarkdownDocument(
            recoveryStore: SessionRecoveryStore(),
            fileAccessLane: DocumentFileAccess.makeDocumentLane(),
            fileCommitter: committer,
            managedWriteDidUnblock: {
                order.append("unblock")
            }
        )
        defer { document.syncCoordinator.close() }
        let targetURL = URL(fileURLWithPath: "/tmp/managed-write.md")
        let pendingSave = PendingSaveToken(
            generation: 1,
            sourceRevision: SourceRevision(number: 1, text: "saved"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: DocumentSnapshot(text: "saved", format: .newDocument)
            ),
            expectedDurableState: nil,
            targetURL: targetURL
        )
        let request = DocumentSyncSaveCommitRequest(
            token: SyncEffectToken(
                lifetime: UUID(),
                attachmentEpoch: 1,
                operation: .saveCommit,
                attempt: 1
            ),
            pendingSave: pendingSave,
            targetURL: targetURL,
            identity: DocumentIdentity.make(url: targetURL),
            attachmentEpoch: 1,
            expectedBaseline: nil,
            commitGeneration: 1
        )
        try document.syncCoordinator.bridge.install(request)
        let documentBox = UncheckedDocumentBox(document)

        let didWrite = await Task.detached {
            do {
                try documentBox.value.writeSafely(
                    to: targetURL,
                    ofType: "net.daringfireball.markdown",
                    for: .saveOperation
                )
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(didWrite)
        XCTAssertEqual(order.values, ["unblock", "commit"])
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
        await assertInitialAttachment(harness)
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
        guard case .ready = await coordinator.waitForRecoveryStartup() else {
            return XCTFail("Attachment effects require a ready recovery store.")
        }
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
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
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
        await assertInitialAttachment(harness)

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
        async throws
    {
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
        await assertInitialAttachment(harness)
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

    func testSameContentSymlinkRetargetMigratesRecoveryAndBlocksWrites()
        async throws
    {
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
        _ = try await recoveryStore.add(
            snapshot: DocumentSnapshot(
                text: "recoverable\n",
                format: snapshot.format
            ),
            for: oldIdentity
        )
        coordinator.loadInitial(snapshot, data: originalData, from: link)
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

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
        await coordinator.waitForCurrentRecoveryOperation()
        XCTAssertEqual(coordinator.state, .recoveredConflict)
        let oldRecovery = try await recoveryStore.latest(for: oldIdentity)
        XCTAssertNil(oldRecovery)
        let newRecovery = try await recoveryStore.latest(for: newIdentity)
        XCTAssertNotNil(newRecovery)
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
        async throws
    {
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
        await assertInitialAttachment(harness)

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
        await assertInitialAttachment(harness)
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
        async throws
    {
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
        await assertInitialAttachment(harness)

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

    func testFailedAtomicSwapIsProvenNotStartedWithoutReconciliation()
        async throws
    {
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
        await assertInitialAttachment(harness)

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
            error: SafeFileCommitter.CommitError.atomicSwapFailed
        )

        XCTAssertNil(harness.coordinator.reducerState.uncertainCommit)
        XCTAssertTrue(harness.executor.reconciliationRequests.isEmpty)
        XCTAssertFalse(harness.coordinator.failureRequiresSaveAs)
        XCTAssertTrue(harness.coordinator.hasLocalChanges)
        if case .failed = harness.coordinator.presentedState {
            // Expected.
        } else {
            XCTFail("The proven failed swap should surface a local-save issue.")
        }
    }

    func testOverlappingExternalEditPersistsAndRestoresLegacyRecovery()
        async throws
    {
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
        await assertInitialAttachment(harness)

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

        await harness.coordinator.waitForCurrentRecoveryOperation()
        XCTAssertEqual(harness.coordinator.state, .recoveredConflict)
        XCTAssertEqual(harness.coordinator.sourceBuffer.revision.text, "hullo\n")
        let persistedRecovery = try await recoveryStore.latest(
            for: DocumentIdentity.make(url: fixture.url)
        )
        XCTAssertEqual(persistedRecovery?.snapshot.text, "hallo\n")
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
        XCTAssertFalse(
            harness.coordinator.handleSaveCompletion(
                token: save.token,
                error: nil
            )
        )
        await harness.coordinator.waitForCurrentRecoveryOperation()

        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "hallo\n"
        )
        let removedRecovery = try await recoveryStore.latest(
            for: DocumentIdentity.make(url: fixture.url)
        )
        XCTAssertNil(removedRecovery)
        XCTAssertFalse(harness.coordinator.hasLocalRecovery)
    }

    func testFreshConflictUsesTheDestinationGenerationAfterEmptyMigration()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let recoveryStore = SessionRecoveryStore()
        let destinationIdentity = DocumentIdentity.make(url: fixture.url)
        _ = try await recoveryStore.advanceEmptyRecoveryMigration(
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
        await assertInitialAttachment(harness)

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

        await harness.coordinator.waitForCurrentRecoveryOperation()
        XCTAssertEqual(harness.coordinator.state, .recoveredConflict)
        let destinationRecovery = try await recoveryStore.latest(
            for: destinationIdentity
        )
        XCTAssertEqual(destinationRecovery?.snapshot.text, "local\n")
    }

    func testAttachMigratesDecodedAndRawRecoveryRecords()
        async throws
    {
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
        _ = try await store.add(snapshot: recovery, for: oldIdentity)
        let rawData = Data([0xFF])
        let rawEntry = try await store.addRawData(rawData, for: oldIdentity)
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        let didAttach = await coordinator.attachAndWait(
            to: newURL,
            knownData: newData
        )

        XCTAssertTrue(didAttach)
        await coordinator.waitForCurrentRecoveryOperation()
        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        let oldRecovery = try await store.latest(for: oldIdentity)
        XCTAssertNil(oldRecovery)
        let oldRaw = try await store.rawRecoveryEntries(for: oldIdentity)
        XCTAssertTrue(oldRaw.isEmpty)
        let newRecovery = try await store.latest(for: newIdentity)
        XCTAssertEqual(newRecovery?.snapshot, recovery)
        let newRaw = try await store.rawRecoveryEntries(for: newIdentity)
        XCTAssertEqual(newRaw.map(\.id), [rawEntry.id])
        let newRawData = try await newRaw.first?.loadData()
        XCTAssertEqual(newRawData, rawData)
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
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.directory.appendingPathComponent(
                "recovery",
                isDirectory: true
            ),
            migrationWriteHook: { _ in
                throw RecoveryStoreIssue.unavailable
            }
        )
        _ = try await store.add(
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        _ = await coordinator.attachAndWait(to: newURL, knownData: newData)
        await coordinator.waitForCurrentRecoveryOperation()
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
        let retainedRecovery = try await store.latest(for: oldIdentity)
        XCTAssertNotNil(retainedRecovery)
    }

    func testLegacyRecoveryMigrationRetryCannotRestartTheSuppressedSave()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let newURL = fixture.directory.appendingPathComponent("renamed.md")
        let newData = Data("new\n".utf8)
        try newData.write(to: newURL)
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.directory.appendingPathComponent(
                "recovery",
                isDirectory: true
            ),
            migrationWriteHook: { _ in
                throw RecoveryStoreIssue.unavailable
            }
        )
        _ = try await store.add(
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()
        _ = await coordinator.attachAndWait(to: newURL, knownData: newData)
        await coordinator.waitForCurrentRecoveryOperation()

        coordinator.retryRecoveryMigration()
        // Retrying a failed store first reloads the authoritative records,
        // then starts the migration again. Await both tokens so the no-save
        // assertions observe the terminal migration failure, not its barrier.
        await coordinator.waitForCurrentRecoveryOperation()
        await coordinator.waitForCurrentRecoveryOperation()
        coordinator.sourceBuffer.replace(
            with: "still-paused\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: .seconds(1))

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertEqual(
            coordinator.reducerState.recoveryAccess,
            .failed(.recovery)
        )
        XCTAssertTrue(coordinator.statusSnapshot.recoveryMigrationIsPending)
        XCTAssertTrue(host.saveRequests.isEmpty)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        let retainedRecovery = try await store.latest(for: oldIdentity)
        XCTAssertNotNil(retainedRecovery)
    }

    func testLegacyRecoveryPauseExposesOnlyNonDestructiveActions()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "old\n")
        defer { fixture.remove() }
        let oldIdentity = DocumentIdentity.make(url: fixture.url)
        let store = SessionRecoveryStore()
        _ = try await store.addRawData(
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

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
        XCTAssertEqual(
            presentation?.primaryAction,
            .saveAs
        )
        XCTAssertFalse(presentation?.offersRawRecoveryDiscard == true)
        XCTAssertFalse(presentation?.offersLocalRevisionRestore == true)
    }

    func testReopenedRawAndDecodedRecoveryPausesWithoutMutatingEvidence()
        async throws
    {
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
        _ = try await initialStore.add(
            snapshot: recoveredSnapshot,
            for: identity
        )
        _ = try await initialStore.addRawData(rawData, for: identity)

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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertTrue(coordinator.hasLocalRecovery)
        XCTAssertNotNil(coordinator.latestRawRecoveryURL)
        XCTAssertEqual(
            coordinator.sourceBuffer.revision.text,
            diskSnapshot.text
        )
        let decodedRecovery = try await reopenedStore.latest(for: identity)
        XCTAssertEqual(decodedRecovery?.snapshot, recoveredSnapshot)
        let rawRecoveries = try await reopenedStore.rawRecoveryEntries(
            for: identity
        )
        let rawRecovery = try XCTUnwrap(rawRecoveries.first)
        let loadedRawData = try await rawRecovery.loadData()
        XCTAssertEqual(loadedRawData, rawData)
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
        await assertInitialAttachment(harness)

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
        async throws
    {
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
        await assertInitialAttachment(harness)

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
        async throws
    {
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
        await assertInitialAttachment(harness)

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
        async throws
    {
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
        await assertInitialAttachment(harness)

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

        await harness.coordinator.waitForCurrentRecoveryOperation()

        XCTAssertEqual(harness.coordinator.state, .synchronizationPaused)
        XCTAssertEqual(flushResult, false)
        var repeatedFlushResult: Bool?
        harness.coordinator.flushNow { repeatedFlushResult = $0 }
        XCTAssertEqual(repeatedFlushResult, false)
        let identity = DocumentIdentity.make(url: fixture.url)
        let rawEntries = try await recoveryStore.rawRecoveryEntries(for: identity)
        XCTAssertEqual(rawEntries.count, 1)
        let persistedRawData = try await rawEntries.first?.loadData()
        XCTAssertEqual(persistedRawData, invalidExternal)
        XCTAssertEqual(
            harness.coordinator.reducerState.unresolvedDisplacedPreimage?
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

    func testLargeDisplacedPreimagePersistenceKeepsMainActorResponsive()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let rawPersistenceGate = BlockingRecoveryIOGate()
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory,
            rawPersistenceHook: { phase in
                guard phase == .beforeRawPersistence else { return }
                rawPersistenceGate.blockUntilReleased()
            }
        )
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = DeterministicCoordinatorFixture(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: recoveryStore
        )
        defer {
            rawPersistenceGate.release()
            harness.coordinator.close()
        }
        await assertInitialAttachment(harness)

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
        let targetURL = fixture.url
        let displacedByteCount = 8 * 1_024 * 1_024
        let result = try await DocumentFileAccess.perform {
            let displaced = Data(
                repeating: 0xFF,
                count: displacedByteCount
            )
            let committer = SafeFileCommitter(
                recoveryDirectory: recoveryDirectory,
                beforeAtomicSwap: {
                    try displaced.write(to: targetURL)
                }
            )
            return try committer.commit(request.pendingSave)
        }
        XCTAssertEqual(result.displacedPreimage?.fingerprint.byteCount, displacedByteCount)
        try harness.coordinator.bridge.store(result, for: request.token)
        _ = harness.coordinator.handleSaveCompletion(
            token: request.token,
            error: nil
        )

        await rawPersistenceGate.waitUntilBlocked()
        let heartbeat = CoordinatorMainActorHeartbeat()
        Task { @MainActor in
            heartbeat.record()
        }
        await heartbeat.waitForRecord()
        XCTAssertTrue(heartbeat.didRecord)
        XCTAssertEqual(
            harness.coordinator.reducerState.pendingDisplacedPreimage?
                .rawPayload.fingerprint.byteCount,
            displacedByteCount
        )

        rawPersistenceGate.release()
        await harness.coordinator.waitForCurrentRecoveryOperation()
        let identity = DocumentIdentity.make(url: fixture.url)
        let rawEntries = try await recoveryStore.rawRecoveryEntries(for: identity)
        XCTAssertEqual(rawEntries.first?.byteCount, displacedByteCount)
    }

    func testMonitorStartupDoesNotBlockMainActorAndIsCancelledAfterClose()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let monitorStartupGate = BlockingRecoveryIOGate()
        let descriptorClosures = DescriptorCloseRecorder()
        let snapshot = try TextFileCodec.decode(Data("base\n".utf8))
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: true,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler(),
            monitorStartHook: {
                monitorStartupGate.blockUntilReleased()
            },
            monitorDescriptorClosedHook: { didClose in
                descriptorClosures.record(didClose)
            }
        )
        defer {
            monitorStartupGate.release()
            coordinator.close()
        }
        coordinator.loadInitial(
            snapshot,
            data: Data("base\n".utf8),
            from: fixture.url
        )

        await monitorStartupGate.waitUntilBlocked()
        let heartbeat = CoordinatorMainActorHeartbeat()
        Task { @MainActor in
            heartbeat.record()
        }
        await heartbeat.waitForRecord()
        XCTAssertTrue(heartbeat.didRecord)

        coordinator.close()
        monitorStartupGate.release()
        await descriptorClosures.waitForCount(2)
        XCTAssertEqual(descriptorClosures.closedCount, 2)
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
        await assertInitialAttachment(harness)

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

    func testRepeatedSiblingSignalsDoNotStarveLocalWrite() async throws {
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
        await assertInitialAttachment(harness)

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

    func testExternalReloadCancelsAStalePreparedSave() async throws {
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
        await assertInitialAttachment(harness)

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
        await harness.coordinator.waitForCurrentRecoveryOperation()
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
        let recoveredSnapshot = try await recoveryStore.latest(
            for: DocumentIdentity.make(url: fixture.url)
        )
        XCTAssertEqual(recoveredSnapshot?.snapshot.text, "local\n")
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "external\n"
        )
    }

    func testExternalChangeStartsReadingWithoutADebounce() async throws {
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
        await assertInitialAttachment(harness)

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

    func testPendingExternalSignalRunsAfterTheActiveRead() async throws {
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
        await assertInitialAttachment(harness)

        let olderData = Data("older\n".utf8)
        try olderData.write(to: fixture.url)
        let olderPayload = try TextFileCodec.readVerifiedFilePayload(
            at: fixture.url
        )
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let firstRead = try XCTUnwrap(harness.executor.externalReadRequests.last)

        let newerData = Data("newer\n".utf8)
        try newerData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()

        let olderChange = try TextFileCodec.decodeExternalChange(
            data: olderPayload.data,
            targetURL: fixture.url,
            identity: DocumentIdentity.make(url: fixture.url),
            fingerprint: olderPayload.fingerprint
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

    func testRepeatedSiblingSignalsCannotStarveAnExternalReload() async throws {
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
        await assertInitialAttachment(harness)
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

    func testSaveCompletionReportsNewerVisibleEditAsUnsynchronized() async throws {
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
        await assertInitialAttachment(harness)

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

    func testTypedHostReceivesOnlyTheCurrentFullCommitRequest() async throws {
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        coordinator.sourceBuffer.replace(
            with: "first\n",
            origin: .localEditor(paneID: UUID())
        )
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
        let stalePreparation = try XCTUnwrap(executor.savePreparationRequests.last)

        coordinator.sourceBuffer.replace(
            with: "second\n",
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertEqual(executor.cancelledTokens, [stalePreparation.token])
        XCTAssertTrue(
            executor.finishSavePreparation(
                stalePreparation.token,
                with: .prepared(try makePendingSave(from: stalePreparation))
            )
        )
        XCTAssertTrue(host.saveRequests.isEmpty)

        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
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

    func testTypedHostCloseWaitsForTheNativeCommitBoundary() async throws {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let coordinator = DocumentSyncCoordinator(
            snapshot: snapshot,
            recoveryStore: SessionRecoveryStore(),
            fileMonitoringEnabled: false,
            effectExecutor: ControllableCoordinatorEffectExecutor(),
            manualScheduler: ManualSyncScheduler()
        )
        defer { coordinator.close() }
        let host = TypedCoordinatorTestHost(fileURL: fixture.url)
        coordinator.delegate = host
        coordinator.loadInitial(snapshot, data: data, from: fixture.url)

        coordinator.requestClose()

        guard case .closing(let provisionalAttempt) = coordinator.reducerState.lifecycle else {
            return XCTFail("A close during initial verification must remain pending.")
        }
        XCTAssertEqual(provisionalAttempt.kind, .managedFile)
        XCTAssertNil(provisionalAttempt.resolution)
        XCTAssertTrue(host.closeResolutions.isEmpty)

        await assertInitialAttachment(coordinator)
        guard case .ready = await coordinator.waitForRecoveryStartup() else {
            return XCTFail("A clean opened file must finish recovery before close resolves.")
        }
        let resolution = try XCTUnwrap(host.closeResolutions.last)
        XCTAssertEqual(resolution.disposition, .allowManagedClose)
        XCTAssertEqual(host.closeResolutions.count, 1)
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

    func testPersistedLegacyRecoveryEvidencePausesWithoutMutation() async throws {
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
        _ = try await store.add(snapshot: recoveredSnapshot, for: identity)
        let rawData = Data([0xFF, 0xFE, 0x00])
        let rawEntry = try await store.addRawData(rawData, for: identity)
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()

        XCTAssertEqual(coordinator.state, .synchronizationPaused)
        XCTAssertEqual(coordinator.presentedState, .synchronizationPaused)
        XCTAssertTrue(coordinator.hasLocalRecovery)
        XCTAssertNotNil(coordinator.latestRawRecoveryURL)
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
        let decodedRecovery = try await store.latest(for: identity)
        XCTAssertEqual(decodedRecovery?.snapshot, recoveredSnapshot)
        let rawRecovery = try await store.rawRecoveryEntries(for: identity)
        XCTAssertEqual(rawRecovery, [rawEntry])
        let persistedRawData = try await rawRecovery.first?.loadData()
        XCTAssertEqual(persistedRawData, rawData)
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
        await assertInitialAttachment(coordinator)
        _ = await coordinator.waitForRecoveryStartup()
        coordinator.sourceBuffer.replace(
            with: "local\n",
            origin: .localEditor(paneID: UUID())
        )

        let didMove = await coordinator.noteFileMovedAndWait(
            to: destination.url,
            knownData: data
        )

        XCTAssertTrue(didMove)
        await coordinator.waitForCurrentRecoveryOperation()
        XCTAssertEqual(coordinator.fileURL, destination.url.standardizedFileURL)
        XCTAssertNotEqual(coordinator.state, .synchronizationPaused)
        guard case .debouncing = coordinator.reducerState.external else {
            return XCTFail("A moved destination must be verified before saving newer local text.")
        }
        coordinator.advanceScheduledWork(by: .zero)
        let externalRead = try XCTUnwrap(executor.externalReadRequests.last)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: destination.url,
            data: data
        )
        let observation = try TextFileCodec.externalReadObservation(
            data: data,
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
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
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

    func testFirstAttachmentReportsRecoveredConflictForPersistedRecovery()
        async throws
    {
        let fixture = try TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let store = SessionRecoveryStore()
        let identity = DocumentIdentity.make(url: fixture.url)
        _ = try await store.add(
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
        _ = await coordinator.waitForRecoveryStartup()

        XCTAssertEqual(coordinator.fileURL, fixture.url.standardizedFileURL)
        XCTAssertEqual(coordinator.presentedState, .recoveredConflict)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
        let persistedRecovery = try await store.latest(for: identity)
        XCTAssertEqual(persistedRecovery?.snapshot.text, "recoverable\n")
    }

    func testSaveAsKeepsANewerLocalRevisionDirty() async throws {
        let destination = try TemporaryMarkdownFile(contents: "captured\n")
        defer { destination.remove() }
        let scheduler = ManualSyncScheduler()
        let executor = ControllableCoordinatorEffectExecutor()
        let initial = DocumentSnapshot(text: "before\n", format: .newDocument)
        let recoveryGate = BlockingRecoveryIOGate()
        let coordinator = DocumentSyncCoordinator(
            snapshot: initial,
            recoveryStore: SessionRecoveryStore(
                startupCompletionHook: {
                    recoveryGate.blockUntilReleased()
                }
            ),
            fileMonitoringEnabled: false,
            effectExecutor: executor,
            manualScheduler: scheduler
        )
        defer {
            recoveryGate.release()
            coordinator.close()
        }
        let host = TypedCoordinatorTestHost(fileURL: destination.url)
        coordinator.delegate = host
        coordinator.loadInitial(initial, data: Data("before\n".utf8), from: nil)
        await recoveryGate.waitUntilBlocked()

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

        let saveAsAttachment = Task { @MainActor in
            try await coordinator.attachAfterSaveAs(
                to: destination.url,
                expectedData: capturedData,
                expectedSnapshot: capturedSnapshot,
                expectedSourceRevision: capturedRevision
            )
        }
        try await saveAsAttachment.value

        XCTAssertEqual(coordinator.durableState?.snapshot, capturedSnapshot)
        XCTAssertEqual(
            coordinator.reducerState.durableBaseline?.sourceRevision,
            capturedRevision
        )
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "newer local\n")
        XCTAssertTrue(coordinator.hasLocalChanges)
        XCTAssertEqual(coordinator.reducerState.recoveryAccess, .loading)
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)

        recoveryGate.release()
        _ = await coordinator.waitForRecoveryStartup()
        guard case .debouncing = coordinator.reducerState.external else {
            return XCTFail("Save As must verify the destination before writing newer local text.")
        }
        XCTAssertTrue(executor.savePreparationRequests.isEmpty)
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
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
        let preparation = try XCTUnwrap(executor.savePreparationRequests.last)
        XCTAssertEqual(preparation.snapshot.text, "newer local\n")
    }

    func testInitialDurableStateSurvivesUntilAnExplicitAttachmentDecision()
        throws
    {
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

private enum CoordinatorPostSwapError: Error {
    case injected
}

@MainActor
private final class AwaitingCoordinatorTestHost: DocumentSyncCoordinatorHost {
    let synchronizationFileURL: URL?
    private var queuedSaveRequests: [DocumentSyncSaveCommitRequest] = []
    private var saveWaiters: [CheckedContinuation<DocumentSyncSaveCommitRequest, Never>] = []
    private var queuedCloseResolutions: [DocumentSyncCloseResolution] = []
    private var closeWaiters: [CheckedContinuation<DocumentSyncCloseResolution, Never>] = []

    init(fileURL: URL?) {
        synchronizationFileURL = fileURL
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave request: DocumentSyncSaveCommitRequest
    ) {
        if let waiter = saveWaiters.first {
            saveWaiters.removeFirst()
            waiter.resume(returning: request)
        } else {
            queuedSaveRequests.append(request)
        }
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        resolveClose resolution: DocumentSyncCloseResolution
    ) {
        if let waiter = closeWaiters.first {
            closeWaiters.removeFirst()
            waiter.resume(returning: resolution)
        } else {
            queuedCloseResolutions.append(resolution)
        }
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    ) {}

    func nextSaveRequest() async -> DocumentSyncSaveCommitRequest {
        if !queuedSaveRequests.isEmpty {
            return queuedSaveRequests.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
        }
    }

    func nextCloseResolution() async -> DocumentSyncCloseResolution {
        if !queuedCloseResolutions.isEmpty {
            return queuedCloseResolutions.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }
}

@MainActor
private final class ControllableCoordinatorEffectExecutor:
    DocumentSyncCoordinatorEffectExecuting
{
    private(set) var cancelledTokens: [SyncEffectToken] = []
    private(set) var cancelAllCallCount = 0
    private(set) var savePreparationRequests: [DocumentSyncSavePreparationRequest] = []
    private(set) var externalReadRequests: [DocumentSyncExternalReadRequest] = []
    private(set) var mergeRequests: [DocumentSyncMergeRequest] = []
    private(set) var reconciliationRequests: [DocumentSyncCommitReconciliationRequest] = []

    private var savePreparationCompletions:
        [SyncEffectToken: @MainActor (DocumentSyncSavePreparationExecution) -> Void] = [:]
    private var externalReadCompletions:
        [SyncEffectToken: @MainActor (DocumentSyncExternalReadExecution) -> Void] = [:]
    private var mergeCompletions:
        [SyncEffectToken: @MainActor (DocumentSyncMergeExecution) -> Void] = [:]
    private var reconciliationCompletions:
        [SyncEffectToken: @MainActor (DocumentSyncCommitReconciliationResult) -> Void] = [:]

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

    func cancel(token: SyncEffectToken) {
        cancelledTokens.append(token)
    }

    func cancelAll() {
        cancelAllCallCount += 1
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

    /// Tests that assert verified file state or scheduler effects must cross
    /// both asynchronous boundaries. The initial source itself remains
    /// synchronous and is intentionally asserted separately where needed.
    func finishInitialAttachment() async -> Bool {
        let didAttach = await coordinator.waitForInitialAttachment()
        _ = await coordinator.waitForRecoveryStartup()
        return didAttach
    }

    func fireLocalSave() {
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
    }

    func fireExternalRead() {
        coordinator.advanceScheduledWork(by: .zero)
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

private final class UncheckedDocumentBox: @unchecked Sendable {
    let value: MarkdownDocument

    @MainActor
    init(_ value: MarkdownDocument) {
        self.value = value
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private struct RecordingDocumentFileCommitter: DocumentFileCommitting {
    let order: StringRecorder

    func commit(_ token: PendingSaveToken) throws -> FileCommitResult {
        order.append("commit")
        return FileCommitResult(
            generation: token.generation,
            committedFingerprint: token.contentFingerprint,
            displacedPreimage: nil,
            safety: .coordinatedReplacement
        )
    }
}

private struct FailingDocumentFileCommitter: DocumentFileCommitting {
    func commit(_ token: PendingSaveToken) throws -> FileCommitResult {
        _ = token
        throw SafeFileCommitter.CommitError.atomicSwapFailed
    }
}

private final class DescriptorCloseRecorder: @unchecked Sendable {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var values: [Bool] = []
    private var waiters: [Waiter] = []

    var closedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.filter { $0 }.count
    }

    func record(_ didClose: Bool) {
        var readyWaiters: [Waiter] = []
        var remainingWaiters: [Waiter] = []
        lock.lock()
        values.append(didClose)
        for waiter in waiters {
            if values.count >= waiter.expectedCount {
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

    func waitForCount(_ expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if values.count >= expectedCount {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(
                Waiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
            lock.unlock()
        }
    }
}

@MainActor
private final class CoordinatorMainActorHeartbeat {
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
private func assertInitialAttachment(
    _ coordinator: DocumentSyncCoordinator,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let didAttach = await coordinator.waitForInitialAttachment()
    XCTAssertTrue(didAttach, file: file, line: line)
}

@MainActor
private func assertInitialAttachment(
    _ fixture: DeterministicCoordinatorFixture,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let didAttach = await fixture.finishInitialAttachment()
    XCTAssertTrue(didAttach, file: file, line: line)
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
