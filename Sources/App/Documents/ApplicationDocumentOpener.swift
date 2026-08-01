import AppKit

@MainActor
enum ApplicationDocumentOpener {
    static func open(
        _ url: URL,
        replacing candidate: MarkdownDocument?
    ) {
        open(
            [url],
            replacing: EmptyUntitledDocumentReplacement(
                candidate: candidate
            )
        )
    }

    static func openFromPanel(replacing candidate: MarkdownDocument?) {
        let replacement = EmptyUntitledDocumentReplacement(
            candidate: candidate
        )
        NSDocumentController.shared.beginOpenPanel { urls in
            guard let urls, !urls.isEmpty else { return }
            open(urls, replacing: replacement)
        }
    }

    private static func open(
        _ urls: [URL],
        replacing replacement: EmptyUntitledDocumentReplacement
    ) {
        let controller = NSDocumentController.shared
        for url in urls {
            controller.openDocument(
                withContentsOf: url,
                display: true
            ) { document, _, error in
                if let document {
                    replacement.complete(with: document)
                }
                if let error {
                    controller.presentError(error)
                }
            }
        }
    }
}

@MainActor
private final class EmptyUntitledDocumentReplacement {
    private weak var candidate: MarkdownDocument?

    init(candidate: MarkdownDocument?) {
        if candidate?.isReplaceableEmptyUntitledDocument == true {
            self.candidate = candidate
        } else {
            self.candidate = nil
        }
    }

    func complete(with openedDocument: NSDocument) {
        guard let candidate,
            candidate !== openedDocument,
            candidate.isReplaceableEmptyUntitledDocument
        else {
            return
        }
        self.candidate = nil
        candidate.close()
    }
}
