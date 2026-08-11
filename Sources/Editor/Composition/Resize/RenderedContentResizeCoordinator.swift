import AppKit

@MainActor
final class RenderedContentResizeCoordinator {
    private let viewportObserver: EditorViewportResizeObserver
    private let firstVisibleLineAnchor: FirstVisibleLineResizeAnchor
    private let onMermaidViewportWidth: @MainActor (CGFloat) -> Void

    private weak var textView: NSTextView?
    private weak var layoutView: NSView?
    private var originNormalizationScheduled = false
    private var renderedBlockStabilizationScheduled = false

    init(
        viewportObserver: EditorViewportResizeObserver =
            EditorViewportResizeObserver(),
        firstVisibleLineAnchor: FirstVisibleLineResizeAnchor =
            FirstVisibleLineResizeAnchor(),
        onMermaidViewportWidth: @escaping @MainActor (CGFloat) -> Void
    ) {
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
            originNormalizationScheduled = false
            renderedBlockStabilizationScheduled = false
            self.textView = textView
            self.layoutView = layoutView
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

    func editorWidthWillChange(to width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        firstVisibleLineAnchor.widthWillChange()
    }

    func presentationDidChange() {
        firstVisibleLineAnchor.cancel()
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
            onMermaidViewportWidth(viewportWidth)
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
            firstVisibleLineAnchor.finishWhenSettled()
        case .liveQuiet(let viewportWidth):
            onMermaidViewportWidth(viewportWidth)
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
        case .liveEnded(let viewportWidth):
            onMermaidViewportWidth(viewportWidth)
            stabilizeCenteredRenderedBlocks(viewportWidth: viewportWidth)
            firstVisibleLineAnchor.finishWhenSettled()
        }
    }

    private func resizeWillStart(viewportWidth: CGFloat) {
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

}
