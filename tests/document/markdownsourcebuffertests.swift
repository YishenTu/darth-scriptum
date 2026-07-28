import XCTest
@testable import DarthMD

@MainActor
final class MarkdownSourceBufferTests: XCTestCase {
    func testPublishesMonotonicRevisionsToMultipleObservers() throws {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "a", format: .newDocument)
        )
        var first: [UInt64] = []
        var second: [UInt64] = []
        let firstToken = buffer.observe { revision, _ in first.append(revision.number) }
        let secondToken = buffer.observe { revision, _ in second.append(revision.number) }

        _ = try buffer.apply(
            SourceEdit(
                range: NSRange(location: 1, length: 0),
                replacement: "b",
                expectedRevision: 0,
                origin: .localEditor(paneID: UUID())
            )
        )
        buffer.removeObserver(firstToken)
        buffer.replace(with: "abc", origin: .externalReload)
        buffer.removeObserver(secondToken)

        XCTAssertEqual(first, [1])
        XCTAssertEqual(second, [1, 2])
        XCTAssertEqual(buffer.revision.text, "abc")
    }

    func testUndoAndRedoUseOneHistoryAcrossEditorPanes() {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "base", format: .newDocument)
        )
        let primaryPaneID = UUID()
        let secondaryPaneID = UUID()
        var origins: [DocumentChangeOrigin] = []
        let token = buffer.observe { _, origin in origins.append(origin) }

        buffer.replace(
            with: "primary",
            origin: .localEditor(paneID: primaryPaneID)
        )
        buffer.replace(
            with: "secondary",
            origin: .localEditor(paneID: secondaryPaneID)
        )

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "primary")
        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "base")
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.revision.text, "primary")
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.revision.text, "secondary")
        XCTAssertFalse(buffer.canRedo)
        XCTAssertEqual(
            origins,
            [
                .localEditor(paneID: primaryPaneID),
                .localEditor(paneID: secondaryPaneID),
                .undoRedo,
                .undoRedo,
                .undoRedo,
                .undoRedo
            ]
        )
        buffer.removeObserver(token)
    }

    func testUndoPreservesUnicodeReplacementBoundaries() {
        let paneID = UUID()
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: "before 😀 after",
                format: .newDocument
            )
        )

        buffer.replace(
            with: "before 😎 after",
            origin: .localEditor(paneID: paneID)
        )

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "before 😀 after")
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.revision.text, "before 😎 after")
    }

    func testExternalReplacementInvalidatesUndoHistory() {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "base", format: .newDocument)
        )
        buffer.replace(
            with: "local",
            origin: .localEditor(paneID: UUID())
        )

        buffer.replace(with: "external", origin: .externalReload)

        XCTAssertFalse(buffer.canUndo)
        XCTAssertFalse(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "external")
    }
}
