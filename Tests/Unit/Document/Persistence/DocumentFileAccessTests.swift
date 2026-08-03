import Foundation
import XCTest

@testable import DarthScriptum

final class DocumentFileAccessTests: XCTestCase {
    func testOperationsOnOneLaneRemainFIFO() async throws {
        let lane = DocumentFileAccessLane(label: "test.document-lane.fifo")
        let firstStarted = expectation(description: "first operation started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let recorder = IntegerRecorder()

        let first = Task {
            try await lane.perform {
                firstStarted.fulfill()
                releaseFirst.wait()
                recorder.append(1)
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let second = Task {
            try await lane.perform {
                recorder.append(2)
            }
        }
        XCTAssertTrue(recorder.values.isEmpty)

        releaseFirst.signal()
        try await first.value
        try await second.value

        XCTAssertEqual(recorder.values, [1, 2])
    }

    func testBlockedLaneDoesNotDelayAnotherLane() async throws {
        let blockedLane = DocumentFileAccessLane(
            label: "test.document-lane.blocked"
        )
        let independentLane = DocumentFileAccessLane(
            label: "test.document-lane.independent"
        )
        let blockedOperationStarted = expectation(
            description: "blocked operation started"
        )
        let releaseBlockedOperation = DispatchSemaphore(value: 0)

        let blockedOperation = Task {
            try await blockedLane.perform {
                blockedOperationStarted.fulfill()
                releaseBlockedOperation.wait()
            }
        }
        await fulfillment(of: [blockedOperationStarted], timeout: 1)

        let value = try await independentLane.perform { 42 }

        XCTAssertEqual(value, 42)
        releaseBlockedOperation.signal()
        try await blockedOperation.value
    }

    func testSynchronousAccessCanReenterItsOwnLane() async throws {
        let lane = DocumentFileAccessLane(label: "test.document-lane.reentrant")

        let value = try await lane.perform {
            try lane.performSynchronously { 42 }
        }

        XCTAssertEqual(value, 42)
    }

    @MainActor
    func testSynchronousAccessRejectsTheMainThread() {
        let lane = DocumentFileAccessLane(label: "test.document-lane.main")

        XCTAssertThrowsError(try lane.performSynchronously { 42 }) { error in
            XCTAssertEqual(
                error as? DocumentFileAccessError,
                .synchronousAccessFromMainThread
            )
        }
    }
}

private final class IntegerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.withLock { storage }
    }

    func append(_ value: Int) {
        lock.withLock {
            storage.append(value)
        }
    }
}
