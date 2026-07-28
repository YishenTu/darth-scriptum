import AppKit
import SwiftUI
import XCTest
@testable import DarthScriptum

@MainActor
final class MermaidRendererTests: XCTestCase {
    func testParserFindsBacktickTildeAndCRLFFences() throws {
        let source = """
        before

        ```swift
        let ignored = true
        ```

          ```Mermaid title
        flowchart LR
          A --> B
          ```

        ~~~~mermaid\r
        sequenceDiagram\r
          Alice->>Bob: Hello\r
        ~~~~\r
        after
        """

        let blocks = MermaidFencedBlockParser.blocks(in: source)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(
            blocks[0].source,
            "flowchart LR\n  A --> B\n"
        )
        XCTAssertEqual(
            blocks[1].source,
            "sequenceDiagram\r\n  Alice->>Bob: Hello\r\n"
        )
        XCTAssertTrue(
            (source as NSString)
                .substring(with: blocks[0].fullRange)
                .hasPrefix("  ```Mermaid")
        )
        XCTAssertTrue(
            (source as NSString)
                .substring(with: blocks[1].fullRange)
                .hasSuffix("~~~~")
        )
    }

    func testParserLeavesUnclosedAndEmptyBlocksAsSource() {
        let unclosed = """
        ```mermaid
        flowchart LR
        """
        let empty = """
        ```mermaid

        ```
        """

        XCTAssertTrue(
            MermaidFencedBlockParser.blocks(in: unclosed).isEmpty
        )
        XCTAssertTrue(
            MermaidFencedBlockParser.blocks(in: empty).isEmpty
        )
    }

    func testRendererDeduplicatesAndCachesSuccessfulRender() async throws {
        let backend = StubMermaidBackend(outcome: .rendered(Self.output()))
        let renderer = MermaidRenderer(backend: backend)
        let source = "flowchart LR\nA --> B"

        XCTAssertNil(renderer.diagram(for: source))
        XCTAssertNil(renderer.diagram(for: source))
        try await waitUntil {
            renderer.diagram(for: source) != nil
        }

        XCTAssertEqual(backend.callCount, 1)
        XCTAssertNotNil(renderer.diagram(for: source))
        XCTAssertEqual(backend.callCount, 1)
    }

    func testRendererRejectsOversizedInputBeforeBackend() async {
        let backend = StubMermaidBackend(outcome: .rendered(Self.output()))
        let renderer = MermaidRenderer(backend: backend)
        let oversized = String(
            repeating: "x",
            count: MermaidRenderer.maximumSourceUTF8Bytes + 1
        )

        XCTAssertNil(renderer.diagram(for: oversized))
        await Task.yield()
        XCTAssertEqual(backend.callCount, 0)
    }

    func testRendererBoundsPendingWork() {
        let backend = StubMermaidBackend(
            outcome: .unsupported,
            delay: .milliseconds(100)
        )
        let renderer = MermaidRenderer(backend: backend)

        for index in 0..<(MermaidRenderer.maximumPendingEntries + 10) {
            XCTAssertNil(
                renderer.diagram(
                    for: "flowchart LR\nA\(index) --> B\(index)"
                )
            )
        }

        XCTAssertEqual(
            renderer.pendingEntryCountForTesting,
            MermaidRenderer.maximumPendingEntries
        )
    }

