import AppKit
import Foundation
import MarkdownEngine
import SwiftUI
import XCTest

@testable import DarthScriptum

final class EditPipelinePerformanceAuditTests: XCTestCase {
    private struct Workload {
        let name: String
        let source: String
        let capturedMutationP95BudgetMilliseconds: Double
    }

    @MainActor
    func testPreparedFourMiBInstallationStaysWithinMainActorBudget() async throws {
        let source = source(byteCount: 4 * 1_024 * 1_024)
        let snapshot = DocumentSnapshot(text: source, format: .newDocument)
        let preparedContent = await Task.detached {
            PreparedSourceContent(snapshot: snapshot)
        }.value
        var installedBuffer: MarkdownSourceBuffer?

        let samples = try measureSamples {
            installedBuffer = nil
            installedBuffer = MarkdownSourceBuffer(
                preparedContent: preparedContent
            )
            XCTAssertEqual(installedBuffer?.metrics, preparedContent.metrics)
        }
        installedBuffer = nil

        let p95 = report(
            name: "prepared-source-installation-4mib",
            samples: samples
        )
        XCTAssertLessThanOrEqual(
            p95,
            5,
            "Installing prepared source must not rescan it on the main actor."
        )
    }

    @MainActor
    func testSplitPaneUserEditPropagationStaysWithinIncrementalBudget()
        async throws
    {
        let source = source(byteCount: 128 * 1_024)
        let buffer = MarkdownSourceBuffer(
            snapshot: DocumentSnapshot(text: source, format: .newDocument)
        )
        let workspace = WorkspaceModel()
        let hostingView = NSHostingView(
            rootView: HStack(spacing: 0) {
                LivePreviewTextView(
                    sourceBuffer: buffer,
                    pane: workspace.primaryPane,
                    sourceMode: false,
                    fontSize: 14,
                    newlineStyle: .lf
                )
                LivePreviewTextView(
                    sourceBuffer: buffer,
                    pane: workspace.secondaryPane,
                    sourceMode: false,
                    fontSize: 14,
                    newlineStyle: .lf
                )
            }
            .frame(width: 1_200, height: 600)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        try await waitUntil {
            let textViews = MarkdownEngineCompatibility.nativeTextViews(
                in: hostingView
            )
            return textViews.count == 2
                && textViews.allSatisfy { $0.string == source }
                && textViews.contains {
                    $0.identifier?.rawValue
                        == "DarthScriptum.MarkdownEditor."
                        + workspace.primaryPane.id.uuidString
                }
        }
        let primaryTextView = try XCTUnwrap(
            MarkdownEngineCompatibility.nativeTextViews(in: hostingView)
                .first {
                    $0.identifier?.rawValue
                        == "DarthScriptum.MarkdownEditor."
                        + workspace.primaryPane.id.uuidString
                }
        )
        let sourceText = source as NSString
        let middleSearchRange = NSRange(
            location: sourceText.length / 2,
            length: sourceText.length - sourceText.length / 2
        )
        let target = sourceText.range(
            of: "fast",
            options: [],
            range: middleSearchRange
        )
        guard target.location != NSNotFound else {
            XCTFail("The continuous-list fixture must contain an editable item.")
            return
        }
        var insertionLocation = NSMaxRange(target)
        var samples: [Double] = []
        var originatingPaneSamples: [Double] = []
        for index in 0..<9 {
            let replacement = String(index)
            let expected = NSMutableString(string: buffer.revision.text)
            expected.insert(replacement, at: insertionLocation)
            let expectedText = expected as String
            let start = ContinuousClock.now
            let insertionRange = NSRange(
                location: insertionLocation,
                length: 0
            )
            primaryTextView.setSelectedRange(insertionRange)
            primaryTextView.insertText(
                replacement,
                replacementRange: insertionRange
            )
            insertionLocation += replacement.utf16.count
            originatingPaneSamples.append(
                milliseconds(ContinuousClock.now - start)
            )
            try await waitUntil {
                let textViews = MarkdownEngineCompatibility.nativeTextViews(
                    in: hostingView
                )
                return textViews.count == 2
                    && textViews.allSatisfy { $0.string == expectedText }
            }
            samples.append(milliseconds(ContinuousClock.now - start))
        }

        _ = report(
            name: "originating-pane-user-edit-128kib",
            samples: originatingPaneSamples
        )
        let p95 = report(
            name: "split-pane-user-edit-propagation-128kib",
            samples: samples
        )
        XCTAssertLessThanOrEqual(
            p95,
            1_000,
            "The 128 KiB continuous-list workload must avoid full pane rebuilds."
        )
        window.contentView = nil
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

    @MainActor
    func testUncachedMaximumSizeImageLookupStaysWithinSynchronousBudget()
        throws
    {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let documentURL = rootURL.appendingPathComponent("document.md")
        try Data().write(to: documentURL)
        let fixtureURL = rootURL.appendingPathComponent("image-0.png")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixtureURL.path,
                contents: nil
            )
        )
        let fixtureHandle = try FileHandle(forWritingTo: fixtureURL)
        try fixtureHandle.truncate(
            atOffset: UInt64(MarkdownImageLoader.maximumEncodedImageBytes)
        )
        try fixtureHandle.close()

        let requestCount = 11
        for index in 1..<requestCount {
            try FileManager.default.linkItem(
                at: fixtureURL,
                to: rootURL.appendingPathComponent("image-\(index).png")
            )
        }
        let loader = PerformanceBlockingImageLoader()
        let provider = MarkdownImageProvider(
            documentURL: documentURL,
            loader: loader,
            publishUpdate: {}
        )
        defer {
            loader.releaseAll()
            provider.dispose()
        }
        var requestIndex = 0

        let samples = try measureSamples {
            let request = EmbeddedImageRequest(
                name: "image-\(requestIndex).png"
            )
            requestIndex += 1
            XCTAssertNil(provider.image(for: request))
        }

        XCTAssertEqual(requestIndex, requestCount)
        XCTAssertEqual(provider.pendingLoadCountForTesting, requestCount)
        let p95 = report(
            name: "uncached-image-scheduling-32mib",
            samples: samples
        )
        XCTAssertLessThanOrEqual(
            p95,
            5,
            "An uncached image lookup must never synchronously read or decode."
        )
    }

    func testAboveLimitMergeRejectionStaysWithinBudget() throws {
        let oversizedCore = String(
            repeating: "x",
            count: ThreeWayTextMerger.maximumChangedCoreUTF8ByteCount + 1
        )
        let merger = ThreeWayTextMerger()
        var result: ThreeWayMergeResult?

        let samples = try measureSamples {
            result = merger.merge(
                base: "base",
                local: oversizedCore,
                external: "external"
            )
        }

        XCTAssertEqual(result, .conflict)
        let p95 = report(
            name: "oversized-merge-rejection-8mib",
            samples: samples
        )
        XCTAssertLessThanOrEqual(
            p95,
            100,
            "Unsupported merge inputs must fail closed before expensive diffing."
        )
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

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for split-pane source propagation.")
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

private final class PerformanceBlockingImageLoader: MarkdownImageLoading,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var isReleased = false

    func load(_ request: MarkdownImageLoadRequest) -> MarkdownDecodedImage? {
        _ = request
        condition.lock()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return nil
    }

    func releaseAll() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
