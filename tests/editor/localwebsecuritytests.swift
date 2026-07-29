import AppKit
import Darwin
import Dispatch
import Foundation
import WebKit
import XCTest
@testable import DarthScriptum

@MainActor
final class LocalWebSecurityTests: XCTestCase {
    func testPolicyAllowsOnlyExactCanonicalEntryAndAboutBlank() async throws {
        try await withTemporaryDirectory { rootURL in
            let entryURL = rootURL.appendingPathComponent("renderer.html")
            let siblingURL = rootURL.appendingPathComponent("sibling.html")
            let nestedURL = rootURL.appendingPathComponent("nested")
            let traversalURL = URL(
                fileURLWithPath: nestedURL.path + "/../renderer.html"
            )
            let symlinkURL = rootURL.appendingPathComponent("renderer-link.html")
            try FileManager.default.createDirectory(
                at: nestedURL,
                withIntermediateDirectories: true
            )
            try "<!doctype html>".write(
                to: entryURL,
                atomically: true,
                encoding: .utf8
            )
            try "<!doctype html>".write(
                to: siblingURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: entryURL
            )

            let policy = try XCTUnwrap(
                LocalWebResourcePolicy(
                    entryURL: entryURL,
                    resourceRootURL: rootURL
                )
            )

            XCTAssertTrue(
                policy.allowsMainFrameNavigation(to: policy.entryURL)
            )
            XCTAssertFalse(
                policy.allowsNavigation(
                    to: policy.entryURL,
                    isMainFrame: false
                )
            )
            XCTAssertTrue(
                policy.allowsMainFrameNavigation(
                    to: try XCTUnwrap(URL(string: "about:blank"))
                )
            )
            XCTAssertFalse(policy.allowsMainFrameNavigation(to: siblingURL))
            XCTAssertFalse(policy.allowsMainFrameNavigation(to: traversalURL))
            XCTAssertFalse(policy.allowsMainFrameNavigation(to: symlinkURL))
            XCTAssertFalse(
                policy.allowsMainFrameNavigation(
                    to: try XCTUnwrap(
                        URL(string: "http://127.0.0.1:8080/renderer.html")
                    )
                )
            )
        }
    }

    func testRendererPoliciesUseCanonicalVendorBundleRoots() throws {
        let mathJaxPolicy = try XCTUnwrap(
            LocalWebResourcePolicy(
                bundle: .main,
                entryResourceName: "mathjax-renderer",
                resourceDirectoryName: "MathJax.bundle"
            )
        )
        let mermaidPolicy = try XCTUnwrap(
            LocalWebResourcePolicy(
                bundle: .main,
                entryResourceName: "mermaid-renderer",
                resourceDirectoryName: "Mermaid.bundle"
            )
        )

        XCTAssertEqual(mathJaxPolicy.resourceRootURL.lastPathComponent, "MathJax.bundle")
        XCTAssertEqual(mermaidPolicy.resourceRootURL.lastPathComponent, "Mermaid.bundle")
        XCTAssertEqual(
            mathJaxPolicy.entryURL.deletingLastPathComponent(),
            mathJaxPolicy.resourceRootURL
        )
        XCTAssertEqual(
            mermaidPolicy.entryURL.deletingLastPathComponent(),
            mermaidPolicy.resourceRootURL
        )
        XCTAssertTrue(
            mathJaxPolicy.allowsMainFrameNavigation(
                to: mathJaxPolicy.entryURL
            )
        )
        XCTAssertTrue(
            mermaidPolicy.allowsMainFrameNavigation(
                to: mermaidPolicy.entryURL
            )
        )
    }

