import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest

@testable import DarthScriptum

final class MarkdownImageLoaderTests: XCTestCase {
    func testLoaderDecodesOnlyRegularImagesInsideCanonicalRoot() throws {
        try withTemporaryDirectory { rootURL in
            let outsideURL =
                rootURL
                .deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: outsideURL) }
            let imageURL = rootURL.appendingPathComponent("image.png")
            let symlinkURL = rootURL.appendingPathComponent("escaped.png")
            try Self.pngData(red: 255).write(to: imageURL)
            try Self.pngData(red: 128).write(to: outsideURL)
            try FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: outsideURL
            )
            let loader = MarkdownImageLoader()

            let loaded = loader.load(
                MarkdownImageLoadRequest(
                    rootURL: rootURL,
                    targetURL: imageURL
                )
            )

            XCTAssertEqual(loaded?.image.width, 1)
            XCTAssertEqual(loaded?.image.height, 1)
            XCTAssertEqual(loaded?.decodedCost, 4)
            XCTAssertNil(
                loader.load(
                    MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL: symlinkURL
                    )
                )
            )
            XCTAssertNil(
                loader.load(
                    MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL:
                            rootURL
                            .deletingLastPathComponent()
                            .appendingPathComponent("missing.png")
                    )
                )
            )
        }
    }

    func testLoaderRejectsInRootSymbolicLinkThatCannotBeReliablyWatched()
        throws
    {
        try withTemporaryDirectory { rootURL in
            let imageURL = rootURL.appendingPathComponent("image.png")
            let symlinkURL = rootURL.appendingPathComponent("linked.png")
            try Self.pngData(red: 255).write(to: imageURL)
            try FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: imageURL
            )

            XCTAssertNil(
                MarkdownImageLoader().load(
                    MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL: symlinkURL
                    )
                )
            )
        }
    }

    func testLoaderRejectsEncodedPayloadBeyondLimitBeforeDecode() throws {
        try withTemporaryDirectory { rootURL in
            let imageURL = rootURL.appendingPathComponent("oversized.png")
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: imageURL.path,
                    contents: nil
                )
            )
            let handle = try FileHandle(forWritingTo: imageURL)
            try handle.truncate(
                atOffset: UInt64(MarkdownImageLoader.maximumEncodedImageBytes + 1)
            )
            try handle.close()

            XCTAssertNil(
                MarkdownImageLoader().load(
                    MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL: imageURL
                    )
                )
            )
        }
    }

    func testLoaderRejectsFIFOWithoutWaitingForWriter() throws {
        try withTemporaryDirectory { rootURL in
            let fifoURL = rootURL.appendingPathComponent("image.png")
            let creationResult = fifoURL.path.withCString {
                Darwin.mkfifo($0, mode_t(0o600))
            }
            XCTAssertEqual(creationResult, 0)
            let completion = DispatchSemaphore(value: 0)
            let result = ImageLoadResultRecorder()

            DispatchQueue.global(qos: .userInitiated).async {
                result.record(
                    MarkdownImageLoader().load(
                        MarkdownImageLoadRequest(
                            rootURL: rootURL,
                            targetURL: fifoURL
                        )
                    )
                )
                completion.signal()
            }

            let initialWait = completion.wait(
                timeout: .now() + .milliseconds(250)
            )
            if initialWait == .timedOut {
                let writer = fifoURL.path.withCString {
                    Darwin.open($0, O_WRONLY | O_NONBLOCK)
                }
                if writer >= 0 {
                    Darwin.close(writer)
                }
                XCTAssertEqual(
                    completion.wait(timeout: .now() + 2),
                    .success
                )
            }

            XCTAssertEqual(initialWait, .success)
            XCTAssertFalse(result.didLoadImage)
        }
    }

    func testImageWatcherRejectsFIFOWithoutWaitingForWriter() throws {
        try withTemporaryDirectory { rootURL in
            let fifoURL = rootURL.appendingPathComponent("image.png")
            XCTAssertEqual(
                fifoURL.path.withCString {
                    Darwin.mkfifo($0, mode_t(0o600))
                },
                0
            )
            let request = try XCTUnwrap(
                MarkdownImageLoader().authorizedRequest(
                    for: MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL: fifoURL
                    )
                )
            )
            let completion = DispatchSemaphore(value: 0)
            let result = ImageWatcherResultRecorder()

            DispatchQueue.global(qos: .userInitiated).async {
                let watcher = MarkdownImageFileWatcherFactory().makeWatcher(
                    request: request,
                    onChange: {}
                )
                result.record(watcher != nil)
                watcher?.cancel()
                completion.signal()
            }

            let initialWait = completion.wait(
                timeout: .now() + .milliseconds(250)
            )
            if initialWait == .timedOut {
                let writer = fifoURL.path.withCString {
                    Darwin.open($0, O_RDWR | O_NONBLOCK)
                }
                if writer >= 0 {
                    Darwin.close(writer)
                }
                XCTAssertEqual(
                    completion.wait(timeout: .now() + 2),
                    .success
                )
            }

            XCTAssertEqual(initialWait, .success)
            XCTAssertFalse(result.didCreateWatcher)
        }
    }

    func testLoaderRejectsImageWithExcessiveFrameCount() throws {
        try withTemporaryDirectory { rootURL in
            let imageURL = rootURL.appendingPathComponent("animated.gif")
            try Self.gifData(frameCount: 257).write(to: imageURL)

            XCTAssertNil(
                MarkdownImageLoader().load(
                    MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL: imageURL
                    )
                )
            )
        }
    }

    func testLoaderWhenIntermediateDirectoryIsSwappedAfterAuthorizationRejectsEscape() throws {
        try withTemporaryDirectory { rootURL in
            let imagesURL = rootURL.appendingPathComponent(
                "images",
                isDirectory: true
            )
            let originalImagesURL = rootURL.appendingPathComponent(
                "original-images",
                isDirectory: true
            )
            let outsideURL = rootURL.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outsideURL) }
            try FileManager.default.createDirectory(
                at: imagesURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outsideURL,
                withIntermediateDirectories: true
            )
            let targetURL = imagesURL.appendingPathComponent("image.png")
            try Self.pngData(red: 255).write(to: targetURL)
            try Self.pngData(red: 128).write(
                to: outsideURL.appendingPathComponent("image.png")
            )
            let loader = MarkdownImageLoader(beforeSecureOpen: {
                try! FileManager.default.moveItem(
                    at: imagesURL,
                    to: originalImagesURL
                )
                try! FileManager.default.createSymbolicLink(
                    at: imagesURL,
                    withDestinationURL: outsideURL
                )
            })

            XCTAssertNil(
                loader.load(
                    MarkdownImageLoadRequest(
                        rootURL: rootURL,
                        targetURL: targetURL
                    )
                )
            )
        }
    }

    func testDecodedImageDimensionsAreBoundedAndOverflowSafe() {
        XCTAssertEqual(
            MarkdownImageLoader.decodedCost(width: 1, height: 1),
            4
        )
        XCTAssertNil(
            MarkdownImageLoader.decodedCost(width: 4_096, height: 4_096)
        )
        XCTAssertNil(
            MarkdownImageLoader.decodedCost(width: Int.max, height: 2)
        )
    }

    func testDecodedCostWhenImageUsesHighBitDepthAccountsForRetainedStorage() throws {
        XCTAssertEqual(
            MarkdownImageLoader.decodedCost(
                width: 2_048,
                height: 2_048,
                bitsPerComponent: 16
            ),
            MarkdownImageLoader.maximumDecodedImageCost
        )
        XCTAssertNil(
            MarkdownImageLoader.decodedCost(
                width: 2_049,
                height: 2_048,
                bitsPerComponent: 16
            )
        )

        let storage = Data(count: 16) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: storage))
        let image = try XCTUnwrap(
            CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 16,
                bitsPerPixel: 64,
                bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        XCTAssertEqual(MarkdownImageLoader.decodedCost(of: image), 16)
    }

    func testLoaderStopsReadingWhenCancellationIsRequested() throws {
        try withTemporaryDirectory { rootURL in
            let imageURL = rootURL.appendingPathComponent("image.png")
            try Data(count: 3 * 64 * 1_024).write(to: imageURL)
            let cancellation = ImageLoadCancellationRecorder(
                cancellationCheckLimit: 6
            )

            let result = MarkdownImageLoader().load(
                MarkdownImageLoadRequest(
                    rootURL: rootURL,
                    targetURL: imageURL
                ),
                cancellationCheck: { cancellation.shouldCancel() }
            )

            XCTAssertNil(result)
            XCTAssertTrue(cancellation.didRequestCancellation)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try body(rootURL)
    }

    private static func pngData(red: UInt8) throws -> Data {
        let image = try onePixelImage(red: red)
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

    private static func gifData(frameCount: Int) throws -> Data {
        let image = try onePixelImage(red: 255)
        let mutableData = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                mutableData,
                "com.compuserve.gif" as CFString,
                frameCount,
                nil
            )
        )
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return mutableData as Data
    }

    private static func onePixelImage(red: UInt8) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [red, 0, 0, 255]
        let context = bytes.withUnsafeMutableBytes { storage in
            CGContext(
                data: storage.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        return try XCTUnwrap(context?.makeImage())
    }
}

private final class ImageLoadResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedImage = false

    var didLoadImage: Bool {
        lock.withLock { recordedImage }
    }

    func record(_ result: MarkdownDecodedImage?) {
        lock.withLock {
            recordedImage = result != nil
        }
    }
}

private final class ImageWatcherResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var createdWatcher = false

    var didCreateWatcher: Bool {
        lock.withLock { createdWatcher }
    }

    func record(_ didCreateWatcher: Bool) {
        lock.withLock {
            createdWatcher = didCreateWatcher
        }
    }
}

private final class ImageLoadCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationCheckLimit: Int
    private var cancellationCheckCount = 0
    private var recordedCancellation = false

    init(cancellationCheckLimit: Int) {
        self.cancellationCheckLimit = cancellationCheckLimit
    }

    var didRequestCancellation: Bool {
        lock.withLock { recordedCancellation }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            cancellationCheckCount += 1
            if cancellationCheckCount >= cancellationCheckLimit {
                recordedCancellation = true
            }
            return recordedCancellation
        }
    }
}
