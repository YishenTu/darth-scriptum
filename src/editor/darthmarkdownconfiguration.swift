import AppKit
import ImageIO
import MarkdownEngine
import MarkdownEngineLatex

@MainActor
enum DarthMarkdownConfiguration {
    private static let latexRenderer = SwiftMathBridge()

    static func make(
        rawSourceMode: Bool,
        fontSize: CGFloat,
        documentURL: URL?
    ) -> MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: DarthTheme.foreground,
            mutedText: DarthTheme.mutedForeground,
            disabledText: DarthTheme.mutedForeground.withAlphaComponent(0.65),
            headingMarker: DarthTheme.accent,
            link: DarthTheme.accent,
            incompleteLink: DarthTheme.accent,
            findMatchHighlight: DarthTheme.selectionBackground,
            findCurrentMatchHighlight: DarthTheme.accent,
            latexLightModeText: DarthTheme.foreground,
            latexDarkModeText: DarthTheme.foreground,
            strikethroughColor: DarthTheme.mutedForeground,
            highlightColor: DarthTheme.selectionBackground
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.theme = theme
        configuration.services = MarkdownEditorServices(
            images: DarthMarkdownImageProvider(documentURL: documentURL),
            syntaxHighlighter: DarthSyntaxHighlighter(),
            latex: latexRenderer
        )
        configuration.textInsets = TextInsets(horizontal: 32, vertical: 28)
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

private struct DarthSyntaxHighlighter: SyntaxHighlighter {
    func codeFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    func backgroundColor() -> NSColor {
        DarthTheme.codeBackground
    }

    func highlight(
        code: String,
        language: String?
    ) -> NSAttributedString? {
        nil
    }

    var appearanceDidChangeNotification: Notification.Name? {
        nil
    }
}

final class DarthMarkdownImageProvider: EmbeddedImageProvider, @unchecked Sendable {
    private static let maximumImageFileBytes = 8 * 1_024 * 1_024
    private static let maximumDecodedImageCost = 32 * 1_024 * 1_024

    private let documentURL: URL?
    private let cache = NSCache<NSURL, NSImage>()

    init(documentURL: URL?) {
        self.documentURL = documentURL?.standardizedFileURL
        cache.totalCostLimit = Self.maximumDecodedImageCost
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        guard let url = MarkdownLinkResolver.resolveLocalFile(
            reference.name,
            relativeTo: documentURL
        ) else {
            return nil
        }
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize <= Self.maximumImageFileBytes,
        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
        let decodedCost = decodedCost(of: imageSource),
        decodedCost <= Self.maximumDecodedImageCost,
        let decodedImage = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        ) else {
            return nil
        }
        let image = NSImage(
            cgImage: decodedImage,
            size: NSSize(
                width: decodedImage.width,
                height: decodedImage.height
            )
        )
        cache.setObject(image, forKey: url as NSURL, cost: decodedCost)
        return image
    }

    func fingerprint() -> AnyHashable {
        documentURL?.path ?? "untitled"
    }

    private func decodedCost(of source: CGImageSource) -> Int? {
        var total = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                return nil
            }
            let (pixels, pixelOverflow) = width.intValue
                .multipliedReportingOverflow(by: height.intValue)
            guard !pixelOverflow else { return nil }
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            guard !byteOverflow else { return nil }
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(bytes)
            guard !totalOverflow,
                  nextTotal <= Self.maximumDecodedImageCost else {
                return nil
            }
            total = nextTotal
        }
        return total
    }
}