    func testRendererCSPsDenyAllUnneededCapabilities() throws {
        let expectations: [(directory: String, name: String, directives: [String])] = [
            (
                "MathJax.bundle",
                "mathjax-renderer",
                [
                    "default-src 'none'",
                    "script-src 'self'",
                    "style-src 'unsafe-inline'",
                    "font-src 'self' data:",
                    "img-src 'self' data:",
                    "connect-src 'none'",
                    "media-src 'none'",
                    "frame-src 'none'",
                    "worker-src 'none'",
                    "object-src 'none'",
                    "base-uri 'none'",
                    "form-action 'none'"
                ]
            ),
            (
                "Mermaid.bundle",
                "mermaid-renderer",
                [
                    "default-src 'none'",
                    "script-src 'self'",
                    "style-src 'unsafe-inline'",
                    "img-src data: blob:",
                    "font-src 'none'",
                    "connect-src 'none'",
                    "media-src 'none'",
                    "frame-src 'none'",
                    "worker-src 'none'",
                    "object-src 'none'",
                    "base-uri 'none'",
                    "form-action 'none'"
                ]
            )
        ]

        for expectation in expectations {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: expectation.name,
                    withExtension: "html",
                    subdirectory: expectation.directory
                )
            )
            let html = try String(contentsOf: url, encoding: .utf8)
            for directive in expectation.directives {
                XCTAssertTrue(
                    html.contains(directive),
                    "\(expectation.name) is missing \(directive)"
                )
            }
            XCTAssertFalse(html.contains("http://"))
            XCTAssertFalse(html.contains("https://"))
        }
    }

    func testHostileLocalPageMakesNoLoopbackRequestsAndCannotOpenWindow()
        async throws {
        let listener = try LoopbackRequestListener()
        try await withTemporaryDirectory { directoryURL in
            try copyHostileFixture(
                named: "hostile-local-renderer",
                extension: "html",
                to: directoryURL,
                port: listener.port
            )
            try copyHostileFixture(
                named: "hostile-local-renderer",
                extension: "js",
                to: directoryURL,
                port: listener.port
            )

            let entryURL = directoryURL.appendingPathComponent(
                "hostile-local-renderer.html"
            )
            let policy = try XCTUnwrap(
                LocalWebResourcePolicy(
                    entryURL: entryURL,
                    resourceRootURL: directoryURL
                )
            )
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true

            let webView = WKWebView(frame: .zero, configuration: configuration)
            let navigationObserver = LocalWebNavigationObserver(policy: policy)
            webView.navigationDelegate = navigationObserver
            webView.uiDelegate = policy
            defer {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
            }

            policy.loadEntry(in: webView)
            try await waitForHostileFixture(
                in: webView,
                navigationObserver: navigationObserver
            )
            let windowWasDenied = try await webView.callAsyncJavaScript(
                "return window.__hostileWindowWasDenied === true;",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? Bool

            XCTAssertTrue(windowWasDenied ?? false)
            XCTAssertTrue(navigationObserver.didFinish)
            XCTAssertNil(navigationObserver.loadError)
            XCTAssertEqual(listener.requestCount, 0)
        }
    }

    func testMathJaxNavigationFailureResumesLoadWaitersOnceAndCleansUp()
        async throws {
        let renderer = MathJaxFallbackRenderer()
        async let first = renderer.waitForLoadForTesting()
        async let second = renderer.waitForLoadForTesting()
        try await waitUntil {
            renderer.loadWaiterCountForTesting == 2
        }

        let failedWebView = renderer.webViewForTesting
        XCTAssertNotNil(failedWebView.uiDelegate)
        XCTAssertFalse(
            failedWebView.configuration.preferences
                .javaScriptCanOpenWindowsAutomatically
        )
        renderer.webView(
            failedWebView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotLoadFromNetwork)
        )

        let firstResult = await first
        let secondResult = await second
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
        XCTAssertFalse(renderer.hasLoadTimeoutForTesting)
        XCTAssertNil(failedWebView.navigationDelegate)
        XCTAssertNil(failedWebView.uiDelegate)

        renderer.webView(
            failedWebView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotLoadFromNetwork)
        )
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
    }

    func testMathJaxProcessTerminationResumesLoadWaitersOnceAndCleansUp()
        async throws {
        let renderer = MathJaxFallbackRenderer()
        async let first = renderer.waitForLoadForTesting()
        async let second = renderer.waitForLoadForTesting()
        try await waitUntil {
            renderer.loadWaiterCountForTesting == 2
        }

        let failedWebView = renderer.webViewForTesting
        renderer.webViewWebContentProcessDidTerminate(failedWebView)

        let firstResult = await first
        let secondResult = await second
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
        XCTAssertFalse(renderer.hasLoadTimeoutForTesting)
        XCTAssertNil(failedWebView.navigationDelegate)
        XCTAssertNil(failedWebView.uiDelegate)

        renderer.webViewWebContentProcessDidTerminate(failedWebView)
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
    }

    func testMathJaxProcessTerminationResumesActiveInvocationOnce()
        async throws {
        let renderer = MathJaxFallbackRenderer()
        async let invocation = renderer.waitForInvocationForTesting()
        try await waitUntil {
            renderer.hasActiveInvocationForTesting
        }

        let failedWebView = renderer.webViewForTesting
        renderer.webViewWebContentProcessDidTerminate(failedWebView)

        let invocationResult = await invocation
        XCTAssertFalse(invocationResult)
        XCTAssertFalse(renderer.hasActiveInvocationForTesting)
        renderer.webViewWebContentProcessDidTerminate(failedWebView)
        XCTAssertFalse(renderer.hasActiveInvocationForTesting)
    }

    func testMermaidNavigationFailureResumesLoadWaitersOnceAndCleansUp()
        async throws {
        let renderer = MermaidWebRenderer()
        async let first = renderer.waitForLoadForTesting()
        async let second = renderer.waitForLoadForTesting()
        try await waitUntil {
            renderer.loadWaiterCountForTesting == 2
        }

        let failedWebView = renderer.webViewForTesting
        XCTAssertNotNil(failedWebView.uiDelegate)
        XCTAssertFalse(
            failedWebView.configuration.preferences
                .javaScriptCanOpenWindowsAutomatically
        )
        renderer.webView(
            failedWebView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotLoadFromNetwork)
        )

        let firstResult = await first
        let secondResult = await second
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
        XCTAssertFalse(renderer.hasLoadTimeoutForTesting)
        XCTAssertNil(failedWebView.navigationDelegate)
        XCTAssertNil(failedWebView.uiDelegate)

        renderer.webView(
            failedWebView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotLoadFromNetwork)
        )
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
    }

    func testMermaidProcessTerminationResumesLoadWaitersOnceAndCleansUp()
        async throws {
        let renderer = MermaidWebRenderer()
        async let first = renderer.waitForLoadForTesting()
        async let second = renderer.waitForLoadForTesting()
        try await waitUntil {
            renderer.loadWaiterCountForTesting == 2
        }

        let failedWebView = renderer.webViewForTesting
        renderer.webViewWebContentProcessDidTerminate(failedWebView)

        let firstResult = await first
        let secondResult = await second
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
        XCTAssertFalse(renderer.hasLoadTimeoutForTesting)
        XCTAssertNil(failedWebView.navigationDelegate)
        XCTAssertNil(failedWebView.uiDelegate)

        renderer.webViewWebContentProcessDidTerminate(failedWebView)
        XCTAssertEqual(renderer.loadWaiterCountForTesting, 0)
    }

    private func copyHostileFixture(
        named name: String,
        extension fileExtension: String,
        to directoryURL: URL,
        port: UInt16
    ) throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("web-rendering", isDirectory: true)
            .appendingPathComponent("\(name).\(fileExtension)")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw FixtureError.missing
        }
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let destinationURL = directoryURL.appendingPathComponent(
            "\(name).\(fileExtension)"
        )
        try source.replacingOccurrences(
            of: "__LOOPBACK_PORT__",
            with: String(port)
        ).write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func waitForHostileFixture(
        in webView: WKWebView,
        navigationObserver: LocalWebNavigationObserver
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let error = navigationObserver.loadError {
                throw error
            }
            if navigationObserver.didFinish {
                let didComplete = try await webView.callAsyncJavaScript(
                    "return window.__hostileAttemptsComplete === true;",
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                ) as? Bool
                if didComplete == true {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for hostile renderer fixture.")
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for local WebKit renderer state.")
    }

    private func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return try await body(directoryURL)
    }
}

