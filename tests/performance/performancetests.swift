import XCTest
@testable import DarthMD

final class PerformanceTests: XCTestCase {
    func testOneMiBEditorReconciliationCompletesWithinBudget() {
        let line = "- [x] **fast** `native` [link](relative.md)\r\n"
        let repetitions = max(1, 1_048_576 / line.utf8.count)
        let source = String(repeating: line, count: repetitions)
        let editLocation = (source as NSString).length / 2
        let edited = NSMutableString(string: source)
        edited.insert("\n", at: editLocation)
        let clock = ContinuousClock()
        let start = clock.now

        let result = MarkdownEditorTextAdapter.reconcile(
            editorText: edited as String,
            currentSource: source,
            newlineStyle: .crlf
        )

        XCTAssertEqual(
            (result as NSString).length,
            (source as NSString).length + 2
        )
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100))
    }

    func testTenMiBCodecRoundTripMeasurement() throws {
        let source = String(repeating: "text\r\n", count: 1_500_000)
        let snapshot = DocumentSnapshot(
            text: source,
            format: TextFileFormat(
                encoding: .utf8,
                dominantNewline: .crlf,
                hasFinalNewline: true
            )
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            do {
                let encoded = try TextFileCodec.encode(snapshot)
                _ = try TextFileCodec.decode(encoded)
            } catch {
                XCTFail("Codec measurement failed: \(error)")
            }
        }
    }
}
