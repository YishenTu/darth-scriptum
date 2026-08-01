import AppKit
import SwiftUI
import XCTest
@testable import DarthScriptum

@MainActor
final class EditorResizeTestHarness {
    let hostingController: NSHostingController<AnyView>
    let window: NSWindow

    init<V: View>(
        rootView: V,
        size: NSSize = NSSize(width: 900, height: 680),
        onScreen: Bool = false
    ) {
        hostingController = NSHostingController(rootView: AnyView(rootView))
        window = NSWindow(contentViewController: hostingController)
        window.minSize = NSSize(width: 680, height: 440)
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(size)
        if onScreen {
            window.orderFrontRegardless()
            window.displayIfNeeded()
        } else {
            window.layoutIfNeeded()
        }
    }

    var rootView: NSView {
        hostingController.view
    }

    func close() {
        window.orderOut(nil)
    }

    func nativeTextView() async throws -> NSTextView {
        try await nativeTextViews(count: 1)[0]
    }

    func nativeTextViews(count: Int) async throws -> [NSTextView] {
        try await waitUntil {
            self.window.layoutIfNeeded()
            let textViews = MarkdownEngineCompatibility.nativeTextViews(
                in: self.rootView
            )
            guard textViews.count == count,
                  textViews.allSatisfy({ $0.identifier != nil }) else {
                return nil
            }
            return textViews
        }
    }

    func beginLiveResize(for textView: NSTextView) throws {
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        try XCTUnwrap(textView.enclosingScrollView).viewWillStartLiveResize()
    }

    func endLiveResize(for textView: NSTextView) throws {
        try XCTUnwrap(textView.enclosingScrollView).viewDidEndLiveResize()
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    func resize(
        through widths: [CGFloat],
        display: Bool = false
    ) async {
        for width in widths {
            resizeImmediately(to: width, display: display)
            await nextMainQueueTurn()
        }
    }

    func resizeImmediately(
        to width: CGFloat,
        display: Bool = false
    ) {
        let contentHeight = window.contentView?.bounds.height ?? 680
        window.setContentSize(
            NSSize(width: width, height: contentHeight)
        )
        window.layoutIfNeeded()
        if display {
            window.displayIfNeeded()
        }
    }

    func renderedBlock(
        in textView: NSTextView,
        at location: Int,
        satisfying predicate:
            @escaping (MarkdownEngineCompatibility.RenderedBlock) -> Bool = {
                _ in true
            }
    ) async throws -> MarkdownEngineCompatibility.RenderedBlock {
        try await waitUntil {
            guard let block = textView.textStorage.flatMap({
                MarkdownEngineCompatibility.renderedBlock(
                    in: $0,
                    at: location
                )
            }), predicate(block) else {
                return nil
            }
            return block
        }
    }

    func glyphX(in textView: NSTextView, at location: Int) -> CGFloat? {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager
                as? NSTextContentStorage,
              let start = contentStorage.location(
                  contentStorage.documentRange.location,
                  offsetBy: location
              ) else {
            return nil
        }
        var glyphX: CGFloat?
        layoutManager.enumerateTextLayoutFragments(
            from: start,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentStart = contentStorage.offset(
                from: contentStorage.documentRange.location,
                to: fragment.rangeInElement.location
            )
            for lineFragment in fragment.textLineFragments {
                let range = lineFragment.characterRange
                let local = location - fragmentStart
                if local >= range.location,
                   local < range.location + range.length {
                    glyphX = fragment.layoutFragmentFrame.origin.x
                        + lineFragment.typographicBounds.origin.x
                        + lineFragment.locationForCharacter(at: local).x
                }
            }
            return false
        }
        return glyphX
    }

    func onScreenLeadingEdge(
        in textView: NSTextView,
        at location: Int
    ) -> CGFloat? {
        guard let glyphX = glyphX(in: textView, at: location),
              let clipView = textView.enclosingScrollView?.contentView else {
            return nil
        }
        return textView.textContainerOrigin.x + glyphX
            - clipView.bounds.origin.x
    }

    func scrollPastDocumentLocation(
        _ location: Int,
        in textView: NSTextView
    ) async throws {
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        window.layoutIfNeeded()
        let bottomY = max(
            0,
            (scrollView.documentView?.bounds.height ?? 0)
                - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        layoutManager.textViewportLayoutController.layoutViewport()
        try await waitUntil {
            guard let viewportRange = layoutManager
                .textViewportLayoutController.viewportRange else {
                return false
            }
            let viewportLocation = layoutManager.offset(
                from: layoutManager.documentRange.location,
                to: viewportRange.location
            )
            return viewportLocation > location
        }
    }

    func scroll(
        toVerticalFraction fraction: CGFloat,
        in textView: NSTextView
    ) async throws {
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        window.layoutIfNeeded()
        let clipView = scrollView.contentView
        let maximumY = max(
            0,
            (scrollView.documentView?.bounds.height ?? 0)
                - clipView.bounds.height
        )
        let targetY = maximumY * min(max(fraction, 0), 1)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        layoutManager.textViewportLayoutController.layoutViewport()
        try await waitUntil {
            abs(clipView.bounds.minY - targetY) <= 1
        }
    }

    func waitUntil<Value>(
        timeout: Duration = .seconds(3),
        _ terminalValue: @escaping @MainActor () -> Value?
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let value = terminalValue() {
                return value
            }
            // Suspend briefly instead of continuously re-enqueuing work on the
            // main dispatch queue. The resize implementation deliberately uses
            // run-loop timers and deferred layout callbacks; a busy polling
            // loop can otherwise prevent the state it is observing from ever
            // being delivered.
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for editor resize state.")
        throw EditorResizeTestError.timeout
    }

    func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let _: Bool = try await waitUntil(timeout: timeout) {
            condition() ? true : nil
        }
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

private enum EditorResizeTestError: Error {
    case timeout
}
