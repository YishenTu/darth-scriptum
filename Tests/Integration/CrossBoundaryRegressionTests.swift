import AppKit
import Foundation
import WebKit
import XCTest

@testable import DarthScriptum

@MainActor
final class CrossBoundaryRegressionTests: XCTestCase {
    func testExternalEditDuringSavePreparationRejectsTheStaleSave()
        async throws
    {
        let fixture = try Q1TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let harness = try await Q1CoordinatorHarness(fixture: fixture)
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
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(
                    .changed(
                        try makeQ1ExternalChange(
                            data: externalData,
                            url: fixture.url
                        )
                    )
                )
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

        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                stalePreparation.token,
                with: .prepared(
                    try makeQ1PendingSave(from: stalePreparation)
                )
            )
        )
        XCTAssertTrue(harness.host.saveRequests.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "external\n"
        )
        XCTAssertEqual(
            harness.coordinator.sourceBuffer.revision.text,
            "external\n"
        )
        XCTAssertTrue(harness.coordinator.hasLocalRecovery)
    }

    func testExternalEditDuringCommitIsObservedBeforeAnyRetry()
        async throws
    {
        let fixture = try Q1TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let harness = try await Q1CoordinatorHarness(fixture: fixture)
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
                with: .prepared(try makeQ1PendingSave(from: preparation))
            )
        )
        let commit = try XCTUnwrap(harness.host.saveRequests.last)

        let externalData = Data("external\n".utf8)
        try externalData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let read = try XCTUnwrap(
            harness.executor.externalReadRequests.last
        )

        XCTAssertFalse(
            harness.coordinator.handleSaveCompletion(
                token: commit.token,
                error: SafeFileCommitter.CommitError
                    .targetChangedBeforeCommit
            )
        )
        XCTAssertTrue(
            harness.executor.finishExternalRead(
                read.token,
                with: .finished(
                    .changed(
                        try makeQ1ExternalChange(
                            data: externalData,
                            url: fixture.url
                        )
                    )
                )
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

        XCTAssertEqual(harness.host.saveRequests.count, 1)
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "external\n"
        )
        XCTAssertEqual(
            harness.coordinator.sourceBuffer.revision.text,
            "external\n"
        )
        XCTAssertTrue(harness.coordinator.hasLocalRecovery)
    }

    func testMoveDuringExternalReadRejectsTheOldAttachmentResult()
        async throws
    {
        let fixture = try Q1TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let harness = try await Q1CoordinatorHarness(fixture: fixture)
        defer { harness.coordinator.close() }

        let externalData = Data("external-at-old-path\n".utf8)
        try externalData.write(to: fixture.url)
        harness.coordinator.noteCoordinatedExternalChange()
        harness.fireExternalRead()
        let oldRead = try XCTUnwrap(
            harness.executor.externalReadRequests.last
        )
        let oldChange = try makeQ1ExternalChange(
            data: externalData,
            url: fixture.url
        )

        try FileManager.default.moveItem(
            at: fixture.url,
            to: fixture.movedURL
        )
        let didMove = await harness.coordinator.noteFileMovedAndWait(
            to: fixture.movedURL,
            knownData: externalData
        )
        XCTAssertTrue(didMove)

        XCTAssertTrue(
            harness.executor.finishExternalRead(
                oldRead.token,
                with: .finished(.changed(oldChange))
            )
        )
        XCTAssertEqual(
            harness.coordinator.fileURL,
            fixture.movedURL.standardizedFileURL
        )
        XCTAssertEqual(
            harness.coordinator.sourceBuffer.revision.text,
            "base\n"
        )
        XCTAssertEqual(harness.host.acceptedExternalChangeCount, 0)
        XCTAssertEqual(
            try String(contentsOf: fixture.movedURL, encoding: .utf8),
            "external-at-old-path\n"
        )
    }

    func testManagedCloseWaitsForBlockedRecoveryStartup() async throws {
        let fixture = try Q1TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let gate = Q1BlockingIOGate()
        let store = SessionRecoveryStore(
            persistenceDirectory: fixture.recoveryDirectory,
            startupReadHook: {
                gate.blockUntilReleased()
            }
        )
        let data = Data("base\n".utf8)
        let snapshot = try TextFileCodec.decode(data)
        let harness = Q1CoordinatorHarness(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: store
        )
        defer {
            gate.release()
            harness.coordinator.close()
        }

        let didAttach = await harness.coordinator.waitForInitialAttachment()
        XCTAssertTrue(didAttach)
        await gate.waitUntilBlocked()
        harness.coordinator.requestClose()

        XCTAssertTrue(harness.host.closeResolutions.isEmpty)
        guard
            case .closing(let attempt) =
                harness.coordinator.reducerState.lifecycle
        else {
            return XCTFail("Managed close must remain pending during recovery.")
        }
        XCTAssertNil(attempt.resolution)

        gate.release()
        guard
            case .ready =
                await harness.coordinator.waitForRecoveryStartup()
        else {
            return XCTFail("Recovery startup should finish after release.")
        }
        let resolution = try XCTUnwrap(harness.host.closeResolutions.last)
        XCTAssertEqual(resolution.disposition, .allowManagedClose)
        XCTAssertEqual(harness.host.closeResolutions.count, 1)
        harness.coordinator.completeClose(
            token: resolution.token,
            didCommit: false
        )
    }

    func testQuitWithCleanFailingAndUntitledDocumentsPreservesRefusal()
        async throws
    {
        let cleanFixture = try Q1TemporaryMarkdownFile(contents: "clean\n")
        let refusalFixture = try Q1TemporaryMarkdownFile(contents: "base\n")
        defer {
            cleanFixture.remove()
            refusalFixture.remove()
        }

        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: refusalFixture.recoveryDirectory
        )
        let cleanDocument = MarkdownDocument(recoveryStore: recoveryStore)
        cleanDocument.fileURL = cleanFixture.url
        try cleanDocument.read(
            from: Data("clean\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        let cleanDidAttach = await cleanDocument.syncCoordinator
            .waitForInitialAttachment()
        XCTAssertTrue(cleanDidAttach)
        guard
            case .ready =
                await cleanDocument.syncCoordinator.waitForRecoveryStartup()
        else {
            return XCTFail("Clean document recovery startup must finish.")
        }

        let refusalDocument = MarkdownDocument(recoveryStore: recoveryStore)
        refusalDocument.fileURL = refusalFixture.url
        try refusalDocument.read(
            from: Data("base\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        let refusalDidAttach = await refusalDocument.syncCoordinator
            .waitForInitialAttachment()
        XCTAssertTrue(refusalDidAttach)
        guard
            case .ready =
                await refusalDocument.syncCoordinator.waitForRecoveryStartup()
        else {
            return XCTFail("Failing document recovery startup must finish.")
        }
        refusalDocument.syncCoordinator.sourceBuffer.replace(
            with: "edited\n",
            origin: .localEditor(paneID: UUID())
        )
        try FileManager.default.removeItem(at: refusalFixture.url)

        let untitledDocument = MarkdownDocument(
            recoveryStore: recoveryStore
        )
        let controller = NSDocumentController.shared
        controller.addDocument(refusalDocument)
        controller.addDocument(untitledDocument)
        controller.addDocument(cleanDocument)
        defer {
            for document in [
                cleanDocument,
                untitledDocument,
                refusalDocument,
            ]
            where controller.documents.contains(
                where: { $0 === document }
            ) {
                controller.removeDocument(document)
            }
            cleanDocument.syncCoordinator.close()
            untitledDocument.syncCoordinator.close()
            refusalDocument.syncCoordinator.close()
        }

        let recorder = Q1CloseAllRecorder()
        controller.closeAllDocuments(
            withDelegate: recorder,
            didCloseAllSelector: #selector(
                Q1CloseAllRecorder.documentController(
                    _:didCloseAll:contextInfo:
                )
            ),
            contextInfo: nil
        )
        let didCloseAll = await recorder.waitForDecision()

        XCTAssertFalse(didCloseAll)
        XCTAssertEqual(recorder.decisions, [false])
        XCTAssertFalse(
            controller.documents.contains { $0 === cleanDocument }
        )
        XCTAssertFalse(
            controller.documents.contains { $0 === untitledDocument }
        )
        XCTAssertTrue(
            controller.documents.contains { $0 === refusalDocument }
        )
    }

    func testRendererProcessDeathDuringManagedCloseDoesNotStallCommit()
        async throws
    {
        let fixture = try Q1TemporaryMarkdownFile(contents: "base\n")
        defer { fixture.remove() }
        let harness = try await Q1CoordinatorHarness(fixture: fixture)
        defer { harness.coordinator.close() }

        harness.coordinator.sourceBuffer.replace(
            with: "edited\n",
            origin: .localEditor(paneID: UUID())
        )
        harness.fireLocalSave()
        let preparation = try XCTUnwrap(
            harness.executor.savePreparationRequests.last
        )
        XCTAssertTrue(
            harness.executor.finishSavePreparation(
                preparation.token,
                with: .prepared(try makeQ1PendingSave(from: preparation))
            )
        )
        let commit = try XCTUnwrap(harness.host.saveRequests.last)
        harness.coordinator.requestClose()
        XCTAssertTrue(harness.host.closeResolutions.isEmpty)

        let session = LocalWebRenderSession(resourcePolicy: nil)
        defer { session.dispose() }
        let evaluation = Task { @MainActor in
            await session.waitForJavaScriptEvaluationForTesting(
                timeout: .seconds(30)
            )
        }
        await Task.yield()
        XCTAssertTrue(session.hasActiveJavaScriptEvaluationForTesting)
        let terminatedWebView = try XCTUnwrap(session.webViewForTesting)
        session.webViewWebContentProcessDidTerminate(terminatedWebView)
        guard case .processTerminated = await evaluation.value else {
            return XCTFail("Process death must resolve renderer work.")
        }
        XCTAssertTrue(harness.host.closeResolutions.isEmpty)

        let result = try SafeFileCommitter().commit(commit.pendingSave)
        try harness.coordinator.bridge.store(result, for: commit.token)
        XCTAssertTrue(
            harness.coordinator.handleSaveCompletion(
                token: commit.token,
                error: nil
            )
        )
        let resolution = try XCTUnwrap(harness.host.closeResolutions.last)
        XCTAssertEqual(resolution.disposition, .allowManagedClose)
        harness.coordinator.completeClose(
            token: resolution.token,
            didCommit: false
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "edited\n"
        )
    }

    func testDependencyAdapterFailureLeavesCanonicalSourceEditable()
        throws
    {
        let sourceBuffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: "canonical",
                format: .newDocument
            )
        )
        let changedWrapper = NSScrollView()
        let changedDocumentView = NSView()
        changedDocumentView.addSubview(NSTextView())
        changedDocumentView.addSubview(NSTextView())
        changedWrapper.documentView = changedDocumentView

        XCTAssertNil(
            MarkdownEngineCompatibility.nativeTextView(in: changedWrapper)
        )
        try sourceBuffer.apply(
            SourceEdit(
                range: NSRange(location: 9, length: 0),
                replacement: " source",
                expectedRevision: sourceBuffer.revision.number,
                origin: .localEditor(paneID: UUID())
            )
        )

        XCTAssertEqual(sourceBuffer.revision.text, "canonical source")
        XCTAssertEqual(
            changedDocumentView.subviews
                .compactMap { $0 as? NSTextView }
                .map(\.string),
            ["", ""]
        )
    }

    func testHostileLocalWebKitRemainsConfinedAfterProcessReset()
        async throws
    {
        let fixture = try Q1HostileWebFixture()
        defer { fixture.remove() }
        let policy = try XCTUnwrap(
            LocalWebResourcePolicy(
                entryURL: fixture.entryURL,
                resourceRootURL: fixture.directory
            )
        )
        let session = LocalWebRenderSession(resourcePolicy: policy)
        defer { session.dispose() }

        let didInitiallyLoad = await session.waitUntilReady()
        XCTAssertTrue(didInitiallyLoad)
        let terminatedWebView = try XCTUnwrap(session.webViewForTesting)
        session.webViewWebContentProcessDidTerminate(terminatedWebView)
        XCTAssertNil(terminatedWebView.navigationDelegate)
        XCTAssertNil(terminatedWebView.uiDelegate)

        let didReload = await session.waitUntilReady()
        XCTAssertTrue(didReload)
        let replacementWebView = try XCTUnwrap(session.webViewForTesting)
        XCTAssertFalse(replacementWebView === terminatedWebView)
        XCTAssertTrue(replacementWebView.navigationDelegate === session)
        XCTAssertTrue(replacementWebView.uiDelegate === policy)
        XCTAssertFalse(
            policy.allowsMainFrameNavigation(
                to: URL(string: "https://example.invalid/escape")!
            )
        )

        let outcome = await session.evaluateJavaScript(
            "return await window.__hostileResult;",
            arguments: [:]
        )
        guard case .value(let value) = outcome,
            let result = value as? [String: Any]
        else {
            return XCTFail("The local hostile fixture must report its result.")
        }
        XCTAssertEqual(result["fetchBlocked"] as? Bool, true)
        XCTAssertEqual(result["windowDenied"] as? Bool, true)
    }
}

