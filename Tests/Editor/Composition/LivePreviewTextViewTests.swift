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

    func testNativeEditorPreservesCRLFForAppendedLineAndFinalNewline() async throws {
        let source = "# CRLF\r\n\r\nFirst line\r\nSecond line\r\n"
        let appendedLine = source + "Saved line"
        let expected = appendedLine + "\r\n"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: source,
                format: TextFileFormat(
                    encoding: .utf8,
                    dominantNewline: .crlf,
                    hasFinalNewline: true
                )
            )
        )
        let pane = EditorPaneModel()
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .crlf
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
        )
        try await waitUntil {
            textView.string == source
        }
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        textView.insertText(
            "Saved line",
            replacementRange: textView.selectedRange()
        )

        try await waitUntil {
            buffer.revision.text == appendedLine
        }
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        textView.insertText(
            "\n",
            replacementRange: textView.selectedRange()
        )

        try await waitUntil {
            buffer.revision.text == expected
        }
        XCTAssertEqual(buffer.revision.text, expected)
        _ = window
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

    func testConfiguredLaTeXRendererSupportsFinancialFormula() {
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

    func testLineDenseDocumentsUseRawSourceBeforeTheByteLimit() {
        let source = String(
            repeating: "\n",
            count: MarkdownPresentationPolicy.maximumLivePreviewLines
        )
        let metrics = DocumentMetrics(text: source)

        XCTAssertLessThan(
            metrics.utf8ByteCount,
            MarkdownPresentationPolicy.maximumLivePreviewBytes
        )
        XCTAssertTrue(
            MarkdownPresentationPolicy.usesRawSource(
                requestedSourceMode: false,
                metrics: metrics
            )
        )
    }

    func testSelectionTransformTracksIncrementalEditsWithoutTextSearch() {
        let insertion = SourceEdit(
            range: NSRange(location: 3, length: 0),
            replacement: "wide",
            expectedRevision: 0,
            origin: .undoRedo
        )
        XCTAssertEqual(
            SourceSelectionTransformer.transform(
                NSRange(location: 8, length: 2),
                by: insertion
            ),
            NSRange(location: 12, length: 2)
        )

        let replacement = SourceEdit(
            range: NSRange(location: 5, length: 4),
            replacement: "x",
            expectedRevision: 1,
            origin: .undoRedo
        )
        XCTAssertEqual(
            SourceSelectionTransformer.transform(
                NSRange(location: 6, length: 2),
                by: replacement
            ),
            NSRange(location: 5, length: 1)
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
                MarkdownEngineCompatibility.nativeTextViews(in: hostingView)
                    .compactMap(\.identifier?.rawValue)
            )
            return identifiers.contains(
                "DarthScriptum.MarkdownEditor.\(primaryPane.id.uuidString)"
            )
                && identifiers.contains(
                    "DarthScriptum.MarkdownEditor.\(secondaryPane.id.uuidString)"
                )
        }

        buffer.replace(
            with: updatedSource,
            origin: .localEditor(paneID: primaryPane.id)
        )

        try await waitUntil {
            MarkdownEngineCompatibility.nativeTextViews(in: hostingView)
                .allSatisfy { $0.string == updatedSource }
        }
        XCTAssertEqual(secondaryPane.selectedRange.location, 15)
        let secondaryTextView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextViews(in: hostingView)
                .first(where: {
                    $0.identifier?.rawValue
                        == "DarthScriptum.MarkdownEditor."
                        + secondaryPane.id.uuidString
                })
        )
        XCTAssertEqual(secondaryTextView.selectedRange().location, 15)
        _ = window
    }

    func testEngineRendersHeadingBulletAndLaTeX() async throws {
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
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
                storage.length == (source as NSString).length
            else {
                return false
            }
            let headingLocation = (source as NSString)
                .range(of: "Heading").location
            let bulletLocation = (source as NSString)
                .range(of: "- item").location
            let inlineLaTeXLocation = (source as NSString)
                .range(of: "4+3=7").location
            let headingFont =
                storage.attribute(
                    .font,
                    at: headingLocation,
                    effectiveRange: nil
                ) as? NSFont
            let bullet = MarkdownEngineCompatibility.isBulletListMarker(
                in: storage,
                at: bulletLocation
            )
            let inlineLaTeX = MarkdownEngineCompatibility.renderedBlock(
                in: storage,
                at: inlineLaTeXLocation
            )?.image
            return headingFont?.pointSize == 28
                && bullet == true
                && inlineLaTeX != nil
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
        XCTAssertTrue(
            MarkdownEngineCompatibility.isBulletListMarker(
                in: try XCTUnwrap(textView.textStorage),
                at: (source as NSString).range(of: "- item").location
            )
        )
        XCTAssertNotNil(
            textView.textStorage.flatMap {
                MarkdownEngineCompatibility.renderedBlock(
                    in: $0,
                    at: (source as NSString).range(of: "4+3=7").location
                )?.image
            }
        )
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertTrue(
            MarkdownEngineCompatibility.containsRenderedImage(
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

    func testLiveResizeKeepsWrappedProseInsideTrailingInset() async throws {
        let source = String(
            repeating:
                "Option pricing connects probability, economics, and numerical methods. ",
            count: 24
        )
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let pane = EditorPaneModel()
        let initialSize = NSSize(width: 960, height: 420)
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        try await waitUntil {
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
        )
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let textContainer = try XCTUnwrap(textView.textContainer)
        try await waitUntil {
            textView.string == source
        }
        let wideLineCount = wrappedLineCount(in: textView)
        let wideViewportWidth = scrollView.contentView.bounds.width
        let wideContainerWidth = textContainer.containerSize.width

        let narrowSize = NSSize(width: 560, height: initialSize.height)
        hostingView.frame.size = narrowSize
        window.setContentSize(narrowSize)
        window.layoutIfNeeded()

        try await waitUntil {
            scrollView.contentView.bounds.width < wideViewportWidth
                && textContainer.containerSize.width < wideContainerWidth
                && self.wrappedLineCount(in: textView) > wideLineCount
        }
        let narrowLineCount = wrappedLineCount(in: textView)
        let horizontalInset = textView.textContainerInset.width
        let maximumWrapWidth =
            scrollView.contentView.bounds.width - horizontalInset * 2

        XCTAssertGreaterThan(narrowLineCount, wideLineCount)
        XCTAssertLessThanOrEqual(
            textContainer.containerSize.width,
            maximumWrapWidth + 1
        )
        XCTAssertLessThanOrEqual(
            maximumRenderedLineX(in: textView),
            textView.bounds.width - horizontalInset + 1
        )
        XCTAssertFalse(scrollView.hasHorizontalScroller)
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
        )

        try await waitUntil(timeout: .seconds(5)) {
            guard let storage = textView.textStorage,
                storage.length == (source as NSString).length
            else {
                return false
            }
            return MarkdownEngineCompatibility.containsRenderedImage(
                in: storage,
                range: NSRange(location: 0, length: storage.length)
            )
        }

        XCTAssertEqual(textView.string, source)
        XCTAssertTrue(
            MarkdownEngineCompatibility.containsRenderedImage(
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
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
            MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            ).count == 1
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
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

    private func wrappedLineCount(in textView: NSTextView) -> Int {
        guard let layoutManager = textView.textLayoutManager else {
            return 0
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var count = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            count += fragment.textLineFragments.count
            return true
        }
        return count
    }

    private func maximumRenderedLineX(in textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.textLayoutManager else {
            return 0
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var maximumX: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            for line in fragment.textLineFragments {
                maximumX = max(
                    maximumX,
                    fragment.layoutFragmentFrame.minX
                        + line.typographicBounds.maxX
                )
            }
            return true
        }
        return maximumX
    }
}
