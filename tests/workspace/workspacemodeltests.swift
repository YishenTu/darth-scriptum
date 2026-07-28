import XCTest
@testable import DarthMD

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testSplitAndSourceModeDoNotOwnDocumentContents() {
        let model = WorkspaceModel()
        model.toggleSplit()
        model.toggleSourceMode()

        XCTAssertTrue(model.isSplit)
        XCTAssertTrue(model.sourceMode)
    }

    func testZoomBoundsAndReset() {
        let model = WorkspaceModel()
        for _ in 0..<100 { model.zoom(by: 1) }
        XCTAssertEqual(model.fontSize, 32)
        for _ in 0..<100 { model.zoom(by: -1) }
        XCTAssertEqual(model.fontSize, 10)
        model.resetZoom()
        XCTAssertEqual(model.fontSize, 14)
    }

    func testActivePaneTracksSplitFocusAndResetsWhenSplitCloses() {
        let model = WorkspaceModel()

        model.activate(model.secondaryPane)
        XCTAssertEqual(model.activePaneID, model.primaryPane.id)

        model.toggleSplit()
        model.activate(model.secondaryPane)
        model.secondaryPane.line = 7
        model.secondaryPane.column = 12

        XCTAssertEqual(model.activePaneID, model.secondaryPane.id)
        XCTAssertTrue(model.activePane === model.secondaryPane)
        XCTAssertEqual(model.activePane.line, 7)
        XCTAssertEqual(model.activePane.column, 12)

        model.toggleSplit()

        XCTAssertEqual(model.activePaneID, model.primaryPane.id)
        XCTAssertTrue(model.activePane === model.primaryPane)
    }

    func testSourceModeToggleDoesNotClearDocumentUndoHistory() {
        let model = WorkspaceModel()
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "before", format: .newDocument)
        )
        buffer.replace(
            with: "after",
            origin: .localEditor(paneID: model.primaryPane.id)
        )

        model.toggleSourceMode()

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "before")
    }
}
