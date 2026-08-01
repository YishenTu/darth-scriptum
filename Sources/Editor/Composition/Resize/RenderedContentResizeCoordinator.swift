import AppKit

@MainActor
final class RenderedContentResizeCoordinator {
    private let viewportObserver: EditorViewportResizeObserver
    private let firstVisibleLineAnchor: FirstVisibleLineResizeAnchor
    private let restyleNotification: Notification.Name
    private let onMermaidViewportWidth: @MainActor (CGFloat) -> Void

    private weak var textView: NSTextView?
    private weak var layoutView: NSView?
    private var presentation: MarkdownSourcePresentation
    private var hasTableCandidate: Bool?
    private var originNormalizationScheduled = false
    private var renderedBlockStabilizationScheduled = false
    private var finalTableRestyleTimer: Timer?
    private var pendingFinalTableRestyleWidth: CGFloat?
    private var lastTableRestyleWidth: CGFloat?

    init(
        presentation: MarkdownSourcePresentation,
        restyleNotification: Notification.Name,
        viewportObserver: EditorViewportResizeObserver =
            EditorViewportResizeObserver(),
        firstVisibleLineAnchor: FirstVisibleLineResizeAnchor =
            FirstVisibleLineResizeAnchor(),
        onMermaidViewportWidth: @escaping @MainActor (CGFloat) -> Void
    ) {
        self.presentation = presentation
        self.restyleNotification = restyleNotification
        self.viewportObserver = viewportObserver
        self.firstVisibleLineAnchor = firstVisibleLineAnchor
        self.onMermaidViewportWidth = onMermaidViewportWidth

        viewportObserver.onImmediateWidthChange = { [weak self] _ in
            self?.scheduleTextContainerOriginNormalization()
        }
        viewportObserver.onLiveResizeWillStart = { [weak self] viewportWidth in
            self?.resizeWillStart(viewportWidth: viewportWidth)
        }
        viewportObserver.onOrdinaryResizeWillStart = {
            [weak self] viewportWidth in
            self?.resizeWillStart(viewportWidth: viewportWidth)
        }
        viewportObserver.onSettledUpdate = { [weak self] update in
            self?.handle(update)
        }
    }

    var isApplyingAnchorCompensation: Bool {
        firstVisibleLineAnchor.isApplyingCompensation
    }

    func attach(to textView: NSTextView, layoutView: NSView) {
        let editorChanged =
            textView !== self.textView
            || layoutView !== self.layoutView
        if editorChanged {
            cancelPendingFinalTableRestyle()
            originNormalizationScheduled = false
            renderedBlockStabilizationScheduled = false
            self.textView = textView
            self.layoutView = layoutView
            lastTableRestyleWidth = nil
        }
        viewportObserver.attach(
            clipView: textView.enclosingScrollView?.contentView,
            window: textView.window
        )
        firstVisibleLineAnchor.attach(to: textView, layoutView: layoutView)
        if editorChanged {
            scheduleRenderedBlockStabilization()
        }
    }

    func updatePresentation(_ presentation: MarkdownSourcePresentation) {
        guard presentation != self.presentation else { return }
        cancelPendingFinalTableRestyle()
        firstVisibleLineAnchor.cancel()
        self.presentation = presentation
        hasTableCandidate = nil
        lastTableRestyleWidth = nil
    }

    func editorWidthWillChange(to width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        cancelPendingFinalTableRestyle()
        firstVisibleLineAnchor.widthWillChange()
    }

    func editorLayoutDidComplete() {
        firstVisibleLineAnchor.layoutDidComplete()
    }

    func renderedContentDidUpdate(mayContainCenteredBlocks: Bool) {
        if mayContainCenteredBlocks {
            scheduleRenderedBlockStabilization()
        } else {
            scheduleTextContainerOriginNormalization()
        }
        firstVisibleLineAnchor.layoutDidChange()
    }

    func stop() {
        viewportObserver.stop()
        firstVisibleLineAnchor.stop()
        cancelPendingFinalTableRestyle()
        lastTableRestyleWidth = nil
        hasTableCandidate = nil
        originNormalizationScheduled = false
        renderedBlockStabilizationScheduled = false
        textView = nil
        layoutView = nil
    }

