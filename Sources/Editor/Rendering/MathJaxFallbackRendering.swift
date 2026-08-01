import Foundation
import MarkdownEngine
import MarkdownEngineLatex

@MainActor
protocol MathJaxFallbackRendering: AnyObject {
    func render(
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) async -> MathJaxFallbackRenderOutcome
}

enum MathJaxFallbackRenderOutcome {
    case rendered(MathJaxFallbackRenderedOutput)
    case unsupported
    case transientFailure
}

struct MathJaxFallbackRenderedOutput {
    let result: LatexRenderResult
    let cacheCost: Int
}
