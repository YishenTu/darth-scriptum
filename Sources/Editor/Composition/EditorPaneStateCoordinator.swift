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
    private lazy var renderedContentResizeCoordinator =
        RenderedContentResizeCoordinator(
            presentation: presentation,
            restyleNotification: pane.latexRenderer.updateNotification
        ) { [weak self] viewportWidth in
            self?.scheduleMermaidApply(viewportWidth: viewportWidth)
        }
    private var sourceObservation: UUID?
    private var lineIndexObservation: UUID?
    private var lastSourceText: String
    private var hasRestoredState = false
    private var pendingSelectionRestore: NSRange?
    private var mermaidParseTask: Task<Void, Never>?
    private var mermaidBlocks: [MermaidFencedBlock] = []
    private var mermaidBlocksRevision: UInt64?
    private var mermaidBlocksSourceRange: NSRange?
    private var mermaidParseRevision: UInt64?
    private var mermaidParseSourceRange: NSRange?
    private var mermaidApplyScheduled = false
    private var pendingMermaidViewportWidth: CGFloat?

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
        self.presentation =
            presentation
            ?? MarkdownSourcePresentation.make(
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
        if pane.latexRenderer.updateNotification
            != pane.mermaidRenderer.updateNotification
        {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(renderedContentDidUpdate(_:)),
                name: pane.latexRenderer.updateNotification,
                object: nil
            )
        }
    }

    func stop() {
        mermaidParseTask?.cancel()
        mermaidParseTask = nil
        mermaidParseRevision = nil
        mermaidParseSourceRange = nil
        pendingMermaidViewportWidth = nil
        MarkdownEngineCompatibility.endObservingSelection(
            of: textView,
            observer: self
        )
        endObservingTextStorage(of: textView)
        NotificationCenter.default.removeObserver(self)
        renderedContentResizeCoordinator.stop()
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
            guard
                let candidate = MarkdownEngineCompatibility.nativeTextView(
                    in: rootView
                )
            else {
                return
            }
            self.attach(to: candidate, layoutView: rootView)
        }
    }

    func editorWidthWillChange(to width: CGFloat) {
        renderedContentResizeCoordinator.editorWidthWillChange(to: width)
    }

    func editorLayoutDidComplete() {
        renderedContentResizeCoordinator.editorLayoutDidComplete()
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
        renderedContentResizeCoordinator.updatePresentation(newPresentation)
        if sourceRangeChanged {
            pendingSelectionRestore = pane.selectedRange
            hasRestoredState = false
        }
        scheduleMermaidParse()
    }

    private func attach(to candidate: NSTextView, layoutView: NSView) {
        if candidate !== textView {
            MarkdownEngineCompatibility.endObservingSelection(
                of: textView,
                observer: self
            )
            endObservingTextStorage(of: textView)
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
            MarkdownEngineCompatibility.beginObservingSelection(
                of: candidate,
                observer: self,
                selector: #selector(selectionDidChange(_:))
            )
            beginObservingTextStorage(of: candidate)
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
        renderedContentResizeCoordinator.attach(
            to: candidate,
            layoutView: layoutView
        )
        restoreStateIfNeeded()
        restorePendingSelectionIfNeeded()
        updatePaneState()
        scheduleMermaidParse()
    }

    private func beginObservingTextStorage(of textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(observedTextStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    private func endObservingTextStorage(of textView: NSTextView?) {
        guard let textStorage = textView?.textStorage else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
        pane.bindingMutationAccumulator.reset()
    }

    @objc private func observedTextStorageDidProcessEditing(
        _ notification: Notification
    ) {
        guard let textStorage = notification.object as? NSTextStorage,
            textStorage === textView?.textStorage,
            textStorage.editedMask.contains(.editedCharacters)
        else {
            return
        }
        let editedRange = textStorage.editedRange
        let changeInLength = textStorage.changeInLength
        let originalLength = editedRange.length - changeInLength
        let originalPresentedLength = textStorage.length - changeInLength
        guard editedRange.location >= 0,
            editedRange.length >= 0,
            NSMaxRange(editedRange) <= textStorage.length,
            originalLength >= 0,
            originalPresentedLength >= 0
        else {
            pane.bindingMutationAccumulator.reset()
            return
        }
        pane.bindingMutationAccumulator.record(
            EditorBindingMutation(
                range: NSRange(
                    location: editedRange.location,
                    length: originalLength
                ),
                replacement: (textStorage.string as NSString).substring(
                    with: editedRange
                ),
                sourceRevisionNumber: sourceBuffer.revision.number,
                presentedSourceRange: presentation.sourceRange,
                originalPresentedLength: originalPresentedLength,
                updatedPresentedLength: textStorage.length
            )
        )
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard let changedTextView = notification.object as? NSTextView,
            changedTextView === textView
        else {
            return
        }
        DispatchQueue.main.async { [weak self, weak changedTextView] in
            guard let self,
                let changedTextView,
                changedTextView === self.textView
            else {
                return
            }
            if changedTextView.window?.firstResponder === changedTextView {
                self.onBecameActive()
            }
            self.updatePaneState()
            self.scheduleMermaidApply()
        }
    }

    @objc private func viewportDidChange(_ notification: Notification) {
        guard let observed = notification.object as? NSClipView,
            observed === clipView
        else {
            return
        }
        let isAnchorCompensation = renderedContentResizeCoordinator
            .isApplyingAnchorCompensation
        DispatchQueue.main.async { [weak self, weak observed] in
            guard let self,
                let observed,
                observed === self.clipView
            else {
                return
            }
            let origin = observed.bounds.origin
            if self.pane.visibleOrigin != origin {
                self.pane.visibleOrigin = origin
            }
            if !isAnchorCompensation {
                self.scheduleMermaidApply()
            }
        }
    }

    @objc private func renderedContentDidUpdate(_ notification: Notification) {
        if let sender = notification.object as? NSTextView {
            guard sender === textView else { return }
            // The resize coordinator posts this targeted notification and
            // stabilizes the resulting full restyle synchronously itself.
            return
        }
        let isMermaidUpdate =
            notification.name == pane.mermaidRenderer.updateNotification
        let isLaTeXUpdate =
            notification.name == pane.latexRenderer.updateNotification
        if isMermaidUpdate || isLaTeXUpdate {
            scheduleMermaidApply()
        }
        if isLaTeXUpdate {
            renderedContentResizeCoordinator.renderedContentDidUpdate(
                mayContainCenteredBlocks: true
            )
        }
    }

    private func sourceDidChange(
        _ revision: SourceRevision,
        origin: DocumentChangeOrigin
    ) {
        DispatchQueue.main.async { [weak textView] in
            textView?.undoManager?.removeAllActions()
        }
        let isOwnEdit: Bool
        if case .localEditor(let paneID) = origin {
            isOwnEdit = paneID == pane.id
        } else {
            isOwnEdit = false
        }
        if !isOwnEdit {
            let currentSelection =
                pendingSelectionRestore ?? pane.selectedRange
            let resolved: NSRange
            if let edit = sourceBuffer.lastAppliedEdit,
                edit.expectedRevision &+ 1 == revision.number
            {
                resolved = SourceSelectionTransformer.transform(
                    currentSelection,
                    by: edit
                )
            } else {
                let anchor = SelectionAnchor.capture(
                    selectedRange: currentSelection,
                    in: lastSourceText
                )
                resolved = anchor.resolve(in: revision.text)
            }
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
            != presentation.sourceRange.location
        {
            pendingSelectionRestore =
                pendingSelectionRestore
                ?? pane.selectedRange
            hasRestoredState = false
        }
        presentation = newPresentation
        renderedContentResizeCoordinator.updatePresentation(newPresentation)
        lastSourceText = revision.text
        scheduleMermaidParse()
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
        let selectedRange =
            normalizesDisplayMathSelection
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
        guard
            let position = sourceBuffer.position(
                atUTF16Location: sourceSelection.location
            )
        else {
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

    private func scheduleMermaidParse() {
        let revisionNumber = sourceBuffer.revision.number
        let expectedSourceRange = presentation.sourceRange
        if mermaidBlocksRevision == revisionNumber,
            mermaidBlocksSourceRange == expectedSourceRange,
            presentation.rendersMarkdown
        {
            scheduleMermaidApply()
            return
        }
        if mermaidParseRevision == revisionNumber,
            mermaidParseSourceRange == expectedSourceRange,
            presentation.rendersMarkdown
        {
            return
        }

        mermaidParseTask?.cancel()
        guard presentation.rendersMarkdown,
            sourceBuffer.metrics.containsMermaidCandidate
        else {
            mermaidParseTask = nil
            mermaidBlocks = []
            mermaidBlocksRevision = revisionNumber
            mermaidBlocksSourceRange = expectedSourceRange
            mermaidParseRevision = nil
            mermaidParseSourceRange = nil
            return
        }

        let source = presentation.text
        mermaidParseRevision = revisionNumber
        mermaidParseSourceRange = expectedSourceRange
        mermaidParseTask = Task.detached(priority: .utility) { [weak self] in
            let blocks = MermaidFencedBlockParser.blocks(in: source) {
                Task.isCancelled
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                    self.sourceBuffer.revision.number == revisionNumber,
                    self.presentation.sourceRange == expectedSourceRange,
                    self.presentation.rendersMarkdown
                else {
                    return
                }
                self.mermaidBlocks = blocks
                self.mermaidBlocksRevision = revisionNumber
                self.mermaidBlocksSourceRange = expectedSourceRange
                self.mermaidParseTask = nil
                self.mermaidParseRevision = nil
                self.mermaidParseSourceRange = nil
                self.scheduleMermaidApply()
            }
        }
    }

    private func scheduleMermaidApply(viewportWidth: CGFloat? = nil) {
        if let viewportWidth,
            viewportWidth.isFinite,
            viewportWidth > 0
        {
            pendingMermaidViewportWidth = viewportWidth
        }
        guard !mermaidApplyScheduled else { return }
        mermaidApplyScheduled = true
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self else { return }
            self.mermaidApplyScheduled = false
            let viewportWidth = self.pendingMermaidViewportWidth
            self.pendingMermaidViewportWidth = nil
            guard
                let textView,
                textView === self.textView,
                self.mermaidBlocksRevision
                    == self.sourceBuffer.revision.number
            else {
                return
            }
            let didApply = self.mermaidPresenter.apply(
                to: textView,
                rendersMarkdown: self.presentation.rendersMarkdown,
                source: self.presentation.text,
                blocks: self.mermaidBlocks,
                viewportWidth: viewportWidth
            )
            if didApply {
                self.renderedContentResizeCoordinator.renderedContentDidUpdate(
                    mayContainCenteredBlocks: false
                )
            }
        }
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
            ) == "$$"
        else {
            return selection
        }

        var start = selection.location
        var end = NSMaxRange(selection)
        while start < end,
            isRendererTrimmedWhitespace(text.character(at: start))
        {
            start += 1
        }
        while end > start,
            isRendererTrimmedWhitespace(text.character(at: end - 1))
        {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isRendererTrimmedWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
