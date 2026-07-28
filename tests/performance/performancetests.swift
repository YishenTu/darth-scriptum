import XCTest
@testable import DarthMD

final class PerformanceTests: XCTestCase {
    func testOneMiBEditorReconciliationIsCorrect() {
        let line = "- [x] **fast** `native` [link](relative.md)\r\n"
        let repetitions = max(1, 1_048_576 / line.utf8.count)
        let source = String(repeating: line, count: repetitions)
        let editLocation = (source as NSString).length / 2
        let edited = NSMutableString(string: source)
        edited.insert("\n", at: editLocation)
        let result = MarkdownEditorTextAdapter.reconcile(
            editorText: edited as String,
            currentSource: source,
            newlineStyle: .crlf
        )

        XCTAssertEqual(
            (result as NSString).length,
            (source as NSString).length + 2
        )
    }

    @MainActor
    func testOneMiBEndToEndEditorEditIsCorrect() throws {
        let line = "- [x] **fast** `native` [link](relative.md)\n"
        let repetitions = max(1, 1_048_576 / line.utf8.count)
        let source = String(repeating: line, count: repetitions)
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let edited = NSMutableString(string: source)
        edited.insert("x", at: edited.length / 2)
        let edit = try XCTUnwrap(
            MarkdownEditorTextAdapter.sourceEdit(
                editorText: edited as String,
                currentRevision: buffer.revision,
                newlineStyle: .lf,
                origin: .localEditor(paneID: UUID())
            )
        )
        try buffer.apply(edit)

        XCTAssertEqual(
            (buffer.revision.text as NSString).length,
            (source as NSString).length + 1
        )
    }

    @MainActor
    func testIndexedCaretLookupsHandleLargeDocuments() {
        let line = "0123456789 abcdefghijklmnopqrstuvwxyz\n"
        let source = String(repeating: line, count: 30_000)
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let length = (source as NSString).length
        var checksum = 0
        for offset in 0..<10_000 {
            let position = try! XCTUnwrap(buffer.position(
                atUTF16Location: length - offset
            ))
            checksum &+= position.line &+ position.column
        }

        XCTAssertGreaterThan(checksum, 0)
    }

    @MainActor
    func testDenseFourMiBLineIndexEditRemainsExactAndSparse() async throws {
        let source = String(repeating: "\n", count: 4 * 1_024 * 1_024)
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        try await waitForLineIndex(in: buffer)
        XCTAssertLessThan(
            try XCTUnwrap(buffer.lineIndexStorageEntryCount),
            5_000
        )
        let location = (source as NSString).length / 2

        try buffer.apply(
            SourceEdit(
                range: NSRange(location: location, length: 0),
                replacement: "x",
                expectedRevision: buffer.revision.number,
                origin: .localEditor(paneID: UUID())
            )
        )

        let finalPosition = try XCTUnwrap(
            buffer.position(
                atUTF16Location: (buffer.revision.text as NSString).length
            )
        )
        XCTAssertEqual(
            finalPosition.line,
            4 * 1_024 * 1_024 + 1
        )
    }

    @MainActor
    func testFourMiBBulkReplacementIsCorrect() {
        let source = String(repeating: "content\n", count: 512 * 1_024)
        let buffer = MarkdownSourceBuffer()

        buffer.replace(with: source, origin: .externalReload)

        XCTAssertEqual(buffer.revision.text, source)
    }

    func testLargeMultiHunkMergeIsCorrect() {
        let baseLines = (0..<2_000).map { "line \($0)\n" }
        let base = baseLines.joined()
        var localLines = baseLines
        var externalLines = baseLines
        for index in stride(from: 0, to: baseLines.count, by: 4) {
            localLines[index] = "local \(index)\n"
        }
        for index in stride(from: 2, to: baseLines.count, by: 4) {
            externalLines[index] = "external \(index)\n"
        }
        let result = ThreeWayTextMerger().merge(
            base: base,
            local: localLines.joined(),
            external: externalLines.joined()
        )

        guard case let .merged(text) = result else {
            return XCTFail("Expected non-overlapping hunks to merge")
        }
        XCTAssertTrue(text.contains("local 0\n"))
        XCTAssertTrue(text.contains("external 2\n"))
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

    @MainActor
    private func waitForLineIndex(
        in buffer: MarkdownSourceBuffer,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if buffer.position(atUTF16Location: 0) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the background line index.")
    }
}
