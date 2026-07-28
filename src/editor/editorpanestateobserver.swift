import AppKit

@MainActor
final class EditorPaneStateCoordinator: NSObject {
    private let sourceBuffer: MarkdownSourceBuffer
    private let pane: EditorPaneModel
    private let mermaidPresenter: MermaidBlockPresenter
    private let onBecameActive: @MainActor () -> Void
    private var presentation: MarkdownSourcePresentation
    private var normalizesDisplayMathSelection: Bool
    private weak var textView: NSTextView?
    private weak var clipView: NSClipView?
    private var sourceObservation: UUID?
    private var lineIndexObservation: UUID?
    private var lastSourceText: String
    private var hasRestoredState = false
    private var pendingSelectionRestore: NSRange?

    init(
        sourceBuffer: MarkdownSourceBuffer,
        pane: EditorPaneModel,
        presentation: MarkdownSourcePresentation? = nil,
        normalizesDisplayMathSelection: Bool = true,
        onBecameActive: @escaping @MainActor () -> Void = {}
    ) {
        self.sourceBuffer = sourceBuffer
        self.pane = pane
        mermaidPresenter = MermaidBlockPresenter(
            renderer: pane.mermaidRenderer
        )
        self.presentation = presentation ?? MarkdownSourcePresentation.make(
            source: sourceBuffer.revision.text,
            rendersMarkdown: true
        )
        self.normalizesDisplayMathSelection = normalizesDisplayMathSelection
        self.onBecameActive = onBecameActive
        lastSourceText = sourceBuffer.revision.text
        super.init()
    }

