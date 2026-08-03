import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownWindowControllerTests: XCTestCase {
    func testDocumentWindowOptsIntoStableNativeRestoration() throws {
        let document = MarkdownDocument()
        let controller = MarkdownWindowController(
            document: document,
            onOpenMarkdownFile: { _ in }
        )
        document.addWindowController(controller)
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock {
            document.removeWindowController(controller)
            controller.close()
        }

        XCTAssertTrue(window.isRestorable)
        XCTAssertEqual(
            window.identifier?.rawValue,
            "DarthScriptum.MarkdownDocumentWindow"
        )
        XCTAssertTrue(window.restorationClass === type(of: NSDocumentController.shared))
    }

    func testSelectedTabbedWindowRoutesResponderActionsToItsDocument() throws {
        let firstDocument = MarkdownDocument()
        let secondDocument = MarkdownDocument()
        let firstController = MarkdownWindowController(
            document: firstDocument,
            onOpenMarkdownFile: { _ in }
        )
        let secondController = MarkdownWindowController(
            document: secondDocument,
            onOpenMarkdownFile: { _ in }
        )
        firstDocument.addWindowController(firstController)
        secondDocument.addWindowController(secondController)
        let firstWindow = try XCTUnwrap(firstController.window)
        let secondWindow = try XCTUnwrap(secondController.window)
        firstWindow.addTabbedWindow(secondWindow, ordered: .above)
        firstWindow.tabGroup?.selectedWindow = secondWindow
        addTeardownBlock {
            firstDocument.removeWindowController(firstController)
            secondDocument.removeWindowController(secondController)
            firstController.close()
            secondController.close()
        }

        let selectedController = try XCTUnwrap(
            firstWindow.tabGroup?.selectedWindow?.windowController
                as? MarkdownWindowController
        )
        let target = selectedController.supplementalTarget(
            forAction: #selector(MarkdownDocument.undoDocument(_:)),
            sender: nil
        )

        XCTAssertTrue(selectedController === secondController)
        XCTAssertTrue(target as AnyObject? === secondDocument)
    }

    func testRestoredPaneStateIsPresentWhenTheEditorAttaches() async throws {
        let document = MarkdownDocument()
        document.syncCoordinator.sourceBuffer.replace(
            with: "# Restored selection\n",
            origin: .initialLoad
        )
        let controller = MarkdownWindowController(
            document: document,
            onOpenMarkdownFile: { _ in }
        )
        let state = try XCTUnwrap(
            WorkspaceRestorationState(
                isSplit: false,
                sourceMode: true,
                fontSize: 18,
                activePane: .primary,
                primarySelection: NSRange(location: 2, length: 8),
                primaryVisibleOrigin: .zero,
                secondarySelection: NSRange(location: 0, length: 0),
                secondaryVisibleOrigin: .zero
            )
        )
        controller.workspaceModel.restore(state)
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock {
            controller.close()
            withExtendedLifetime(document) {}
        }

        try await waitUntil {
            guard let contentView = window.contentView else { return false }
            return MarkdownEngineCompatibility.nativeTextView(in: contentView)?
                .selectedRange() == state.primarySelection
        }

        XCTAssertTrue(controller.workspaceModel.sourceMode)
        XCTAssertEqual(controller.workspaceModel.fontSize, 18)
    }

    func testCancelOperationWhenEditorDoesNotConsumeItDefocusesEditor() throws {
        let harness = try makeHarness()

        harness.editor.doCommand(
            by: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertTrue(harness.window.firstResponder === harness.window)
    }

    func testCancelOperationWhenEditorConsumesItPreservesEditorFocus() throws {
        let delegate = CancelOperationConsumingTextViewDelegate()
        let harness = try makeHarness(textViewDelegate: delegate)

        harness.editor.doCommand(
            by: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertTrue(harness.window.firstResponder === harness.editor)
        XCTAssertEqual(delegate.cancelOperationCount, 1)
    }

    func testCancelOperationWhenNonEditorIsFocusedPreservesFocus() throws {
        let harness = try makeHarness()
        let otherTextView = NSTextView(frame: .zero)
        harness.window.contentView?.addSubview(otherTextView)
        XCTAssertTrue(harness.window.makeFirstResponder(otherTextView))

        harness.controller.cancelOperation(nil)

        XCTAssertTrue(harness.window.firstResponder === otherTextView)
    }

    private func makeHarness(
        textViewDelegate: NSTextViewDelegate? = nil
    ) throws -> Harness {
        let document = MarkdownDocument()
        let controller = MarkdownWindowController(
            document: document,
            onOpenMarkdownFile: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        window.contentViewController = nil
        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView
        let editor = NSTextView(frame: .zero)
        editor.delegate = textViewDelegate
        let editorContainer = NSView(frame: .zero)
        editorContainer.addSubview(editor)
        let editorScrollView = NSScrollView(frame: .zero)
        editorScrollView.documentView = editorContainer
        contentView.addSubview(editorScrollView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        addTeardownBlock {
            controller.close()
            withExtendedLifetime(document) {}
        }
        return Harness(
            document: document,
            controller: controller,
            window: window,
            editor: editor
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
        XCTFail("Timed out waiting for restored editor attachment.")
    }
}

@MainActor
private struct Harness {
    let document: MarkdownDocument
    let controller: MarkdownWindowController
    let window: NSWindow
    let editor: NSTextView
}

@MainActor
private final class CancelOperationConsumingTextViewDelegate: NSObject,
    NSTextViewDelegate
{
    private(set) var cancelOperationCount = 0

    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:))
        else {
            return false
        }
        cancelOperationCount += 1
        return true
    }
}
