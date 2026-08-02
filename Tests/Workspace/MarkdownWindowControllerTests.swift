import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownWindowControllerTests: XCTestCase {
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
