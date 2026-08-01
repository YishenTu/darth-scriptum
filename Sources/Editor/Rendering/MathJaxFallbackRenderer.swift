import AppKit
import Foundation
import MarkdownEngine
import MarkdownEngineLatex
import WebKit

@MainActor
final class MathJaxFallbackRenderer: NSObject, MathJaxFallbackRendering {
    private enum JavaScriptInvocationOutcome: @unchecked Sendable {
        case value(Any?)
        case failure(String)
    }

    private static let maximumSVGBytes = 2 * 1_024 * 1_024
    private static let maximumQueuedRenders =
        AdaptiveLaTeXRenderer.maximumPendingEntries

    private(set) var lastError: String?
    private let session: LocalWebRenderSession
    private var isRendering = false
    private var renderWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        session = LocalWebRenderSession(
            resourcePolicy: LocalWebResourcePolicy(
                bundle: .main,
                entryResourceName: "mathjax-renderer",
                resourceDirectoryName: "MathJax.bundle"
            )
        )
        super.init()
    }

    #if DEBUG || TESTING
        var webViewForTesting: WKWebView? {
            session.webViewForTesting
        }

        var sessionForTesting: LocalWebRenderSession {
            session
        }

        var loadWaiterCountForTesting: Int {
            session.loadWaiterCountForTesting
        }

        var hasLoadTimeoutForTesting: Bool {
            session.hasLoadTimeoutForTesting
        }

        var hasActiveInvocationForTesting: Bool {
            session.hasActiveJavaScriptEvaluationForTesting
        }

        func waitForLoadForTesting() async -> Bool {
            await session.waitForReadinessForTesting(loadsEntry: false)
        }

        func waitForInvocationForTesting() async -> Bool {
            switch await session.waitForJavaScriptEvaluationForTesting() {
            case .value:
                true
            case .failure, .timedOut, .cancelled, .processTerminated:
                false
            }
        }
    #endif

    func render(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome {
        guard await acquireRenderSlot() else {
            lastError = "MathJax renderer queue is full."
            return .transientFailure
        }
        let outcome = await renderSerially(
            latex: latex,
            fontSize: fontSize,
            colorHex: colorHex
        )
        releaseRenderSlot()
        return outcome
    }

    private func renderSerially(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome {
        guard await session.waitUntilReady() else {
            lastError = "MathJax renderer page failed to load."
            return .transientFailure
        }

        let invocation = await invokeJavaScript(
            latex: latex,
            fontSize: fontSize,
            colorHex: colorHex
        )
        guard case .value(let value) = invocation else {
            if case .failure(let message) = invocation {
                lastError = message
            }
            return .transientFailure
        }
        guard let response = value as? [String: Any] else {
            lastError = "MathJax returned an invalid response."
            return .transientFailure
        }
        if let error = response["error"] as? String {
            lastError = error
            return Self.isPermanentRenderError(error)
                ? .unsupported
                : .transientFailure
        }
        guard let svg = response["svg"] as? String,
            let data = svg.data(using: .utf8),
            data.count <= Self.maximumSVGBytes,
            let width = Self.number(response["width"]),
            let height = Self.number(response["height"]),
            let baseline = Self.number(response["baseline"]),
            width.isFinite,
            height.isFinite,
            baseline.isFinite,
            width > 0,
            height > 0
        else {
            lastError = "MathJax returned invalid SVG output."
            return .transientFailure
        }
        let backingScale = max(
            1,
            NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        )
        guard
            let cacheCost = Self.estimatedCacheCost(
                svgByteCount: data.count,
                width: width,
                height: height,
                backingScale: backingScale
            )
        else {
            lastError = "output-too-large"
            return .unsupported
        }
        guard let image = NSImage(data: data) else {
            lastError = "MathJax returned invalid SVG output."
            return .transientFailure
        }

        lastError = nil
        let size = CGSize(width: width, height: height)
        image.size = size
        return .rendered(
            MathJaxFallbackRenderedOutput(
                result: LatexRenderResult(
                    image: image,
                    size: size,
                    baselineOffset: min(max(0, baseline), height)
                ),
                cacheCost: cacheCost
            )
        )
    }

    private func invokeJavaScript(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> JavaScriptInvocationOutcome {
        switch await session.evaluateJavaScript(
            """
            return await window.renderLaTeX(
                latex,
                fontSize,
                color
            );
            """,
            arguments: [
                "latex": latex,
                "fontSize": fontSize,
                "color": colorHex,
            ]
        ) {
        case .value(let value):
            .value(value)
        case .failure(let message):
            .failure(message)
        case .timedOut:
            .failure("MathJax rendering timed out.")
        case .cancelled:
            .failure("MathJax web renderer was reset.")
        case .processTerminated:
            .failure("MathJax web process terminated.")
        }
    }

    private static func isPermanentRenderError(_ error: String) -> Bool {
        switch error {
        case "invalid-input",
            "invalid-dimensions",
            "missing-svg",
            "output-too-large",
            "unsupported-latex":
            true
        default:
            false
        }
    }

    static func estimatedCacheCost(
        svgByteCount: Int,
        width: CGFloat,
        height: CGFloat,
        backingScale: CGFloat
    ) -> Int? {
        guard svgByteCount >= 0,
            width.isFinite,
            height.isFinite,
            backingScale.isFinite,
            width > 0,
            height > 0,
            backingScale >= 1
        else {
            return nil
        }
        let pixelWidth = ceil(Double(width * backingScale))
        let pixelHeight = ceil(Double(height * backingScale))
        let decodedByteCount = pixelWidth * pixelHeight * 4
        let total = decodedByteCount + Double(svgByteCount)
        guard total.isFinite,
            total <= Double(AdaptiveLaTeXRenderer.maximumCacheCost),
            total <= Double(Int.max)
        else {
            return nil
        }
        return Int(total.rounded(.up))
    }

    private func acquireRenderSlot() async -> Bool {
        if !isRendering {
            isRendering = true
            return true
        }
        guard renderWaiters.count < Self.maximumQueuedRenders - 1 else {
            return false
        }
        await withCheckedContinuation { continuation in
            renderWaiters.append(continuation)
        }
        return true
    }

    private func releaseRenderSlot() {
        if renderWaiters.isEmpty {
            isRendering = false
        } else {
            renderWaiters.removeFirst().resume()
        }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as NSNumber:
            CGFloat(value.doubleValue)
        case let value as Double:
            CGFloat(value)
        default:
            nil
        }
    }
}
