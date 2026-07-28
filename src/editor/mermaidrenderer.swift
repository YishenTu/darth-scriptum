import AppKit
import Foundation
import WebKit

@MainActor
protocol MermaidRenderingBackend: AnyObject {
    func render(source: String) async -> MermaidRenderOutcome
}

enum MermaidRenderOutcome {
    case rendered(MermaidRenderedOutput)
    case unsupported
    case transientFailure
}

struct MermaidRenderedDiagram {
    let image: NSImage
    let naturalSize: CGSize
}

struct MermaidRenderedOutput {
    let diagram: MermaidRenderedDiagram
    let cacheCost: Int
}

@MainActor
final class MermaidRenderer {
    static let maximumSourceUTF8Bytes = 64 * 1_024
    static let maximumPendingEntries = 8
    static let maximumCacheCost = 64 * 1_024 * 1_024

    private struct CacheKey: Hashable {
        let source: String
    }

    private static let maximumCacheEntries = 256
    private static let maximumTrackedFailures = 512
    private static let maximumTransientAttempts = 3

    let updateNotification: Notification.Name
    private let backend: any MermaidRenderingBackend
    private let notificationCenter: NotificationCenter
    private var cache: [CacheKey: MermaidRenderedDiagram] = [:]
    private var cacheCosts: [CacheKey: Int] = [:]
    private var cacheCost = 0
    private var pendingKeys: Set<CacheKey> = []
    private var terminalKeys: Set<CacheKey> = []
    private var transientAttempts: [CacheKey: Int] = [:]
    private var accessOrder: [CacheKey: UInt64] = [:]
    private var nextAccessOrder: UInt64 = 0

    init(
        backend: (any MermaidRenderingBackend)? = nil,
        notificationCenter: NotificationCenter = .default,
        updateNotification: Notification.Name = Notification.Name(
            "DarthScriptum.MermaidRendererDidUpdate"
        )
    ) {
        self.backend = backend ?? MermaidWebRenderer()
        self.notificationCenter = notificationCenter
        self.updateNotification = updateNotification
    }

    #if DEBUG
    var pendingEntryCountForTesting: Int {
        pendingKeys.count
    }
    #endif

    func diagram(for source: String) -> MermaidRenderedDiagram? {
        guard source.utf8.count <= Self.maximumSourceUTF8Bytes else {
            return nil
        }
        let normalized = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return nil }

        let key = CacheKey(source: normalized)
        if let cached = cache[key] {
            markSeen(key)
            return cached
        }
        guard !pendingKeys.contains(key),
              !terminalKeys.contains(key),
              pendingKeys.count < Self.maximumPendingEntries else {
            return nil
        }

