import AppKit
import XCTest
@testable import DarthScriptum

@MainActor
final class MarkdownWorkspaceResizeTests: XCTestCase {
    func testVisibleTableRewrapsDuringLiveResize() async throws {
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

        let liveContainerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        _ = try await harness.renderedBlock(
            in: textView,
            at: tableLocation
        ) {
            $0.bounds.width <= liveContainerWidth + 0.5
                && $0.bounds.width < initialBlock.bounds.width - 20
        }

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

    func testOffscreenTableRewrapsDuringLiveResize() async throws {
        let source = Self.tableSource
            + "\n\n"
            + String(
                repeating: "Spacer paragraph keeps the document scrollable.\n\n",
                count: 160
            )
        let (harness, syncCoordinator, model) = makeHarness(source: source)
        defer {
            harness.close()
            syncCoordinator.close()
        }
        let textView = try await harness.nativeTextView()
        let tableLocation = (source as NSString).range(of: "| Legal form").location
        let initialBlock = try await harness.renderedBlock(
            in: textView,
            at: tableLocation
        )
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
        let restyled = expectation(
            forNotification:
                model.primaryPane.latexRenderer.updateNotification,
            object: textView
        )
        await harness.resize(through: [820, 760, 700, 680])
        await fulfillment(of: [restyled], timeout: 2)

        let containerWidth = try XCTUnwrap(
            textView.textContainer?.containerSize.width
        )
        let currentBlock = try XCTUnwrap(
            textView.textStorage.flatMap {
                MarkdownEngineCompatibility.renderedBlock(
                    in: $0,
                    at: tableLocation
                )
            }
        )
        XCTAssertEqual(
            currentBlock.bounds.width,
            containerWidth,
            accuracy: 1
        )
        XCTAssertGreaterThan(
            abs(currentBlock.bounds.width - initialBlock.bounds.width),
            20
        )

        try harness.endLiveResize(for: textView)
        liveResizeActive = false
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
