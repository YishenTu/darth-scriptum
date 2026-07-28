import XCTest
@testable import DarthMD

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
}
