import AppKit
import XCTest
@testable import DarthMD

@MainActor
final class DarthMarkdownConfigurationTests: XCTestCase {
    func testConfiguredSyntaxHighlighterHighlightsPythonCode() throws {
        let configuration = DarthMarkdownConfiguration.make(
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

    func testConfiguredSyntaxHighlighterUsesDarthCodeStyling() {
        let highlighter = DarthMarkdownConfiguration.make(
            rawSourceMode: false,
            fontSize: 14,
            documentURL: nil
        ).services.syntaxHighlighter

        XCTAssertEqual(highlighter.backgroundColor(), DarthTheme.codeBackground)
        XCTAssertTrue(highlighter.codeFont(size: 14).isFixedPitch)
    }

    func testSyntaxHighlighterBoundsAndCanonicalizesLanguageNames() {
        XCTAssertEqual(
            DarthSyntaxHighlightingPolicy.supportedLanguage(" JS "),
            "javascript"
        )
        XCTAssertEqual(
            DarthSyntaxHighlightingPolicy.supportedLanguage("python"),
            "python"
        )
        XCTAssertNil(
            DarthSyntaxHighlightingPolicy.supportedLanguage(
                "unknown-language"
            )
        )
        XCTAssertNil(
            DarthSyntaxHighlightingPolicy.supportedLanguage(
                String(repeating: "x", count: 65)
            )
        )
    }

    func testSyntaxHighlighterRejectsOversizedCodeBeforeHighlighting() {
        let maximum = DarthSyntaxHighlightingPolicy.maximumCodeUTF8Bytes
        XCTAssertTrue(
            DarthSyntaxHighlightingPolicy.shouldHighlight(
                code: String(repeating: "x", count: maximum),
                language: "plaintext"
            )
        )
        XCTAssertFalse(
            DarthSyntaxHighlightingPolicy.shouldHighlight(
                code: String(repeating: "x", count: maximum + 1),
                language: "plaintext"
            )
        )
        XCTAssertFalse(
            DarthSyntaxHighlightingPolicy.shouldHighlight(
                code: "let value = 1",
                language: "unknown-language"
            )
        )

        let highlighter = DarthMarkdownConfiguration.make(
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
