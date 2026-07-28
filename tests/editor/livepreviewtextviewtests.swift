import AppKit
import SwiftUI
import XCTest
@testable import DarthScriptum

@MainActor
final class LivePreviewTextViewTests: XCTestCase {
    func testEditorUsesTextKit2() {
        let textView = NSTextView(usingTextLayoutManager: true)
        XCTAssertNotNil(textView.textLayoutManager)
        XCTAssertNotNil(textView.textContentStorage)
    }

    func testSplitPaneModelsKeepIndependentSelections() {
        let primary = EditorPaneModel()
        let secondary = EditorPaneModel()
        primary.selectedRange = NSRange(location: 2, length: 0)
        secondary.selectedRange = NSRange(location: 20, length: 4)

        XCTAssertNotEqual(primary.selectedRange, secondary.selectedRange)
        XCTAssertNotEqual(primary.id, secondary.id)
    }

    func testEditorTextAdapterPreservesCRLFForInsertedNewline() {
        XCTAssertEqual(
            MarkdownEditorTextAdapter.reconcile(
                editorText: "first\r\nsec\nond",
                currentSource: "first\r\nsecond",
                newlineStyle: .crlf
            ),
            "first\r\nsec\r\nond"
        )
    }

    func testEditorTextAdapterPreservesUntouchedMixedNewlines() {
        XCTAssertEqual(
            MarkdownEditorTextAdapter.reconcile(
                editorText: "a\r\nedited\nc",
                currentSource: "a\r\nb\nc",
                newlineStyle: .crlf
            ),
            "a\r\nedited\nc"
        )
    }

    func testEditorTextAdapterDoesNotSplitSurrogatePairs() {
        XCTAssertEqual(
            MarkdownEditorTextAdapter.reconcile(
                editorText: "before 😎 after",
                currentSource: "before 😀 after",
                newlineStyle: .lf
            ),
            "before 😎 after"
        )
    }

    func testEditorTextAdapterProtectsTrailingSurrogateBoundary() throws {
        let original = try XCTUnwrap(UnicodeScalar(0x10000))
        let replacement = try XCTUnwrap(UnicodeScalar(0x10400))

        XCTAssertEqual(
            MarkdownEditorTextAdapter.reconcile(
                editorText: "before \(replacement) after",
                currentSource: "before \(original) after",
                newlineStyle: .lf
            ),
            "before \(replacement) after"
        )
    }

    func testRelativeLinksResolveAgainstTheDocumentDirectory() {
        let documentURL = URL(fileURLWithPath: "/tmp/notes/current.md")

        XCTAssertEqual(
            MarkdownLinkResolver.resolve(
                "images/example.png",
                relativeTo: documentURL
            ),
            URL(fileURLWithPath: "/tmp/notes/images/example.png")
        )
        XCTAssertEqual(
            MarkdownLinkResolver.resolve(
                "https://example.com/reference",
                relativeTo: documentURL
            )?.absoluteString,
            "https://example.com/reference"
        )
        XCTAssertNil(
            MarkdownLinkResolver.resolve(
                "javascript:alert(1)",
                relativeTo: documentURL
            )
        )
    }

    func testSelectionAnchorResolvesInLargeRepeatedText() {
        let source = String(repeating: "same repeated line\n", count: 250_000)
        let location = (source as NSString).length / 2
        let anchor = SelectionAnchor.capture(
            selectedRange: NSRange(location: location, length: 0),
            in: source
        )
        let updated = "prefix\n" + source
        let resolved = anchor.resolve(in: updated)

        XCTAssertEqual(resolved.location, location + 7)
    }

    func testConfiguredLatexRendererSupportsFinancialFormula() {
        let configuration = MarkdownConfigurationFactory.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        )

