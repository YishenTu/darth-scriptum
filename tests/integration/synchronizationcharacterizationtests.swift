import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import DarthScriptum

@MainActor
final class SynchronizationCharacterizationTests: XCTestCase {
    func testDocumentReadOpensAndAttachesTheDecodedSnapshot() throws {
        let fixture = try CharacterizationMarkdownFile(contents: "opened\r\n")
        defer { fixture.remove() }

        let document = MarkdownDocument()
        document.fileURL = fixture.url
        defer { document.syncCoordinator.close() }

        try document.read(
            from: Data("opened\r\n".utf8),
            ofType: "net.daringfireball.markdown"
        )

        XCTAssertEqual(document.syncCoordinator.sourceBuffer.revision.text, "opened\r\n")
        XCTAssertEqual(
            document.syncCoordinator.fileURL,
            fixture.url.standardizedFileURL
        )
        XCTAssertEqual(
            document.syncCoordinator.durableState?.snapshot.text,
            "opened\r\n"
        )
        XCTAssertEqual(
            document.syncCoordinator.format.dominantNewline,
            .crlf
        )
    }

    func testOpenEditAndAutosavePersistTheCanonicalSnapshot() async throws {
        let fixture = try CharacterizationMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let initialData = Data("base\n".utf8)
        let initialSnapshot = try TextFileCodec.decode(initialData)
        let coordinator = DocumentSyncCoordinator(snapshot: initialSnapshot)
        let delegate = CharacterizationSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(
            initialSnapshot,
            data: initialData,
            from: fixture.url
        )
        defer { coordinator.close() }

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

        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "base\n")
        XCTAssertEqual(coordinator.durableState?.snapshot, initialSnapshot)
        XCTAssertEqual(coordinator.fileURL, fixture.url.standardizedFileURL)

