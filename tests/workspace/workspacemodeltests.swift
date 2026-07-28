import AppKit
import XCTest
@testable import DarthScriptum

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

    func testSplitRightOpensAndActivatesSecondaryPaneIdempotently() {
        let model = WorkspaceModel()

        model.splitRight()

        XCTAssertTrue(model.isSplit)
        XCTAssertTrue(model.activePane === model.secondaryPane)

        model.splitRight()

        XCTAssertTrue(model.isSplit)
        XCTAssertTrue(model.activePane === model.secondaryPane)
    }

    func testRoutineSynchronizationStatesStaySilent() {
        for state in [
            SynchronizationState.idle,
            .waitingToWrite,
            .writing,
            .checkingExternalChange,
            .reloading,
            .merging
        ] {
            XCTAssertNil(
                SynchronizationStatusPresentation.message(for: state)
            )
        }
    }

    func testPersistentSynchronizationStatesRemainVisible() {
        XCTAssertEqual(
            SynchronizationStatusPresentation.message(
                for: .recoveredConflict
            ),
            "Disk version shown · local revision recoverable"
        )
        XCTAssertEqual(
            SynchronizationStatusPresentation.message(for: .readOnly),
            "Read only"
        )
        XCTAssertEqual(
            SynchronizationStatusPresentation.message(for: .missing),
            "File missing"
        )
        XCTAssertEqual(
            SynchronizationStatusPresentation.message(
                for: .failed("Unable to reload")
            ),
            "Unable to reload"
        )
        XCTAssertEqual(
            SynchronizationStatusPresentation.message(
                for: .limitedSyncSafety
            ),
            "Limited sync safety"
        )
        XCTAssertEqual(
            SynchronizationStatusPresentation.message(
                for: .synchronizationPaused
            ),
            "Synchronization paused"
        )
    }

    func testSynchronizationPresentationKeepsMessageAndActionsConsistent() {
        let missing = SynchronizationStatusPresentation.make(for: .missing)
        XCTAssertEqual(missing?.message, "File missing")
        XCTAssertEqual(
            missing?.systemImage,
            "exclamationmark.triangle.fill"
        )
        XCTAssertEqual(missing?.tone, .failure)
        XCTAssertEqual(missing?.primaryAction, .saveAs)

        let retryable = SynchronizationStatusPresentation.make(
            for: .failed("Unable to reload")
        )
        XCTAssertEqual(retryable?.primaryAction, .retrySynchronization)

        let saveAsFailure = SynchronizationStatusPresentation.make(
            for: .failed("Unable to save"),
            failureRequiresSaveAs: true
        )
        XCTAssertEqual(saveAsFailure?.primaryAction, .saveAs)

        let recoveryURL = URL(fileURLWithPath: "/tmp/recovery.md")
        let paused = SynchronizationStatusPresentation.make(
            for: .synchronizationPaused,
            rawRecoveryURL: recoveryURL,
            hasLocalRecovery: true
        )
        XCTAssertEqual(paused?.primaryAction, .showRecoveryFile(recoveryURL))
        XCTAssertTrue(paused?.offersLocalRevisionRestore == true)
        XCTAssertTrue(paused?.offersRawRecoveryDiscard == true)
    }

    func testTabShortcutPolicyUsesOneThroughEightAndNineForLast() {
        XCTAssertEqual(
            (1...3).map {
                TabShortcutPolicy.selectionIndex(
                    for: $0,
                    tabCount: 3
                )
            },
            [0, 1, 2]
        )
        XCTAssertEqual(
            TabShortcutPolicy.selectionIndex(for: 9, tabCount: 3),
            2
        )
        XCTAssertNil(
            TabShortcutPolicy.selectionIndex(for: 4, tabCount: 3)
        )
        XCTAssertEqual(
            (0..<3).map {
                TabShortcutPolicy.displayNumber(
                    forTabAt: $0,
                    tabCount: 3
                )
            },
            [1, 2, 3]
        )
        XCTAssertEqual(
            (0..<11).map {
                TabShortcutPolicy.displayNumber(
                    forTabAt: $0,
                    tabCount: 11
                )
            },
            [1, 2, 3, 4, 5, 6, 7, 8, nil, nil, 9]
        )
    }

    func testTabShortcutPresentationUsesRightAlignedAccessoryViews() {
        let windows = (0..<3).map { _ in NSWindow() }

        TabShortcutPresentation.update(windows: windows)

        XCTAssertEqual(
            windows.compactMap {
                ($0.tab.accessoryView as? NSTextField)?.stringValue
            },
            ["⌘1", "⌘2", "⌘3"]
        )
        XCTAssertTrue(
            windows.allSatisfy {
                ($0.tab.accessoryView as? NSTextField)?.alignment == .right
            }
        )

        TabShortcutPresentation.update(windows: [windows[0]])

        XCTAssertNil(windows[0].tab.accessoryView)
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