        pendingKeys.insert(key)
        markSeen(key)
        Task { @MainActor [weak self, backend] in
            let outcome = await backend.render(source: normalized)
            self?.complete(outcome, for: key)
        }
        return nil
    }

    private func complete(
        _ outcome: MermaidRenderOutcome,
        for key: CacheKey
    ) {
        guard pendingKeys.remove(key) != nil else { return }

        switch outcome {
        case let .rendered(output):
            transientAttempts[key] = nil
            guard insert(output, for: key) else {
                if markTerminal(key) {
                    publishUpdate()
                }
                return
            }
            publishUpdate()

        case .unsupported:
            transientAttempts[key] = nil
            if markTerminal(key) {
                publishUpdate()
            }

        case .transientFailure:
            let attempt = (transientAttempts[key] ?? 0) + 1
            transientAttempts[key] = attempt
            guard attempt < Self.maximumTransientAttempts else {
                if markTerminal(key) {
                    publishUpdate()
                }
                return
            }
            let delay = pow(2, Double(attempt - 1)) * 0.25
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self,
                      self.transientAttempts[key] == attempt,
                      !self.terminalKeys.contains(key) else {
                    return
                }
                self.notificationCenter.post(
                    name: self.updateNotification,
                    object: self
                )
            }
        }
    }

    private func insert(
        _ output: MermaidRenderedOutput,
        for key: CacheKey
    ) -> Bool {
        guard output.cacheCost >= 0,
              output.cacheCost <= Self.maximumCacheCost,
              output.diagram.naturalSize.width.isFinite,
              output.diagram.naturalSize.height.isFinite,
              output.diagram.naturalSize.width > 0,
              output.diagram.naturalSize.height > 0 else {
            return false
        }

        reclaimLeastRecentlyUsedEntriesIfNeeded(
            additionalCost: output.cacheCost
        )
        let (newCost, overflow) = cacheCost.addingReportingOverflow(
            output.cacheCost
        )
        guard cache.count < Self.maximumCacheEntries,
              !overflow,
              newCost <= Self.maximumCacheCost else {
            return false
        }

        cache[key] = output.diagram
        cacheCosts[key] = output.cacheCost
        cacheCost = newCost
        markSeen(key)
        return true
    }

    private func reclaimLeastRecentlyUsedEntriesIfNeeded(
        additionalCost: Int
    ) {
        let requiresEntry = cache.count >= Self.maximumCacheEntries
        let projectedCost = cacheCost.addingReportingOverflow(additionalCost)
        guard requiresEntry
                || projectedCost.overflow
                || projectedCost.partialValue > Self.maximumCacheCost else {
            return
        }

        let candidates = cache.keys.sorted { lhs, rhs in
            (accessOrder[lhs] ?? 0) < (accessOrder[rhs] ?? 0)
        }
        for candidate in candidates {
            if cache.removeValue(forKey: candidate) != nil {
                cacheCost -= cacheCosts.removeValue(forKey: candidate) ?? 0
            }
            accessOrder[candidate] = nil

            let remainingCost = cacheCost.addingReportingOverflow(
                additionalCost
            )
            if cache.count < Self.maximumCacheEntries,
               !remainingCost.overflow,
               remainingCost.partialValue <= Self.maximumCacheCost {
                return
            }
        }
    }

    private func markTerminal(_ key: CacheKey) -> Bool {
        if terminalKeys.contains(key) {
            return true
        }
        guard terminalKeys.count < Self.maximumTrackedFailures else {
            return false
        }
        terminalKeys.insert(key)
        return true
    }

    private func publishUpdate() {
        notificationCenter.post(name: updateNotification, object: self)
    }

    private func markSeen(_ key: CacheKey) {
        if nextAccessOrder == .max {
            let orderedKeys = accessOrder.keys.sorted {
                (accessOrder[$0] ?? 0) < (accessOrder[$1] ?? 0)
            }
            accessOrder.removeAll(keepingCapacity: true)
            nextAccessOrder = 0
            for orderedKey in orderedKeys {
                nextAccessOrder &+= 1
                accessOrder[orderedKey] = nextAccessOrder
            }
        }
        nextAccessOrder &+= 1
        accessOrder[key] = nextAccessOrder
    }
}

@MainActor
final class MermaidWebRenderer: NSObject, MermaidRenderingBackend {
    private enum JavaScriptInvocationOutcome: @unchecked Sendable {
        case value(Any?)
        case failure(String)
        case timedOut
    }

    private struct ActiveInvocation {
        let id: UInt64
        let continuation:
            CheckedContinuation<JavaScriptInvocationOutcome, Never>
    }

    private static let maximumSVGBytes = 4 * 1_024 * 1_024
    private static let maximumPNGBytes = 16 * 1_024 * 1_024
    private static let maximumDimension: CGFloat = 8_192
    private static let maximumArea: CGFloat = 32 * 1_024 * 1_024
    private static let maximumRasterPixels: CGFloat = 12 * 1_024 * 1_024
    private static let maximumQueuedRenders =
        MermaidRenderer.maximumPendingEntries

    private(set) var lastError: String?
    #if DEBUG
    private(set) var lastSVGForTesting: String?
    #endif
    private lazy var webView = makeWebView()
    private var isReady = false
    private var loadAttempt = 0
    private var activeLoadAttempt: Int?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var isRendering = false
    private var renderWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextInvocationID: UInt64 = 0
    private var activeInvocation: ActiveInvocation?

    func render(source: String) async -> MermaidRenderOutcome {
        guard await acquireRenderSlot() else {
            lastError = "Mermaid renderer queue is full."
            return .transientFailure
        }
        let outcome = await renderSerially(source: source)
        releaseRenderSlot()
        return outcome
    }

