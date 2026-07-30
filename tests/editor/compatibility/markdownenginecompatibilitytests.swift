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
}

@MainActor
private final class SelectionObserver: NSObject {
    private(set) var notificationCount = 0

    @objc func selectionDidChange(_ notification: Notification) {
        notificationCount += 1
    }
}
