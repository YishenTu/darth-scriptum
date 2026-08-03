import AppKit
import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownConfigurationFactoryTests: XCTestCase {
    func testEditorUsesComfortableSymmetricContentInsets() {
        let configuration = MarkdownConfigurationFactory.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        )

        XCTAssertEqual(configuration.textInsets.horizontal, 48)
        XCTAssertEqual(configuration.textInsets.vertical, 28)
    }

    func testConfiguredSyntaxHighlighterHighlightsPythonCode() throws {
        let configuration = MarkdownConfigurationFactory.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        )
        let code = """
            def normal_cdf(x: float) -> float:
                return 0.5 * (1.0 + erf(x / sqrt(2.0)))
            """

        let highlighted = try XCTUnwrap(
            configuration.services.syntaxHighlighter.highlight(
                code: code,
                language: "python"
            )
        )

        XCTAssertEqual(highlighted.string, code)
        XCTAssertGreaterThan(distinctForegroundColors(in: highlighted), 1)
    }

    func testConfiguredSyntaxHighlighterUsesCodeStyling() {
        let highlighter = MarkdownConfigurationFactory.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        ).services.syntaxHighlighter

        XCTAssertEqual(highlighter.backgroundColor(), AppTheme.codeBackground)
        XCTAssertTrue(highlighter.codeFont(size: 14).isFixedPitch)
    }

    func testConfiguredSyntaxHighlighterFollowsApplicationAppearance() throws {
        let highlighter = MarkdownConfigurationFactory.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        ).services.syntaxHighlighter

        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightBackground = highlighter.backgroundColor().hexRGB(in: aqua)
        let darkBackground = highlighter.backgroundColor().hexRGB(in: darkAqua)

        XCTAssertEqual(lightBackground, 0xEFE5D8)
        XCTAssertEqual(darkBackground, 0x2A221E)
        XCTAssertNotEqual(lightBackground, darkBackground)
    }

    func testSyntaxHighlighterBoundsAndCanonicalizesLanguageNames() {
        XCTAssertEqual(
            SyntaxHighlightingPolicy.supportedLanguage(" JS "),
            "javascript"
        )
        XCTAssertEqual(
            SyntaxHighlightingPolicy.supportedLanguage("python"),
            "python"
        )
        XCTAssertNil(
            SyntaxHighlightingPolicy.supportedLanguage(
                "unknown-language"
            )
        )
        XCTAssertNil(
            SyntaxHighlightingPolicy.supportedLanguage(
                String(repeating: "x", count: 65)
            )
        )
    }

    func testSyntaxHighlighterRejectsOversizedCodeBeforeHighlighting() {
        let maximum = SyntaxHighlightingPolicy.maximumCodeUTF8Bytes
        XCTAssertTrue(
            SyntaxHighlightingPolicy.shouldHighlight(
                code: String(repeating: "x", count: maximum),
                language: "plaintext"
            )
        )
        XCTAssertFalse(
            SyntaxHighlightingPolicy.shouldHighlight(
                code: String(repeating: "x", count: maximum + 1),
                language: "plaintext"
            )
        )
        XCTAssertFalse(
            SyntaxHighlightingPolicy.shouldHighlight(
                code: "let value = 1",
                language: "unknown-language"
            )
        )

        let highlighter = MarkdownConfigurationFactory.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        ).services.syntaxHighlighter
        XCTAssertNil(
            highlighter.highlight(
                code: String(repeating: "x", count: maximum + 1),
                language: nil
            )
        )
    }

    private func distinctForegroundColors(
        in attributedString: NSAttributedString
    ) -> Int {
        var colors = Set<String>()
        attributedString.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            guard let color = value as? NSColor else { return }
            colors.insert(
                color.usingColorSpace(.sRGB)?.description
                    ?? color.description
            )
        }
        return colors.count
    }
}

extension NSColor {
    fileprivate func hexRGB(in appearance: NSAppearance) -> UInt32? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = usingColorSpace(.sRGB)
        }
        guard let color = resolved else { return nil }
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}
