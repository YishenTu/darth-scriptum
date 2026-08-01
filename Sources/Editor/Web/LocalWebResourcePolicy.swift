import Foundation
import WebKit

@MainActor
final class LocalWebResourcePolicy: NSObject, WKUIDelegate {
    let entryURL: URL
    let resourceRootURL: URL

    init?(entryURL: URL, resourceRootURL: URL) {
        guard let canonicalEntryURL = Self.canonicalFileURL(entryURL),
            let canonicalResourceRootURL = Self.canonicalFileURL(
                resourceRootURL
            ),
            Self.isDescendant(
                canonicalEntryURL,
                of: canonicalResourceRootURL
            )
        else {
            return nil
        }
        self.entryURL = canonicalEntryURL
        self.resourceRootURL = canonicalResourceRootURL
    }

    convenience init?(
        bundle: Bundle = .main,
        entryResourceName: String,
        resourceDirectoryName: String
    ) {
        guard
            let resourceRootURL = bundle.resourceURL?
                .appendingPathComponent(resourceDirectoryName, isDirectory: true),
            let entryURL = bundle.url(
                forResource: entryResourceName,
                withExtension: "html",
                subdirectory: resourceDirectoryName
            )
        else {
            return nil
        }
        self.init(entryURL: entryURL, resourceRootURL: resourceRootURL)
    }

    @discardableResult
    func loadEntry(in webView: WKWebView) -> WKNavigation? {
        webView.loadFileURL(
            entryURL,
            allowingReadAccessTo: resourceRootURL
        )
    }

    func allowsMainFrameNavigation(to url: URL) -> Bool {
        allowsNavigation(to: url, isMainFrame: true)
    }

    func allowsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame,
            let url
        else {
            return false
        }
        if url.absoluteString == "about:blank" {
            return true
        }
        guard let canonicalURL = Self.canonicalFileURL(url),
            url.absoluteString == canonicalURL.absoluteString
        else {
            return false
        }
        return canonicalURL == entryURL
    }

    func navigationPolicy(
        for navigationAction: WKNavigationAction
    ) -> WKNavigationActionPolicy {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        return allowsNavigation(
            to: navigationAction.request.url,
            isMainFrame: isMainFrame
        ) ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    private static func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else {
            return nil
        }
        return url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func isDescendant(
        _ fileURL: URL,
        of rootURL: URL
    ) -> Bool {
        let filePathComponents = fileURL.pathComponents
        let rootPathComponents = rootURL.pathComponents
        guard filePathComponents.count > rootPathComponents.count else {
            return false
        }
        return zip(filePathComponents, rootPathComponents).allSatisfy(==)
    }
}
