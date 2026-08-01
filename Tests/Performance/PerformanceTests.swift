import XCTest

@testable import DarthScriptum

final class PerformanceTests: XCTestCase {
    @MainActor
    func testFourMiBRawSourceEditPreservesExactContent() throws {
        let source = String(
            repeating: "0123456789abcdef",
            count: 256 * 1_024
        )
        let location = (source as NSString).length / 2
        let expected = NSMutableString(string: source)
        expected.replaceCharacters(
            in: NSRange(location: location, length: 16),
            with: "RAW-SOURCE-EDIT"
        )
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )

        try buffer.apply(
            SourceEdit(
                range: NSRange(location: location, length: 16),
                replacement: "RAW-SOURCE-EDIT",
                expectedRevision: buffer.revision.number,
                origin: .localEditor(paneID: UUID())
            )
        )

        XCTAssertEqual(buffer.revision.number, 1)
        XCTAssertEqual(buffer.revision.text, expected as String)
    }

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
            let position = try! XCTUnwrap(
                buffer.position(
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

        guard case .merged(let text) = result else {
            return XCTFail("Expected non-overlapping hunks to merge")
        }
        XCTAssertTrue(text.contains("local 0\n"))
        XCTAssertTrue(text.contains("external 2\n"))
    }

    @MainActor
    func testFourMiBRecoveryPersistenceRoundTripIsExact() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let documentURL = directory.appendingPathComponent("large.md")
        let identity = DocumentIdentity.make(url: documentURL)
        let data = Data(
            repeating: 0xA5,
            count: 4 * 1_024 * 1_024
        )
        let store = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )

        let persisted = try await store.addRawData(data, for: identity)
        XCTAssertEqual(persisted.byteCount, data.count)
        XCTAssertFalse(persisted.isDataResident)

        let reopened = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let entries = try await reopened.rawRecoveryEntries(for: identity)
        let recovered = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(recovered.contentDigest, persisted.contentDigest)
        let recoveredData = try await recovered.loadData()
        XCTAssertEqual(recoveredData, data)
    }

    @MainActor
    func testRendererQueueSaturationRemainsBoundedAndDeterministic()
        async
    {
        let backend = BenchmarkMermaidBackend()
        let renderer = MermaidRenderer(backend: backend)
        let submittedCount = MermaidRenderer.maximumPendingEntries + 32

        for index in 0..<submittedCount {
            XCTAssertNil(
                renderer.diagram(
                    for: "flowchart LR\nA\(index) --> B\(index)"
                )
            )
        }

        XCTAssertEqual(
            renderer.pendingEntryCountForTesting,
            MermaidRenderer.maximumPendingEntries
        )
        await backend.waitForCallCount(
            MermaidRenderer.maximumPendingEntries
        )
        XCTAssertEqual(
            backend.callCount,
            MermaidRenderer.maximumPendingEntries
        )
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
        in buffer: MarkdownSourceBuffer
    ) async throws {
        if buffer.position(atUTF16Location: 0) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            var observerToken: UUID?
            observerToken = buffer.observeLineIndex {
                if let observerToken {
                    buffer.removeLineIndexObserver(observerToken)
                }
                continuation.resume()
            }
            if buffer.position(atUTF16Location: 0) != nil {
                if let observerToken {
                    buffer.removeLineIndexObserver(observerToken)
                }
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class BenchmarkMermaidBackend: MermaidRenderingBackend {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var callCount = 0
    private var waiters: [Waiter] = []

    func render(source: String) async -> MermaidRenderOutcome {
        callCount += 1
        let ready = waiters.filter { callCount >= $0.expectedCount }
        waiters.removeAll { callCount >= $0.expectedCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
        return .unsupported
    }

    func waitForCallCount(_ expectedCount: Int) async {
        if callCount >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            if callCount >= expectedCount {
                continuation.resume()
            } else {
                waiters.append(
                    Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                )
            }
        }
    }
}