        XCTAssertNotNil(
            configuration.services.latex.render(
                latex: #"C = S_0 \, N(d_1) - K \, e^{-rT} \, N(d_2)"#,
                fontSize: 14,
                theme: configuration.theme
            )
        )
    }

    func testLargeDocumentsAutomaticallyUseRawSourcePresentation() {
        let limit = MarkdownPresentationPolicy.maximumLivePreviewBytes
        let atLimit = String(repeating: "a", count: limit)
        let overLimit = atLimit + "a"

        XCTAssertFalse(
            MarkdownPresentationPolicy.usesRawSource(
                requestedSourceMode: false,
                text: atLimit
            )
        )
        XCTAssertTrue(
            MarkdownPresentationPolicy.usesRawSource(
                requestedSourceMode: false,
                text: overLimit
            )
        )
        XCTAssertTrue(
            MarkdownPresentationPolicy.usesRawSource(
                requestedSourceMode: true,
                text: "# Small"
            )
        )
        XCTAssertTrue(
            MarkdownConfigurationFactory.make(
                rawSourceMode: MarkdownPresentationPolicy.usesRawSource(
                    requestedSourceMode: false,
                    text: overLimit
                ),
                fontSize: 14,
                documentURL: nil
            ).rawSourceMode
        )
    }

    func testOtherPaneSelectionReanchorsAfterLocalEdit() async throws {
        let source = "alpha\nomega"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let primaryPane = EditorPaneModel()
        let secondaryPane = EditorPaneModel()
        primaryPane.selectedRange = NSRange(location: 8, length: 0)
        secondaryPane.selectedRange = NSRange(location: 8, length: 0)
        let primaryCoordinator = EditorPaneStateCoordinator(
            sourceBuffer: buffer,
            pane: primaryPane
        )
        let secondaryCoordinator = EditorPaneStateCoordinator(
            sourceBuffer: buffer,
            pane: secondaryPane
        )
        primaryCoordinator.start()
        secondaryCoordinator.start()
        defer {
            primaryCoordinator.stop()
            secondaryCoordinator.stop()
        }

        buffer.replace(
            with: "prefix\n\(source)",
            origin: .localEditor(paneID: primaryPane.id)
        )

        try await waitUntil {
            primaryPane.selectedRange.location == 8
                && secondaryPane.selectedRange.location == 15
        }
    }

    func testRenderedSplitPaneRestoresReanchoredSelection() async throws {
        let source = "alpha\nomega"
        let updatedSource = "prefix\n\(source)"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let primaryPane = EditorPaneModel()
        let secondaryPane = EditorPaneModel()
        secondaryPane.selectedRange = NSRange(location: 8, length: 0)
        let hostingView = NSHostingView(
            rootView: HStack {
                LivePreviewTextView(
                    sourceBuffer: buffer,
                    pane: primaryPane,
                    sourceMode: false,
                    fontSize: 14,
                    newlineStyle: .lf
                )
                LivePreviewTextView(
                    sourceBuffer: buffer,
                    pane: secondaryPane,
                    sourceMode: false,
                    fontSize: 14,
                    newlineStyle: .lf
                )
            }
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
            let identifiers = Set(
                self.descendantTextViews(in: hostingView)
                    .compactMap(\.identifier?.rawValue)
            )
            return identifiers.contains(
                "DarthScriptum.MarkdownEditor.\(primaryPane.id.uuidString)"
            ) && identifiers.contains(
                "DarthScriptum.MarkdownEditor.\(secondaryPane.id.uuidString)"
            )
        }

        buffer.replace(
            with: updatedSource,
            origin: .localEditor(paneID: primaryPane.id)
        )

        try await waitUntil {
            self.descendantTextViews(in: hostingView)
                .allSatisfy { $0.string == updatedSource }
        }
        XCTAssertEqual(secondaryPane.selectedRange.location, 15)
        let secondaryTextView = try XCTUnwrap(
            descendantTextViews(in: hostingView)
                .first(where: {
                    $0.identifier?.rawValue
                        == "DarthScriptum.MarkdownEditor."
                            + secondaryPane.id.uuidString
                })
        )
        XCTAssertEqual(secondaryTextView.selectedRange().location, 15)
        _ = window
    }

    func testEngineRendersHeadingBulletAndLatex() async throws {
        let source = """
        # Heading

        - item

        $4+3=7$

        $$
        C = S_0 \\, N(d_1) - K \\, e^{-rT} \\, N(d_2)
        $$

        after
        """
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: source,
                format: .newDocument
            )
        )
        let pane = EditorPaneModel()
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf
            )
            .frame(width: 640, height: 520)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 520)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        try await waitUntil {
            self.descendantTextViews(in: hostingView).count == 1
        }
        let textView = try XCTUnwrap(
            descendantTextViews(in: hostingView).first
        )
        try await waitUntil {
            textView.identifier?.rawValue
                == "DarthScriptum.MarkdownEditor.\(pane.id.uuidString)"
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        try await waitUntil {
            guard let storage = textView.textStorage,
                  storage.length == (source as NSString).length else {
                return false
            }
            let headingLocation = (source as NSString)
                .range(of: "Heading").location
            let bulletLocation = (source as NSString)
                .range(of: "- item").location
            let inlineLatexLocation = (source as NSString)
                .range(of: "4+3=7").location
            let headingFont = storage.attribute(
                .font,
                at: headingLocation,
                effectiveRange: nil
            ) as? NSFont
            let bullet = storage.attribute(
                NSAttributedString.Key("BulletListMarker"),
                at: bulletLocation,
                effectiveRange: nil
            ) as? Bool
            let inlineLatex = storage.attribute(
                NSAttributedString.Key("LatexRenderedImage"),
                at: inlineLatexLocation,
                effectiveRange: nil
            ) as? NSImage
            return headingFont?.pointSize == 28
                && bullet == true
                && inlineLatex != nil
        }

        let headingLocation = (source as NSString)
            .range(of: "Heading").location
        let headingFont = try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: headingLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertEqual(headingFont.pointSize, 28, accuracy: 0.01)
        XCTAssertTrue(
            NSFontManager.shared.traits(of: headingFont)
                .contains(.boldFontMask)
        )
        XCTAssertEqual(
            textView.textStorage?.attribute(
                NSAttributedString.Key("BulletListMarker"),
                at: (source as NSString).range(of: "- item").location,
                effectiveRange: nil
            ) as? Bool,
            true
        )
        XCTAssertNotNil(
            textView.textStorage?.attribute(
                NSAttributedString.Key("LatexRenderedImage"),
                at: (source as NSString).range(of: "4+3=7").location,
                effectiveRange: nil
            ) as? NSImage
        )
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertTrue(
            containsRenderedLatex(
                in: storage,
                range: NSRange(
                    location: (source as NSString).range(of: "$$").location,
                    length: storage.length
                        - (source as NSString).range(of: "$$").location
                )
            )
        )
        _ = window
    }

    func testEngineRestylesWhenMathJaxFallbackCompletes() async throws {
        let source = """
        before

        $$
        \\dfrac{37}{113} + \\begin{pmatrix}a & b \\\\ c & d\\end{pmatrix}
        $$

        after
        """
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: source,
                format: .newDocument
            )
        )
        let pane = EditorPaneModel()
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

        try await waitUntil(timeout: .seconds(5)) {
            self.descendantTextViews(in: hostingView).count == 1
        }
        let textView = try XCTUnwrap(
            descendantTextViews(in: hostingView).first
        )

        try await waitUntil(timeout: .seconds(5)) {
            guard let storage = textView.textStorage,
                  storage.length == (source as NSString).length else {
                return false
            }
            return self.containsRenderedLatex(
                in: storage,
                range: NSRange(location: 0, length: storage.length)
            )
        }

        XCTAssertEqual(textView.string, source)
        XCTAssertTrue(
            containsRenderedLatex(
                in: try XCTUnwrap(textView.textStorage),
                range: NSRange(
                    location: 0,
                    length: (source as NSString).length
                )
            )
        )
        _ = window
    }

    func testDisplayMathSelectionHighlightsOnlyVisibleFormulaContent() async throws {
        let formula = #"P = K \, e^{-rT} \, N(-d_2) - S_0 \, N(-d_1)"#
        let source = """
        before

        $$
          \(formula)
        $$

        after
        """
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: source,
                format: .newDocument
            )
        )
        let pane = EditorPaneModel()
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
            self.descendantTextViews(in: hostingView).count == 1
        }
        let textView = try XCTUnwrap(
            descendantTextViews(in: hostingView).first
        )
        try await waitUntil {
            textView.identifier?.rawValue
                == "DarthScriptum.MarkdownEditor.\(pane.id.uuidString)"
        }

        let nsSource = source as NSString
        let contentRange = nsSource.range(
            of: "\n  \(formula)\n"
        )
        let visibleFormulaRange = nsSource.range(of: formula)
        textView.setSelectedRange(contentRange)
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )

        try await waitUntil {
            textView.selectedRange() == visibleFormulaRange
                && pane.selectedRange == visibleFormulaRange
        }
        _ = window
    }

    func testRawSourceModePreservesExactDisplayMathSelection() async throws {
        let formula = #"P = K \, e^{-rT}"#
        let source = "$$\n  \(formula)\n$$"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: source,
                format: .newDocument
            )
        )
        let pane = EditorPaneModel()
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
            self.descendantTextViews(in: hostingView).count == 1
        }
        let textView = try XCTUnwrap(
            descendantTextViews(in: hostingView).first
        )
        try await waitUntil {
            textView.identifier?.rawValue
                == "DarthScriptum.MarkdownEditor.\(pane.id.uuidString)"
        }

        let contentRange = (source as NSString).range(of: "\n  \(formula)\n")
        textView.setSelectedRange(contentRange)
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )

        try await waitUntil {
            pane.selectedRange == contentRange
        }
        XCTAssertEqual(textView.selectedRange(), contentRange)
        _ = window
    }

    func testDisplayMathSelectionPreservesInternalLineBreaks() {
        let source = "$$\r\n  first \\\\\r\n  second  \r\n$$"
        let content = (source as NSString).range(
            of: "\r\n  first \\\\\r\n  second  \r\n"
        )

        XCTAssertEqual(
            DisplayMathSelectionPolicy.normalized(content, in: source),
            (source as NSString).range(of: "first \\\\\r\n  second")
        )
    }

    func testDisplayMathSelectionLeavesOrdinarySelectionsUnchanged() {
        let source = "prefix $$ value $$ suffix"
        let selection = (source as NSString).range(of: "value")

        XCTAssertEqual(
            DisplayMathSelectionPolicy.normalized(selection, in: source),
            selection
        )
    }

    func testPaneStateTracksEngineSelection() async throws {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: "first\nsecond\nthird",
                format: .newDocument
            )
        )
        let pane = EditorPaneModel()
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf
            )
            .frame(width: 480, height: 320)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        try await waitUntil {
            self.descendantTextViews(in: hostingView).count == 1
        }
        let textView = try XCTUnwrap(
            descendantTextViews(in: hostingView).first
        )
        try await waitUntil {
            textView.identifier?.rawValue
                == "DarthScriptum.MarkdownEditor.\(pane.id.uuidString)"
        }
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        try await waitUntil {
            pane.selectedRange.location == 8
                && pane.line == 2
                && pane.column == 3
        }
        _ = window
    }

    func testFocusedPaneReportsItBecameActive() async throws {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "text", format: .newDocument)
        )
        let pane = EditorPaneModel()
        var activationCount = 0
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf,
                onBecameActive: {
                    activationCount += 1
                }
            )
            .frame(width: 480, height: 320)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        try await waitUntil {
            self.descendantTextViews(in: hostingView).count == 1
        }
        let textView = try XCTUnwrap(
            descendantTextViews(in: hostingView).first
        )
        try await waitUntil {
            textView.identifier?.rawValue
                == "DarthScriptum.MarkdownEditor.\(pane.id.uuidString)"
        }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let activationCountBeforeNotification = activationCount
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )

        try await waitUntil {
            activationCount > activationCountBeforeNotification
        }
        window.orderOut(nil)
    }

    func testTaskToggleChangesOnlyTheSourceMarker() {
        let source = "- [ ] first\n1. [x] second\n"
        XCTAssertEqual(
            MarkdownEditingCommands.taskToggle(
                in: source,
                selection: NSRange(location: 5, length: 0)
            ),
            MarkdownTextMutation(
                range: NSRange(location: 3, length: 1),
                replacement: "x"
            )
        )
        XCTAssertEqual(
            MarkdownEditingCommands.taskToggle(
                in: source,
                selection: NSRange(location: 16, length: 0)
            ),
            MarkdownTextMutation(
                range: NSRange(location: 16, length: 1),
                replacement: " "
            )
        )
    }

    func testTaskTogglePromotesAPlainLine() {
        XCTAssertEqual(
            MarkdownEditingCommands.taskToggle(
                in: "plain\n",
                selection: NSRange(location: 2, length: 0)
            ),
            MarkdownTextMutation(
                range: NSRange(location: 0, length: 0),
                replacement: "- [ ] "
            )
        )
    }

    func testIndentationPreservesMixedLineTerminators() {
        let source = "- one\r\n- two\n- three\r\n"
        let indented = MarkdownEditingCommands.transformLines(
            source,
            indenting: true
        )
        XCTAssertEqual(indented, "  - one\r\n  - two\n  - three\r\n")
        XCTAssertEqual(
            MarkdownEditingCommands.transformLines(
                indented,
                indenting: false
            ),
            source
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
        XCTFail("Timed out waiting for editor state.")
    }

    private func descendantTextViews(in view: NSView) -> [NSTextView] {
        if let textView = view as? NSTextView {
            return [textView]
        }
        return view.subviews.flatMap(descendantTextViews)
    }

    private func containsRenderedLatex(
        in storage: NSTextStorage,
        range: NSRange
    ) -> Bool {
        var found = false
        storage.enumerateAttribute(
            NSAttributedString.Key("LatexRenderedImage"),
            in: range
        ) { value, _, stop in
            if value is NSImage {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
