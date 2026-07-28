import AppKit
import SwiftUI
import XCTest
@testable import DarthMD

@MainActor
final class MarkdownPresentationTests: XCTestCase {
    func testFrontMatterIsRemovedFromRenderedPresentation() throws {
        let source = """
        ---
        title: "Option Pricing"
        tags:
          - derivatives
        ---
        # Article
        """

        let bodyRange = try XCTUnwrap(
            MarkdownFrontMatter.bodyRange(in: source)
        )
        let presentation = MarkdownPresentationPolicy.presentation(
            requestedSourceMode: false,
            text: source
        )

        XCTAssertEqual(
            (source as NSString).substring(with: bodyRange),
            "# Article"
        )
        XCTAssertEqual(presentation.text, "# Article")
        XCTAssertEqual(presentation.sourceRange, bodyRange)
        XCTAssertTrue(presentation.rendersMarkdown)
    }

    func testSourceModePreservesFrontMatterVerbatim() {
        let source = "---\ntitle: Test\n---\n# Article"

        let presentation = MarkdownPresentationPolicy.presentation(
            requestedSourceMode: true,
            text: source
        )

        XCTAssertEqual(presentation.text, source)
        XCTAssertEqual(
            presentation.sourceRange,
            NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertFalse(presentation.rendersMarkdown)
    }

    func testFrontMatterSupportsBOMCRLFAndYAMLEndMarker() throws {
        let source = "\u{FEFF}---\r\ntitle: Test\r\n...\r\nBody"
        let bodyRange = try XCTUnwrap(
            MarkdownFrontMatter.bodyRange(in: source)
        )

        XCTAssertEqual(
            (source as NSString).substring(with: bodyRange),
            "Body"
        )
    }

    func testFrontMatterConsumesBlankSeparatorLines() throws {
        let source = "---\ntitle: Test\n---\n \t\n\n# Article"
        let bodyRange = try XCTUnwrap(
            MarkdownFrontMatter.bodyRange(in: source)
        )

        XCTAssertEqual(
            (source as NSString).substring(with: bodyRange),
            "# Article"
        )
    }

    func testFrontMatterRequiresAClosedLeadingFence() {
        XCTAssertNil(
            MarkdownFrontMatter.bodyRange(
                in: "---\ntitle: Unclosed\n# Article"
            )
        )
        XCTAssertNil(
            MarkdownFrontMatter.bodyRange(
                in: "Introduction\n---\ntitle: Not Front Matter\n---"
            )
        )
        XCTAssertNil(
            MarkdownFrontMatter.bodyRange(
                in: "----\ntitle: Wrong Opening\n---"
            )
        )
    }

    func testPresentedAndSourceRangesRoundTrip() {
        let source = "---\ntitle: Test\n---\n# 😀 Options"
        let presentation = MarkdownPresentationPolicy.presentation(
            requestedSourceMode: false,
            text: source
        )
        let presentedSelection = (presentation.text as NSString).range(
            of: "😀 Options"
        )
        let sourceSelection = presentation.sourceRange(
            forPresentedRange: presentedSelection
        )

        XCTAssertEqual(
            (source as NSString).substring(with: sourceSelection),
            "😀 Options"
        )
        XCTAssertEqual(
            presentation.presentedRange(forSourceRange: sourceSelection),
            presentedSelection
        )
    }

    func testBodyEditPreservesFrontMatterAndDocumentNewlines() {
        let source = "---\r\ntitle: Test\r\n---\r\n# Old"
        let presentation = MarkdownPresentationPolicy.presentation(
            requestedSourceMode: false,
            text: source
        )

        XCTAssertEqual(
            MarkdownEditorTextAdapter.reconcile(
                editorText: "# New\n\nParagraph",
                currentSource: source,
                newlineStyle: .crlf,
                presentedSourceRange: presentation.sourceRange
            ),
            "---\r\ntitle: Test\r\n---\r\n# New\r\n\r\nParagraph"
        )
    }

    func testFirstBodyEditTerminatesEOFFrontMatterDelimiter() throws {
        let cases: [
            (source: String, style: NewlineStyle, expected: String)
        ] = [
            (
                source: "---\ntitle: Test\n---",
                style: .lf,
                expected: "---\ntitle: Test\n---\n# Body"
            ),
            (
                source: "---\r\ntitle: Test\r\n---",
                style: .crlf,
                expected: "---\r\ntitle: Test\r\n---\r\n# Body"
            ),
            (
                source: "---\ntitle: Test\n...",
                style: .lf,
                expected: "---\ntitle: Test\n...\n# Body"
            ),
            (
                source: "---\ntitle: Test\n---\n",
                style: .lf,
                expected: "---\ntitle: Test\n---\n# Body"
            ),
            (
                source: "---\r\ntitle: Test\r\n...\r\n",
                style: .crlf,
                expected: "---\r\ntitle: Test\r\n...\r\n# Body"
            ),
            (
                source: "---\ntitle: Test\n---\n\n",
                style: .lf,
                expected: "---\ntitle: Test\n---\n\n# Body"
            )
        ]

        for testCase in cases {
            let presentation = MarkdownPresentationPolicy.presentation(
                requestedSourceMode: false,
                text: testCase.source
            )
            XCTAssertEqual(presentation.text, "")

            let reconciled = MarkdownEditorTextAdapter.reconcile(
                editorText: "# Body",
                currentSource: testCase.source,
                newlineStyle: testCase.style,
                presentedSourceRange: presentation.sourceRange
            )

            XCTAssertEqual(reconciled, testCase.expected)
            let bodyRange = try XCTUnwrap(
                MarkdownFrontMatter.bodyRange(in: reconciled)
            )
            XCTAssertEqual(
                (reconciled as NSString).substring(with: bodyRange),
                "# Body"
            )
        }
    }

    func testLivePreviewDisplaysBodyAndReportsSourcePosition() async throws {
        let source = "---\ntitle: Test\n---\n# Heading\n"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let pane = EditorPaneModel()
        pane.selectedRange = (source as NSString).range(of: "Heading")
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf
            )
            .frame(width: 640, height: 300)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        try await waitUntil {
            guard let textView = self.descendantTextViews(in: hostingView).first
            else {
                return false
            }
            return textView.string == "# Heading\n"
                && textView.selectedRange()
                    == ("# Heading\n" as NSString).range(of: "Heading")
                && pane.line == 4
                && pane.column == 3
        }

        XCTAssertEqual(buffer.revision.text, source)
        _ = window
    }

