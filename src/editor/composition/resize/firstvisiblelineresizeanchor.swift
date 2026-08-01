import AppKit

/// A semantic scroll position that survives width-dependent text reflow.
///
/// A clip-view origin is only a pixel offset. Once wrapping or a rendered block
/// changes the height above that offset, it points at different note content.
/// This value instead identifies the first visible layout line and remembers
/// the line's exact offset from the top of the viewport.
@MainActor
struct FirstVisibleLineViewportAnchor: Equatable {
    let utf16Location: Int
    let viewportOffset: CGFloat

    static func capture(in textView: NSTextView) -> Self? {
        guard let geometry = firstVisibleLineGeometry(in: textView),
              let clipView = textView.enclosingScrollView?.contentView else {
            return nil
        }
        return Self(
            utf16Location: geometry.utf16Location,
            viewportOffset: geometry.documentMinY - clipView.bounds.minY
        )
    }

    func currentViewportOffset(in textView: NSTextView) -> CGFloat? {
        guard let geometry = Self.lineGeometry(
            at: utf16Location,
            in: textView
        ), let clipView = textView.enclosingScrollView?.contentView else {
            return nil
        }
        return geometry.documentMinY - clipView.bounds.minY
    }

    @discardableResult
    func restore(in textView: NSTextView) -> Bool {
        guard let scrollView = textView.enclosingScrollView,
              let geometry = Self.lineGeometry(
                  at: utf16Location,
                  in: textView
              ) else {
            return false
        }
        let clipView = scrollView.contentView
        let targetY = geometry.documentMinY - viewportOffset
        guard targetY.isFinite else { return false }

        var proposedBounds = clipView.bounds
        proposedBounds.origin.y = targetY
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        guard abs(constrainedBounds.minY - clipView.bounds.minY) > 0.5 else {
            return true
        }
        clipView.scroll(
            to: NSPoint(
                x: clipView.bounds.minX,
                y: constrainedBounds.minY
            )
        )
        scrollView.reflectScrolledClipView(clipView)
        textView.textLayoutManager?.textViewportLayoutController
            .layoutViewport()
        return true
    }

    private struct LineGeometry {
        let utf16Location: Int
        let documentMinY: CGFloat
    }

    private static func firstVisibleLineGeometry(
        in textView: NSTextView
    ) -> LineGeometry? {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager
                as? NSTextContentStorage,
              let documentView = textView.enclosingScrollView?.documentView,
              let clipView = textView.enclosingScrollView?.contentView else {
            return nil
        }
        layoutManager.textViewportLayoutController.layoutViewport()
        let visibleBounds = clipView.bounds
        let startLocation = layoutManager.textViewportLayoutController
            .viewportRange?.location ?? layoutManager.documentRange.location
        var firstLine: LineGeometry?

        layoutManager.enumerateTextLayoutFragments(
            from: startLocation,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentStart = contentStorage.offset(
                from: contentStorage.documentRange.location,
                to: fragment.rangeInElement.location
            )
            for line in fragment.textLineFragments {
                guard line.characterRange.location != NSNotFound else {
                    continue
                }
                let lineRect = documentRect(
                    for: line,
                    in: fragment,
                    textView: textView,
                    documentView: documentView
                )
                guard lineRect.maxY > visibleBounds.minY + 0.01,
                      lineRect.minY < visibleBounds.maxY - 0.01 else {
                    continue
                }
                let candidate = LineGeometry(
                    utf16Location: fragmentStart
                        + line.characterRange.location,
                    documentMinY: lineRect.minY
                )
                if firstLine.map({
                    candidate.documentMinY < $0.documentMinY
                }) ?? true {
                    firstLine = candidate
                }
            }

            guard let firstLine else { return true }
            let fragmentRect = textView.convert(
                fragment.layoutFragmentFrame.offsetBy(
                    dx: textView.textContainerOrigin.x,
                    dy: textView.textContainerOrigin.y
                ),
                to: documentView
            )
            return fragmentRect.minY <= max(
                visibleBounds.maxY,
                firstLine.documentMinY
            )
        }
        return firstLine
    }

    private static func lineGeometry(
        at utf16Location: Int,
        in textView: NSTextView
    ) -> LineGeometry? {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager
                as? NSTextContentStorage,
              let documentView = textView.enclosingScrollView?.documentView,
              utf16Location >= 0,
              utf16Location <= (textView.string as NSString).length,
              let location = contentStorage.location(
                  contentStorage.documentRange.location,
                  offsetBy: utf16Location
              ) else {
            return nil
        }
        let endLocation = contentStorage.location(
            location,
            offsetBy: min(
                1,
                (textView.string as NSString).length - utf16Location
            )
        ) ?? location
        if let range = NSTextRange(location: location, end: endLocation) {
            layoutManager.ensureLayout(for: range)
        }
        guard let fragment = layoutManager.textLayoutFragment(for: location)
        else {
            return nil
        }
        let fragmentStart = contentStorage.offset(
            from: contentStorage.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let localLocation = utf16Location - fragmentStart
        let lines = fragment.textLineFragments
        let line = lines.first {
            $0.characterRange.location == localLocation
        } ?? lines.first {
            localLocation >= $0.characterRange.location
                && localLocation < NSMaxRange($0.characterRange)
        } ?? (utf16Location == (textView.string as NSString).length
            ? lines.last
            : nil)
        guard let line else { return nil }

        let lineRect = documentRect(
            for: line,
            in: fragment,
            textView: textView,
            documentView: documentView
        )
        return LineGeometry(
            utf16Location: utf16Location,
            documentMinY: lineRect.minY
        )
    }

    private static func documentRect(
        for line: NSTextLineFragment,
        in fragment: NSTextLayoutFragment,
        textView: NSTextView,
        documentView: NSView
    ) -> NSRect {
        textView.convert(
            line.typographicBounds.offsetBy(
                dx: fragment.layoutFragmentFrame.minX
                    + textView.textContainerOrigin.x,
                dy: fragment.layoutFragmentFrame.minY
                    + textView.textContainerOrigin.y
            ),
            to: documentView
        )
    }
}

/// Owns one first-line anchor for the duration of a resize transaction.
@MainActor
final class FirstVisibleLineResizeAnchor: NSObject {
    static let defaultSettleInterval: TimeInterval = 0.1

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private weak var layoutView: NSView?
    private var anchor: FirstVisibleLineViewportAnchor?
    private var isActive = false
    private var isUserScrolling = false
    private var layoutNeedsRestore = false
    private var finishRequested = false
    private var finishTimer: Timer?
    private let settleInterval: TimeInterval