    func start() {
        guard sourceObservation == nil else { return }
        sourceObservation = sourceBuffer.observe {
            [weak self] revision, origin in
            self?.sourceDidChange(revision, origin: origin)
        }
        lineIndexObservation = sourceBuffer.observeLineIndex { [weak self] in
            self?.updatePaneState()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(renderedContentDidUpdate(_:)),
            name: pane.mermaidRenderer.updateNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        if let sourceObservation {
            sourceBuffer.removeObserver(sourceObservation)
        }
        if let lineIndexObservation {
            sourceBuffer.removeLineIndexObserver(lineIndexObservation)
        }
        sourceObservation = nil
        lineIndexObservation = nil
        textView = nil
        clipView = nil
    }

    func scheduleAttachment(in rootView: NSView) {
        DispatchQueue.main.async { [weak self, weak rootView] in
            guard let self, let rootView else { return }
            rootView.layoutSubtreeIfNeeded()
            self.attach(in: rootView)
        }
    }

    func setNormalizesDisplayMathSelection(_ shouldNormalize: Bool) {
        normalizesDisplayMathSelection = shouldNormalize
    }

    func setPresentation(_ newPresentation: MarkdownSourcePresentation) {
        guard presentation != newPresentation else { return }
        let sourceRangeChanged =
            presentation.sourceRange.location
                != newPresentation.sourceRange.location
        presentation = newPresentation
        if sourceRangeChanged {
            pendingSelectionRestore = pane.selectedRange
            hasRestoredState = false
        }
        scheduleMermaidPresentation()
    }

    private func attach(in rootView: NSView) {
        guard let candidate = descendantTextViews(in: rootView).first else {
            return
        }
        if candidate !== textView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextView.didChangeSelectionNotification,
                object: textView
            )
            if let clipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: clipView
                )
            }
            textView = candidate
            clipView = candidate.enclosingScrollView?.contentView
            candidate.setAccessibilityLabel("Markdown editor")
            candidate.identifier = NSUserInterfaceItemIdentifier(
                "DarthScriptum.MarkdownEditor.\(pane.id.uuidString)"
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: candidate
            )
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(viewportDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clipView
                )
            }
            hasRestoredState = false
        }
        restoreStateIfNeeded()
        restorePendingSelectionIfNeeded()
        updatePaneState()
        scheduleMermaidPresentation()
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard let changedTextView = notification.object as? NSTextView,
              changedTextView === textView else {
            return
        }
        DispatchQueue.main.async { [weak self, weak changedTextView] in
            guard let self,
                  let changedTextView,
                  changedTextView === self.textView else {
                return
            }
            if changedTextView.window?.firstResponder === changedTextView {
                self.onBecameActive()
            }
            self.updatePaneState()
            self.scheduleMermaidPresentation()
        }
    }

    @objc private func viewportDidChange(_ notification: Notification) {
        guard let observed = notification.object as? NSClipView,
              observed === clipView else {
            return
        }
        DispatchQueue.main.async { [weak self, weak observed] in
            guard let self,
                  let observed,
                  observed === self.clipView else {
                return
            }
            let origin = observed.bounds.origin
            if self.pane.visibleOrigin != origin {
                self.pane.visibleOrigin = origin
            }
            self.scheduleMermaidPresentation()
        }
    }

    @objc private func renderedContentDidUpdate(_ notification: Notification) {
        scheduleMermaidPresentation()
    }

    private func sourceDidChange(
        _ revision: SourceRevision,
        origin: DocumentChangeOrigin
    ) {
        DispatchQueue.main.async { [weak textView] in
            textView?.undoManager?.removeAllActions()
        }
        let isOwnEdit: Bool
        if case let .localEditor(paneID) = origin {
            isOwnEdit = paneID == pane.id
        } else {
            isOwnEdit = false
        }
        if !isOwnEdit {
            let anchor = SelectionAnchor.capture(
                selectedRange: pendingSelectionRestore ?? pane.selectedRange,
                in: lastSourceText
            )
            let resolved = anchor.resolve(in: revision.text)
            pendingSelectionRestore = resolved
            DispatchQueue.main.async { [weak self] in
                self?.restorePendingSelectionIfNeeded()
            }
        }
        let newPresentation = MarkdownSourcePresentation.make(
            source: revision.text,
            rendersMarkdown: presentation.rendersMarkdown
        )
        if newPresentation.sourceRange.location
            != presentation.sourceRange.location {
            pendingSelectionRestore = pendingSelectionRestore
                ?? pane.selectedRange
            hasRestoredState = false
        }
        presentation = newPresentation
        lastSourceText = revision.text
        scheduleMermaidPresentation()
    }

    private func restoreStateIfNeeded() {
        guard !hasRestoredState, let textView else { return }
        hasRestoredState = true
        textView.setSelectedRange(
            clamped(
                presentation.presentedRange(
                    forSourceRange: pane.selectedRange
                ),
                to: textView.string
            )
        )
        guard let scrollView = textView.enclosingScrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: pane.visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restorePendingSelectionIfNeeded() {
        guard let pendingSelectionRestore else {
            return
        }
        guard let textView else {
            self.pendingSelectionRestore = nil
            if pane.selectedRange != pendingSelectionRestore {
                pane.selectedRange = pendingSelectionRestore
            }
            return
        }
        guard textView.string == presentation.text else { return }
        self.pendingSelectionRestore = nil
        let restoredRange = clamped(
            presentation.presentedRange(
                forSourceRange: pendingSelectionRestore
            ),
            to: textView.string
        )
        if textView.selectedRange() != restoredRange {
            textView.setSelectedRange(restoredRange)
        }
        updatePaneState()
    }

    private func updatePaneState() {
        guard let textView else { return }
        let currentSelection = textView.selectedRange()
        let selectedRange = normalizesDisplayMathSelection
            && currentSelection.length > 0
            ? DisplayMathSelectionPolicy.normalized(
                currentSelection,
                in: textView.string
            )
            : currentSelection
        if selectedRange != currentSelection {
            textView.setSelectedRange(selectedRange)
        }
        let sourceSelection = presentation.sourceRange(
            forPresentedRange: selectedRange
        )
        if pane.selectedRange != sourceSelection {
            pane.selectedRange = sourceSelection
        }
        if let clipView, pane.visibleOrigin != clipView.bounds.origin {
            pane.visibleOrigin = clipView.bounds.origin
        }
        guard let position = sourceBuffer.position(
            atUTF16Location: sourceSelection.location
        ) else {
            if !pane.isPositionPending {
                pane.isPositionPending = true
            }
            return
        }
        if pane.isPositionPending {
            pane.isPositionPending = false
        }
        if pane.line != position.line {
            pane.line = position.line
        }
        if pane.column != position.column {
            pane.column = position.column
        }
    }

    private func scheduleMermaidPresentation() {
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self,
                  let textView,
                  textView === self.textView,
                  textView.string == self.presentation.text else {
                return
            }
            self.mermaidPresenter.apply(
                to: textView,
                rendersMarkdown: self.presentation.rendersMarkdown
            )
        }
    }

    private func descendantTextViews(in view: NSView) -> [NSTextView] {
        if let textView = view as? NSTextView {
            return [textView]
        }
        return view.subviews.flatMap(descendantTextViews)
    }

    private func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }
}

enum DisplayMathSelectionPolicy {
    static func normalized(
        _ selection: NSRange,
        in source: String
    ) -> NSRange {
        let text = source as NSString
        guard selection.length > 0,
              selection.location >= 2,
              NSMaxRange(selection) + 2 <= text.length,
              text.substring(
                with: NSRange(location: selection.location - 2, length: 2)
              ) == "$$",
              text.substring(
                with: NSRange(location: NSMaxRange(selection), length: 2)
              ) == "$$" else {
            return selection
        }

        var start = selection.location
        var end = NSMaxRange(selection)
        while start < end,
              isRendererTrimmedWhitespace(text.character(at: start)) {
            start += 1
        }
        while end > start,
              isRendererTrimmedWhitespace(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isRendererTrimmedWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