    func testSwitchingPresentationModesPreservesSourceSelection() async throws {
        let source = "---\ntitle: Test\n---\n# Heading\n"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let pane = EditorPaneModel()
        let sourceSelection = (source as NSString).range(of: "Heading")
        pane.selectedRange = sourceSelection
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: true,
                fontSize: 14,
                newlineStyle: .lf
            )
            .frame(width: 640, height: 300)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        try await waitUntil {
            guard let textView = self.descendantTextViews(in: hostingView).first
            else {
                return false
            }
            return textView.string == source
                && textView.selectedRange() == sourceSelection
        }

        hostingView.rootView = LivePreviewTextView(
            sourceBuffer: buffer,
            pane: pane,
            sourceMode: false,
            fontSize: 14,
            newlineStyle: .lf
        )
        .frame(width: 640, height: 300)
        hostingView.layoutSubtreeIfNeeded()

        try await waitUntil {
            guard let textView = self.descendantTextViews(in: hostingView).first
            else {
                return false
            }
            return textView.string == "# Heading\n"
                && textView.selectedRange()
                    == ("# Heading\n" as NSString).range(of: "Heading")
                && pane.selectedRange == sourceSelection
        }
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
        XCTFail("Timed out waiting for frontmatter presentation.")
    }

    private func descendantTextViews(in view: NSView) -> [NSTextView] {
        if let textView = view as? NSTextView {
            return [textView]
        }
        return view.subviews.flatMap(descendantTextViews)
    }
}