@MainActor
private final class Q1CoordinatorHarness {
    let scheduler: ManualSyncScheduler
    let executor: Q1ControllableEffectExecutor
    let host: Q1CoordinatorHost
    let coordinator: DocumentSyncCoordinator

    convenience init(
        fixture: Q1TemporaryMarkdownFile
    ) async throws {
        let data = try Data(contentsOf: fixture.url)
        let snapshot = try TextFileCodec.decode(data)
        self.init(
            snapshot: snapshot,
            data: data,
            url: fixture.url,
            recoveryStore: SessionRecoveryStore()
        )
        guard await coordinator.waitForInitialAttachment() else {
            throw Q1FixtureError.initialAttachmentFailed
        }
        guard case .ready = await coordinator.waitForRecoveryStartup() else {
            throw Q1FixtureError.recoveryStartupFailed
        }
    }

    init(
        snapshot: DocumentSnapshot,
        data: Data,
        url: URL,
        recoveryStore: SessionRecoveryStore
    ) {
        let scheduler = ManualSyncScheduler()
        let executor = Q1ControllableEffectExecutor()
        let host = Q1CoordinatorHost(fileURL: url)
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
        coordinator.advanceScheduledWork(by: DocumentSyncCoordinator.localWriteDelay)
    }

    func fireExternalRead() {
        coordinator.advanceScheduledWork(by: .zero)
    }
}

