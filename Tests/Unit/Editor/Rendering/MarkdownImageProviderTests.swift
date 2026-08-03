import AppKit
import CoreGraphics
import ImageIO
import MarkdownEngine
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownImageProviderTests: XCTestCase {
    func testCacheMissReturnsImmediatelyAndDuplicateRequestsCoalesceOffMain()
        async throws
    {
        let loader = BlockingMarkdownImageLoader(
            results: [Self.decodedImage(red: 255)],
            startsBlocked: true
        )
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(loader: loader, updates: updates)
        let request = EmbeddedImageRequest(name: "image.png")

        XCTAssertNil(provider.image(for: request))
        XCTAssertNil(provider.image(for: request))
        XCTAssertEqual(loader.waitForStarts(1), .success)
        XCTAssertEqual(loader.callCount, 1)
        XCTAssertFalse(loader.wasCalledOnMainThread)

        loader.release(1)
        try await waitUntil {
            provider.image(for: request) != nil
        }

        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(updates.count, 1)
        XCTAssertTrue(provider.lastPublicationWasOnMainThreadForTesting)
        provider.dispose()
    }

    func testProviderLimitsConcurrentAndPendingLoads() async throws {
        let loader = BlockingMarkdownImageLoader(
            results: Array(
                repeating: Self.decodedImage(red: 128),
                count: MarkdownImageProvider.maximumPendingLoads
            ),
            startsBlocked: true
        )
        let provider = makeProvider(
            loader: loader,
            updates: MarkdownImageUpdateRecorder()
        )

        for index in 0..<(MarkdownImageProvider.maximumPendingLoads + 10) {
            XCTAssertNil(
                provider.image(
                    for: EmbeddedImageRequest(name: "image-\(index).png")
                )
            )
        }
        XCTAssertEqual(
            provider.pendingLoadCountForTesting,
            MarkdownImageProvider.maximumPendingLoads
        )
        XCTAssertEqual(
            loader.waitForStarts(MarkdownImageProvider.maximumConcurrentLoads),
            .success
        )
        XCTAssertEqual(
            loader.maximumActiveCallCount,
            MarkdownImageProvider.maximumConcurrentLoads
        )

        provider.dispose()
        loader.release(MarkdownImageProvider.maximumConcurrentLoads)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.pendingLoadCountForTesting, 0)
    }

    func testSamePathInvalidationPublishesReplacementAndRejectsStaleLoad()
        async throws
    {
        let loader = BlockingMarkdownImageLoader(
            results: [
                Self.decodedImage(red: 255),
                Self.decodedImage(red: 64),
            ]
        )
        let watcherFactory = ManualMarkdownImageWatcherFactory()
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(
            loader: loader,
            updates: updates,
            watcherFactory: watcherFactory
        )
        let request = EmbeddedImageRequest(name: "image.png")

        XCTAssertNil(provider.image(for: request))
        try await waitUntil { provider.image(for: request) != nil }
        let original = try XCTUnwrap(provider.image(for: request))
        try await waitUntil { watcherFactory.isInstalled }

        watcherFactory.signalChange()
        try await waitUntil { updates.count >= 2 }
        XCTAssertNil(provider.image(for: request))
        try await waitUntil { provider.image(for: request) != nil }
        let replacement = try XCTUnwrap(provider.image(for: request))

        XCTAssertFalse(original === replacement)
        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(updates.count, 3)
        provider.dispose()
    }

    func testDefaultPublicationPostsRestyleNotificationOnMainThread()
        async throws
    {
        let loader = BlockingMarkdownImageLoader(
            results: [Self.decodedImage(red: 255)]
        )
        let notificationCenter = NotificationCenter()
        let notification = Notification.Name(UUID().uuidString)
        let notifications = MarkdownImageNotificationRecorder()
        let observer = notificationCenter.addObserver(
            forName: notification,
            object: nil,
            queue: nil
        ) { _ in
            notifications.record()
        }
        defer { notificationCenter.removeObserver(observer) }
        let provider = MarkdownImageProvider(
            documentURL: URL(fileURLWithPath: "/tmp/notes/document.md"),
            loader: loader,
            watcherFactory: NoOpMarkdownImageWatcherFactory(),
            notificationCenter: notificationCenter,
            updateNotification: notification
        )

        XCTAssertNil(
            provider.image(for: EmbeddedImageRequest(name: "image.png"))
        )
        try await waitUntil { notifications.count == 1 }

        XCTAssertTrue(notifications.wasCalledOnMainThread)
        provider.dispose()
    }

    func testDocumentRootChangeDiscardsAnInFlightResult() async throws {
        let loader = BlockingMarkdownImageLoader(
            results: [Self.decodedImage(red: 255)],
            startsBlocked: true
        )
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(loader: loader, updates: updates)

        XCTAssertNil(
            provider.image(for: EmbeddedImageRequest(name: "image.png"))
        )
        XCTAssertEqual(loader.waitForStarts(1), .success)
        provider.update(
            documentURL: URL(fileURLWithPath: "/tmp/other/document.md")
        )
        try await waitUntil { updates.count == 1 }
        loader.release(1)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(provider.pendingLoadCountForTesting, 0)
        provider.dispose()
    }

    func testAtomicFileReplacementInvalidatesAndReloadsTheSameReference()
        async throws
    {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let documentURL = rootURL.appendingPathComponent("document.md")
        let imageURL = rootURL.appendingPathComponent("image.png")
        try Data().write(to: documentURL)
        try Self.pngData(red: 255).write(to: imageURL)
        let updates = MarkdownImageUpdateRecorder()
        let provider = MarkdownImageProvider(
            documentURL: documentURL,
            publishUpdate: { updates.record() }
        )
        let request = EmbeddedImageRequest(name: "image.png")

        XCTAssertNil(provider.image(for: request))
        try await waitUntil { provider.image(for: request) != nil }
        let original = try XCTUnwrap(provider.image(for: request))
        XCTAssertEqual(updates.count, 1)

        try Self.pngData(red: 64).write(to: imageURL, options: .atomic)
        try await waitUntil { updates.count >= 2 }
        XCTAssertNil(provider.image(for: request))
        try await waitUntil { provider.image(for: request) != nil }
        let replacement = try XCTUnwrap(provider.image(for: request))

        XCTAssertFalse(original === replacement)
        XCTAssertEqual(updates.count, 3)
        provider.dispose()
    }

    func testRootChangeAndDisposalPreventLatePublication() async throws {
        let loader = BlockingMarkdownImageLoader(
            results: [Self.decodedImage(red: 255)],
            startsBlocked: true
        )
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(loader: loader, updates: updates)

        XCTAssertNil(
            provider.image(for: EmbeddedImageRequest(name: "image.png"))
        )
        XCTAssertEqual(loader.waitForStarts(1), .success)
        provider.dispose()
        loader.release(1)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(updates.count, 0)
        XCTAssertEqual(provider.pendingLoadCountForTesting, 0)
        XCTAssertNil(
            provider.image(for: EmbeddedImageRequest(name: "image.png"))
        )
    }

    func testDisposalCancelsRunningImageLoad() async throws {
        let loader = CancellationObservingMarkdownImageLoader(
            result: Self.decodedImage(red: 255)
        )
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(loader: loader, updates: updates)

        XCTAssertNil(
            provider.image(for: EmbeddedImageRequest(name: "image.png"))
        )
        XCTAssertEqual(loader.waitForStart(), .success)
        provider.dispose()
        let cancellationResult = loader.waitForCancellation()
        loader.release()

        XCTAssertEqual(cancellationResult, .success)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.pendingLoadCountForTesting, 0)
        XCTAssertEqual(updates.count, 0)
    }

    func testReplacementWhileInitialLoadIsInFlightCannotPublishStaleImage()
        async throws
    {
        let loader = BlockingMarkdownImageLoader(
            results: [
                Self.decodedImage(red: 255),
                Self.decodedImage(red: 64),
            ],
            startsBlocked: true
        )
        let watcherFactory = ManualMarkdownImageWatcherFactory()
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(
            loader: loader,
            updates: updates,
            watcherFactory: watcherFactory
        )
        let request = EmbeddedImageRequest(name: "image.png")

        XCTAssertNil(provider.image(for: request))
        XCTAssertEqual(loader.waitForStarts(1), .success)
        guard watcherFactory.isInstalled else {
            loader.release(1)
            provider.dispose()
            return XCTFail("The watcher must be installed before image loading starts.")
        }

        watcherFactory.signalChange()
        try await waitUntil { updates.count == 1 }
        loader.release(1)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(provider.image(for: request))
        XCTAssertEqual(loader.waitForStarts(1), .success)
        loader.release(1)
        try await waitUntil { provider.image(for: request) != nil }

        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(updates.count, 2)
        provider.dispose()
    }

    func testUnauthorizedImageRequestDoesNotRemainPending() async throws {
        let updates = MarkdownImageUpdateRecorder()
        let provider = makeProvider(
            loader: RejectingMarkdownImageLoader(),
            updates: updates
        )

        XCTAssertNil(
            provider.image(for: EmbeddedImageRequest(name: "image.png"))
        )
        try await waitUntil(timeout: .milliseconds(500)) {
            provider.pendingLoadCountForTesting == 0
        }

        XCTAssertEqual(updates.count, 0)
        provider.dispose()
    }

    func testCacheEvictsLeastRecentlyUsedEntriesByCountAndCost() {
        var cache = MarkdownImageCache(maximumEntryCount: 2, maximumCost: 8)
        let first = NSImage(size: NSSize(width: 1, height: 1))
        let second = NSImage(size: NSSize(width: 1, height: 1))
        let third = NSImage(size: NSSize(width: 1, height: 1))

        cache.insert(first, for: URL(fileURLWithPath: "/tmp/first"), cost: 4)
        cache.insert(second, for: URL(fileURLWithPath: "/tmp/second"), cost: 4)
        XCTAssertNotNil(cache.image(for: URL(fileURLWithPath: "/tmp/first")))
        cache.insert(third, for: URL(fileURLWithPath: "/tmp/third"), cost: 4)

        XCTAssertNotNil(cache.image(for: URL(fileURLWithPath: "/tmp/first")))
        XCTAssertNil(cache.image(for: URL(fileURLWithPath: "/tmp/second")))
        XCTAssertNotNil(cache.image(for: URL(fileURLWithPath: "/tmp/third")))
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertEqual(cache.totalCost, 8)
    }

    private func makeProvider(
        loader: any MarkdownImageLoading,
        updates: MarkdownImageUpdateRecorder,
        watcherFactory: any MarkdownImageWatcherCreating =
            NoOpMarkdownImageWatcherFactory()
    ) -> MarkdownImageProvider {
        MarkdownImageProvider(
            documentURL: URL(fileURLWithPath: "/tmp/notes/document.md"),
            loader: loader,
            watcherFactory: watcherFactory,
            publishUpdate: { updates.record() }
        )
    }

    private static func decodedImage(red: UInt8) -> MarkdownDecodedImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let data = Data([red, 0, 0, 255]) as CFData
        let provider = CGDataProvider(data: data)!
        let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return MarkdownDecodedImage(image: image, decodedCost: 4)
    }

    private static func pngData(red: UInt8) throws -> Data {
        let image = decodedImage(red: red).image
        let mutableData = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                mutableData,
                "public.png" as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return mutableData as Data
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
        XCTFail("Timed out waiting for image-provider state.")
    }
}

