import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownWorkspaceResizeTests: XCTestCase {
    func testTableWidthSettlesImmediatelyWhenLiveResizeEnds() async throws {
        let source = """
            Introductory paragraph.

            | Position | Market view | Maximum loss at expiry | Upside at expiry |
            |:--|:--|--:|:--|
            | Long call | Bullish, with limited downside | Premium paid | Theoretically unlimited |
            | Short call | Neutral or bearish | Theoretically unlimited | Premium received |
            | Long put | Bearish or protective | Premium paid | Limited by zero underlying price |
            | Short put | Neutral or bullish | Large but limited | Premium received |

            Trailing paragraph.
            """
        let (harness, syncCoordinator, _) = makeHarness(source: source)
        defer {
            harness.close()
            syncCoordinator.close()
        }
        let textView = try await harness.nativeTextView()
        let location = (source as NSString).range(of: "| Position").location
        await harness.resize(through: [1_600], display: true)
        let initialWidth = try XCTUnwrap(textView.textContainer?.size.width)
        let initialTable = try await harness.renderedBlock(
            in: textView,
            at: location
        ) {
            $0.bounds.width > 800 && $0.bounds.width < initialWidth
        }
        let naturalWidth = initialTable.bounds.width
        let textStorage = try XCTUnwrap(textView.textStorage)
        try harness.beginLiveResize(for: textView)

        for windowWidth in [900.0, 820, 680, 740, 928, 1_120, 760] {
            // Retain the same image while dragging, even when layout runs.
            harness.resizeImmediately(to: windowWidth, display: true)
            let table = try XCTUnwrap(
                MarkdownEngineCompatibility.renderedBlock(
                    in: textStorage,
                    at: location
                )
            )
            XCTAssertTrue(table.image === initialTable.image)
            XCTAssertEqual(textView.string, source)
        }
        try harness.endLiveResize(for: textView)
        let containerWidth = try XCTUnwrap(textView.textContainer?.size.width)
        let settled = try XCTUnwrap(
            MarkdownEngineCompatibility.renderedBlock(in: textStorage, at: location)
        )
        XCTAssertEqual(settled.bounds.width, min(naturalWidth, containerWidth), accuracy: 2)
        XCTAssertEqual(textView.string, source)
    }

    func testVisibleTableRewrapsWhenLiveResizeEnds() async throws {
        let (harness, syncCoordinator, _) = makeHarness(
            source: Self.tableSource
        )
        defer {
            harness.close()
            syncCoordinator.close()
        }
        let textView = try await harness.nativeTextView()
        let tableLocation = (Self.tableSource as NSString).range(
            of: "| Legal form"
        ).location
        let initialBlock = try await harness.renderedBlock(
            in: textView,
            at: tableLocation
        )
        let initialContainerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )

        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [820, 760])

        let liveBlock = try XCTUnwrap(
            MarkdownEngineCompatibility.renderedBlock(
                in: try XCTUnwrap(textView.textStorage), at: tableLocation
            )
        )
        XCTAssertTrue(liveBlock.image === initialBlock.image)

        await harness.resize(through: [700, 680])
        try harness.endLiveResize(for: textView)
        liveResizeActive = false

        let finalContainerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        let finalBlock = try await harness.renderedBlock(
            in: textView,
            at: tableLocation
        ) {
            $0.bounds.width <= finalContainerWidth + 0.5
                && $0.bounds.width < initialBlock.bounds.width - 20
        }
        XCTAssertLessThan(finalContainerWidth, initialContainerWidth)
        XCTAssertLessThan(finalBlock.bounds.width, initialBlock.bounds.width)
    }

    func testOffscreenTableRewrapsWhenLiveResizeEnds() async throws {
        let source =
            Self.tableSource
            + "\n\n"
            + String(
                repeating: "Spacer paragraph keeps the document scrollable.\n\n",
                count: 160
            )
        let (harness, syncCoordinator, _) = makeHarness(source: source)
        defer {
            harness.close()
            syncCoordinator.close()
        }
        let textView = try await harness.nativeTextView()
        let tableLocation = (source as NSString).range(of: "| Legal form").location

        // Establish a deterministic wide baseline after the coordinator is
        // attached. The hosting view can initially present the table at its
        // minimum width before the requested window size finishes settling.
        await harness.resize(through: [1_000])
        let initialContainerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        let initialBlock = try await harness.renderedBlock(
            in: textView,
            at: tableLocation
        ) {
            $0.bounds.width <= initialContainerWidth + 0.5
                && $0.bounds.width >= initialContainerWidth - 4
        }
        try await harness.scrollPastDocumentLocation(
            NSMaxRange(
                (source as NSString).range(
                    of: Self.tableSource
                )
            ),
            in: textView
        )
        var liveResizeActive = false
        defer {
            if liveResizeActive {
                try? harness.endLiveResize(for: textView)
            }
        }
        try harness.beginLiveResize(for: textView)
        liveResizeActive = true
        await harness.resize(through: [820, 760, 700, 680])

        try harness.endLiveResize(for: textView)
        liveResizeActive = false

        let containerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        let currentBlock = try await harness.renderedBlock(
            in: textView,
            at: tableLocation
        ) {
            $0.bounds.width <= containerWidth + 0.5
                && $0.bounds.width < initialBlock.bounds.width - 20
        }
        XCTAssertLessThanOrEqual(
            currentBlock.bounds.width,
            containerWidth + 0.5
        )
        XCTAssertLessThan(
            currentBlock.bounds.width,
            initialBlock.bounds.width - 20
        )
    }

    private func makeHarness(
        source: String
    ) -> (
        EditorResizeTestHarness,
        DocumentSyncCoordinator,
        WorkspaceModel
    ) {
        let syncCoordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(
                text: source,
                format: .newDocument
            )
        )
        let model = WorkspaceModel()
        let harness = EditorResizeTestHarness(
            rootView: MarkdownWorkspace(
                syncCoordinator: syncCoordinator,
                model: model,
                fileName: "table-resize.md"
            )
        )
        return (harness, syncCoordinator, model)
    }

    private static let tableSource = """
        # Option Pricing

        Ordinary prose should keep equal gutters during a rapid resize.

        | Legal form | Detailed formation and registration requirements | Recurring accounting taxation and compliance obligations |
        | --- | --- | --- |
        | Sole proprietorship with direct owner control | Registration filings professional advice initial licensing and local permit expenses | Bookkeeping annual accounts tax preparation regulatory renewals and continuing professional advice throughout the year |
        | Partnership governed by a negotiated agreement | Contract drafting registration filings professional advice initial licensing and local permit expenses | Ongoing administration partner reporting tax preparation regulatory renewals and continuing professional advice |
        """
}