    private func renderSerially(source: String) async -> MermaidRenderOutcome {
        #if DEBUG
        lastSVGForTesting = nil
        #endif
        guard await ensureReady() else {
            lastError = "Mermaid renderer page failed to load."
            return .transientFailure
        }

        let invocation = await invokeJavaScript(source: source)
        switch invocation {
        case .timedOut:
            lastError = "render-timeout"
            return .transientFailure
        case let .failure(message):
            lastError = message
            return .transientFailure
        case let .value(value):
            return decode(value)
        }
    }

    private func decode(_ value: Any?) -> MermaidRenderOutcome {
        guard let response = value as? [String: Any] else {
            lastError = "Mermaid returned an invalid response."
            return .transientFailure
        }
        if let error = response["error"] as? String {
            lastError = error
            return Self.isPermanentRenderError(error)
                ? .unsupported
                : .transientFailure
        }
        guard let svg = response["svg"] as? String,
              let svgData = svg.data(using: .utf8),
              svgData.count <= Self.maximumSVGBytes,
              Self.isSafeSVG(svg),
              let pngDataURL = response["png"] as? String,
              let pngData = Self.decodePNGDataURL(pngDataURL),
              pngData.count <= Self.maximumPNGBytes,
              let width = Self.number(response["width"]),
              let height = Self.number(response["height"]),
              let pixelWidth = Self.number(response["pixelWidth"]),
              let pixelHeight = Self.number(response["pixelHeight"]),
              width.isFinite,
              height.isFinite,
              pixelWidth.isFinite,
              pixelHeight.isFinite,
              width > 0,
              height > 0,
              pixelWidth > 0,
              pixelHeight > 0,
              width <= Self.maximumDimension,
              height <= Self.maximumDimension,
              pixelWidth <= Self.maximumDimension,
              pixelHeight <= Self.maximumDimension,
              width * height <= Self.maximumArea,
              pixelWidth * pixelHeight <= Self.maximumRasterPixels,
              let image = NSImage(data: pngData) else {
            lastError = "Mermaid returned invalid rendered output."
            return .transientFailure
        }
        #if DEBUG
        lastSVGForTesting = svg
        #endif

        let rasterPixelCount = Int(pixelWidth.rounded(.up))
            * Int(pixelHeight.rounded(.up))
        let (rasterCost, rasterOverflow) =
            rasterPixelCount.multipliedReportingOverflow(by: 4)
        let (encodedCost, encodedOverflow) =
            svgData.count.addingReportingOverflow(pngData.count)
        let (cacheCost, cacheOverflow) =
            rasterCost.addingReportingOverflow(encodedCost)
        guard !rasterOverflow,
              !encodedOverflow,
              !cacheOverflow,
              cacheCost <= MermaidRenderer.maximumCacheCost else {
            lastError = "output-too-large"
            return .unsupported
        }

        let size = CGSize(width: width, height: height)
        image.size = size
        lastError = nil
        return .rendered(
            MermaidRenderedOutput(
                diagram: MermaidRenderedDiagram(
                    image: image,
                    naturalSize: size
                ),
                cacheCost: cacheCost
            )
        )
    }

