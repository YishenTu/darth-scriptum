import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class AppThemeTests: XCTestCase {
    func testWarmColorTokensAdaptBetweenAquaAndDarkAqua() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightBackground = AppTheme.background.hexRGB(in: aqua)
        let darkBackground = AppTheme.background.hexRGB(in: darkAqua)

        XCTAssertEqual(lightBackground, 0xF7F1E8)
        XCTAssertEqual(darkBackground, 0x1A1614)
        XCTAssertNotEqual(lightBackground, darkBackground)
        XCTAssertLessThan(AppTheme.backgroundOverlayOpacity, 0.7)
        XCTAssertGreaterThan(AppTheme.backgroundOverlayOpacity, 0)
        XCTAssertLessThan(AppTheme.statusBarOverlayOpacity, 0.78)
        XCTAssertGreaterThan(AppTheme.statusBarOverlayOpacity, 0)
        XCTAssertEqual(AppTheme.foreground.hexRGB(in: darkAqua), 0xE8D5B7)
        XCTAssertEqual(AppTheme.accent.hexRGB(in: darkAqua), 0xC4956A)
        XCTAssertEqual(
            AppTheme.selectionBackground.hexRGB(in: darkAqua),
            0x4A3A2A
        )
        XCTAssertNotEqual(
            AppTheme.codeBackground.hexRGB(in: aqua),
            AppTheme.codeBackground.hexRGB(in: darkAqua)
        )
    }

    func testMaterialTracksWindowActivityAndReduceTransparencyFallback() {
        let view = MaterialEffectView()

        view.apply(isWindowActive: true, reducesTransparency: false)
        XCTAssertEqual(view.effectState, .active)
        XCTAssertFalse(view.usesOpaqueFallback)

        view.apply(isWindowActive: false, reducesTransparency: false)
        XCTAssertEqual(view.effectState, .inactive)
        XCTAssertFalse(view.usesOpaqueFallback)

        view.apply(isWindowActive: true, reducesTransparency: true)
        XCTAssertTrue(view.usesOpaqueFallback)
        XCTAssertTrue(view.isEffectHidden)
    }

    func testOpaqueMaterialFallbackTracksEffectiveAppearanceChanges() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let view = MaterialEffectView(
            reducesTransparencyProvider: { true }
        )
        view.appearance = aqua
        view.refresh()

        XCTAssertEqual(view.opaqueFallbackHexRGB(in: aqua), 0xF7F1E8)

        view.appearance = darkAqua

        XCTAssertTrue(view.usesOpaqueFallback)
        XCTAssertEqual(view.opaqueFallbackHexRGB(in: darkAqua), 0x1A1614)
    }

    func testFontSizeIsClamped() {
        XCTAssertEqual(AppTheme.editorFont(size: 1).pointSize, 10, accuracy: 0.01)
        XCTAssertEqual(AppTheme.editorFont(size: 100).pointSize, 32, accuracy: 0.01)
    }

    func testHeadingLevelsHaveAStableReadableScale() {
        let sizes = (1...6).map {
            AppTheme.headingFont(level: $0, baseSize: 14).pointSize
        }

        for (actual, expected) in zip(
            sizes,
            [28, 22.4, 18.9, 16.1, 14, 12.6]
        ) {
            XCTAssertEqual(actual, expected, accuracy: 0.01)
        }
        XCTAssertEqual(
            AppTheme.headingFont(level: 1, baseSize: 32).pointSize,
            64,
            accuracy: 0.01
        )
    }

    func testBlockParagraphStylesAddMarkdownSpacingAndIndentation() {
        let body = AppTheme.bodyParagraphStyle(fontSize: 14)
        let heading = AppTheme.headingParagraphStyle(
            level: 1,
            fontSize: 14
        )
        let nestedList = AppTheme.listParagraphStyle(
            depth: 2,
            fontSize: 14
        )

        XCTAssertGreaterThan(body.lineSpacing, 0)
        XCTAssertGreaterThan(heading.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(nestedList.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(
            nestedList.headIndent,
            nestedList.firstLineHeadIndent
        )
    }
}

extension NSColor {
    fileprivate func hexRGB(in appearance: NSAppearance) -> UInt32? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = usingColorSpace(.sRGB)
        }
        guard let resolved else { return nil }
        let red = UInt32((resolved.redComponent * 255).rounded())
        let green = UInt32((resolved.greenComponent * 255).rounded())
        let blue = UInt32((resolved.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}

extension MaterialEffectView {
    fileprivate func opaqueFallbackHexRGB(
        in appearance: NSAppearance
    ) -> UInt32? {
        guard
            let backgroundColor = layer?.backgroundColor,
            let color = NSColor(cgColor: backgroundColor)
        else {
            return nil
        }
        return color.hexRGB(in: appearance)
    }
}