@MainActor
private final class MarkdownImageUpdateRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private final class BlockingMarkdownImageLoader: MarkdownImageLoading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let startsBlocked: Bool
    private var results: [MarkdownDecodedImage]
    private var recordedCallCount = 0
    private var activeCallCount = 0
    private var recordedMaximumActiveCallCount = 0
    private var recordedMainThreadCall = false

    init(results: [MarkdownDecodedImage], startsBlocked: Bool = false) {
        self.results = results
        self.startsBlocked = startsBlocked
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    var maximumActiveCallCount: Int {
        lock.withLock { recordedMaximumActiveCallCount }
    }

    var wasCalledOnMainThread: Bool {
        lock.withLock { recordedMainThreadCall }
    }

    func load(_ request: MarkdownImageLoadRequest) -> MarkdownDecodedImage? {
        let result = lock.withLock { () -> MarkdownDecodedImage? in
            recordedCallCount += 1
            activeCallCount += 1
            recordedMaximumActiveCallCount = max(
                recordedMaximumActiveCallCount,
                activeCallCount
            )
            recordedMainThreadCall = recordedMainThreadCall || Thread.isMainThread
            let index = recordedCallCount - 1
            return results.indices.contains(index) ? results[index] : nil
        }
        started.signal()
        if startsBlocked {
            releaseGate.wait()
        }
        lock.withLock {
            activeCallCount -= 1
        }
        return result
    }

    func waitForStarts(_ count: Int) -> DispatchTimeoutResult {
        for _ in 0..<count {
            guard started.wait(timeout: .now() + 2) == .success else {
                return .timedOut
            }
        }
        return .success
    }

    func release(_ count: Int) {
        for _ in 0..<count {
            releaseGate.signal()
        }
    }
}

