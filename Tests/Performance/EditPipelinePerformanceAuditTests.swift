import Foundation
import XCTest

@testable import DarthScriptum

final class EditPipelinePerformanceAuditTests: XCTestCase {
    private struct Workload {
        let name: String
        let source: String
        let capturedMutationP95BudgetMilliseconds: Double
    }

    @MainActor
    func testLegacyBindingPipelineBaseline() throws {
        for workload in workloads {
            let source = workload.source
            let revision = SourceRevision(number: 41, text: source)
            let location = (source as NSString).length / 2
            let editorText = NSMutableString(string: source)
            editorText.insert("x", at: location)
            let updatedText = editorText as String
            let origin = DocumentChangeOrigin.localEditor(paneID: UUID())
            var resultLength = 0

            let samples = try measureSamples {
                let edit = try XCTUnwrap(
                    MarkdownEditorTextAdapter.sourceEdit(
                        editorText: updatedText,
                        currentRevision: revision,
                        newlineStyle: .lf,
                        origin: origin
                    )
                )
                resultLength = try edit.applying(to: revision).text.utf16.count
            }

            XCTAssertEqual(resultLength, source.utf16.count + 1)
            report(
                name: "legacy-binding-\(workload.name)",
                samples: samples
            )
        }
    }

    @MainActor
    func testCapturedMutationBindingPipeline() throws {
        for workload in workloads {
            let source = workload.source
            let revision = SourceRevision(number: 41, text: source)
            let sourceLength = (source as NSString).length
            let location = sourceLength / 2
            let editorText = NSMutableString(string: source)
            editorText.insert("x", at: location)
            let updatedText = editorText as String
            let origin = DocumentChangeOrigin.localEditor(paneID: UUID())
            let mutation = EditorBindingMutation(
                range: NSRange(location: location, length: 0),
                replacement: "x",
                sourceRevisionNumber: revision.number,
                presentedSourceRange: NSRange(
                    location: 0,
                    length: sourceLength
                ),
                originalPresentedLength: sourceLength,
                updatedPresentedLength: sourceLength + 1
            )
            var resultLength = 0

            let samples = try measureSamples {
                let edit = try XCTUnwrap(
                    MarkdownEditorTextAdapter.sourceEdit(
                        editorText: updatedText,
                        capturedMutation: mutation,
                        currentRevision: revision,
                        newlineStyle: .lf,
                        origin: origin
                    )
                )
                resultLength = try edit.applying(to: revision).text.utf16.count
            }

            XCTAssertEqual(resultLength, source.utf16.count + 1)
            let p95 = report(
                name: "captured-binding-\(workload.name)",
                samples: samples
            )
            XCTAssertLessThanOrEqual(
                p95,
                workload.capturedMutationP95BudgetMilliseconds,
                "Captured edit pipeline exceeded its p95 performance budget."
            )
        }
    }

    private var workloads: [Workload] {
        [
            Workload(
                name: "128kib",
                source: source(byteCount: 128 * 1_024),
                capturedMutationP95BudgetMilliseconds: 1
            ),
            Workload(
                name: "1mib",
                source: source(byteCount: 1_024 * 1_024),
                capturedMutationP95BudgetMilliseconds: 3
            ),
            Workload(
                name: "4mib",
                source: source(byteCount: 4 * 1_024 * 1_024),
                capturedMutationP95BudgetMilliseconds: 8
            ),
        ]
    }

    private func source(byteCount: Int) -> String {
        let line = "- [x] **fast** `native` [link](relative.md)\n"
        return String(repeating: line, count: max(1, byteCount / line.utf8.count))
    }

    private func measureSamples(
        warmupCount: Int = 2,
        sampleCount: Int = 9,
        operation: () throws -> Void
    ) throws -> [Double] {
        for _ in 0..<warmupCount {
            try autoreleasepool(invoking: operation)
        }
        return try (0..<sampleCount).map { _ in
            let start = ContinuousClock.now
            try autoreleasepool(invoking: operation)
            return milliseconds(ContinuousClock.now - start)
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    @discardableResult
    private func report(name: String, samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(
            sorted.count - 1,
            Int(ceil(Double(sorted.count) * 0.95)) - 1
        )
        let p95 = sorted[p95Index]
        print(
            String(
                format: "PERF_AUDIT name=%@ median_ms=%.3f p95_ms=%.3f samples=%d",
                name,
                median,
                p95,
                samples.count
            )
        )
        return p95
    }
}
