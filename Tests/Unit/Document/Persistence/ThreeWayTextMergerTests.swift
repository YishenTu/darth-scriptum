import XCTest

@testable import DarthScriptum

final class ThreeWayTextMergerTests: XCTestCase {
    private let merger = ThreeWayTextMerger()

    func testNonOverlappingChangesMerge() {
        XCTAssertEqual(
            merger.merge(
                base: "alpha\nbeta\ngamma\n",
                local: "ALPHA\nbeta\ngamma\n",
                external: "alpha\nbeta\nGAMMA\n"
            ),
            .merged("ALPHA\nbeta\nGAMMA\n")
        )
    }

    func testOverlappingChangesConflict() {
        XCTAssertEqual(
            merger.merge(base: "hello", local: "hallo", external: "hullo"),
            .conflict
        )
    }

    func testAdjacentChangesMerge() {
        XCTAssertEqual(
            merger.merge(base: "abcd", local: "aBcd", external: "abcD"),
            .merged("aBcD")
        )
    }

    func testCRLFAndFinalNewlineRemainExact() {
        XCTAssertEqual(
            merger.merge(
                base: "a\r\nb\r\n",
                local: "A\r\nb\r\n",
                external: "a\r\nb\r\nc\r\n"
            ),
            .merged("A\r\nb\r\nc\r\n")
        )
    }

    func testMultipleLocalHunksMergeAroundExternalHunk() {
        XCTAssertEqual(
            merger.merge(
                base: "one\ntwo\nthree\nfour\nfive\n",
                local: "ONE\ntwo\nthree\nfour\nFIVE\n",
                external: "one\ntwo\nTHREE\nfour\nfive\n"
            ),
            .merged("ONE\ntwo\nTHREE\nfour\nFIVE\n")
        )
    }

    func testMultipleHunksStillConflictOnSharedLine() {
        XCTAssertEqual(
            merger.merge(
                base: "one\ntwo\nthree\nfour\n",
                local: "ONE\ntwo\nTHREE\nfour\n",
                external: "one\ntwo\nthXee\nfour\n"
            ),
            .conflict
        )
    }

    func testChangedCoreBeyondByteLimitFailsClosed() {
        let oversizedCore = String(
            repeating: "x",
            count: ThreeWayTextMerger.maximumChangedCoreUTF8ByteCount + 1
        )

        XCTAssertEqual(
            merger.merge(
                base: "base",
                local: oversizedCore,
                external: "external"
            ),
            .conflict
        )
    }

    func testChangedCoreBeyondLineLimitFailsClosed() {
        let oversizedCore = String(
            repeating: "changed\n",
            count: ThreeWayTextMerger.maximumChangedLineCount + 1
        )

        XCTAssertEqual(
            merger.merge(
                base: "base\n",
                local: oversizedCore,
                external: "external\n"
            ),
            .conflict
        )
    }

    func testIdenticalChangedCoresBeyondLimitStillFailClosed() {
        let oversizedCore = String(
            repeating: "changed\n",
            count: ThreeWayTextMerger.maximumChangedLineCount + 1
        )

        XCTAssertEqual(
            merger.merge(
                base: "base\n",
                local: oversizedCore,
                external: oversizedCore
            ),
            .conflict
        )
    }

    func testMergeStopsWhenScanningIsCancelled() {
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try merger.mergeCancellable(
                base: "alpha\nbeta\ngamma\n",
                local: "ALPHA\nbeta\ngamma\n",
                external: "alpha\nbeta\nGAMMA\n",
                cancellationCheck: {
                    cancellationChecks += 1
                    if cancellationChecks == 2 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 2)
    }

    func testMergeWhenChangesOverlapWithinLargeContextAvoidsTokenizingUnchangedLines() throws {
        let sharedPrefix = String(repeating: "same\n", count: 250_000)
        var cancellationChecks = 0

        let result = try merger.mergeCancellable(
            base: sharedPrefix + "one\ntwo\nthree\n",
            local: sharedPrefix + "ONE\ntwo\nTHREE\n",
            external: sharedPrefix + "one\nTWO\nthree\n",
            cancellationCheck: {
                cancellationChecks += 1
                if cancellationChecks > 180 {
                    throw CancellationError()
                }
            }
        )

        XCTAssertEqual(result, .merged(sharedPrefix + "ONE\nTWO\nTHREE\n"))
        XCTAssertLessThanOrEqual(cancellationChecks, 180)
    }

    func testLineDifferenceWhenInputsAreWithinLineLimitButWorkIsPathologicalRejects() {
        XCTAssertTrue(
            ThreeWayTextMerger.supportsLineDifference(
                baseLineCount: 2_000,
                updatedLineCount: 2_000
            )
        )
        XCTAssertFalse(
            ThreeWayTextMerger.supportsLineDifference(
                baseLineCount: ThreeWayTextMerger.maximumChangedLineCount,
                updatedLineCount: ThreeWayTextMerger.maximumChangedLineCount
            )
        )
        XCTAssertFalse(
            ThreeWayTextMerger.supportsLineDifference(
                baseLineCount: .max,
                updatedLineCount: 2
            )
        )
    }

    func testMergeWhenLineDifferenceWorkIsPathologicalFailsClosed() {
        let lineCount = ThreeWayTextMerger.maximumChangedLineCount
        let base = (0..<lineCount).map { "base-\($0)\n" }.joined()
        let local = (0..<lineCount).map { "local-\($0)\n" }.joined()
        let external = (0..<lineCount).map { "external-\($0)\n" }.joined()

        XCTAssertEqual(
            merger.merge(base: base, local: local, external: external),
            .conflict
        )
    }
}