private enum FixtureError: LocalizedError {
    case missing

    var errorDescription: String? {
        switch self {
        case .missing:
            "Missing hostile WebKit fixture."
        }
    }
}

@MainActor
private final class LocalWebNavigationObserver: NSObject, WKNavigationDelegate {
    private let policy: LocalWebResourcePolicy
    private(set) var didFinish = false
    private(set) var loadError: (any Error)?

    init(policy: LocalWebResourcePolicy) {
        self.policy = policy
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        didFinish = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        loadError = error
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        loadError = error
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy.navigationPolicy(for: navigationAction))
    }
}

private final class LoopbackRequestListener: @unchecked Sendable {
    let port: UInt16

    private let socketFileDescriptor: Int32
    private let lock = NSLock()
    private var requestStorage = 0
    private var source: DispatchSourceRead?

    var requestCount: Int {
        lock.withLock { requestStorage }
    }

    init() throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.ENFILE)
        }
        socketFileDescriptor = fileDescriptor

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard didBind == 0, Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
            Darwin.close(fileDescriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadAddress = withUnsafeMutablePointer(to: &boundAddress) {
            pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fileDescriptor, $0, &length)
            }
        }
        guard didReadAddress == 0 else {
            Darwin.close(fileDescriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = UInt16(bigEndian: boundAddress.sin_port)

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue(label: "LocalWebSecurityTests.loopback")
        )
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    private func acceptConnection() {
        let clientFileDescriptor = Darwin.accept(
            socketFileDescriptor,
            nil,
            nil
        )
        guard clientFileDescriptor >= 0 else {
            return
        }
        lock.withLock {
            requestStorage += 1
        }
        Darwin.close(clientFileDescriptor)
    }
}
