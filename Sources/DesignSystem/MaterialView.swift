import AppKit
import SwiftUI

struct MaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> MaterialEffectView {
        MaterialEffectView()
    }

    func updateNSView(_ view: MaterialEffectView, context: Context) {
        view.refresh()
    }
}

@MainActor
final class MaterialEffectView: NSView {
    private let effectView = NSVisualEffectView()
    private let reducesTransparencyProvider: @MainActor () -> Bool
    private var windowObservationTokens: [NSObjectProtocol] = []
    private var accessibilityObservationToken: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        reducesTransparencyProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        super.init(frame: frameRect)
        configure()
    }

    init(
        frame frameRect: NSRect,
        reducesTransparencyProvider: @escaping @MainActor () -> Bool
    ) {
        self.reducesTransparencyProvider = reducesTransparencyProvider
        super.init(frame: frameRect)
        configure()
    }

    convenience init(
        reducesTransparencyProvider: @escaping @MainActor () -> Bool
    ) {
        self.init(
            frame: .zero,
            reducesTransparencyProvider: reducesTransparencyProvider
        )
    }

    private func configure() {
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        addSubview(effectView)
        accessibilityObservationToken = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        refresh()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else {
            refresh()
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refresh()
                    }
                }
            )
        }
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func refresh() {
        apply(
            isWindowActive: window?.isKeyWindow == true,
            reducesTransparency: reducesTransparencyProvider()
        )
    }

    func apply(isWindowActive: Bool, reducesTransparency: Bool) {
        effectView.state = isWindowActive ? .active : .inactive
        effectView.isHidden = reducesTransparency
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                reducesTransparency
                ? AppTheme.background.usingColorSpace(.sRGB)?.cgColor
                : NSColor.clear.cgColor
        }
    }

    var effectState: NSVisualEffectView.State {
        effectView.state
    }

    var usesOpaqueFallback: Bool {
        !effectView.isHidden ? false : layer?.backgroundColor != nil
    }

    var isEffectHidden: Bool {
        effectView.isHidden
    }

    private func removeWindowObservers() {
        for token in windowObservationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservationTokens.removeAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    isolated deinit {
        removeWindowObservers()
        if let accessibilityObservationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(
                accessibilityObservationToken
            )
        }
    }
}
