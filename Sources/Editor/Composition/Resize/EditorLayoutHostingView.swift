import AppKit
import SwiftUI

/// Exposes the SwiftUI/AppKit layout boundary that owns editor width changes.
///
/// The first visible line must be captured before descendants reflow and
/// restored only after that reflow has completed. Frame notifications from the
/// scroll view are too late for the first half of that transaction.
@MainActor
final class EditorLayoutHostingView: NSHostingView<AnyView> {
    var onWidthWillChange: (@MainActor (CGFloat) -> Void)?
    var onLayoutDidComplete: (@MainActor () -> Void)?

    private var isCompletingLayout = false

    override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.width) > 0.5 {
            onWidthWillChange?(newSize.width)
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        guard !isCompletingLayout else { return }

        isCompletingLayout = true
        onLayoutDidComplete?()
        isCompletingLayout = false
    }
}
