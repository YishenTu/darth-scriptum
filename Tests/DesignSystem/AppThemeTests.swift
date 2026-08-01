import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class AppThemeTests: XCTestCase {
    func testGhosttyColorTokens() {
        XCTAssertEqual(AppTheme.background.usingColorSpace(.sRGB)?.hexRGB, 0x1A1614)
        XCTAssertLessThan(AppTheme.backgroundOverlayOpacity, 0.7)
        XCTAssertGreaterThan(AppTheme.backgroundOverlayOpacity, 0)
        XCTAssertLessThan(AppTheme.statusBarOverlayOpacity, 0.78)
        XCTAssertGreaterThan(AppTheme.statusBarOverlayOpacity, 0)
        XCTAssertEqual(AppTheme.foreground.usingColorSpace(.sRGB)?.hexRGB, 0xE8D5B7)
        XCTAssertEqual(AppTheme.accent.usingColorSpace(.sRGB)?.hexRGB, 0xC4956A)
        XCTAssertEqual(
            AppTheme.selectionBackground.usingColorSpace(.sRGB)?.hexRGB,
            0x4A3A2A
        )
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
    fileprivate var hexRGB: UInt32 {
        let red = UInt32((redComponent * 255).rounded())
        let green = UInt32((greenComponent * 255).rounded())
        let blue = UInt32((blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}
