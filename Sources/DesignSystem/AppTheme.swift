import AppKit
import SwiftUI

enum AppTheme {
    static let background = NSColor(hex: 0x1A1614)
    static let backgroundOverlayOpacity: CGFloat = 0.55
    static let statusBarOverlayOpacity: CGFloat = 0.66
    static let foreground = NSColor(hex: 0xE8D5B7)
    static let accent = NSColor(hex: 0xC4956A)
    static let selectionBackground = NSColor(hex: 0x4A3A2A)
    static let mutedForeground = NSColor(hex: 0xA9967D)
    static let codeBackground = NSColor(hex: 0x2A221E)
    static let separator = NSColor(hex: 0x5A4638)
    static let failure = NSColor(hex: 0xE06C75)
    static let success = NSColor(hex: 0x98C379)

    static func editorFont(size: CGFloat) -> NSFont {
        let clampedSize = min(max(size, 10), 32)
        return editorFont(at: clampedSize)
    }

    static func headingFont(level: Int, baseSize: CGFloat) -> NSFont {
        let scales: [CGFloat] = [2, 1.6, 1.35, 1.15, 1, 0.9]
        let scale = scales[min(max(level - 1, 0), scales.count - 1)]
        let clampedBaseSize = min(max(baseSize, 10), 32)
        let headingSize = max(clampedBaseSize * scale, 10)
        return NSFontManager.shared.convert(
            editorFont(at: headingSize),
            toHaveTrait: .boldFontMask
        )
    }

    static func bodyParagraphStyle(fontSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(fontSize * 0.18, 2)
        style.paragraphSpacing = max(fontSize * 0.55, 6)
        return style
    }

    static func headingParagraphStyle(
        level: Int,
        fontSize: CGFloat
    ) -> NSParagraphStyle {
        let style =
            bodyParagraphStyle(fontSize: fontSize).mutableCopy()
            as! NSMutableParagraphStyle
        let clampedLevel = min(max(level, 1), 6)
        let prominence = CGFloat(7 - clampedLevel) / 6
        style.lineHeightMultiple = 1.05
        style.paragraphSpacingBefore = fontSize * (0.4 + prominence * 0.5)
        style.paragraphSpacing = fontSize * (0.45 + prominence * 0.25)
        return style
    }

    static func listParagraphStyle(
        depth: Int,
        fontSize: CGFloat
    ) -> NSParagraphStyle {
        let style =
            bodyParagraphStyle(fontSize: fontSize).mutableCopy()
            as! NSMutableParagraphStyle
        let level = CGFloat(max(depth, 1))
        let indentation = max(fontSize * 1.45, 16)
        style.firstLineHeadIndent = indentation * (level - 1)
        style.headIndent = indentation * level
        style.paragraphSpacing = max(fontSize * 0.2, 3)
        return style
    }

    static func quoteParagraphStyle(fontSize: CGFloat) -> NSParagraphStyle {
        let style =
            bodyParagraphStyle(fontSize: fontSize).mutableCopy()
            as! NSMutableParagraphStyle
        style.headIndent = max(fontSize * 0.9, 10)
        style.paragraphSpacing = max(fontSize * 0.35, 4)
        return style
    }

    private static func editorFont(at size: CGFloat) -> NSFont {
        let base =
            NSFont(name: "DejaVu Sans Mono for Powerline", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [
                NSFontDescriptor(fontAttributes: [
                    .name: "Hiragino Sans GB"
                ])
            ]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

struct MaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
