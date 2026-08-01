import AppKit
import MarkdownEngine
import SwiftUI
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownEngineCompatibilityTests: XCTestCase {
    func testDiscoversNativeTextViewThroughPublicWrapperHierarchy() async throws {
        let source = "# Compatibility"
        let hostingView = NSHostingView(
            rootView: AnyView(
                NativeTextViewWrapper(
                    text: .constant(source),
                    configuration: .default,
                    fontName: "Helvetica",
                    fontSize: 14,
                    documentId: "compatibility-test"
                )
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        try await waitUntil {
            MarkdownEngineCompatibility.nativeTextView(in: hostingView) != nil
        }
        let textView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextView(in: hostingView)
        )

        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(
            MarkdownEngineCompatibility.nativeTextViews(in: hostingView).count,
            1
        )
        _ = window
    }

    func testNativeTextViewDiscoveryFailsClosedForMissingOrChangedHierarchy() {
        let missingHierarchy = NSView()
        XCTAssertNil(
            MarkdownEngineCompatibility.nativeTextView(in: missingHierarchy)
        )

        let changedHierarchy = NSScrollView()
        let documentView = NSView()
        documentView.addSubview(NSTextView())
        documentView.addSubview(NSTextView())
        changedHierarchy.documentView = documentView

        XCTAssertTrue(
            MarkdownEngineCompatibility.nativeTextViews(
                in: changedHierarchy
            ).isEmpty
        )
        XCTAssertNil(
            MarkdownEngineCompatibility.nativeTextView(in: changedHierarchy)
        )
    }

    func testSelectionObservationCanBeTornDown() {
        let textView = NSTextView()
        let observer = SelectionObserver()

        MarkdownEngineCompatibility.beginObservingSelection(
            of: textView,
            observer: observer,
            selector: #selector(SelectionObserver.selectionDidChange(_:))
        )
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        XCTAssertEqual(observer.notificationCount, 1)

        MarkdownEngineCompatibility.endObservingSelection(
            of: textView,
            observer: observer
        )
        NotificationCenter.default.post(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        XCTAssertEqual(observer.notificationCount, 1)
    }

    func testBlockImageAttributesRoundTripThroughCompatibilitySurface() throws {
        let storage = NSTextStorage(string: "diagram")
        let image = NSImage(size: NSSize(width: 120, height: 80))
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        let range = NSRange(location: 0, length: 1)

        MarkdownEngineCompatibility.applyRenderedBlockImage(
            image,
            bounds: bounds,
            sourceIdentity: 42,
            displayWidth: 120,
            to: storage,
            range: range
        )

        let attributes = try XCTUnwrap(
            MarkdownEngineCompatibility.renderedBlock(
                in: storage,
                at: range.location
            )
        )
        XCTAssertTrue(attributes.image === image)
        XCTAssertEqual(attributes.bounds, bounds)
        XCTAssertTrue(attributes.isBlock)
        XCTAssertEqual(attributes.sourceIdentity, 42)
        XCTAssertEqual(attributes.displayWidth, 120)
        XCTAssertTrue(
            MarkdownEngineCompatibility.containsRenderedImage(
                in: storage,
                range: range
            )
        )
    }

    func testCenteredRenderedBlockIsLeftPinnedAndRecentersAtNewWidth() throws {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200)
        )
        let storage = try XCTUnwrap(textView.textStorage)
        storage.setAttributedString(NSAttributedString(string: "formula\n"))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        storage.addAttribute(
            .paragraphStyle,
            value: centered,
            range: NSRange(location: 0, length: storage.length)
        )
        MarkdownEngineCompatibility.applyRenderedBlockImage(
            NSImage(size: NSSize(width: 200, height: 60)),
            bounds: CGRect(x: 0, y: 0, width: 200, height: 60),
            sourceIdentity: 1,
            displayWidth: 200,
            to: storage,
            range: NSRange(location: 0, length: 1)
        )
        textView.textContainer?.containerSize = NSSize(
            width: 300,
            height: CGFloat.greatestFiniteMagnitude
        )

        XCTAssertTrue(
            MarkdownEngineCompatibility.stabilizeCenteredRenderedBlocks(
                in: textView
            )
        )
        var paragraph = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.alignment, .left)
        XCTAssertEqual(paragraph.headIndent, 50, accuracy: 0.5)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 50, accuracy: 0.5)

        XCTAssertTrue(
            MarkdownEngineCompatibility.stabilizeCenteredRenderedBlocks(
                in: textView,
                viewportWidth: 160
            )
        )
        paragraph = try XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.alignment, .left)
        XCTAssertEqual(paragraph.headIndent, 0, accuracy: 0.5)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 0, accuracy: 0.5)
    }

    func testTableCandidateDetectionMatchesOuterPipeSourceSyntax() {
        XCTAssertTrue(
            MarkdownEngineCompatibility.containsTableCandidate(
                in: "| Name | Value |\n| --- | ---: |\n| A | 1 |\n"
            )
        )
        XCTAssertTrue(
            MarkdownEngineCompatibility.containsTableCandidate(
                in: "  | Name | Value |  \r\n  | --- | ---: |  \r\n"
            )
        )
        XCTAssertFalse(
            MarkdownEngineCompatibility.containsTableCandidate(
                in: "$$\n|x|\n$$\n"
            )
        )
        XCTAssertFalse(
            MarkdownEngineCompatibility.containsTableCandidate(
                in: "| Name | Value |\n| not | a separator |\n"
            )
        )
    }

    func testFileDropWhenAllURLsAreMarkdownOpensDocumentsWithoutFallback() {
        let textView = NSTextView()
        let urls = [
            URL(fileURLWithPath: "/tmp/first.md"),
            URL(fileURLWithPath: "/tmp/SECOND.MARKDOWN"),
            URL(fileURLWithPath: "/tmp/third.mdown"),
        ]
        var openedURLs: [URL] = []
        var fallbackCallCount = 0
        MarkdownEngineCompatibility.setMarkdownFileDropHandler(
            on: textView
        ) {
            openedURLs = $0
        }
        defer {
            MarkdownEngineCompatibility.removeMarkdownFileDropHandler(
                from: textView
            )
        }

        let didHandle = MarkdownEngineCompatibility.performFileDrop(
            on: textView,
            pasteboard: filePasteboard(containing: urls)
        ) {
            fallbackCallCount += 1
            return false
        }

        XCTAssertTrue(didHandle)
        XCTAssertEqual(openedURLs, urls)
        XCTAssertEqual(fallbackCallCount, 0)
    }

    func testNativeDragOperationWhenURLIsMarkdownUsesRegisteredHandler() {
        let textView = NSTextView()
        let url = URL(fileURLWithPath: "/tmp/native-drop.md")
        var openedURLs: [URL] = []
        MarkdownEngineCompatibility.setMarkdownFileDropHandler(
            on: textView
        ) {
            openedURLs = $0
        }
        defer {
            MarkdownEngineCompatibility.removeMarkdownFileDropHandler(
                from: textView
            )
        }

        let didHandle = textView.performDragOperation(
            DraggingInfoStub(
                pasteboard: filePasteboard(containing: [url])
            )
        )

        XCTAssertTrue(didHandle)
        XCTAssertEqual(openedURLs, [url])
    }

    func testFileDropWhenURLIsNonMarkdownPreservesNativePathInsertion() {
        let textView = NSTextView()
        let url = URL(fileURLWithPath: "/tmp/diagram.png")
        let pasteboard = filePasteboard(containing: [url])
        var openedURLs: [URL] = []
        var fallbackCallCount = 0
        MarkdownEngineCompatibility.setMarkdownFileDropHandler(
            on: textView
        ) {
            openedURLs = $0
        }
        defer {
            MarkdownEngineCompatibility.removeMarkdownFileDropHandler(
                from: textView
            )
        }

        let didHandle = MarkdownEngineCompatibility.performFileDrop(
            on: textView,
            pasteboard: pasteboard
        ) {
            fallbackCallCount += 1
            return textView.readSelection(from: pasteboard)
        }

        XCTAssertTrue(didHandle)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(fallbackCallCount, 1)
        XCTAssertEqual(textView.string, url.path)
    }

    func testFileDropWhenURLsAreMixedPreservesNativeFallback() {
        let textView = NSTextView()
        let urls = [
            URL(fileURLWithPath: "/tmp/notes.md"),
            URL(fileURLWithPath: "/tmp/diagram.png"),
        ]
        var openedURLs: [URL] = []
        var fallbackCallCount = 0
        MarkdownEngineCompatibility.setMarkdownFileDropHandler(
            on: textView
        ) {
            openedURLs = $0
        }
        defer {
            MarkdownEngineCompatibility.removeMarkdownFileDropHandler(
                from: textView
            )
        }

        let didHandle = MarkdownEngineCompatibility.performFileDrop(
            on: textView,
            pasteboard: filePasteboard(containing: urls)
        ) {
            fallbackCallCount += 1
            return true
        }

        XCTAssertTrue(didHandle)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(fallbackCallCount, 1)
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
        XCTFail("Timed out waiting for the MarkdownEngine wrapper hierarchy.")
    }

    private func filePasteboard(containing urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("MarkdownFileDrop.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]))
        return pasteboard
    }
}

@MainActor
private final class SelectionObserver: NSObject {
    private(set) var notificationCount = 0

    @objc func selectionDidChange(_ notification: Notification) {
        notificationCount += 1
    }
}

@MainActor
private final class DraggingInfoStub: NSObject, @MainActor NSDraggingInfo {
    typealias EnumerationStop = UnsafeMutablePointer<ObjCBool>
    typealias EnumerationBlock = (
        NSDraggingItem,
        Int,
        EnumerationStop
    ) -> Void

    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 0
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(
        atDestination dropDestination: URL
    ) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping EnumerationBlock
    ) {}

    func resetSpringLoading() {}
}
