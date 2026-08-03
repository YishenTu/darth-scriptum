import Foundation

struct WorkspaceRestorationState: Equatable {
    enum ActivePane: Int, Equatable {
        case primary
        case secondary
    }

    static let currentVersion = 1
    private static let maximumSelectionComponent = 1_073_741_824
    private static let maximumScrollCoordinate: CGFloat = 10_000_000

    let version: Int
    let isSplit: Bool
    let sourceMode: Bool
    let fontSize: CGFloat
    let activePane: ActivePane
    let primarySelection: NSRange
    let primaryVisibleOrigin: NSPoint
    let secondarySelection: NSRange
    let secondaryVisibleOrigin: NSPoint

    init?(
        version: Int = Self.currentVersion,
        isSplit: Bool,
        sourceMode: Bool,
        fontSize: CGFloat,
        activePane: ActivePane,
        primarySelection: NSRange,
        primaryVisibleOrigin: NSPoint,
        secondarySelection: NSRange,
        secondaryVisibleOrigin: NSPoint
    ) {
        guard version == Self.currentVersion,
            fontSize.isFinite,
            (10...32).contains(fontSize),
            activePane != .secondary || isSplit,
            Self.isValid(selection: primarySelection),
            Self.isValid(selection: secondarySelection),
            Self.isValid(origin: primaryVisibleOrigin),
            Self.isValid(origin: secondaryVisibleOrigin)
        else {
            return nil
        }
        self.version = version
        self.isSplit = isSplit
        self.sourceMode = sourceMode
        self.fontSize = fontSize
        self.activePane = activePane
        self.primarySelection = primarySelection
        self.primaryVisibleOrigin = primaryVisibleOrigin
        self.secondarySelection = secondarySelection
        self.secondaryVisibleOrigin = secondaryVisibleOrigin
    }

    func encode(to coder: NSCoder) {
        coder.encode(version, forKey: Key.version)
        coder.encode(isSplit, forKey: Key.isSplit)
        coder.encode(sourceMode, forKey: Key.sourceMode)
        coder.encode(Double(fontSize), forKey: Key.fontSize)
        coder.encode(activePane.rawValue, forKey: Key.activePane)
        Self.encode(primarySelection, prefix: "primarySelection", to: coder)
        Self.encode(primaryVisibleOrigin, prefix: "primaryOrigin", to: coder)
        Self.encode(secondarySelection, prefix: "secondarySelection", to: coder)
        Self.encode(secondaryVisibleOrigin, prefix: "secondaryOrigin", to: coder)
    }

    static func decode(from coder: NSCoder) -> WorkspaceRestorationState? {
        guard
            let activePane = ActivePane(
                rawValue: coder.decodeInteger(forKey: Key.activePane)
            )
        else {
            return nil
        }
        return WorkspaceRestorationState(
            version: coder.decodeInteger(forKey: Key.version),
            isSplit: coder.decodeBool(forKey: Key.isSplit),
            sourceMode: coder.decodeBool(forKey: Key.sourceMode),
            fontSize: CGFloat(coder.decodeDouble(forKey: Key.fontSize)),
            activePane: activePane,
            primarySelection: decodeSelection(
                prefix: "primarySelection",
                from: coder
            ),
            primaryVisibleOrigin: decodeOrigin(
                prefix: "primaryOrigin",
                from: coder
            ),
            secondarySelection: decodeSelection(
                prefix: "secondarySelection",
                from: coder
            ),
            secondaryVisibleOrigin: decodeOrigin(
                prefix: "secondaryOrigin",
                from: coder
            )
        )
    }

    private enum Key {
        static let version = "workspace.version"
        static let isSplit = "workspace.isSplit"
        static let sourceMode = "workspace.sourceMode"
        static let fontSize = "workspace.fontSize"
        static let activePane = "workspace.activePane"
    }

    private static func isValid(selection: NSRange) -> Bool {
        selection.location >= 0
            && selection.length >= 0
            && selection.location <= maximumSelectionComponent
            && selection.length <= maximumSelectionComponent - selection.location
    }

    private static func isValid(origin: NSPoint) -> Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && origin.x >= 0
            && origin.y >= 0
            && origin.x <= maximumScrollCoordinate
            && origin.y <= maximumScrollCoordinate
    }

    private static func encode(
        _ selection: NSRange,
        prefix: String,
        to coder: NSCoder
    ) {
        coder.encode(selection.location, forKey: "\(prefix).location")
        coder.encode(selection.length, forKey: "\(prefix).length")
    }

    private static func encode(
        _ origin: NSPoint,
        prefix: String,
        to coder: NSCoder
    ) {
        coder.encode(Double(origin.x), forKey: "\(prefix).x")
        coder.encode(Double(origin.y), forKey: "\(prefix).y")
    }

    private static func decodeSelection(
        prefix: String,
        from coder: NSCoder
    ) -> NSRange {
        NSRange(
            location: coder.decodeInteger(forKey: "\(prefix).location"),
            length: coder.decodeInteger(forKey: "\(prefix).length")
        )
    }

    private static func decodeOrigin(
        prefix: String,
        from coder: NSCoder
    ) -> NSPoint {
        NSPoint(
            x: coder.decodeDouble(forKey: "\(prefix).x"),
            y: coder.decodeDouble(forKey: "\(prefix).y")
        )
    }
}