    private func invokeJavaScript(
        source: String
    ) async -> JavaScriptInvocationOutcome {
        await withCheckedContinuation { continuation in
            nextInvocationID &+= 1
            let invocationID = nextInvocationID
            activeInvocation = ActiveInvocation(
                id: invocationID,
                continuation: continuation
            )

            webView.callAsyncJavaScript(
                "return await window.renderMermaid(source);",
                arguments: ["source": source],
                in: nil,
                in: .page,
                completionHandler: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .success(value):
                        self.finishInvocation(
                            id: invocationID,
                            outcome: .value(value)
                        )
                    case let .failure(error):
                        self.finishInvocation(
                            id: invocationID,
                            outcome: .failure(error.localizedDescription)
                        )
                    }
                }
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self,
                      self.activeInvocation?.id == invocationID else {
                    return
                }
                self.finishInvocation(id: invocationID, outcome: .timedOut)
                self.replaceWebViewAfterFailure()
            }
        }
    }

    private func finishInvocation(
        id: UInt64,
        outcome: JavaScriptInvocationOutcome
    ) {
        guard let activeInvocation,
              activeInvocation.id == id else {
            return
        }
        self.activeInvocation = nil
        activeInvocation.continuation.resume(returning: outcome)
    }

    private static func isPermanentRenderError(_ error: String) -> Bool {
        switch error {
        case "invalid-input",
             "invalid-dimensions",
             "invalid-diagram",
             "missing-svg",
             "output-too-large":
            true
        default:
            false
        }
    }

    private static func isSafeSVG(_ svg: String) -> Bool {
        let forbiddenPatterns = [
            #"<\s*(?:script|foreignobject|iframe|image|object|a)\b"#,
            #"<!\s*(?:doctype|entity)\b"#,
            #"\son[a-z]+\s*="#,
            #"(?:xlink:)?href\s*=\s*[\"'](?!#)"#,
            #"@import"#,
            #"url\s*\(\s*[\"']?(?:https?:|//|file:)"#
        ]
        return !forbiddenPatterns.contains { pattern in
            svg.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private static func decodePNGDataURL(_ value: String) -> Data? {
        let prefix = "data:image/png;base64,"
        guard value.hasPrefix(prefix),
              let data = Data(
                  base64Encoded: String(value.dropFirst(prefix.count))
              ),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            return nil
        }
        return data
    }

    private func ensureReady() async -> Bool {
        if isReady {
            return true
        }

        return await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
            guard loadWaiters.count == 1 else { return }

            loadAttempt &+= 1
            let attempt = loadAttempt
            activeLoadAttempt = attempt
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self,
                      self.activeLoadAttempt == attempt else {
                    return
                }
                self.finishLoading(succeeded: false)
                self.replaceWebViewAfterFailure()
            }

            guard let rendererURL = Bundle.main.url(
                forResource: "mermaid-renderer",
                withExtension: "html"
            ) else {
                finishLoading(succeeded: false)
                return
            }
            webView.loadFileURL(
                rendererURL,
                allowingReadAccessTo: rendererURL.deletingLastPathComponent()
            )
        }
    }

    private func finishLoading(succeeded: Bool) {
        activeLoadAttempt = nil
        isReady = succeeded
        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume(returning: succeeded)
        }
    }

    private func replaceWebViewAfterFailure() {
        let failedWebView = webView
        failedWebView.navigationDelegate = nil
        failedWebView.stopLoading()
        webView = makeWebView()
        isReady = false
    }

    private func acquireRenderSlot() async -> Bool {
        if !isRendering {
            isRendering = true
            return true
        }
        guard renderWaiters.count < Self.maximumQueuedRenders - 1 else {
            return false
        }
        await withCheckedContinuation { continuation in
            renderWaiters.append(continuation)
        }
        return true
    }

    private func releaseRenderSlot() {
        if renderWaiters.isEmpty {
            isRendering = false
        } else {
            renderWaiters.removeFirst().resume()
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 4_096, height: 2_048),
            configuration: configuration
        )
        view.navigationDelegate = self
        return view
    }

    private static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as NSNumber:
            CGFloat(value.doubleValue)
        case let value as Double:
            CGFloat(value)
        default:
            nil
        }
    }
}

extension MermaidWebRenderer: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        guard webView === self.webView else { return }
        finishLoading(succeeded: true)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        finishLoading(succeeded: false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        finishLoading(succeeded: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        isReady = false
        if let activeInvocation {
            finishInvocation(
                id: activeInvocation.id,
                outcome: .failure("Mermaid web process terminated.")
            )
        }
        if !loadWaiters.isEmpty {
            finishLoading(succeeded: false)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === self.webView,
              let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let rendererURL = Bundle.main.url(
            forResource: "mermaid-renderer",
            withExtension: "html"
        )?.standardizedFileURL
        let allowed = url.absoluteString == "about:blank"
            || (url.isFileURL && url.standardizedFileURL == rendererURL)
        decisionHandler(allowed ? .allow : .cancel)
    }
}
