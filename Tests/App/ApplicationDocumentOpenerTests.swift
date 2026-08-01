import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class ApplicationDocumentOpenerTests: XCTestCase {
    func testOpenWhenCurrentDocumentIsEmptyAndUntitledReplacesIt() async throws {
        let fixture = try ApplicationOpeningMarkdownFile(
            name: "opened.md",
            contents: "# Opened\n"
        )
        defer { fixture.remove() }
        let controller = NSDocumentController.shared
        let placeholder = MarkdownDocument()
        try show(placeholder, in: controller)
        defer {
            closeDocuments(
                matching: [fixture.url],
                including: placeholder,
                in: controller
            )
        }

        ApplicationDocumentOpener.open(
            fixture.url,
            replacing: placeholder
        )

        try await waitUntil {
            controller.document(for: fixture.url) != nil
                && !controller.documents.contains { $0 === placeholder }
        }
        XCTAssertFalse(controller.documents.contains { $0 === placeholder })
        XCTAssertNotNil(controller.document(for: fixture.url))
    }

    func testOpenWhenCurrentDocumentIsExistingEmptyFilePreservesIt()
        async throws
    {
        let existingFixture = try ApplicationOpeningMarkdownFile(
            name: "existing-empty.md",
            contents: ""
        )
        let openedFixture = try ApplicationOpeningMarkdownFile(
            name: "opened.md",
            contents: "# Opened\n"
        )
        defer {
            existingFixture.remove()
            openedFixture.remove()
        }
        let controller = NSDocumentController.shared
        let existingDocument = MarkdownDocument()
        existingDocument.fileURL = existingFixture.url
        try existingDocument.read(
            from: Data(),
            ofType: "net.daringfireball.markdown"
        )
        try show(existingDocument, in: controller)
        defer {
            closeDocuments(
                matching: [existingFixture.url, openedFixture.url],
                including: existingDocument,
                in: controller
            )
        }

        ApplicationDocumentOpener.open(
            openedFixture.url,
            replacing: existingDocument
        )

        try await waitUntil {
            controller.document(for: openedFixture.url) != nil
        }
        XCTAssertTrue(
            controller.documents.contains { $0 === existingDocument }
        )
        XCTAssertEqual(existingDocument.fileURL, existingFixture.url)
    }

    func testOpenWhenCurrentUntitledDocumentHasContentPreservesIt()
        async throws
    {
        let fixture = try ApplicationOpeningMarkdownFile(
            name: "opened.md",
            contents: "# Opened\n"
        )
        defer { fixture.remove() }
        let controller = NSDocumentController.shared
        let draft = MarkdownDocument()
        draft.syncCoordinator.sourceBuffer.replace(
            with: "# Draft\n",
            origin: .localEditor(paneID: UUID())
        )
        try show(draft, in: controller)
        defer {
            closeDocuments(
                matching: [fixture.url],
                including: draft,
                in: controller
            )
        }

        ApplicationDocumentOpener.open(
            fixture.url,
            replacing: draft
        )

        try await waitUntil {
            controller.document(for: fixture.url) != nil
        }
        XCTAssertTrue(controller.documents.contains { $0 === draft })
        XCTAssertEqual(
            draft.syncCoordinator.sourceBuffer.revision.text,
            "# Draft\n"
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
        XCTFail("Timed out waiting for the document opening result.")
    }

    private func closeDocuments(
        matching urls: [URL],
        including document: NSDocument,
        in controller: NSDocumentController
    ) {
        let standardizedURLs = Set(urls.map(\.standardizedFileURL))
        let documents = controller.documents.filter {
            $0 === document
                || $0.fileURL.map {
                    standardizedURLs.contains($0.standardizedFileURL)
                } == true
        }
        for document in documents {
            document.close()
        }
    }

    private func show(
        _ document: MarkdownDocument,
        in controller: NSDocumentController
    ) throws {
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ApplicationOpeningMarkdownFile {
    let directory: URL
    let url: URL

    init(name: String, contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
