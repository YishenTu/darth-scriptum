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
}