    private func handle(
        _ update: EditorViewportResizeObserver.SettledUpdate
    ) {
        switch update {
        case .ordinary(let viewportWidth):
            applyTableRestyle(viewportWidth: viewportWidth)
            onMermaidViewportWidth(viewportWidth)
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
            firstVisibleLineAnchor.finishWhenSettled()
        case .liveQuiet(let viewportWidth):
            applyTableRestyle(viewportWidth: viewportWidth)
            onMermaidViewportWidth(viewportWidth)
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
        case .liveEnded(let viewportWidth):
            onMermaidViewportWidth(viewportWidth)
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
            // A quiet update can observe the final width before SwiftUI has
            // committed the final descendant layout. Always run one trailing
            // final-width restyle after live resizing ends.
            scheduleFinalTableRestyle(viewportWidth: viewportWidth)
            firstVisibleLineAnchor.finishWhenSettled()
        }
    }

    private func resizeWillStart(viewportWidth: CGFloat) {
        cancelPendingFinalTableRestyle()
        firstVisibleLineAnchor.beginIfNeeded()
        stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
    }

    private func scheduleRenderedBlockStabilization() {
        guard !renderedBlockStabilizationScheduled else { return }
        renderedBlockStabilizationScheduled = true
        let observedTextView = textView
        DispatchQueue.main.async { [weak self, weak observedTextView] in
            guard let self else { return }
            self.renderedBlockStabilizationScheduled = false
            guard let observedTextView,
                observedTextView === self.textView
            else {
                return
            }
            self.stabilizeCenteredRenderedBlocks(viewportWidth: nil)
        }
    }

    private func stabilizeCenteredRenderedBlocks(
        viewportWidth: CGFloat?
    ) {
        guard let textView else { return }
        MarkdownEngineCompatibility.stabilizeCenteredRenderedBlocks(
            in: textView,
            viewportWidth: viewportWidth
        )
        MarkdownEngineCompatibility.normalizeTextContainerOrigin(in: textView)
        scheduleTextContainerOriginNormalization()
        firstVisibleLineAnchor.layoutDidChange()
    }

    private func scheduleTextContainerOriginNormalization() {
        guard !originNormalizationScheduled else { return }
        originNormalizationScheduled = true
        let observedTextView = textView
        RunLoop.main.perform(inModes: [.default, .eventTracking]) {
            [weak self, weak observedTextView] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.originNormalizationScheduled = false
                guard let observedTextView,
                    observedTextView === self.textView
                else {
                    return
                }
                MarkdownEngineCompatibility.normalizeTextContainerOrigin(
                    in: observedTextView
                )
            }
        }
    }

    private func scheduleFinalTableRestyle(viewportWidth: CGFloat) {
        pendingFinalTableRestyleWidth = viewportWidth
        finalTableRestyleTimer?.invalidate()
        let timer = Timer(
            timeInterval: EditorViewportResizeObserver.defaultQuietInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPendingFinalTableRestyle()
            }
        }
        finalTableRestyleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    private func applyTableRestyle(
        viewportWidth: CGFloat,
        force: Bool = false
    ) -> Bool {
        cancelPendingFinalTableRestyle()
        guard presentation.rendersMarkdown,
            sourceContainsTable(),
            let textView,
            force
                || (lastTableRestyleWidth.map {
                    abs($0 - viewportWidth) > 0.5
                } ?? true)
        else {
            return false
        }
        if force {
            textView.window?.contentView?.layoutSubtreeIfNeeded()
        }
        lastTableRestyleWidth = viewportWidth
        MarkdownEngineCompatibility.requestFullRestyle(
            of: textView,
            notification: restyleNotification
        )
        firstVisibleLineAnchor.layoutDidChange()
        return true
    }

    private func applyPendingFinalTableRestyle() {
        guard let viewportWidth = pendingFinalTableRestyleWidth else {
            finalTableRestyleTimer = nil
            return
        }
        let didRestyle = applyTableRestyle(
            viewportWidth: viewportWidth,
            force: true
        )
        if didRestyle {
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
            onMermaidViewportWidth(viewportWidth)
        }
    }

    private func cancelPendingFinalTableRestyle() {
        finalTableRestyleTimer?.invalidate()
        finalTableRestyleTimer = nil
        pendingFinalTableRestyleWidth = nil
    }

    private func sourceContainsTable() -> Bool {
        if let hasTableCandidate {
            return hasTableCandidate
        }
        let detected = MarkdownEngineCompatibility.containsTableCandidate(
            in: presentation.text
        )
        hasTableCandidate = detected
        return detected
    }
}