        coordinator.sourceBuffer.replace(
            with: "edited\n",
            origin: .localEditor(paneID: UUID())
        )

        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8))
                == "edited\n"
                && coordinator.durableState?.snapshot.text == "edited\n"
                && coordinator.state == .idle
        }
    }

    func testExternalOnlyChangeReloadsTheCanonicalSource() async throws {
        let fixture = try CharacterizationMarkdownFile(contents: "base\n")
        defer { fixture.remove() }

        let initialData = Data("base\n".utf8)
        let initialSnapshot = try TextFileCodec.decode(initialData)
        let coordinator = DocumentSyncCoordinator(snapshot: initialSnapshot)
        let delegate = CharacterizationSyncDelegate(fileURL: fixture.url)
        coordinator.delegate = delegate
        coordinator.loadInitial(
            initialSnapshot,
            data: initialData,
            from: fixture.url
        )
        defer { coordinator.close() }

        try Data("external\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()

        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "external\n"
                && coordinator.durableState?.snapshot.text == "external\n"
                && delegate.acceptedExternalChangeCount > 0
        }
        XCTAssertFalse(coordinator.hasLocalChanges)
    }

    func testCompatibleExternalAndLocalEditsMergeThenPersist() async throws {
        let fixture = try CharacterizationMarkdownFile(
            contents: "first\nmiddle\nlast\n"
        )
        defer { fixture.remove() }

        let initialData = Data("first\nmiddle\nlast\n".utf8)
        let initialSnapshot = try TextFileCodec.decode(initialData)
        let coordinator = DocumentSyncCoordinator(snapshot: initialSnapshot)
        let delegate = CharacterizationSyncDelegate(fileURL: fixture.url)
        var requestedTokens: [PendingSaveToken] = []
        delegate.onSave = { token in requestedTokens.append(token) }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            initialSnapshot,
            data: initialData,
            from: fixture.url
        )
        defer { coordinator.close() }

        coordinator.sourceBuffer.replace(
            with: "local first\nmiddle\nlast\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { requestedTokens.count == 1 }
        let interruptedSave = try XCTUnwrap(requestedTokens.first)

        try Data("first\nmiddle\nexternal last\n".utf8).write(
            to: fixture.url
        )
        coordinator.noteCoordinatedExternalChange()
        coordinator.handleSaveCompletion(
            generation: interruptedSave.generation,
            error: SafeFileCommitter.CommitError.targetChangedBeforeCommit
        )

        let expectedMergedText = "local first\nmiddle\nexternal last\n"
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == expectedMergedText
                && requestedTokens.count == 2
        }
        let mergedSave = try XCTUnwrap(requestedTokens.last)
        XCTAssertEqual(mergedSave.snapshot.text, expectedMergedText)

        let result = try SafeFileCommitter().commit(mergedSave)
        try coordinator.bridge.store(result)
        XCTAssertTrue(
            coordinator.handleSaveCompletion(
                generation: mergedSave.generation,
                error: nil
            )
        )
        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8))
                == expectedMergedText
                && coordinator.state == .idle
                && !coordinator.hasLocalRecovery
        }
    }

    func testConflictingExternalEditKeepsLocalRevisionForRecovery() async throws {
        let fixture = try CharacterizationMarkdownFile(contents: "hello\n")
        defer { fixture.remove() }

        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let recoveryStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let initialData = Data("hello\n".utf8)
        let initialSnapshot = try TextFileCodec.decode(initialData)
        let coordinator = DocumentSyncCoordinator(
            snapshot: initialSnapshot,
            recoveryStore: recoveryStore
        )
        let delegate = CharacterizationSyncDelegate(fileURL: fixture.url)
        var requestedTokens: [PendingSaveToken] = []
        delegate.onSave = { token in requestedTokens.append(token) }
        coordinator.delegate = delegate
        coordinator.loadInitial(
            initialSnapshot,
            data: initialData,
            from: fixture.url
        )
        defer { coordinator.close() }

        coordinator.sourceBuffer.replace(
            with: "hallo\n",
            origin: .localEditor(paneID: UUID())
        )
        try await waitUntil { requestedTokens.count == 1 }
        let interruptedSave = try XCTUnwrap(requestedTokens.first)

        try Data("hullo\n".utf8).write(to: fixture.url)
        coordinator.noteCoordinatedExternalChange()
        coordinator.handleSaveCompletion(
            generation: interruptedSave.generation,
            error: SafeFileCommitter.CommitError.targetChangedBeforeCommit
        )

        try await waitUntil {
            coordinator.state == .recoveredConflict
                && coordinator.sourceBuffer.revision.text == "hullo\n"
                && coordinator.hasLocalRecovery
        }
        let recoveredEntry = recoveryStore.latest(
            for: DocumentIdentity.make(url: fixture.url)
        )
        XCTAssertEqual(recoveredEntry?.snapshot.text, "hallo\n")

        coordinator.restoreLatestRecovery()
        try await waitUntil {
            coordinator.sourceBuffer.revision.text == "hallo\n"
                && requestedTokens.count == 2
        }
        let restoreSave = try XCTUnwrap(requestedTokens.last)
        let result = try SafeFileCommitter().commit(restoreSave)
        try coordinator.bridge.store(result)
        _ = coordinator.handleSaveCompletion(
            generation: restoreSave.generation,
            error: nil
        )
        try await waitUntil {
            (try? String(contentsOf: fixture.url, encoding: .utf8))
                == "hallo\n"
                && !coordinator.hasLocalRecovery
                && coordinator.state == .idle
        }
    }

    func testSaveAsAttachmentUsesTheCapturedSnapshotAsItsBaseline() async throws {
        let destination = try CharacterizationMarkdownFile(contents: "captured\n")
        defer { destination.remove() }

        let initial = DocumentSnapshot(
            text: "before\n",
            format: .newDocument
        )
        let coordinator = DocumentSyncCoordinator(snapshot: initial)
        defer { coordinator.close() }
        coordinator.loadInitial(initial, data: Data("before\n".utf8), from: nil)

        coordinator.sourceBuffer.replace(
            with: "captured\n",
            origin: .localEditor(paneID: UUID())
        )
        let capturedSnapshot = coordinator.currentSnapshot
        let capturedData = try TextFileCodec.encode(capturedSnapshot)

        coordinator.sourceBuffer.replace(
            with: "newer local revision\n",
            origin: .localEditor(paneID: UUID())
        )

        try await coordinator.attachAfterSaveAs(
            to: destination.url,
            expectedData: capturedData,
            expectedSnapshot: capturedSnapshot
        )

        XCTAssertEqual(
            coordinator.fileURL,
            destination.url.standardizedFileURL
        )
        XCTAssertEqual(coordinator.durableState?.snapshot, capturedSnapshot)
        XCTAssertEqual(
            coordinator.sourceBuffer.revision.text,
            "newer local revision\n"
        )
        XCTAssertTrue(coordinator.hasLocalChanges)
    }

    func testSplitPanesRenderTheSameSourceBuffer() async throws {
        let initial = DocumentSnapshot(
            text: "before\n",
            format: .newDocument
        )
        let coordinator = DocumentSyncCoordinator(snapshot: initial)
        let model = WorkspaceModel()
        model.splitRight()
        defer { coordinator.close() }

        let hostingView = NSHostingView(
            rootView: MarkdownWorkspace(
                syncCoordinator: coordinator,
                model: model,
                fileName: "fixture.md"
            )
            .frame(width: 800, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        try await waitUntil {
            self.descendantTextViews(in: hostingView).count == 2
        }

        coordinator.sourceBuffer.replace(
            with: "after\n",
            origin: .localEditor(paneID: model.primaryPane.id)
        )

        try await waitUntil {
            self.descendantTextViews(in: hostingView).allSatisfy {
                $0.string == "after\n"
            }
        }
        XCTAssertEqual(coordinator.sourceBuffer.revision.text, "after\n")
        XCTAssertTrue(model.isSplit)
        _ = window
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
        XCTFail("Timed out waiting for synchronization characterization.")
    }

    private func descendantTextViews(in view: NSView) -> [NSTextView] {
        if let textView = view as? NSTextView {
            return [textView]
        }
        return view.subviews.flatMap(descendantTextViews)
    }
}

@MainActor
private final class CharacterizationSyncDelegate: DocumentSyncCoordinatorDelegate {
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

private struct CharacterizationMarkdownFile {
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
