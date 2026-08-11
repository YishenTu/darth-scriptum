import Foundation

@MainActor
final class EditorTextBindingContext {
    private struct ExpectedSourceEcho {
        let id: UInt64
        let text: String
        let revisionNumber: UInt64
    }

    private(set) var newlineStyle: NewlineStyle = .lf
    private var requestedSourceMode = false
    private var expectedSourceEchoes: [ExpectedSourceEcho] = []
    private var nextExpectedSourceEchoID: UInt64 = 0

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

    func expectSourceEcho(text: String, revisionNumber: UInt64) {
        nextExpectedSourceEchoID &+= 1
        let expectation = ExpectedSourceEcho(
            id: nextExpectedSourceEchoID,
            text: text,
            revisionNumber: revisionNumber
        )
        expectedSourceEchoes.append(expectation)
        DispatchQueue.main.async { [weak self] in
            self?.expectedSourceEchoes.removeAll {
                $0.id == expectation.id
            }
        }
    }

    func consumeExpectedSourceEcho(
        text: String,
        revisionNumber: UInt64
    ) -> Bool {
        guard
            let index = expectedSourceEchoes.firstIndex(where: {
                $0.revisionNumber <= revisionNumber && $0.text == text
            })
        else {
            return false
        }
        expectedSourceEchoes.remove(at: index)
        return true
    }
}
