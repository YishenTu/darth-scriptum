import Dispatch
import Foundation
import XCTest

@testable import DarthScriptum

final class DirectoryFileMonitorTests: XCTestCase {
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
