import AppKit

@MainActor
final class EditorViewportResizeObserver: NSObject {
    static let defaultQuietInterval: TimeInterval = 0.05

    enum SettledUpdate {
        case ordinary(viewportWidth: CGFloat)
        case liveQuiet(viewportWidth: CGFloat)
        case liveEnded(viewportWidth: CGFloat)
    }

    var onImmediateWidthChange: (@MainActor (CGFloat) -> Void)?
    var onLiveResizeWillStart: (@MainActor (CGFloat) -> Void)?
    var onOrdinaryResizeWillStart: (@MainActor (CGFloat) -> Void)?
    var onSettledUpdate: (@MainActor (SettledUpdate) -> Void)?

    private weak var clipView: NSClipView?
    private weak var window: NSWindow?
    private let quietInterval: TimeInterval
    private var isLiveResizing = false
    private var lastObservedWidth: CGFloat?
    private var pendingLiveResizeWidth: CGFloat?
    private var liveResizeTimer: Timer?
    private var ordinaryResizeInProgress = false
    private var pendingOrdinaryResizeWidth: CGFloat?
    private var ordinaryResizeTimer: Timer?

    init(
        quietInterval: TimeInterval =
            EditorViewportResizeObserver.defaultQuietInterval
    ) {
        self.quietInterval = max(0, quietInterval)
        super.init()
    }

    func attach(clipView: NSClipView?, window: NSWindow?) {
        if clipView !== self.clipView {
            stopObservingClipView()
            self.clipView = clipView
            if let clipView {
                clipView.postsFrameChangedNotifications = true
                lastObservedWidth = clipView.bounds.width
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(clipViewFrameDidChange(_:)),
                    name: NSView.frameDidChangeNotification,
                    object: clipView
                )
            }
        }
        if window !== self.window {
            stopObservingWindow()
            self.window = window
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowWillStartLiveResize(_:)),
                    name: NSWindow.willStartLiveResizeNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidEndLiveResize(_:)),
                    name: NSWindow.didEndLiveResizeNotification,
                    object: window
                )
            }
        }
    }

    func stop() {
        stopObservingClipView()
        stopObservingWindow()
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        guard let observed = notification.object as? NSClipView,
            observed === clipView
        else {
            return
        }
        let width = observed.bounds.width
        if let previousWidth = lastObservedWidth,
            abs(width - previousWidth) <= 0.5
        {
            return
        }
        lastObservedWidth = width
        onImmediateWidthChange?(width)

        guard isLiveResizing else {
            if !ordinaryResizeInProgress {
                ordinaryResizeInProgress = true
                onOrdinaryResizeWillStart?(width)
            }
            pendingOrdinaryResizeWidth = width
            scheduleOrdinaryResizeUpdate()
            return
        }
        pendingLiveResizeWidth = width
        scheduleLiveResizeUpdate()
    }

    @objc private func windowWillStartLiveResize(
        _ notification: Notification
    ) {
        guard let observed = notification.object as? NSWindow,
            observed === window
        else {
            return
        }
        cancelPendingOrdinaryResizeUpdate()
        isLiveResizing = true
        cancelPendingLiveResizeUpdate()
        guard let viewportWidth = clipView?.bounds.width else { return }
        onLiveResizeWillStart?(viewportWidth)
    }

    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        guard let observed = notification.object as? NSWindow,
            observed === window
        else {
            return
        }
        isLiveResizing = false
        cancelPendingLiveResizeUpdate()
        guard let viewportWidth = clipView?.bounds.width else { return }
        lastObservedWidth = viewportWidth
        onImmediateWidthChange?(viewportWidth)
        onSettledUpdate?(.liveEnded(viewportWidth: viewportWidth))
    }

    private func scheduleLiveResizeUpdate() {
        liveResizeTimer?.invalidate()
        let timer = Timer(
            timeInterval: quietInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deliverPendingLiveResizeUpdate()
            }
        }
        liveResizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleOrdinaryResizeUpdate() {
        ordinaryResizeTimer?.invalidate()
        let timer = Timer(
            timeInterval: quietInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deliverPendingOrdinaryResizeUpdate()
            }
        }
        ordinaryResizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func deliverPendingLiveResizeUpdate() {
        liveResizeTimer = nil
        guard isLiveResizing,
            let viewportWidth = pendingLiveResizeWidth
        else {
            return
        }
        pendingLiveResizeWidth = nil
        onSettledUpdate?(.liveQuiet(viewportWidth: viewportWidth))
    }

    private func deliverPendingOrdinaryResizeUpdate() {
        ordinaryResizeTimer = nil
        guard !isLiveResizing,
            let viewportWidth = pendingOrdinaryResizeWidth
        else {
            return
        }
        pendingOrdinaryResizeWidth = nil
        ordinaryResizeInProgress = false
        onSettledUpdate?(.ordinary(viewportWidth: viewportWidth))
    }

    private func cancelPendingLiveResizeUpdate() {
        liveResizeTimer?.invalidate()
        liveResizeTimer = nil
        pendingLiveResizeWidth = nil
    }

    private func cancelPendingOrdinaryResizeUpdate() {
        ordinaryResizeTimer?.invalidate()
        ordinaryResizeTimer = nil
        pendingOrdinaryResizeWidth = nil
        ordinaryResizeInProgress = false
    }

    private func stopObservingClipView() {
        cancelPendingOrdinaryResizeUpdate()
        cancelPendingLiveResizeUpdate()
        if let clipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: clipView
            )
        }
        clipView = nil
        lastObservedWidth = nil
    }

    private func stopObservingWindow() {
        cancelPendingLiveResizeUpdate()
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willStartLiveResizeNotification,
                object: window
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEndLiveResizeNotification,
                object: window
            )
        }
        window = nil
        isLiveResizing = false
    }
}
