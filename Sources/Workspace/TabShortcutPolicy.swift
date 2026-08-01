enum TabShortcutPolicy {
    static let lastTabShortcut = 9
    private static let directShortcutRange = 1...8

    static func selectionIndex(
        for shortcutNumber: Int,
        tabCount: Int
    ) -> Int? {
        guard tabCount > 0 else { return nil }
        if shortcutNumber == lastTabShortcut {
            return tabCount - 1
        }
        guard directShortcutRange.contains(shortcutNumber),
            shortcutNumber <= tabCount
        else {
            return nil
        }
        return shortcutNumber - 1
    }

    static func displayNumber(
        forTabAt index: Int,
        tabCount: Int
    ) -> Int? {
        guard tabCount > 1, index >= 0, index < tabCount else {
            return nil
        }
        if index < directShortcutRange.upperBound {
            return index + 1
        }
        return index == tabCount - 1 ? lastTabShortcut : nil
    }
}
