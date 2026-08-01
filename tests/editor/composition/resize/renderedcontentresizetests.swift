import AppKit
import MarkdownEngine
import SwiftUI
import XCTest
@testable import DarthScriptum

@MainActor
final class RenderedContentResizeTests: XCTestCase {
    func testFinalTableRestylePreservesMermaidPresentation() async throws {
        let source = Self.mermaidSource + """


        | Name | Value |
        | --- | ---: |
        | A | 1 |
        """
        let notification = Notification.Name(
            "RenderedContentResizeTests.mixed.\(UUID().uuidString)"
        )
        let renderer = testMermaidRenderer(naturalWidth: 700)
        let rendered = expectation(
            forNotification: renderer.updateNotification,
            object: renderer
        )
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(
                latexRenderer: AdaptiveLatexRenderer(
                    updateNotification: notification
                ),
                mermaidRenderer: renderer
            )
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        let anchor = (source as NSString).range(of: "flowchart").location
        await fulfillment(of: [rendered], timeout: 2)
        let initialBlock = try await harness.renderedBlock(
            in: textView,
            at: anchor
        )
        let sourceIdentity = try XCTUnwrap(initialBlock.sourceIdentity)

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [760])

        let finalRestyle = expectation(
            forNotification: notification,
            object: textView
        )
        try harness.endLiveResize(for: textView)
        liveResizeActive = false
        await fulfillment(of: [finalRestyle], timeout: 2)