@MainActor
private final class Q1CoordinatorHost: DocumentSyncCoordinatorHost {
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
private final class Q1ControllableEffectExecutor:
    DocumentSyncCoordinatorEffectExecuting
{
    private(set) var savePreparationRequests: [DocumentSyncSavePreparationRequest] = []
    private(set) var externalReadRequests: [DocumentSyncExternalReadRequest] = []
    private(set) var mergeRequests: [DocumentSyncMergeRequest] = []
    private(set) var reconciliationRequests: [DocumentSyncCommitReconciliationRequest] = []

    private var savePreparationCompletions:
        [SyncEffectToken:
            @MainActor (DocumentSyncSavePreparationExecution) -> Void] = [:]
    private var externalReadCompletions:
        [SyncEffectToken:
            @MainActor (DocumentSyncExternalReadExecution) -> Void] = [:]
    private var mergeCompletions:
        [SyncEffectToken:
            @MainActor (DocumentSyncMergeExecution) -> Void] = [:]
    private var reconciliationCompletions:
        [SyncEffectToken:
            @MainActor (DocumentSyncCommitReconciliationResult) -> Void] = [:]

    func prepareSave(
        _ request: DocumentSyncSavePreparationRequest,
        completion:
            @escaping @MainActor (
                DocumentSyncSavePreparationExecution
            ) -> Void
    ) {
        savePreparationRequests.append(request)
        savePreparationCompletions[request.token] = completion
    }

    func readExternal(
        _ request: DocumentSyncExternalReadRequest,
        completion:
            @escaping @MainActor (
                DocumentSyncExternalReadExecution
            ) -> Void
    ) {
        externalReadRequests.append(request)
        externalReadCompletions[request.token] = completion
    }

    func merge(
        _ request: DocumentSyncMergeRequest,
        completion:
            @escaping @MainActor (
                DocumentSyncMergeExecution
            ) -> Void
    ) {
        mergeRequests.append(request)
        mergeCompletions[request.token] = completion
    }

    func reconcileCommit(
        _ request: DocumentSyncCommitReconciliationRequest,
        completion:
            @escaping @MainActor (
                DocumentSyncCommitReconciliationResult
            ) -> Void
    ) {
        reconciliationRequests.append(request)
        reconciliationCompletions[request.token] = completion
    }

    @discardableResult
    func finishSavePreparation(
        _ token: SyncEffectToken,
        with result: DocumentSyncSavePreparationExecution
    ) -> Bool {
        guard
            let completion =
                savePreparationCompletions.removeValue(forKey: token)
        else {
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
        guard
            let completion =
                externalReadCompletions.removeValue(forKey: token)
        else {
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
        guard
            let completion =
                mergeCompletions.removeValue(forKey: token)
        else {
            return false
        }
        completion(result)
        return true
    }
}

private final class Q1BlockingIOGate: @unchecked Sendable {
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

@MainActor
private final class Q1CloseAllRecorder: NSObject {
    private(set) var decisions: [Bool] = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    @objc func documentController(
        _ documentController: NSDocumentController,
        didCloseAll: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        decisions.append(didCloseAll)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: didCloseAll)
        }
    }

    func waitForDecision() async -> Bool {
        if let decision = decisions.first {
            return decision
        }
        return await withCheckedContinuation { continuation in
            if let decision = decisions.first {
                continuation.resume(returning: decision)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private struct Q1TemporaryMarkdownFile {
    let directory: URL
    let url: URL

    var movedURL: URL {
        directory.appendingPathComponent("moved.md")
    }

    var recoveryDirectory: URL {
        directory.appendingPathComponent("recovery", isDirectory: true)
    }

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

private struct Q1HostileWebFixture {
    let directory: URL
    let entryURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        entryURL = directory.appendingPathComponent("hostile.html")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let scriptURL = directory.appendingPathComponent("hostile.js")
        try Self.html.write(
            to: entryURL,
            atomically: true,
            encoding: .utf8
        )
        try Self.javaScript.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta
            http-equiv="Content-Security-Policy"
            content="default-src 'none'; script-src 'self'; connect-src 'none'; \
        img-src 'self' data:; frame-src 'none'; object-src 'none'; \
        base-uri 'none'; form-action 'none'"
          >
          <script src="hostile.js"></script>
        </head>
        <body></body>
        </html>
        """

    private static let javaScript = """
        (() => {
          "use strict";
          const destination = "https://example.invalid/escape";
          const windowDenied = window.open(destination, "hostile") === null;
          window.__hostileResult = fetch(destination, {cache: "no-store"})
            .then(
              () => ({fetchBlocked: false, windowDenied}),
              () => ({fetchBlocked: true, windowDenied})
            );
        })();
        """
}

private func makeQ1PendingSave(
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

private func makeQ1ExternalChange(
    data: Data,
    url: URL
) throws -> DocumentSyncExternalChange {
    try TextFileCodec.decodeExternalChange(
        data: data,
        targetURL: url,
        identity: DocumentIdentity.make(url: url),
        fingerprint: try SafeFileCommitter.fingerprint(
            for: url,
            data: data
        )
    )
}

private enum Q1FixtureError: Error {
    case initialAttachmentFailed
    case recoveryStartupFailed
}
