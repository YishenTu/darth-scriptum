import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class EditorViewportResizeObserverTests: XCTestCase {
    func testRapidFrameChangesEmitEveryImmediateWidthAndOneQuietWidth()
        async throws
    {
        let clipView = NSClipView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 680)
        )
        let window = NSWindow()
        let observer = EditorViewportResizeObserver(quietInterval: 0.01)
        defer { observer.stop() }

        var immediateWidths: [CGFloat] = []
        var liveResizeStartWidths: [CGFloat] = []
        var quietWidths: [CGFloat] = []
        var finalWidths: [CGFloat] = []
        let quietUpdate = expectation(description: "quiet resize update")
        observer.onImmediateWidthChange = { width in
            immediateWidths.append(width)
        }
        observer.onLiveResizeWillStart = { width in
            liveResizeStartWidths.append(width)
        }
        observer.onSettledUpdate = { update in
            switch update {
            case .liveQuiet(let viewportWidth):
                quietWidths.append(viewportWidth)
                quietUpdate.fulfill()
            case .liveEnded(let viewportWidth):
                finalWidths.append(viewportWidth)
            case .ordinary:
                break
            }
        }
        observer.attach(clipView: clipView, window: window)
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        XCTAssertEqual(liveResizeStartWidths, [900])

        for width in stride(from: 899.0, through: 680.0, by: -1.0) {
            clipView.setFrameSize(NSSize(width: width, height: 680))
        }

        XCTAssertEqual(try XCTUnwrap(immediateWidths.last), 680, accuracy: 0.5)
        await fulfillment(of: [quietUpdate], timeout: 2)
        XCTAssertEqual(quietWidths.count, 1)
        XCTAssertEqual(try XCTUnwrap(quietWidths.first), 680, accuracy: 0.5)

        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        XCTAssertEqual(try XCTUnwrap(finalWidths.first), 680, accuracy: 0.5)
    }

    func testOrdinaryFrameBurstEmitsOneStartAndOneSettledWidth()
        async throws
    {
        let clipView = NSClipView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 680)
        )
        let observer = EditorViewportResizeObserver(quietInterval: 0.01)
        defer { observer.stop() }

        var startWidths: [CGFloat] = []
        var immediateWidths: [CGFloat] = []
        var settledWidths: [CGFloat] = []
        let settled = expectation(description: "ordinary resize settled")
        observer.onOrdinaryResizeWillStart = { width in
            startWidths.append(width)
        }
        observer.onImmediateWidthChange = { width in
            immediateWidths.append(width)
        }
        observer.onSettledUpdate = { update in
            guard case .ordinary(let viewportWidth) = update else { return }
            settledWidths.append(viewportWidth)
            settled.fulfill()
        }
        observer.attach(clipView: clipView, window: nil)

        for width in stride(from: 899.0, through: 680.0, by: -1.0) {
            clipView.setFrameSize(NSSize(width: width, height: 680))
        }

        XCTAssertEqual(startWidths, [899])
        XCTAssertEqual(try XCTUnwrap(immediateWidths.last), 680, accuracy: 0.5)
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(settledWidths, [680])
    }
}
