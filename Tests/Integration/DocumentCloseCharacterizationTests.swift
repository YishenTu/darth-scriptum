import AppKit
import Foundation
import XCTest

@testable import DarthScriptum

@MainActor
final class DocumentCloseCharacterizationTests: XCTestCase {
    func testManagedCloseRefusesWhenTheLatestRevisionCannotFlush() async throws {
        let fixture = try CloseCharacterizationMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let document = MarkdownDocument()
        document.fileURL = fixture.url
        defer { document.syncCoordinator.close() }
        try document.read(
            from: Data("base\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        document.syncCoordinator.sourceBuffer.replace(
            with: "edited\n",
            origin: .localEditor(paneID: UUID())
        )
        try FileManager.default.removeItem(at: fixture.url)

        let recorder = CloseDecisionRecorder()
        document.canClose(
            withDelegate: recorder,
            shouldClose: #selector(
                CloseDecisionRecorder.document(_:shouldClose:contextInfo:)
            ),
            contextInfo: nil
        )

        try await waitUntil { recorder.decisions == [false] }
        XCTAssertEqual(recorder.decisions, [false])
        XCTAssertNotEqual(document.syncCoordinator.state, .idle)
    }

    func testPristineUntitledCloseDelegatesToNativeDocumentBehavior() async throws {
        let document = MarkdownDocument()
        defer { document.syncCoordinator.close() }
        let recorder = CloseDecisionRecorder()

        XCTAssertNil(document.fileURL)
        XCTAssertFalse(document.hasUnsavedUntitledContent)
        document.canClose(
            withDelegate: recorder,
            shouldClose: #selector(
                CloseDecisionRecorder.document(_:shouldClose:contextInfo:)
            ),
            contextInfo: nil
        )

        try await waitUntil { recorder.decisions == [true] }
        XCTAssertEqual(recorder.decisions, [true])
        XCTAssertNil(document.syncCoordinator.fileURL)
    }

    func testCloseAllDocumentsReportsManagedCloseRefusal() async throws {
        let fixture = try CloseCharacterizationMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let document = MarkdownDocument()
        document.fileURL = fixture.url
        try document.read(
            from: Data("base\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        document.syncCoordinator.sourceBuffer.replace(
            with: "edited\n",
            origin: .localEditor(paneID: UUID())
        )
        try FileManager.default.removeItem(at: fixture.url)

        let controller = NSDocumentController.shared
        controller.addDocument(document)
        defer {
            controller.removeDocument(document)
            document.syncCoordinator.close()
        }
        let recorder = CloseAllDecisionRecorder()
        controller.closeAllDocuments(
            withDelegate: recorder,
            didCloseAllSelector: #selector(
                CloseAllDecisionRecorder.documentController(
                    _:didCloseAll:contextInfo:
                )
            ),
            contextInfo: nil
        )

        try await waitUntil { recorder.decisions == [false] }
        XCTAssertEqual(recorder.decisions, [false])
        XCTAssertTrue(controller.documents.contains { $0 === document })
    }

    func testCloseAllDocumentsClosesCleanDocumentAndReportsOneManagedRefusal()
        async throws
    {
        let cleanFixture = try CloseCharacterizationMarkdownFile(
            contents: "clean\n"
        )
        let refusalFixture = try CloseCharacterizationMarkdownFile(
            contents: "base\n"
        )
        defer {
            cleanFixture.remove()
            refusalFixture.remove()
        }

        let cleanDocument = MarkdownDocument()
        cleanDocument.fileURL = cleanFixture.url
        try cleanDocument.read(
            from: Data("clean\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        let cleanDidAttach = await cleanDocument.syncCoordinator
            .waitForInitialAttachment()
        XCTAssertTrue(cleanDidAttach)
        _ = await cleanDocument.syncCoordinator.waitForRecoveryStartup()

        let refusalDocument = MarkdownDocument()
        refusalDocument.fileURL = refusalFixture.url
        try refusalDocument.read(
            from: Data("base\n".utf8),
            ofType: "net.daringfireball.markdown"
        )
        let refusalDidAttach = await refusalDocument.syncCoordinator
            .waitForInitialAttachment()
        XCTAssertTrue(refusalDidAttach)
        _ = await refusalDocument.syncCoordinator.waitForRecoveryStartup()
        refusalDocument.syncCoordinator.sourceBuffer.replace(
            with: "edited\n",
            origin: .localEditor(paneID: UUID())
        )
        try FileManager.default.removeItem(at: refusalFixture.url)

        let controller = NSDocumentController.shared
        controller.addDocument(refusalDocument)
        controller.addDocument(cleanDocument)
        defer {
            if controller.documents.contains(where: { $0 === cleanDocument }) {
                controller.removeDocument(cleanDocument)
            }
            if controller.documents.contains(where: { $0 === refusalDocument }) {
                controller.removeDocument(refusalDocument)
            }
            cleanDocument.syncCoordinator.close()
            refusalDocument.syncCoordinator.close()
        }
        let recorder = CloseAllDecisionRecorder()
        controller.closeAllDocuments(
            withDelegate: recorder,
            didCloseAllSelector: #selector(
                CloseAllDecisionRecorder.documentController(
                    _:didCloseAll:contextInfo:
                )
            ),
            contextInfo: nil
        )

        let didCloseAll = await recorder.waitForDecision()
        XCTAssertFalse(didCloseAll)
        XCTAssertEqual(recorder.decisions, [false])
        XCTAssertFalse(controller.documents.contains { $0 === cleanDocument })
        XCTAssertTrue(controller.documents.contains { $0 === refusalDocument })
    }

    func testQuitRoutesThroughNativeTerminationWithoutAnAppLevelForceClose() {
        let originalMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = originalMenu }

        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        let quitItem = NSApp.mainMenu?
            .item(withTitle: "DarthScriptum")?
            .submenu?
            .item(withTitle: "Quit DarthScriptum")

        XCTAssertTrue(quitItem?.target === NSApp)
        XCTAssertEqual(quitItem?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertFalse(
            delegate.responds(
                to: NSSelectorFromString("applicationShouldTerminate:")
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for document close characterization.")
    }
}

@MainActor
private final class CloseDecisionRecorder: NSObject {
    private(set) var decisions: [Bool] = []

    @objc func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        decisions.append(shouldClose)
    }
}

@MainActor
private final class CloseAllDecisionRecorder: NSObject {
    private(set) var decisions: [Bool] = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    @objc func documentController(
        _ documentController: NSDocumentController,
        didCloseAll: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        decisions.append(didCloseAll)
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: didCloseAll)
        }
    }

    func waitForDecision() async -> Bool {
        if let decision = decisions.first { return decision }
        return await withCheckedContinuation { continuation in
            if let decision = decisions.first {
                continuation.resume(returning: decision)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private struct CloseCharacterizationMarkdownFile {
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