    func testPresenterPreservesSourceAndAddsRenderedImage() async throws {
        let backend = StubMermaidBackend(outcome: .rendered(Self.output()))
        let renderer = MermaidRenderer(backend: backend)
        let presenter = MermaidBlockPresenter(renderer: renderer)
        let source = """
        before

        ```mermaid
        flowchart LR
          A --> B
        ```

        after
        """
        let textView = makeTextView(source: source)
        textView.setSelectedRange(
            NSRange(location: (source as NSString).length, length: 0)
        )

        presenter.apply(to: textView, rendersMarkdown: true)
        try await waitUntil {
            renderer.diagram(for: "flowchart LR\n  A --> B\n") != nil
        }
        presenter.apply(to: textView, rendersMarkdown: true)

        let anchor = (source as NSString).range(of: "flowchart").location
        XCTAssertNotNil(
            textView.textStorage?.attribute(
                NSAttributedString.Key("LatexRenderedImage"),
                at: anchor,
                effectiveRange: nil
            ) as? NSImage
        )
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: (source as NSString).range(of: "```mermaid").location,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.clear
        )
    }

    func testPresenterDoesNotRenderActiveOrRawSourceBlocks() async {
        let backend = StubMermaidBackend(outcome: .rendered(Self.output()))
        let renderer = MermaidRenderer(backend: backend)
        let presenter = MermaidBlockPresenter(renderer: renderer)
        let source = """
        ```mermaid
        flowchart LR
        A --> B
        ```
        """
        let activeTextView = makeTextView(source: source)
        activeTextView.setSelectedRange(
            NSRange(
                location: (source as NSString).range(of: "flowchart").location,
                length: 0
            )
        )

        presenter.apply(to: activeTextView, rendersMarkdown: true)
        presenter.apply(
            to: makeTextView(source: source),
            rendersMarkdown: false
        )
        await Task.yield()

        XCTAssertEqual(backend.callCount, 0)
        XCTAssertEqual(activeTextView.string, source)
    }

    func testLivePreviewRendersThenRevealsMermaidSourceForEditing() async throws {
        let backend = StubMermaidBackend(outcome: .rendered(Self.output()))
        let renderer = MermaidRenderer(backend: backend)
        let pane = EditorPaneModel(mermaidRenderer: renderer)
        let source = """
        before

        ```mermaid
        flowchart LR
          Spot --> Payoff
        ```

        after
        """
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let hostingView = NSHostingView(
            rootView: LivePreviewTextView(
                sourceBuffer: buffer,
                pane: pane,
                sourceMode: false,
                fontSize: 14,
                newlineStyle: .lf
            )
            .frame(width: 640, height: 360)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
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
        let anchor = (source as NSString).range(of: "flowchart").location
        try await waitUntil {
            textView.textStorage?.attribute(
                NSAttributedString.Key("LatexRenderedImage"),
                at: anchor,
                effectiveRange: nil
            ) is NSImage
        }

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(buffer.revision.text, source)

        textView.setSelectedRange(NSRange(location: anchor, length: 0))
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        try await waitUntil {
            textView.textStorage?.attribute(
                NSAttributedString.Key("LatexRenderedImage"),
                at: anchor,
                effectiveRange: nil
            ) == nil
        }

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(buffer.revision.text, source)
        _ = window
    }

    func testBundledWebRendererRasterizesFlowchartInWebKit() async throws {
        let renderer = MermaidWebRenderer()

        let outcome = await renderer.render(
            source: """
            flowchart LR
                Spot["Spot today"] --> Payoff["Option payoff"]
            """
        )
        let output = try XCTUnwrap(
            outcome.output,
            renderer.lastError ?? "Mermaid did not provide an error."
        )

        XCTAssertGreaterThan(output.diagram.naturalSize.width, 0)
        XCTAssertGreaterThan(output.diagram.naturalSize.height, 0)
        XCTAssertGreaterThan(output.diagram.image.size.width, 0)
        XCTAssertTrue(
            output.diagram.image.representations.contains {
                $0 is NSBitmapImageRep
            },
            "Mermaid output must be rasterized by WebKit so SVG text layout "
                + "is not reinterpreted by AppKit."
        )
        let svg = try XCTUnwrap(renderer.lastSVGForTesting)
        XCTAssertTrue(svg.contains("dominant-baseline: auto"))
        XCTAssertTrue(svg.contains("alignment-baseline: baseline"))
        XCTAssertFalse(svg.contains(#"dominant-baseline="central""#))
        XCTAssertFalse(svg.contains(#"alignment-baseline="central""#))
    }

    func testBundledWebRendererRecoversAfterInvalidDiagram() async {
        let renderer = MermaidWebRenderer()

        let invalid = await renderer.render(
            source: "flowchart LR\nA -- broken"
        )
        guard case .unsupported = invalid else {
            return XCTFail(
                renderer.lastError ?? "Invalid Mermaid source was accepted."
            )
        }

        let valid = await renderer.render(
            source: "sequenceDiagram\nAlice->>Bob: Price"
        )
        XCTAssertNotNil(
            valid.output,
            renderer.lastError ?? "Renderer did not recover."
        )
    }

    func testMermaidResourcesArePinnedAndNetworkDisabled() throws {
        let rendererURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "mermaid-renderer",
                withExtension: "html"
            )
        )
        let html = try String(contentsOf: rendererURL, encoding: .utf8)
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("worker-src 'none'"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("http://"))

        let scriptURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "mermaid-renderer",
                withExtension: "js"
            )
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains(#"securityLevel: "strict""#))
        XCTAssertTrue(script.contains("htmlLabels: false"))
        XCTAssertTrue(script.contains("maxEdges: 1000"))
        XCTAssertTrue(script.contains("normalizeTextBaselines(svg)"))
        XCTAssertTrue(script.contains(#"canvas.toDataURL("image/png")"#))

        let bundleURL = try XCTUnwrap(
            Bundle.main.resourceURL?
                .appendingPathComponent("Mermaid.bundle", isDirectory: true)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent("mermaid.min.js")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("LICENSE").path
            )
        )
        let packageData = try Data(
            contentsOf: bundleURL.appendingPathComponent("package.json")
        )
        let package = try XCTUnwrap(
            JSONSerialization.jsonObject(with: packageData)
                as? [String: Any]
        )
        XCTAssertEqual(package["version"] as? String, "11.16.0")
        XCTAssertEqual(package["license"] as? String, "MIT")
    }

    private static func output() -> MermaidRenderedOutput {
        let size = CGSize(width: 240, height: 120)
        return MermaidRenderedOutput(
            diagram: MermaidRenderedDiagram(
                image: NSImage(size: size),
                naturalSize: size
            ),
            cacheCost: 1_024
        )
    }

    private func makeTextView(source: String) -> NSTextView {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        textView.string = source
        textView.textContainer?.size = CGSize(
            width: 600,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributes(
            [
                .font: AppTheme.editorFont(size: 14),
                .foregroundColor: AppTheme.foreground,
                .paragraphStyle: AppTheme.bodyParagraphStyle(fontSize: 14)
            ],
            range: NSRange(location: 0, length: (source as NSString).length)
        )
        return textView
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Mermaid state.")
    }

    private func descendantTextViews(in view: NSView) -> [NSTextView] {
        if let textView = view as? NSTextView {
            return [textView]
        }
        return view.subviews.flatMap(descendantTextViews)
    }
}

@MainActor
private final class StubMermaidBackend: MermaidRenderingBackend {
    private(set) var callCount = 0
    private let outcome: MermaidRenderOutcome
    private let delay: Duration

    init(
        outcome: MermaidRenderOutcome,
        delay: Duration = .zero
    ) {
        self.outcome = outcome
        self.delay = delay
    }

    func render(source: String) async -> MermaidRenderOutcome {
        callCount += 1
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return outcome
    }
}

private extension MermaidRenderOutcome {
    var output: MermaidRenderedOutput? {
        if case let .rendered(output) = self {
            return output
        }
        return nil
    }
}
