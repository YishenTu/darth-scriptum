import Darwin
import Dispatch
import Foundation
import XCTest

@testable import DarthScriptum

final class DirectoryFileMonitorTests: XCTestCase {
    func testStartRejectsFIFOWithoutWaitingForWriter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("fixture.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(
            target.path.withCString {
                Darwin.mkfifo($0, mode_t(0o600))
            },
            0
        )
        let completion = DispatchSemaphore(value: 0)
        let resultRecorder = DirectoryMonitorStartResultRecorder()
        let monitor = DirectoryFileMonitor(targetURL: target, onChange: {})

        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                try monitor.start()
                resultRecorder.recordRejected(false)
                monitor.cancel()
            } catch {
                resultRecorder.recordRejected(true)
            }
        }

        let initialWait = completion.wait(
            timeout: .now() + .milliseconds(250)
        )
        if initialWait == .timedOut {
            let writer = target.path.withCString {
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
        XCTAssertTrue(resultRecorder.wasRejected)
    }

    func testCancellationClosesTheOwnedDescriptor() throws {
        let expectation = expectation(description: "Descriptor closed")
        expectation.expectedFulfillmentCount = 2
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("fixture.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("fixture\n".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: directory) }

        let monitor = DirectoryFileMonitor(
            targetURL: target,
            onChange: {},
            onDescriptorClosed: { didClose in
                XCTAssertTrue(didClose)
                expectation.fulfill()
            }
        )
        try monitor.start()
        monitor.cancel()

        wait(for: [expectation], timeout: 1)
    }

    func testDirectWriteToTargetProducesAChangeEvent() throws {
        let expectation = expectation(description: "Direct write observed")
        expectation.assertForOverFulfill = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("fixture.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("before\n".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: directory) }

        let monitor = DirectoryFileMonitor(
            targetURL: target,
            onChange: { expectation.fulfill() }
        )
        try monitor.start()
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("after\n".utf8))
        try handle.close()

        wait(for: [expectation], timeout: 1)
        monitor.cancel()
    }

    func testCancellationWaitsForActiveDirectoryCallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("fixture.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let callbackStarted = expectation(description: "Directory callback started")
        let allowCallbackToFinish = DispatchSemaphore(value: 0)
        let descriptorCloseCount = DispatchSemaphore(value: 0)
        let descriptorClosed = expectation(description: "Descriptor closed")
        descriptorClosed.expectedFulfillmentCount = 1
        let monitor = DirectoryFileMonitor(
            targetURL: target,
            onChange: {
                callbackStarted.fulfill()
                allowCallbackToFinish.wait()
            },
            onDescriptorClosed: { didClose in
                XCTAssertTrue(didClose)
                descriptorCloseCount.signal()
                descriptorClosed.fulfill()
            }
        )
        defer {
            allowCallbackToFinish.signal()
            monitor.cancel()
        }

        try monitor.start()
        try Data("fixture\n".utf8).write(to: target)
        wait(for: [callbackStarted], timeout: 1)

        monitor.cancel()
        XCTAssertEqual(
            descriptorCloseCount.wait(timeout: .now()),
            .timedOut
        )

        allowCallbackToFinish.signal()
        wait(for: [descriptorClosed], timeout: 1)
        XCTAssertEqual(
            descriptorCloseCount.wait(timeout: .now()),
            .success
        )
        XCTAssertEqual(
            descriptorCloseCount.wait(timeout: .now()),
            .timedOut
        )
    }

    func testReadingTargetDoesNotProduceAChangeEvent() throws {
        let expectation = expectation(description: "No read feedback")
        expectation.isInverted = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("fixture.md")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("fixture\n".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: directory) }

        let monitor = DirectoryFileMonitor(
            targetURL: target,
            onChange: { expectation.fulfill() }
        )
        try monitor.start()

        _ = try Data(contentsOf: target, options: [.mappedIfSafe])
        _ = try FileManager.default.attributesOfItem(atPath: target.path)

        wait(for: [expectation], timeout: 0.1)
        monitor.cancel()
    }
}

private final class DirectoryMonitorStartResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    var wasRejected: Bool {
        lock.withLock { rejected }
    }

    func recordRejected(_ rejected: Bool) {
        lock.withLock {
            self.rejected = rejected
        }
    }
}
