import AppKit

private struct LineColumnRequest: Sendable, Equatable {
    let revision: UInt64
    let location: Int
    let text: String
}

private struct LineColumnResult: Sendable, Equatable {
    let request: LineColumnRequest
    let line: Int
    let column: Int
}

private enum LineColumnCalculator {
    static func calculate(_ request: LineColumnRequest) -> LineColumnResult {
        let source = request.text as NSString
        let location = min(max(request.location, 0), source.length)
        var line = 1
        var column = 1
        var index = 0
        while index < location {
            if index.isMultiple(of: 4_096), Task.isCancelled {
                break
            }
            let unit = source.character(at: index)
            if unit == 0x000D {
                if index + 1 < location,
                   source.character(at: index + 1) == 0x000A {
                    index += 1
                }
                line += 1
                column = 1
            } else if unit == 0x000A {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
        return LineColumnResult(
            request: request,
            line: line,
            column: column
        )
    }
}

@MainActor
private final class LineColumnScheduler {
    var onResult: (@MainActor (LineColumnResult) -> Void)?

    private var activeTask: Task<LineColumnResult, Never>?
    private var completionTask: Task<Void, Never>?
    private var pendingRequest: LineColumnRequest?
    private var activeRequest: LineColumnRequest?

    func schedule(_ request: LineColumnRequest) {
        guard activeRequest != request,
              pendingRequest != request else {
            return
        }
        pendingRequest = request
        guard activeTask == nil else { return }
        launchPendingRequest()
    }

    func cancel() {
        pendingRequest = nil
        onResult = nil
        activeTask?.cancel()
        completionTask?.cancel()
    }

    private func launchPendingRequest() {
        guard activeTask == nil,
              let request = pendingRequest else {
            return
        }
        pendingRequest = nil
        activeRequest = request
        let task = Task.detached(priority: .utility) {
            LineColumnCalculator.calculate(request)
        }
        activeTask = task
        completionTask = Task { @MainActor [weak self] in
            let result = await task.value
            self?.finished(result)
        }
    }

    private func finished(_ result: LineColumnResult) {
        guard activeRequest == result.request else { return }
        activeTask = nil
        completionTask = nil
        activeRequest = nil
        if !Task.isCancelled {
            onResult?(result)
        }
        if pendingRequest != nil {
            launchPendingRequest()
        }
    }
}

@MainActor
final class EditorPaneStateCoordinator: NSObject {
    private let sourceBuffer: MarkdownSourceBuffer
    private let pane: EditorPaneModel
    private let onBecameActive: @MainActor () -> Void
    private let lineColumnScheduler = LineColumnScheduler()
    private weak var textView: NSTextView?
    private weak var clipView: NSClipView?
    private var sourceObservation: UUID?
    private var lastSourceText: String
    private var hasRestoredState = false
    private var pendingSelectionRestore: NSRange?

    init(
        sourceBuffer: MarkdownSourceBuffer,
        pane: EditorPaneModel,
        onBecameActive: @escaping @MainActor () -> Void = {}
    ) {
        self.sourceBuffer = sourceBuffer
        self.pane = pane
        self.onBecameActive = onBecameActive
        lastSourceText = sourceBuffer.revision.text
        super.init()
        lineColumnScheduler.onResult = { [weak self] result in
            self?.receiveLineColumn(result)
        }
    }

    func start() {
        guard sourceObservation == nil else { return }
        sourceObservation = sourceBuffer.observe {
            [weak self] revision, origin in
            self?.sourceDidChange(revision, origin: origin)
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        lineColumnScheduler.cancel()
        if let sourceObservation {
            sourceBuffer.removeObserver(sourceObservation)
        }
        sourceObservation = nil
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
                "DarthMD.MarkdownEditor.\(pane.id.uuidString)"
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
        lastSourceText = revision.text
    }

    private func restoreStateIfNeeded() {
        guard !hasRestoredState, let textView else { return }
        hasRestoredState = true
        textView.setSelectedRange(
            clamped(pane.selectedRange, to: textView.string)
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
        guard textView.string == sourceBuffer.revision.text else { return }
        self.pendingSelectionRestore = nil
        let restoredRange = clamped(
            pendingSelectionRestore,
            to: textView.string
        )
        if textView.selectedRange() != restoredRange {
            textView.setSelectedRange(restoredRange)
        }
        updatePaneState()
    }

    private func updatePaneState() {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        if pane.selectedRange != selectedRange {
            pane.selectedRange = selectedRange
        }
        if let clipView, pane.visibleOrigin != clipView.bounds.origin {
            pane.visibleOrigin = clipView.bounds.origin
        }
        let request = LineColumnRequest(
            revision: sourceBuffer.revision.number,
            location: selectedRange.location,
            text: textView.string
        )
        if (textView.string as NSString).length <= 256 * 1_024 {
            let result = LineColumnCalculator.calculate(request)
            if pane.line != result.line {
                pane.line = result.line
            }
            if pane.column != result.column {
                pane.column = result.column
            }
        } else {
            lineColumnScheduler.schedule(request)
        }
    }

    private func receiveLineColumn(_ result: LineColumnResult) {
        guard sourceBuffer.revision.number == result.request.revision,
              pane.selectedRange.location
                == result.request.location else {
            return
        }
        if pane.line != result.line {
            pane.line = result.line
        }
        if pane.column != result.column {
            pane.column = result.column
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
