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

    #if DEBUG || TESTING
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
            pendingKeys.count < Self.maximumPendingEntries
        else {
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
        case .rendered(let output):
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
                    !self.terminalKeys.contains(key)
                else {
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
            output.diagram.naturalSize.height > 0
        else {
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
            newCost <= Self.maximumCacheCost
        else {
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
        guard
            requiresEntry
                || projectedCost.overflow
                || projectedCost.partialValue > Self.maximumCacheCost
        else {
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
                remainingCost.partialValue <= Self.maximumCacheCost
            {
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

    private static let maximumSVGBytes = 4 * 1_024 * 1_024
    private static let maximumPNGBytes = 16 * 1_024 * 1_024
    private static let maximumDimension: CGFloat = 8_192
    private static let maximumArea: CGFloat = 32 * 1_024 * 1_024
    private static let maximumRasterPixels: CGFloat = 12 * 1_024 * 1_024
    private static let maximumQueuedRenders =
        MermaidRenderer.maximumPendingEntries

    private(set) var lastError: String?
    #if DEBUG || TESTING
        private(set) var lastSVGForTesting: String?
    #endif
    private let session: LocalWebRenderSession
    private var isRendering = false
    private var renderWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        session = LocalWebRenderSession(
            resourcePolicy: LocalWebResourcePolicy(
                bundle: .main,
                entryResourceName: "mermaid-renderer",
                resourceDirectoryName: "Mermaid.bundle"
            )
        )
        super.init()
    }

    #if DEBUG || TESTING
        var webViewForTesting: WKWebView? {
            session.webViewForTesting
        }

        var sessionForTesting: LocalWebRenderSession {
            session
        }

        var loadWaiterCountForTesting: Int {
            session.loadWaiterCountForTesting
        }

        var hasLoadTimeoutForTesting: Bool {
            session.hasLoadTimeoutForTesting
        }

        var hasActiveInvocationForTesting: Bool {
            session.hasActiveJavaScriptEvaluationForTesting
        }

        func waitForLoadForTesting() async -> Bool {
            await session.waitForReadinessForTesting(loadsEntry: false)
        }

        func waitForInvocationForTesting() async -> Bool {
            switch await session.waitForJavaScriptEvaluationForTesting() {
            case .value:
                true
            case .failure, .timedOut, .cancelled, .processTerminated:
                false
            }
        }
    #endif

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
        #if DEBUG || TESTING
            lastSVGForTesting = nil
        #endif
        guard await session.waitUntilReady() else {
            lastError = "Mermaid renderer page failed to load."
            return .transientFailure
        }

        let invocation = await invokeJavaScript(source: source)
        switch invocation {
        case .timedOut:
            lastError = "render-timeout"
            return .transientFailure
        case .failure(let message):
            lastError = message
            return .transientFailure
        case .value(let value):
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
            let image = NSImage(data: pngData)
        else {
            lastError = "Mermaid returned invalid rendered output."
            return .transientFailure
        }
        #if DEBUG || TESTING
            lastSVGForTesting = svg
        #endif

        let rasterPixelCount =
            Int(pixelWidth.rounded(.up))
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
            cacheCost <= MermaidRenderer.maximumCacheCost
        else {
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
        switch await session.evaluateJavaScript(
            "return await window.renderMermaid(source);",
            arguments: ["source": source]
        ) {
        case .value(let value):
            .value(value)
        case .failure(let message):
            .failure(message)
        case .timedOut:
            .timedOut
        case .cancelled:
            .failure("Mermaid web renderer was reset.")
        case .processTerminated:
            .failure("Mermaid web process terminated.")
        }
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
            #"url\s*\(\s*[\"']?(?:https?:|//|file:)"#,
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
            data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        else {
            return nil
        }
        return data
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