private final class MarkdownImageNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    private var recordedMainThreadCall = false

    var count: Int {
        lock.withLock { recordedCount }
    }

    var wasCalledOnMainThread: Bool {
        lock.withLock { recordedMainThreadCall }
    }

    func record() {
        lock.withLock {
            recordedCount += 1
            recordedMainThreadCall = recordedMainThreadCall || Thread.isMainThread
        }
    }
}

private struct NoOpMarkdownImageWatcherFactory: MarkdownImageWatcherCreating {
    func makeWatcher(
        request: MarkdownImageLoadRequest,
        onChange: @escaping @Sendable () -> Void
    ) -> (any MarkdownImageWatching)? {
        NoOpMarkdownImageWatcher()
    }
}

private final class NoOpMarkdownImageWatcher: MarkdownImageWatching,
    @unchecked Sendable
{
    func cancel() {}
}

private final class CancellationObservingMarkdownImageLoader:
    MarkdownImageLoading, @unchecked Sendable
{
    private let result: MarkdownDecodedImage
    private let started = DispatchSemaphore(value: 0)
    private let cancellationObserved = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)

    init(result: MarkdownDecodedImage) {
        self.result = result
    }

    func load(_ request: MarkdownImageLoadRequest) -> MarkdownDecodedImage? {
        load(request, cancellationCheck: { false })
    }

    func load(
        _ request: MarkdownImageLoadRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) -> MarkdownDecodedImage? {
        started.signal()
        while releaseGate.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if cancellationCheck() {
                cancellationObserved.signal()
                return nil
            }
        }
        return result
    }

    func waitForStart() -> DispatchTimeoutResult {
        started.wait(timeout: .now() + 2)
    }

    func waitForCancellation() -> DispatchTimeoutResult {
        cancellationObserved.wait(timeout: .now() + .milliseconds(250))
    }

    func release() {
        releaseGate.signal()
    }
}

private struct RejectingMarkdownImageLoader: MarkdownImageLoading {
    func authorizedRequest(
        for request: MarkdownImageLoadRequest
    ) -> MarkdownImageLoadRequest? {
        nil
    }

    func load(_ request: MarkdownImageLoadRequest) -> MarkdownDecodedImage? {
        nil
    }
}

private final class ManualMarkdownImageWatcherFactory:
    MarkdownImageWatcherCreating, @unchecked Sendable
{
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    var isInstalled: Bool {
        lock.withLock { callback != nil }
    }

    func makeWatcher(
        request: MarkdownImageLoadRequest,
        onChange: @escaping @Sendable () -> Void
    ) -> (any MarkdownImageWatching)? {
        lock.withLock {
            callback = onChange
        }
        return ManualMarkdownImageWatcher()
    }

    func signalChange() {
        let capturedCallback: (@Sendable () -> Void)? = lock.withLock {
            self.callback
        }
        capturedCallback?()
    }
}

private final class ManualMarkdownImageWatcher: MarkdownImageWatching,
    @unchecked Sendable
{
    func cancel() {}
}