        _ = try await harness.renderedBlock(in: textView, at: anchor) {
            $0.sourceIdentity == sourceIdentity
        }
    }

    func testResizeEndForcesFinalTableRestyleAfterSameWidthQuietUpdate()
        async throws {
        let source = "| Name | Value |\n| --- | ---: |\n| A | 1 |\n"
        let notification = Notification.Name(
            "RenderedContentResizeTests.finalTable.\(UUID().uuidString)"
        )
        let pane = EditorPaneModel(
            latexRenderer: AdaptiveLatexRenderer(
                updateNotification: notification
            )
        )
        let harness = makeHarness(source: source, pane: pane)
        defer { harness.close() }
        let textView = try await harness.nativeTextView()

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        let quietRestyle = expectation(
            forNotification: notification,
            object: textView
        )
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [760])
        await fulfillment(of: [quietRestyle], timeout: 2)

        let finalRestyle = expectation(
            forNotification: notification,
            object: textView
        )
        try harness.endLiveResize(for: textView)
        liveResizeActive = false
        await fulfillment(of: [finalRestyle], timeout: 2)
    }

    func testVisibleMermaidReflowsBeforeLiveResizeEnds() async throws {
        let source = Self.mermaidSource
        let renderer = testMermaidRenderer(naturalWidth: 1_000)
        let rendered = expectation(
            forNotification: renderer.updateNotification,
            object: renderer
        )
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(mermaidRenderer: renderer)
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        let anchor = (source as NSString).range(of: "flowchart").location
        await fulfillment(of: [rendered], timeout: 2)
        let initialBlock = try await harness.renderedBlock(
            in: textView,
            at: anchor
        )

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [820, 760, 700, 684])

        let containerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        let liveBlock = try await harness.renderedBlock(
            in: textView,
            at: anchor
        ) {
            $0.bounds.width <= containerWidth - 16 + 0.5
                && $0.bounds.width < initialBlock.bounds.width - 20
        }
        XCTAssertLessThan(liveBlock.bounds.width, initialBlock.bounds.width)

        try harness.endLiveResize(for: textView)
        liveResizeActive = false
    }

    func testOffscreenMermaidReflowsBeforeLiveResizeEnds() async throws {
        let source = Self.mermaidSource
            + "\n\n"
            + String(
                repeating: "Spacer paragraph keeps the document scrollable.\n\n",
                count: 160
            )
        let renderer = testMermaidRenderer(naturalWidth: 1_000)
        let rendered = expectation(
            forNotification: renderer.updateNotification,
            object: renderer
        )
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(mermaidRenderer: renderer)
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        let anchor = (source as NSString).range(of: "flowchart").location
        await fulfillment(of: [rendered], timeout: 2)
        let initialBlock = try await harness.renderedBlock(
            in: textView,
            at: anchor
        )
        try await harness.scrollPastDocumentLocation(anchor, in: textView)

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [820, 760, 700, 684])

        let containerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        _ = try await harness.renderedBlock(in: textView, at: anchor) {
            $0.bounds.width <= containerWidth - 16 + 0.5
                && $0.bounds.width < initialBlock.bounds.width - 20
        }

        try harness.endLiveResize(for: textView)
        liveResizeActive = false
    }

    func testRapidShrinkKeepsMermaidTextColumnAnchored() async throws {
        let source = Self.mermaidSource
            + "\n\nTrailing paragraph for gutter comparison."
        let renderer = testMermaidRenderer(naturalWidth: 1_000)
        let rendered = expectation(
            forNotification: renderer.updateNotification,
            object: renderer
        )
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(mermaidRenderer: renderer),
            onScreen: true
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        let anchor = (source as NSString).range(of: "flowchart").location
        await fulfillment(of: [rendered], timeout: 2)
        _ = try await harness.renderedBlock(in: textView, at: anchor)
        let inset = textView.textContainerInset
        let initialLeadingEdge = try XCTUnwrap(
            harness.onScreenLeadingEdge(in: textView, at: anchor)
        )

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(
            through: Array(stride(from: 896.0, through: 680.0, by: -8.0)),
            display: true
        )
        try harness.endLiveResize(for: textView)
        liveResizeActive = false

        let finalContainerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        _ = try await harness.renderedBlock(in: textView, at: anchor) {
            $0.bounds.width <= finalContainerWidth - 16 + 0.5
        }
        try await harness.waitUntil {
            abs(textView.textContainerOrigin.x - inset.width) <= 0.5
        }
        XCTAssertEqual(
            try XCTUnwrap(
                harness.onScreenLeadingEdge(in: textView, at: anchor)
            ),
            initialLeadingEdge,
            accuracy: 0.5
        )
    }

    func testRapidShrinkKeepsDisplayMathOriginStable() async throws {
        let source = """
        # Display Math

        Ordinary prose before the formula.

        $$
        wide_display_formula
        $$

        Ordinary prose after the formula.
        """
        let pane = EditorPaneModel(
            latexRenderer: AdaptiveLatexRenderer(
                primary: FixedWidthLatexRenderer(
                    size: CGSize(width: 760, height: 80)
                ),
                updateNotification: Notification.Name(
                    "RenderedContentResizeTests.latex.\(UUID().uuidString)"
                )
            )
        )
        let harness = makeHarness(
            source: source,
            pane: pane,
            onScreen: true
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        let anchor = (source as NSString).range(
            of: "wide_display_formula"
        ).location
        _ = try await harness.renderedBlock(in: textView, at: anchor)
        let inset = textView.textContainerInset

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        var maximumOriginDrift: CGFloat = 0
        for width in stride(from: 896.0, through: 680.0, by: -8.0) {
            await harness.resize(through: [width], display: true)
            maximumOriginDrift = max(
                maximumOriginDrift,
                abs(textView.textContainerOrigin.x - inset.width)
            )
        }
        try harness.endLiveResize(for: textView)
        liveResizeActive = false

        try await harness.waitUntil {
            abs(textView.textContainerOrigin.x - inset.width) <= 0.5
        }
        XCTAssertLessThanOrEqual(maximumOriginDrift, 0.5)
    }

    func testRewideningRecentersSmallMermaid() async throws {
        let source = Self.mermaidSource
        let renderer = testMermaidRenderer(naturalWidth: 400)
        let rendered = expectation(
            forNotification: renderer.updateNotification,
            object: renderer
        )
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(mermaidRenderer: renderer),
            size: NSSize(width: 760, height: 680)
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        let anchor = (source as NSString).range(of: "flowchart").location
        await fulfillment(of: [rendered], timeout: 2)
        _ = try await harness.renderedBlock(in: textView, at: anchor)

        await harness.resize(through: [1_000])
        let containerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        let expectedIndent = (containerWidth - 400) / 2
        try await harness.waitUntil {
            guard let glyphX = harness.glyphX(in: textView, at: anchor) else {
                return false
            }
            return abs(glyphX - expectedIndent) <= 0.5
        }
    }

    func testRapidResizePinsFirstVisibleWrappedLine() async throws {
        let source = (0..<180).map { index in
            """
            Paragraph \(index) has enough prose to wrap repeatedly as the \
            viewport narrows, changing the height of every preceding paragraph \
            without changing the reader's semantic position in the note.
            """
        }.joined(separator: "\n\n")
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(),
            onScreen: true
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        try await harness.scroll(toVerticalFraction: 0.45, in: textView)
        let anchor = try XCTUnwrap(
            FirstVisibleLineViewportAnchor.capture(in: textView)
        )

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        for width in stride(from: 888.0, through: 680.0, by: -16.0) {
            harness.resizeImmediately(to: width)
            let currentOffset = try XCTUnwrap(
                anchor.currentViewportOffset(in: textView)
            )
            XCTAssertEqual(
                currentOffset,
                anchor.viewportOffset,
                accuracy: 1,
                "The visible anchor must be restored before AppKit can draw."
            )
            harness.window.displayIfNeeded()
        }

        try harness.endLiveResize(for: textView)
        liveResizeActive = false
        try await harness.waitUntil {
            guard let currentOffset = anchor.currentViewportOffset(
                in: textView
            ) else {
                return false
            }
            return abs(currentOffset - anchor.viewportOffset) <= 1
        }
    }

    func testDelayedTableRestyleKeepsFirstVisibleLinePinned() async throws {
        let table = """
        | Legal form | Detailed formation and registration requirements | Recurring accounting taxation and compliance obligations |
        | --- | --- | --- |
        | Sole proprietorship with direct owner control | Registration filings professional advice initial licensing and local permit expenses | Bookkeeping annual accounts tax preparation regulatory renewals and continuing professional advice throughout the year |
        | Partnership governed by a negotiated agreement | Contract drafting registration filings professional advice initial licensing and local permit expenses | Ongoing administration partner reporting tax preparation regulatory renewals and continuing professional advice |
        """
        let trailingProse = (0..<150).map { index in
            """
            Section \(index) remains readable while the table above it rewraps \
            during the delayed full-restyle pass at the end of live resizing.
            """
        }.joined(separator: "\n\n")
        let source = table + "\n\n" + trailingProse
        let notification = Notification.Name(
            "RenderedContentResizeTests.anchorTable.\(UUID().uuidString)"
        )
        let harness = makeHarness(
            source: source,
            pane: EditorPaneModel(
                latexRenderer: AdaptiveLatexRenderer(
                    updateNotification: notification
                )
            ),
            onScreen: true
        )
        defer { harness.close() }
        let textView = try await harness.nativeTextView()
        try await harness.scroll(toVerticalFraction: 0.4, in: textView)
        let anchor = try XCTUnwrap(
            FirstVisibleLineViewportAnchor.capture(in: textView)
        )

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [820, 760, 700, 680], display: true)
        let finalRestyle = expectation(
            forNotification: notification,
            object: textView
        )
        try harness.endLiveResize(for: textView)
        liveResizeActive = false
        await fulfillment(of: [finalRestyle], timeout: 2)

        try await harness.waitUntil {
            guard let currentOffset = anchor.currentViewportOffset(
                in: textView
            ) else {
                return false
            }
            return abs(currentOffset - anchor.viewportOffset) <= 1
        }
    }

    private func makeHarness(
        source: String,
        pane: EditorPaneModel,
        size: NSSize = NSSize(width: 900, height: 680),
        onScreen: Bool = false
    ) -> EditorResizeTestHarness {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        return EditorResizeTestHarness(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf
            ),
            size: size,
            onScreen: onScreen
        )
    }

    private func testMermaidRenderer(naturalWidth: CGFloat) -> MermaidRenderer {
        MermaidRenderer(
            backend: FixedMermaidBackend(
                naturalSize: CGSize(width: naturalWidth, height: 400)
            ),
            updateNotification: Notification.Name(
                "RenderedContentResizeTests.mermaid.\(UUID().uuidString)"
            )
        )
    }

    private static let mermaidSource = """
    # Diagram

    ```mermaid
    flowchart LR
        Source --> Renderer --> Viewport
    ```
    """
}

@MainActor
private final class FixedMermaidBackend: MermaidRenderingBackend {
    private let output: MermaidRenderedOutput

    init(naturalSize: CGSize) {
        output = MermaidRenderedOutput(
            diagram: MermaidRenderedDiagram(
                image: NSImage(size: naturalSize),
                naturalSize: naturalSize
            ),
            cacheCost: 1_024
        )
    }

    func render(source: String) async -> MermaidRenderOutcome {
        .rendered(output)
    }
}

private struct FixedWidthLatexRenderer: LatexRenderer {
    let size: CGSize

    func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        LatexRenderResult(
            image: NSImage(size: size),
            size: size,
            baselineOffset: 0
        )
    }
}
