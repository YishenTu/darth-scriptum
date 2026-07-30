import AppKit
import XCTest
@testable import DarthScriptum

@MainActor
final class MarkdownConfigurationFactoryTests: XCTestCase {
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
