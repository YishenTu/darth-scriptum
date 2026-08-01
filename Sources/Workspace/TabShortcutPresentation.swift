import AppKit

@MainActor
enum TabShortcutPresentation {
    private static let labelIdentifier = NSUserInterfaceItemIdentifier(
        "DarthScriptum.TabShortcut"
    )

    static func update(windows: [NSWindow]) {
        for (index, window) in windows.enumerated() {
            guard
                let number = TabShortcutPolicy.displayNumber(
                    forTabAt: index,
                    tabCount: windows.count
                )
            else {
                if window.tab.accessoryView != nil {
                    window.tab.accessoryView = nil
                }
                continue
            }
            let label = shortcutLabel(for: window)
            let title = "⌘\(number)"
            if label.stringValue != title {
                label.stringValue = title
                label.setAccessibilityLabel("Command-\(number)")
            }
            if window.tab.accessoryView !== label {
                window.tab.accessoryView = label
            }
        }
    }

    private static func shortcutLabel(for window: NSWindow) -> NSTextField {
        if let label = window.tab.accessoryView as? NSTextField,
            label.identifier == labelIdentifier
        {
            return label
        }
        let label = NSTextField(labelWithString: "")
        label.identifier = labelIdentifier
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(
            ofSize: 10,
            weight: .medium
        )
        label.textColor = .tertiaryLabelColor
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 24),
            label.heightAnchor.constraint(equalToConstant: 16),
        ])
        return label
    }
}
