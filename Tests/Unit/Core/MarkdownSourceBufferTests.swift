import Combine
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownSourceBufferTests: XCTestCase {
    func testDocumentMetricsStayExactAcrossCRLFAndMermaidBoundaryEdits() throws {
        let source = "Mermaid\r\nx😀\ny"
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        XCTAssertEqual(buffer.metrics, DocumentMetrics(text: source))

        try buffer.apply(
            SourceEdit(
                range: NSRange(location: 3, length: 5),
                replacement: "",
                expectedRevision: buffer.revision.number,
                origin: .localEditor(paneID: UUID())
            )
        )
        XCTAssertEqual(
            buffer.metrics,
            DocumentMetrics(text: buffer.revision.text)
        )
        XCTAssertFalse(buffer.metrics.containsMermaidCandidate)

        try buffer.apply(
            SourceEdit(
                range: NSRange(location: 3, length: 0),
                replacement: "maid\r",
                expectedRevision: buffer.revision.number,
                origin: .localEditor(paneID: UUID())
            )
        )
        XCTAssertEqual(
            buffer.metrics,
            DocumentMetrics(text: buffer.revision.text)
        )
        XCTAssertTrue(buffer.metrics.containsMermaidCandidate)
        XCTAssertEqual(buffer.metrics.lineCount, 3)
    }

    func testSourceBufferExposesThePublishedIncrementalEdit() throws {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "alpha", format: .newDocument)
        )
        let edit = SourceEdit(
            range: NSRange(location: 2, length: 1),
            replacement: "X",
            expectedRevision: buffer.revision.number,
            origin: .localEditor(paneID: UUID())
        )

        try buffer.apply(edit)

        XCTAssertEqual(buffer.lastAppliedEdit, edit)
        buffer.replace(with: "external", origin: .externalReload)
        XCTAssertEqual(buffer.lastAppliedEdit?.origin, .externalReload)
        XCTAssertEqual(
            try XCTUnwrap(buffer.lastAppliedEdit).applying(
                to: SourceRevision(number: 1, text: "alXha")
            ).text,
            "external"
        )
    }

    func testPublishesMonotonicRevisionsToMultipleObservers() throws {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "a", format: .newDocument)
        )
        var first: [UInt64] = []
        var second: [UInt64] = []
        let firstToken = buffer.observe { revision, _ in first.append(revision.number) }
        let secondToken = buffer.observe { revision, _ in second.append(revision.number) }

        _ = try buffer.apply(
            SourceEdit(
                range: NSRange(location: 1, length: 0),
                replacement: "b",
                expectedRevision: 0,
                origin: .localEditor(paneID: UUID())
            )
        )
        buffer.removeObserver(firstToken)
        buffer.replace(with: "abc", origin: .externalReload)
        buffer.removeObserver(secondToken)

        XCTAssertEqual(first, [1])
        XCTAssertEqual(second, [1, 2])
        XCTAssertEqual(buffer.revision.text, "abc")
    }

    func testUndoAndRedoUseOneHistoryAcrossEditorPanes() {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "base", format: .newDocument)
        )
        let primaryPaneID = UUID()
        let secondaryPaneID = UUID()
        var origins: [DocumentChangeOrigin] = []
        let token = buffer.observe { _, origin in origins.append(origin) }

        buffer.replace(
            with: "primary",
            origin: .localEditor(paneID: primaryPaneID)
        )
        buffer.replace(
            with: "secondary",
            origin: .localEditor(paneID: secondaryPaneID)
        )

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "primary")
        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "base")
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.revision.text, "primary")
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.revision.text, "secondary")
        XCTAssertFalse(buffer.canRedo)
        XCTAssertEqual(
            origins,
            [
                .localEditor(paneID: primaryPaneID),
                .localEditor(paneID: secondaryPaneID),
                .undo,
                .undo,
                .redo,
                .redo,
            ]
        )
        buffer.removeObserver(token)
    }

    func testUndoPreservesUnicodeReplacementBoundaries() {
        let paneID = UUID()
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: "before 😀 after",
                format: .newDocument
            )
        )

        buffer.replace(
            with: "before 😎 after",
            origin: .localEditor(paneID: paneID)
        )

        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "before 😀 after")
        XCTAssertTrue(buffer.redo())
        XCTAssertEqual(buffer.revision.text, "before 😎 after")
    }

    func testExternalReplacementInvalidatesUndoHistory() {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "base", format: .newDocument)
        )
        buffer.replace(
            with: "local",
            origin: .localEditor(paneID: UUID())
        )

        buffer.replace(with: "external", origin: .externalReload)

        XCTAssertFalse(buffer.canUndo)
        XCTAssertFalse(buffer.undo())
        XCTAssertEqual(buffer.revision.text, "external")
    }

    func testIncrementalLineIndexMatchesReferenceAcrossMixedEdits() throws {
        let paneID = UUID()
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: "alpha\r\nbeta\ngamma\rdelta 😀\n",
                format: .newDocument
            )
        )
        assertIndexedPositions(in: buffer)

        let edits = [
            SourceEdit(
                range: NSRange(location: 5, length: 0),
                replacement: "\ninserted",
                expectedRevision: 0,
                origin: .localEditor(paneID: paneID)
            ),
            SourceEdit(
                range: NSRange(location: 0, length: 5),
                replacement: "A\r\nB",
                expectedRevision: 1,
                origin: .localEditor(paneID: paneID)
            ),
            SourceEdit(
                range: NSRange(location: 8, length: 10),
                replacement: "\rreplacement\n",
                expectedRevision: 2,
                origin: .localEditor(paneID: paneID)
            ),
            SourceEdit(
                range: NSRange(location: 0, length: 0),
                replacement: "\r\n",
                expectedRevision: 3,
                origin: .localEditor(paneID: paneID)
            ),
        ]

        for edit in edits {
            try buffer.apply(edit)
            assertIndexedPositions(in: buffer)
        }
        XCTAssertTrue(buffer.undo())
        assertIndexedPositions(in: buffer)
        XCTAssertTrue(buffer.redo())
        assertIndexedPositions(in: buffer)
    }

    func testIncrementalLineIndexMatchesReferenceAcrossChunkBoundaries() throws {
        let paneID = UUID()
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: String(repeating: "a\n", count: 700),
                format: .newDocument
            )
        )
        let edits: [(NSRange, String)] = [
            (NSRange(location: 1, length: 0), "\r\ninserted"),
            (NSRange(location: 510, length: 7), "middle\nlines\r\n"),
            (NSRange(location: 1_020, length: 40), ""),
            (NSRange(location: 1_300, length: 0), "tail\r"),
        ]

        assertIndexedPositions(in: buffer)
        for (range, replacement) in edits {
            try buffer.apply(
                SourceEdit(
                    range: range,
                    replacement: replacement,
                    expectedRevision: buffer.revision.number,
                    origin: .localEditor(paneID: paneID)
                )
            )
            assertIndexedPositions(in: buffer)
        }
    }

    func testSourceEditPublishesOneObservableChange() throws {
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: "base", format: .newDocument)
        )
        var publicationCount = 0
        let observation = buffer.objectWillChange.sink {
            publicationCount += 1
        }

        try buffer.apply(
            SourceEdit(
                range: NSRange(location: 4, length: 0),
                replacement: "\nnext",
                expectedRevision: 0,
                origin: .localEditor(paneID: UUID())
            )
        )

        XCTAssertEqual(publicationCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testIncrementalLineIndexMatchesReferenceForRandomizedEdits() throws {
        let paneID = UUID()
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(
                text: "alpha\r\nbeta\ngamma\rdelta\n",
                format: .newDocument
            )
        )
        var expectedText = buffer.revision.text
        var randomState: UInt64 = 0xD4A7_4D5E_ED
        let replacements = [
            "",
            "x",
            "\n",
            "\r",
            "\r\n",
            "two\nlines",
            "a\r\nb\nc",
        ]

        func nextRandom(_ upperBound: Int) -> Int {
            randomState =
                randomState
                &* 6_364_136_223_846_793_005
                &+ 1_442_695_040_888_963_407
            return Int(randomState % UInt64(max(upperBound, 1)))
        }

        for revision in 0..<500 {
            let expected = expectedText as NSString
            let location = nextRandom(expected.length + 1)
            let maximumRemoval = min(8, expected.length - location)
            let removalLength = nextRandom(maximumRemoval + 1)
            let replacement = replacements[nextRandom(replacements.count)]
            let mutable = NSMutableString(string: expected)
            mutable.replaceCharacters(
                in: NSRange(
                    location: location,
                    length: removalLength
                ),
                with: replacement
            )
            expectedText = mutable as String

            try buffer.apply(
                SourceEdit(
                    range: NSRange(
                        location: location,
                        length: removalLength
                    ),
                    replacement: replacement,
                    expectedRevision: UInt64(revision),
                    origin: .localEditor(paneID: paneID)
                )
            )

            XCTAssertEqual(buffer.revision.text, expectedText)
            assertIndexedPositions(in: buffer)
        }
    }

    func testBackgroundLineIndexRejectsAStaleLargeDocumentBuild() async throws {
        let firstText = String(repeating: "\n", count: 3 * 1_024 * 1_024)
        let secondLineCount = 1_500_000
        let secondText = String(repeating: "x\n", count: secondLineCount)
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: firstText, format: .newDocument)
        )

        buffer.replace(with: secondText, origin: .externalReload)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline,
            buffer.position(atUTF16Location: 0) == nil
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalPosition = try XCTUnwrap(
            buffer.position(
                atUTF16Location: (secondText as NSString).length
            )
        )
        XCTAssertEqual(finalPosition.line, secondLineCount + 1)
    }

    func testSampledLineIndexRemainsExactAcrossDenseDocumentEdits() throws {
        let lineCount = 270_000
        let source = String(repeating: "\n", count: lineCount)
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let middle = lineCount / 2

        XCTAssertLessThan(
            try XCTUnwrap(buffer.lineIndexStorageEntryCount),
            1_000
        )
        try buffer.apply(
            SourceEdit(
                range: NSRange(location: middle, length: 2),
                replacement: "long replacement\r\nwith text",
                expectedRevision: buffer.revision.number,
                origin: .localEditor(paneID: UUID())
            )
        )

        let length = (buffer.revision.text as NSString).length
        for location in [
            0,
            1,
            middle - 1,
            middle,
            middle + 1,
            middle + 20,
            length - 1,
            length,
        ] {
            let expected = referencePosition(
                at: location,
                in: buffer.revision.text
            )
            let actual = try XCTUnwrap(
                buffer.position(atUTF16Location: location)
            )
            XCTAssertEqual(actual.line, expected.line)
            XCTAssertEqual(actual.column, expected.column)
        }
        XCTAssertLessThan(
            try XCTUnwrap(buffer.lineIndexStorageEntryCount),
            1_000
        )
    }

    nonisolated func testCRLFDenseLineIndexBuildObservesCancellation() async {
        let source =
            "x"
            + String(
                repeating: "\r\n",
                count: 8 * 1_024
            )
        let gate = AsyncTestGate()
        let task = Task.detached(priority: .utility) {
            await gate.wait()
            return SourceLineIndex.buildCancellable(text: source)
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        let result = await task.value

        XCTAssertNil(result)
    }

    private func assertIndexedPositions(
        in buffer: MarkdownSourceBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = buffer.revision.text
        let length = (text as NSString).length
        for location in 0...length {
            let expected = referencePosition(
                at: location,
                in: text
            )
            guard
                let actual = buffer.position(
                    atUTF16Location: location
                )
            else {
                XCTFail(
                    "Line index unexpectedly unavailable",
                    file: file,
                    line: line
                )
                return
            }
            XCTAssertEqual(
                actual.line,
                expected.line,
                "Line mismatch at UTF-16 location \(location)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                actual.column,
                expected.column,
                "Column mismatch at UTF-16 location \(location)",
                file: file,
                line: line
            )
        }
    }

    private func referencePosition(
        at requestedLocation: Int,
        in text: String
    ) -> (line: Int, column: Int) {
        let source = text as NSString
        let location = min(max(requestedLocation, 0), source.length)
        var line = 1
        var column = 1
        var index = 0
        while index < location {
            let unit = source.character(at: index)
            if unit == 0x000D {
                if index + 1 < location,
                    source.character(at: index + 1) == 0x000A
                {
                    index += 1
                }
                line += 1
                column = 1
            } else if unit == 0x000A {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
        return (line, column)
    }
}

private actor AsyncTestGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
