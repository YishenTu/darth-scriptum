import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

@MainActor
enum MarkdownConfigurationFactory {
    private static let latexRenderer = AdaptiveLaTeXRenderer()
    private static let syntaxHighlighter = HighlighterSwiftBridge(
        lightTheme: "atom-one-light",
        darkTheme: "atom-one-dark",
        autoSwitchAppearance: true,
        lightBackground: AppTheme.codeBackground,
        darkBackground: AppTheme.codeBackground,
        preferredFontNames: [
            "DejaVu Sans Mono for Powerline",
            "SF Mono",
            "Menlo",
        ]
    )

    static func make(
        rawSourceMode: Bool,
        fontSize: CGFloat,
        documentURL: URL?,
        latexRenderer: AdaptiveLaTeXRenderer? = nil,
        imageProvider: MarkdownImageProvider? = nil
    ) -> MarkdownEditorConfiguration {
        let activeLaTeXRenderer = latexRenderer ?? self.latexRenderer
        let theme = MarkdownEditorTheme(
            bodyText: AppTheme.foreground,
            mutedText: AppTheme.mutedForeground,
            disabledText: AppTheme.mutedForeground.withAlphaComponent(0.65),
            headingMarker: AppTheme.accent,
            link: AppTheme.accent,
            incompleteLink: AppTheme.accent,
            findMatchHighlight: AppTheme.selectionBackground,
            findCurrentMatchHighlight: AppTheme.accent,
            latexLightModeText: AppTheme.foreground,
            latexDarkModeText: AppTheme.foreground,
            strikethroughColor: AppTheme.mutedForeground,
            highlightColor: AppTheme.selectionBackground
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.theme = theme
        configuration.services = MarkdownEditorServices(
            images: imageProvider
                ?? MarkdownImageProvider(
                    documentURL: documentURL,
                    updateNotification: activeLaTeXRenderer.updateNotification
                ),
            syntaxHighlighter: CodeSyntaxHighlighter(
                highlighter: syntaxHighlighter,
                appearanceDidChangeNotification:
                    activeLaTeXRenderer.updateNotification
            ),
            latex: activeLaTeXRenderer
        )
        configuration.textInsets = TextInsets(horizontal: 48, vertical: 28)
        configuration.headings = HeadingStyle(
            fontMultipliers: [2, 1.6, 1.35, 1.15, 1, 0.9],
            topSpacingEm: [0.5, 0.42, 0.34, 0.26, 0.18, 0.1]
        )
        configuration.lists = ListStyle(
            helpersEnabled: true,
            autoClosePairsEnabled: true,
            indentPerLevel: max(fontSize * 1.45, 16),
            maximumNestingLevel: 8,
            extraLineHeight: max(fontSize * 0.18, 2)
        )
        configuration.paragraph = ParagraphStyle(
            spacingFactor: 0.55,
            lineHeightExtraSpacing: max(fontSize * 0.18, 2)
        )
        configuration.rawSourceMode = rawSourceMode
        configuration.extensions = [StrikethroughExtension()]
        return configuration
    }
}

private struct CodeSyntaxHighlighter: SyntaxHighlighter {
    let highlighter: HighlighterSwiftBridge
    let appearanceDidChangeNotification: Notification.Name?

    func codeFont(size: CGFloat) -> NSFont {
        highlighter.codeFont(size: size)
    }

    func backgroundColor() -> NSColor {
        AppTheme.codeBackground
    }

    func highlight(
        code: String,
        language: String?
    ) -> NSAttributedString? {
        guard
            SyntaxHighlightingPolicy.shouldHighlight(
                code: code,
                language: language
            )
        else {
            return nil
        }
        return highlighter.highlight(
            code: code,
            language: SyntaxHighlightingPolicy.supportedLanguage(
                language
            )
        )
    }

}

enum SyntaxHighlightingPolicy {
    static let maximumCodeUTF8Bytes = 64 * 1_024
    private static let maximumLanguageUTF8Bytes = 64
    private static let aliases = [
        "cs": "csharp",
        "docker": "dockerfile",
        "fs": "fsharp",
        "golang": "go",
        "html": "xml",
        "js": "javascript",
        "jsx": "javascript",
        "kt": "kotlin",
        "md": "markdown",
        "objc": "objectivec",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "sh": "bash",
        "tex": "latex",
        "ts": "typescript",
        "tsx": "typescript",
        "vue": "xml",
        "yml": "yaml",
        "zsh": "bash",
    ]
    private static let supportedLanguages = Set(
        """
        1c abnf accesslog actionscript ada angelscript apache applescript arcade
        arduino armasm asciidoc aspectj autohotkey autoit avrasm awk axapta bash
        basic bnf brainfuck c cal capnproto ceylon clean clojure clojure-repl
        cmake coffeescript coq cos cpp crmsh crystal csharp csp css d dart delphi
        diff django dns dockerfile dos dsconfig dts dust ebnf elixir elm erb
        erlang erlang-repl excel fix flix fortran fsharp gams gauss gcode
        gherkin glsl gml go golo gradle graphql groovy haml handlebars haskell
        haxe hsp http hy inform7 ini irpf90 isbl java javascript jboss-cli json
        julia julia-repl kotlin lasso latex ldif leaf less lisp livecodeserver
        livescript llvm lsl lua makefile markdown mathematica matlab maxima mel
        mercury mipsasm mizar mojolicious monkey moonscript n1ql nestedtext nginx
        nim nix node-repl nsis objectivec ocaml openscad oxygene parser3 perl pf
        pgsql php php-template plaintext pony powershell processing profile
        prolog properties protobuf puppet purebasic python python-repl q qml r
        reasonml rib roboconf routeros rsl ruby ruleslanguage rust sas scala
        scheme scilab scss shell smali smalltalk sml sqf sql stan stata step21
        stylus subunit swift taggerscript tap tcl thrift tp twig typescript vala
        vbnet vbscript vbscript-html verilog vhdl vim wasm wren x86asm xl xml
        xquery yaml zephir
        """
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    )

    static func supportedLanguage(_ language: String?) -> String? {
        guard let language,
            language.utf8.count <= maximumLanguageUTF8Bytes
        else {
            return nil
        }
        let normalized =
            language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        if let canonical = aliases[normalized] {
            return canonical
        }
        return supportedLanguages.contains(normalized) ? normalized : nil
    }

    static func shouldHighlight(
        code: String,
        language: String?
    ) -> Bool {
        guard code.utf8.count <= maximumCodeUTF8Bytes else {
            return false
        }
        guard let language else { return true }
        guard language.utf8.count <= maximumLanguageUTF8Bytes else {
            return false
        }
        let normalized = language.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty || supportedLanguage(normalized) != nil
    }
}