    private(set) var isApplyingCompensation = false

    init(settleInterval: TimeInterval = defaultSettleInterval) {
        self.settleInterval = max(0, settleInterval)
        super.init()
    }

    func attach(to textView: NSTextView, layoutView: NSView) {
        let candidateScrollView = textView.enclosingScrollView
        guard textView !== self.textView
                || candidateScrollView !== scrollView
                || layoutView !== self.layoutView else {
            return
        }
        stopObservingScrollView()
        cancel()
        self.textView = textView
        scrollView = candidateScrollView
        self.layoutView = layoutView
        if let candidateScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userScrollWillStart(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: candidateScrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userScrollDidEnd(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: candidateScrollView
            )
        }
    }

    func beginIfNeeded() {
        guard !isActive else { return }
        begin()
    }

    func widthWillChange() {
        beginIfNeeded()
        guard isActive, !isUserScrolling, anchor != nil else { return }
        finishTimer?.invalidate()
        finishTimer = nil
        finishRequested = false
        layoutNeedsRestore = true
    }

    private func begin() {
        guard let textView else { return }
        finishTimer?.invalidate()
        finishTimer = nil
        finishRequested = false
        isUserScrolling = false
        isActive = true
        anchor = FirstVisibleLineViewportAnchor.capture(in: textView)
        layoutNeedsRestore = false
    }

    func layoutDidChange() {
        guard isActive, !isUserScrolling else { return }
        layoutNeedsRestore = true
        requestLayout()
    }

    func layoutDidComplete() {
        guard isActive,
              !isUserScrolling,
              layoutNeedsRestore,
              !isApplyingCompensation,
              let textView,
              let anchor else {
            return
        }

        layoutNeedsRestore = false
        isApplyingCompensation = true
        defer { isApplyingCompensation = false }

        // TextKit can refine viewport geometry when the scroll position moves.
        // A small bounded convergence loop keeps the transaction synchronous
        // without allowing viewport relocation to recursively re-enter layout.
        for _ in 0..<3 {
            guard let currentOffset = anchor.currentViewportOffset(
                in: textView
            ) else {
                break
            }
            guard abs(currentOffset - anchor.viewportOffset) > 0.5 else {
                break
            }
            guard anchor.restore(in: textView) else { break }
        }
        textView.setNeedsDisplay(textView.visibleRect)

        if finishRequested {
            scheduleFinish()
        }
    }

    func finishWhenSettled() {
        guard isActive else { return }
        finishRequested = true
        layoutDidChange()
        scheduleFinish()
    }

    func cancel() {
        finishTimer?.invalidate()
        finishTimer = nil
        anchor = nil
        isActive = false
        isUserScrolling = false
        layoutNeedsRestore = false
        finishRequested = false
        isApplyingCompensation = false
    }

    func stop() {
        stopObservingScrollView()
        cancel()
        textView = nil
        scrollView = nil
        layoutView = nil
    }

    private func scheduleFinish() {
        guard finishRequested, !isUserScrolling else { return }
        finishTimer?.invalidate()
        let timer = Timer(
            timeInterval: settleInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishNow()
            }
        }
        finishTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishNow() {
        guard isActive, !isUserScrolling else { return }
        guard !layoutNeedsRestore else {
            requestLayout()
            scheduleFinish()
            return
        }
        cancel()
    }

    private func requestLayout() {
        layoutView?.needsLayout = true
    }

    @objc private func userScrollWillStart(_ notification: Notification) {
        guard notification.object as? NSScrollView === scrollView,
              isActive else {
            return
        }
        finishTimer?.invalidate()
        finishTimer = nil
        isUserScrolling = true
        anchor = nil
        layoutNeedsRestore = false
    }

    @objc private func userScrollDidEnd(_ notification: Notification) {
        guard notification.object as? NSScrollView === scrollView,
              isActive,
              let textView else {
            return
        }
        isUserScrolling = false
        anchor = FirstVisibleLineViewportAnchor.capture(in: textView)
        layoutNeedsRestore = false
        if finishRequested {
            scheduleFinish()
        }
    }

    private func stopObservingScrollView() {
        if let scrollView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }
    }
}
