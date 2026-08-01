import AppKit
import ObjectiveC

@MainActor
extension MarkdownEngineCompatibility {
    private static let markdownDocumentExtensions: Set<String> = [
        "md",
        "markdown",
        "mdown",
    ]

    static func setMarkdownFileDropHandler(
        on textView: NSTextView,
        handler: @escaping ([URL]) -> Void
    ) {
        guard MarkdownFileDropRuntime.isInstalled else { return }
        MarkdownFileDropRuntime.handlers.setObject(
            MarkdownFileDropHandler(handler),
            forKey: textView
        )
    }

    static func removeMarkdownFileDropHandler(from textView: NSTextView) {
        MarkdownFileDropRuntime.handlers.removeObject(forKey: textView)
    }

    static func performFileDrop(
        on textView: NSTextView,
        pasteboard: NSPasteboard,
        defaultOperation: () -> Bool
    ) -> Bool {
        guard
            let handler = MarkdownFileDropRuntime.handlers.object(
                forKey: textView
            ),
            let fileURLs = fileURLs(from: pasteboard),
            fileURLs.allSatisfy(isMarkdownDocument)
        else {
            return defaultOperation()
        }
        handler.open(fileURLs)
        return true
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        guard let objects, !objects.isEmpty else { return nil }
        let urls = objects.compactMap { ($0 as? NSURL) as URL? }
        guard urls.count == objects.count else { return nil }
        return urls
    }

    private static func isMarkdownDocument(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return markdownDocumentExtensions.contains(
            url.pathExtension.lowercased()
        )
    }
}

@MainActor
private final class MarkdownFileDropHandler: NSObject {
    let open: ([URL]) -> Void

    init(_ open: @escaping ([URL]) -> Void) {
        self.open = open
    }
}

@MainActor
private enum MarkdownFileDropRuntime {
    // MarkdownEngine's native text-view subclass is internal and exposes no
    // file-drop hook. Exchange the inherited operation once; weak handlers
    // keep interception scoped to attached editor views.
    static let handlers = NSMapTable<NSTextView, MarkdownFileDropHandler>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static let isInstalled: Bool = {
        let originalSelector = #selector(NSTextView.performDragOperation(_:))
        let replacementSelector = #selector(
            NSTextView.darthScriptumPerformDragOperation(_:)
        )
        guard
            let originalMethod = class_getInstanceMethod(
                NSTextView.self,
                originalSelector
            ),
            let replacementMethod = class_getInstanceMethod(
                NSTextView.self,
                replacementSelector
            )
        else {
            assertionFailure("NSTextView drag operation hooks are unavailable.")
            return false
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
        return true
    }()
}

@MainActor
extension NSTextView {
    @objc fileprivate dynamic func darthScriptumPerformDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        MarkdownEngineCompatibility.performFileDrop(
            on: self,
            pasteboard: sender.draggingPasteboard
        ) {
            darthScriptumPerformDragOperation(sender)
        }
    }
}
