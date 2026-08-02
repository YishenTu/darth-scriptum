import Foundation

@MainActor
final class EditorTextBindingContext {
    private(set) var newlineStyle: NewlineStyle = .lf
    private var requestedSourceMode = false

    func update(
        requestedSourceMode: Bool,
        newlineStyle: NewlineStyle
    ) {
        self.requestedSourceMode = requestedSourceMode
        self.newlineStyle = newlineStyle
    }

    func presentation(
        text: String,
        metrics: DocumentMetrics
    ) -> MarkdownSourcePresentation {
        MarkdownPresentationPolicy.presentation(
            requestedSourceMode: requestedSourceMode,
            text: text,
            metrics: metrics
        )
    }
}
