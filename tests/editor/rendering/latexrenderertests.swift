import AppKit
import MarkdownEngine
import XCTest
@testable import DarthScriptum

@MainActor
final class AdaptiveLatexRendererTests: XCTestCase {
    func testMathJaxRendersBlackScholesFormulaWithDfrac() async throws {
        let renderer = MathJaxFallbackRenderer()
        let formula = #"""
        d_1 = \frac{\ln\!\left(\dfrac{S_0}{K}\right) + \left(r + \dfrac{\sigma^2}{2}\right)T}{\sigma\sqrt{T}}, \qquad d_2 = d_1 - \sigma\sqrt{T}
        """#

        let outcome = await renderer.render(
            latex: formula,
            fontSize: 16,
            colorHex: "#F2E5D5"
        )
        let result = try XCTUnwrap(
            outcome.renderedResult,
            renderer.lastError ?? "MathJax did not provide an error."
        )

        XCTAssertGreaterThan(result.size.width, 0)
        XCTAssertGreaterThan(result.size.height, 0)
        XCTAssertGreaterThan(result.image.size.width, 0)
        XCTAssertGreaterThanOrEqual(result.baselineOffset, 0)
        XCTAssertLessThanOrEqual(result.baselineOffset, result.size.height)
    }

    func testMathJaxRendersAMSAndAutoloadedCommands() async throws {
        let renderer = MathJaxFallbackRenderer()
        let formulas = [
            #"\begin{aligned}a &= b + c \\ d &= e + f\end{aligned}"#,
            #"\dfrac{1}{2} + \binom{n}{k}"#,
            #"\cancel{x} + \underbrace{a+b}_{\text{sum}}"#,
            #"\dfrac{37}{113} + \begin{pmatrix}a & b \\ c & d\end{pmatrix}"#
        ]

        for formula in formulas {
            let outcome = await renderer.render(
                latex: formula,
                fontSize: 16,
                colorHex: "#F2E5D5"
            )
            XCTAssertNotNil(
                outcome.renderedResult,
                "Expected MathJax to render \(formula): "
                    + (renderer.lastError ?? "unknown error")
            )
        }
    }

    func testMathJaxRejectsUndefinedCommands() async {
        let renderer = MathJaxFallbackRenderer()

        let outcome = await renderer.render(
            latex: #"\definitelyNotATexCommand{value}"#,
            fontSize: 16,
            colorHex: "#F2E5D5"
        )

        XCTAssertNil(outcome.renderedResult)
        guard case .unsupported = outcome else {
            return XCTFail("Undefined commands should be permanently unsupported.")
        }
        XCTAssertEqual(renderer.lastError, "unsupported-latex")
    }

    func testHybridRendererDeduplicatesFallbackAndCachesResult() async throws {
        let fallback = StubMathJaxFallback(
            result: Self.makeResult(),
            delay: .milliseconds(40)
        )
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback,
            notificationCenter: center
        )
        let theme = MarkdownEditorTheme()

        XCTAssertNil(
            renderer.render(
                latex: #"\unsupported{value}"#,
                fontSize: 14,
                theme: theme
            )
        )
        XCTAssertNil(
            renderer.render(
                latex: #"\unsupported{value}"#,
                fontSize: 14,
                theme: theme
            )
        )

        try await waitUntil {
            fallback.completionCount == 1 && counter.value == 1
        }
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertNotNil(
            renderer.render(
                latex: #"\unsupported{value}"#,
                fontSize: 14,
                theme: theme
            )
        )
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertEqual(counter.value, 1)
    }

    func testHybridRendererPublishesCompletedFallbackIncrementally() async throws {
        let fallback = ControllableMathJaxFallback(
            output: Self.makeOutput()
        )
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback,
            notificationCenter: center
        )
        let theme = MarkdownEditorTheme()

        XCTAssertNil(
            renderer.render(latex: "first", fontSize: 14, theme: theme)
        )
        XCTAssertNil(
            renderer.render(latex: "second", fontSize: 14, theme: theme)
        )

        try await waitUntil {
            fallback.startedFormulas.count == 2
        }
        fallback.complete(formula: "first")
        try await waitUntil {
            counter.value == 1
        }
        XCTAssertEqual(counter.value, 1)
        XCTAssertNotNil(
            renderer.render(latex: "first", fontSize: 14, theme: theme)
        )
        XCTAssertNil(
            renderer.render(latex: "second", fontSize: 14, theme: theme)
        )

        fallback.complete(formula: "second")
        try await waitUntil {
            counter.value == 2
        }
    }

    func testUnrelatedEditKeepsInFlightFallbackForUnchangedFormula() async throws {
        let fallback = StubMathJaxFallback(
            result: Self.makeResult(),
            delay: .milliseconds(100)
        )
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )
        let theme = MarkdownEditorTheme()

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: "$stable$"
        )
        XCTAssertNil(
            renderer.render(latex: "stable", fontSize: 14, theme: theme)
        )

        renderer.prepareForPresentation(
            revisionNumber: 1,
            fontSize: 14,
            rawSourceMode: false,
            source: "Unrelated edit\n\n$stable$"
        )
        try await waitUntil {
            fallback.completionCount == 1
        }

        XCTAssertNotNil(
            renderer.render(latex: "stable", fontSize: 14, theme: theme)
        )
        XCTAssertEqual(fallback.callCount, 1)
    }

    func testHybridRendererBoundsPendingFallbackWork() async throws {
        let fallback = StubMathJaxFallback(
            result: Self.makeResult(),
            delay: .milliseconds(200)
        )
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )

        for index in 0..<(AdaptiveLatexRenderer.maximumPendingEntries + 10) {
            XCTAssertNil(
                renderer.render(
                    latex: "formula-\(index)",
                    fontSize: 14,
                    theme: MarkdownEditorTheme()
                )
            )
        }

        try await waitUntil {
            fallback.callCount == AdaptiveLatexRenderer.maximumPendingEntries
        }
        XCTAssertEqual(
            fallback.callCount,
            AdaptiveLatexRenderer.maximumPendingEntries
        )
    }

    func testPresentationChangePrioritizesCurrentFallbackWork() async throws {
        let fallback = ControllableMathJaxFallback(
            output: Self.makeOutput()
        )
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback,
            notificationCenter: center
        )
        let theme = MarkdownEditorTheme()
        let staleFormulas = (
            0..<(AdaptiveLatexRenderer.maximumPendingEntries + 4)
        ).map { "stale-\($0)" }
        let currentFormula = "current-presentation"
        let source = (staleFormulas + [currentFormula])
            .joined(separator: "\n")

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: source
        )
        for formula in staleFormulas {
            XCTAssertNil(
                renderer.render(
                    latex: formula,
                    fontSize: 14,
                    theme: theme
                )
            )
        }
        try await waitUntil {
            fallback.startedFormulas.count
                == AdaptiveLatexRenderer.maximumPendingEntries
        }

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 18,
            rawSourceMode: false,
            source: source
        )
        XCTAssertNil(
            renderer.render(
                latex: currentFormula,
                fontSize: 18,
                theme: theme
            )
        )
        fallback.complete(formula: staleFormulas[0])

        try await waitUntil {
            fallback.startedFormulas.contains(currentFormula)
        }
        XCTAssertEqual(fallback.startedFormulas.last, currentFormula)
        XCTAssertFalse(
            fallback.startedFormulas.contains(
                staleFormulas[AdaptiveLatexRenderer.maximumPendingEntries]
            )
        )
        XCTAssertEqual(counter.value, 0)

        fallback.complete(formula: currentFormula)
        try await waitUntil {
            counter.value == 1
        }
        XCTAssertNotNil(
            renderer.render(
                latex: currentFormula,
                fontSize: 18,
                theme: theme
            )
        )

        for formula in staleFormulas[
            1..<AdaptiveLatexRenderer.maximumPendingEntries
        ] {
            fallback.complete(formula: formula)
        }
        try await waitUntil {
            renderer.pendingEntryCountForTesting == 0
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testSourceModeDiscardsQueuedFallbackWork() async throws {
        let fallback = ControllableMathJaxFallback(
            output: Self.makeOutput()
        )
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback,
            notificationCenter: center
        )
        let theme = MarkdownEditorTheme()
        let formulas = (
            0..<(AdaptiveLatexRenderer.maximumPendingEntries + 4)
        ).map { "formula-\($0)" }
        let source = formulas.joined(separator: "\n")

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: source
        )
        for formula in formulas {
            XCTAssertNil(
                renderer.render(
                    latex: formula,
                    fontSize: 14,
                    theme: theme
                )
            )
        }
        try await waitUntil {
            fallback.startedFormulas.count
                == AdaptiveLatexRenderer.maximumPendingEntries
        }

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: true,
            source: source
        )
        for formula in formulas.prefix(
            AdaptiveLatexRenderer.maximumPendingEntries
        ) {
            fallback.complete(formula: formula)
        }

        try await waitUntil {
            renderer.pendingEntryCountForTesting == 0
        }
        XCTAssertEqual(
            fallback.startedFormulas.count,
            AdaptiveLatexRenderer.maximumPendingEntries
        )
        XCTAssertEqual(counter.value, 0)
    }

    func testHybridRendererMakesProgressBeyondCacheCapacity() async throws {
        let fallback = StubMathJaxFallback(result: Self.makeResult())
        let primary = CountingUnsupportedLatexRenderer()
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: primary,
            fallback: fallback,
            notificationCenter: center
        )
        let formulas = (0..<300).map { "formula-\($0)" }
        let theme = MarkdownEditorTheme()

        for _ in 0..<100 {
            for formula in formulas {
                _ = renderer.render(
                    latex: formula,
                    fontSize: 14,
                    theme: theme
                )
            }
            if fallback.callCount == formulas.count {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntil {
            fallback.completionCount == formulas.count
        }

        XCTAssertEqual(fallback.callCount, formulas.count)
        XCTAssertEqual(primary.callCount, formulas.count)
        XCTAssertNotNil(
            renderer.render(
                latex: formulas[0],
                fontSize: 14,
                theme: theme
            )
        )
        await Task.yield()
        XCTAssertEqual(fallback.callCount, formulas.count)
        XCTAssertEqual(primary.callCount, formulas.count)
        XCTAssertLessThanOrEqual(counter.value, 2)
        XCTAssertNotNil(
            renderer.render(
                latex: formulas[formulas.count - 1],
                fontSize: 14,
                theme: theme
            )
        )
    }

    func testHybridRendererBoundsSuccessfulPrimaryCache() {
        let primary = CountingSupportedLatexRenderer()
        let renderer = AdaptiveLatexRenderer(
            primary: primary,
            fallback: StubMathJaxFallback(result: nil)
        )
        let theme = MarkdownEditorTheme()
        let formulaCount = AdaptiveLatexRenderer.maximumTrackedEntries + 1

        for index in 0..<formulaCount {
            XCTAssertNotNil(
                renderer.render(
                    latex: "native-\(index)",
                    fontSize: 14,
                    theme: theme
                )
            )
        }
        XCTAssertEqual(primary.callCount, formulaCount)

        XCTAssertNotNil(
            renderer.render(
                latex: "native-0",
                fontSize: 14,
                theme: theme
            )
        )
        XCTAssertEqual(primary.callCount, formulaCount + 1)
    }

    func testHybridRendererEvictsLeastRecentlyUsedEntryAtCapacity() async throws {
        let fallback = StubMathJaxFallback(result: Self.makeResult())
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )
        let theme = MarkdownEditorTheme()
        let formulas = (0..<AdaptiveLatexRenderer.maximumTrackedEntries)
            .map { "formula-\($0)" }

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: formulas.joined(separator: "\n")
        )
        for formula in formulas {
            XCTAssertNil(
                renderer.render(
                    latex: formula,
                    fontSize: 14,
                    theme: theme
                )
            )
        }
        try await waitUntil(timeout: .seconds(10)) {
            fallback.completionCount == formulas.count
        }

        renderer.prepareForPresentation(
            revisionNumber: 1,
            fontSize: 14,
            rawSourceMode: false,
            source: (formulas + ["active-overflow", "another-overflow"])
                .joined(separator: "\n")
        )
        for formula in formulas {
            XCTAssertNotNil(
                renderer.render(
                    latex: formula,
                    fontSize: 14,
                    theme: theme
                )
            )
        }
        XCTAssertNil(
            renderer.render(
                latex: "active-overflow",
                fontSize: 14,
                theme: theme
            )
        )
        try await waitUntil {
            fallback.completionCount == formulas.count + 1
        }
        XCTAssertNotNil(
            renderer.render(
                latex: "active-overflow",
                fontSize: 14,
                theme: theme
            )
        )
        XCTAssertNil(
            renderer.render(
                latex: formulas[0],
                fontSize: 14,
                theme: theme
            )
        )
        try await waitUntil {
            fallback.completionCount == formulas.count + 2
        }
        XCTAssertNotNil(
            renderer.render(
                latex: formulas[0],
                fontSize: 14,
                theme: theme
            )
        )

        renderer.prepareForPresentation(
            revisionNumber: 2,
            fontSize: 14,
            rawSourceMode: false,
            source: "replacement-after-deletion"
        )
        XCTAssertNil(
            renderer.render(
                latex: "replacement-after-deletion",
                fontSize: 14,
                theme: theme
            )
        )
        try await waitUntil {
            fallback.completionCount == formulas.count + 3
        }
        XCTAssertNotNil(
            renderer.render(
                latex: "replacement-after-deletion",
                fontSize: 14,
                theme: theme
            )
        )
    }

    func testMathJaxCacheCostIncludesDecodedBackingMemory() {
        XCTAssertEqual(
            MathJaxFallbackRenderer.estimatedCacheCost(
                svgByteCount: 100,
                width: 10,
                height: 5,
                backingScale: 2
            ),
            900
        )
        XCTAssertNil(
            MathJaxFallbackRenderer.estimatedCacheCost(
                svgByteCount: 1,
                width: 8_192,
                height: 8_192,
                backingScale: 2
            )
        )
    }

    func testHybridRendererRetriesTransientFallbackFailure() async throws {
        let fallback = SequencedMathJaxFallback(
            outcomes: [
                .transientFailure,
                .rendered(Self.makeOutput())
            ]
        )
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )
        let theme = MarkdownEditorTheme()

        XCTAssertNil(
            renderer.render(
                latex: "retryable",
                fontSize: 14,
                theme: theme
            )
        )
        try await waitUntil {
            fallback.callCount == 1
        }
        XCTAssertNil(
            renderer.render(
                latex: "retryable",
                fontSize: 14,
                theme: theme
            )
        )
        XCTAssertEqual(fallback.callCount, 1)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(
            renderer.render(
                latex: "retryable",
                fontSize: 14,
                theme: theme
            )
        )
        try await waitUntil {
            fallback.callCount == 2
        }
        XCTAssertNotNil(
            renderer.render(
                latex: "retryable",
                fontSize: 14,
                theme: theme
            )
        )
    }

    func testHybridRendererBoundsTransientFailureState() async throws {
        let fallback = AlwaysTransientMathJaxFallback()
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )
        let theme = MarkdownEditorTheme()
        let formulas = (0...AdaptiveLatexRenderer.maximumTrackedEntries)
            .map { "transient-\($0)" }

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: formulas.joined(separator: "\n")
        )
        for batchStart in stride(
            from: 0,
            to: formulas.count,
            by: AdaptiveLatexRenderer.maximumPendingEntries
        ) {
            let batchEnd = min(
                batchStart + AdaptiveLatexRenderer.maximumPendingEntries,
                formulas.count
            )
            for formula in formulas[batchStart..<batchEnd] {
                XCTAssertNil(
                    renderer.render(
                        latex: formula,
                        fontSize: 14,
                        theme: theme
                    )
                )
            }
            try await waitUntil {
                fallback.callCount == batchEnd
            }
        }

        XCTAssertEqual(
            renderer.transientFailureEntryCountForTesting,
            AdaptiveLatexRenderer.maximumTrackedEntries
        )
    }

    func testTransientFailuresCoalesceRetryWakeup() async throws {
        let fallback = AlwaysTransientMathJaxFallback()
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback,
            notificationCenter: center
        )
        let formulas = (0..<32).map { "transient-\($0)" }

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: formulas.joined(separator: "\n")
        )
        for formula in formulas {
            XCTAssertNil(
                renderer.render(
                    latex: formula,
                    fontSize: 14,
                    theme: MarkdownEditorTheme()
                )
            )
        }

        try await waitUntil {
            fallback.callCount == formulas.count
                && renderer.hasRetryWakeupForTesting
        }
        try await waitUntil {
            counter.value == 1
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testSourceModeCancelsTransientRetryWakeup() async throws {
        let fallback = AlwaysTransientMathJaxFallback()
        let center = NotificationCenter()
        let counter = LockedCounter()
        let observer = center.addObserver(
            forName: .latexRendererDidUpdate,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(observer) }
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback,
            notificationCenter: center
        )

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: false,
            source: "$transient$"
        )
        XCTAssertNil(
            renderer.render(
                latex: "transient",
                fontSize: 14,
                theme: MarkdownEditorTheme()
            )
        )
        try await waitUntil {
            fallback.callCount == 1
                && renderer.hasRetryWakeupForTesting
        }

        renderer.prepareForPresentation(
            revisionNumber: 0,
            fontSize: 14,
            rawSourceMode: true,
            source: "$transient$"
        )

        XCTAssertFalse(renderer.hasRetryWakeupForTesting)
        XCTAssertEqual(counter.value, 0)
    }

    func testHybridRendererNegativeCachesFallbackFailures() async throws {
        let fallback = StubMathJaxFallback(
            result: nil,
            delay: .milliseconds(10)
        )
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )
        let theme = MarkdownEditorTheme()

        XCTAssertNil(
            renderer.render(
                latex: #"\notacommand"#,
                fontSize: 14,
                theme: theme
            )
        )
        try await waitUntil {
            fallback.completionCount == 1
        }
        XCTAssertNil(
            renderer.render(
                latex: #"\notacommand"#,
                fontSize: 14,
                theme: theme
            )
        )
        await Task.yield()
        XCTAssertEqual(fallback.callCount, 1)
    }

    func testHybridRendererRejectsOversizedInputBeforeFallback() async {
        let fallback = StubMathJaxFallback(result: Self.makeResult())
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )

        XCTAssertNil(
            renderer.render(
                latex: String(
                    repeating: "x",
                    count: AdaptiveLatexRenderer.maximumLatexUTF8Bytes + 1
                ),
                fontSize: 14,
                theme: MarkdownEditorTheme()
            )
        )
        await Task.yield()
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testHybridRendererMeasuresCombiningMarksByStorageLength() async {
        let fallback = StubMathJaxFallback(result: Self.makeResult())
        let renderer = AdaptiveLatexRenderer(
            primary: UnsupportedLatexRenderer(),
            fallback: fallback
        )
        let oversizedSingleGrapheme = "a" + String(
            repeating: "\u{0301}",
            count: AdaptiveLatexRenderer.maximumLatexUTF8Bytes
        )

        XCTAssertEqual(oversizedSingleGrapheme.count, 1)
        XCTAssertNil(
            renderer.render(
                latex: oversizedSingleGrapheme,
                fontSize: 14,
                theme: MarkdownEditorTheme()
            )
        )
        await Task.yield()
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testMathJaxResourcesAreBundledAndNetworkDisabled() throws {
        let rendererURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "mathjax-renderer",
                withExtension: "html",
                subdirectory: "MathJax.bundle"
            )
        )
        let html = try String(contentsOf: rendererURL, encoding: .utf8)
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("http://"))

        let bundleURL = try XCTUnwrap(
            Bundle.main.resourceURL?
                .appendingPathComponent("MathJax.bundle", isDirectory: true)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent("tex-svg-full.js")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent("LICENSE")
                    .path
            )
        )
        let packageData = try Data(
            contentsOf: bundleURL.appendingPathComponent("package.json")
        )
        let package = try XCTUnwrap(
            JSONSerialization.jsonObject(with: packageData)
                as? [String: Any]
        )
        XCTAssertEqual(package["version"] as? String, "3.2.2")
        XCTAssertEqual(package["license"] as? String, "Apache-2.0")
    }

    private static func makeResult() -> LatexRenderResult {
        let size = CGSize(width: 20, height: 10)
        return LatexRenderResult(
            image: NSImage(size: size),
            size: size,
            baselineOffset: 2
        )
    }

    private static func makeOutput() -> MathJaxFallbackRenderedOutput {
        MathJaxFallbackRenderedOutput(
            result: makeResult(),
            cacheCost: 1_024
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the LaTeX renderer.")
    }
}

private struct UnsupportedLatexRenderer: LatexRenderer {
    func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        nil
    }
}

private final class CountingUnsupportedLatexRenderer:
    LatexRenderer,
    @unchecked Sendable {
    private(set) var callCount = 0

    func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        callCount += 1
        return nil
    }
}

private final class CountingSupportedLatexRenderer:
    LatexRenderer,
    @unchecked Sendable {
    private(set) var callCount = 0

    func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        callCount += 1
        let size = CGSize(width: 20, height: 10)
        return LatexRenderResult(
            image: NSImage(size: size),
            size: size,
            baselineOffset: 2
        )
    }
}

@MainActor
private final class StubMathJaxFallback: MathJaxFallbackRendering {
    private(set) var callCount = 0
    private(set) var completionCount = 0

    private let result: LatexRenderResult?
    private let delay: Duration

    init(
        result: LatexRenderResult?,
        delay: Duration = .zero
    ) {
        self.result = result
        self.delay = delay
    }

    func render(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome {
        callCount += 1
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        completionCount += 1
        if let result {
            return .rendered(
                MathJaxFallbackRenderedOutput(
                    result: result,
                    cacheCost: 1_024
                )
            )
        }
        return .unsupported
    }
}

@MainActor
private final class ControllableMathJaxFallback: MathJaxFallbackRendering {
    private(set) var startedFormulas: [String] = []

    private let output: MathJaxFallbackRenderedOutput
    private var continuations: [
        String: CheckedContinuation<MathJaxFallbackRenderOutcome, Never>
    ] = [:]

    init(output: MathJaxFallbackRenderedOutput) {
        self.output = output
    }

    func render(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome {
        startedFormulas.append(latex)
        return await withCheckedContinuation { continuation in
            continuations[latex] = continuation
        }
    }

    func complete(formula: String) {
        continuations.removeValue(forKey: formula)?.resume(
            returning: .rendered(output)
        )
    }
}

@MainActor
private final class AlwaysTransientMathJaxFallback:
    MathJaxFallbackRendering {
    private(set) var callCount = 0

    func render(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome {
        callCount += 1
        return .transientFailure
    }
}

@MainActor
private final class SequencedMathJaxFallback: MathJaxFallbackRendering {
    private(set) var callCount = 0
    private var outcomes: [MathJaxFallbackRenderOutcome]

    init(outcomes: [MathJaxFallbackRenderOutcome]) {
        self.outcomes = outcomes
    }

    func render(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome {
        callCount += 1
        guard !outcomes.isEmpty else {
            return .transientFailure
        }
        return outcomes.removeFirst()
    }
}

private extension MathJaxFallbackRenderOutcome {
    var renderedResult: LatexRenderResult? {
        if case let .rendered(output) = self {
            return output.result
        }
        return nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
