import AppKit
import Foundation
import MarkdownEngine
import MarkdownEngineLatex

extension Notification.Name {
    static let latexRendererDidUpdate = Notification.Name(
        "DarthScriptum.LatexRendererDidUpdate"
    )
}

private struct UncachedSwiftMathRenderer: LatexRenderer {
    func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        SwiftMathBridge().render(
            latex: latex,
            fontSize: fontSize,
            theme: theme
        )
    }
}

@MainActor
final class AdaptiveLaTeXRenderer: LatexRenderer, @unchecked Sendable {
    static let maximumLaTeXUTF8Bytes = 32_768
    static let maximumPendingEntries = 8

    private struct TransientFailure {
        let attempt: Int
        let retryAfter: Date
    }

    private struct FallbackRequest {
        let key: CacheKey
        let latex: String
        let fontSize: CGFloat
        let colorHex: String
        let presentationGeneration: UInt64
        let renderingGeneration: UInt64
    }

    private struct CacheKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        let isDarkMode: Bool
        let lightColorRGB: UInt32
        let darkColorRGB: UInt32
    }

    private struct PresentationIdentity: Equatable {
        let revisionNumber: UInt64
        let fontSize: CGFloat
        let rawSourceMode: Bool
        let isDarkMode: Bool
    }

    private struct RenderingIdentity: Equatable {
        let fontSize: CGFloat
        let rawSourceMode: Bool
        let isDarkMode: Bool
    }

    private enum CacheInsertionOutcome {
        case inserted
        case rejectedInvalidOutput
        case rejectedCapacity
    }

    private static let maximumCacheEntries = 1_024
    static let maximumCacheCost = 64 * 1_024 * 1_024
    static let maximumTrackedEntries = 1_024
    private static let maximumAutomaticRetryAttempts = 3

    let updateNotification: Notification.Name
    private let primary: any LatexRenderer
    private let fallback: any MathJaxFallbackRendering
    private let notificationCenter: NotificationCenter
    private var cache: [CacheKey: LatexRenderResult] = [:]
    private var cacheCosts: [CacheKey: Int] = [:]
    private var cacheCost = 0
    private var primaryUnsupportedKeys: Set<CacheKey> = []
    private var terminalKeys: Set<CacheKey> = []
    private var transientFailures: [CacheKey: TransientFailure] = [:]
    private var retryCandidates: Set<CacheKey> = []
    private var retryWakeTask: Task<Void, Never>?
    private var retryWakeDeadline: Date?
    private var pendingRequests: [CacheKey: UInt64] = [:]
    private var deferredRequests: [FallbackRequest] = []
    private var deferredRequestIndex = 0
    private var deferredKeys: Set<CacheKey> = []
    private var publishedInitialWaveUpdate = false
    private var hasUnpublishedRenderedResults = false
    private var presentationIdentity: PresentationIdentity?
    private var presentationGeneration: UInt64 = 0
    private var renderingIdentity: RenderingIdentity?
    private var renderingGeneration: UInt64 = 0
    private var lastAccessOrder: [CacheKey: UInt64] = [:]
    private var nextAccessOrder: UInt64 = 0
    private var saturatedFallbackGeneration: UInt64?
    private var currentSource: String?

    init(
        primary: any LatexRenderer = UncachedSwiftMathRenderer(),
        fallback: (any MathJaxFallbackRendering)? = nil,
        notificationCenter: NotificationCenter = .default,
        updateNotification: Notification.Name = .latexRendererDidUpdate
    ) {
        self.primary = primary
        self.fallback = fallback ?? MathJaxFallbackRenderer()
        self.notificationCenter = notificationCenter
        self.updateNotification = updateNotification
    }

    #if DEBUG || TESTING
        var transientFailureEntryCountForTesting: Int {
            transientFailures.count
        }

        var pendingEntryCountForTesting: Int {
            pendingRequests.count
        }

        var hasRetryWakeupForTesting: Bool {
            retryWakeTask != nil
        }
    #endif

    func prepareForPresentation(
        revisionNumber: UInt64,
        fontSize: CGFloat,
        rawSourceMode: Bool,
        source: String
    ) {
        currentSource = source
        let identity = PresentationIdentity(
            revisionNumber: revisionNumber,
            fontSize: fontSize,
            rawSourceMode: rawSourceMode,
            isDarkMode: Self.currentIsDarkMode
        )
        guard identity != presentationIdentity else { return }
        presentationIdentity = identity
        presentationGeneration &+= 1
        publishedInitialWaveUpdate = false
        hasUnpublishedRenderedResults = false

        let newRenderingIdentity = RenderingIdentity(
            fontSize: identity.fontSize,
            rawSourceMode: identity.rawSourceMode,
            isDarkMode: identity.isDarkMode
        )
        let renderingIdentityChanged = newRenderingIdentity != renderingIdentity
        if renderingIdentityChanged {
            renderingIdentity = newRenderingIdentity
            renderingGeneration &+= 1
        }
        resetRetryWakeup(clearFailures: renderingIdentityChanged)
        discardDeferredRequests()
    }

    nonisolated func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        MainActor.assumeIsolated {
            renderOnMainActor(
                latex: latex,
                fontSize: fontSize,
                theme: theme
            )
        }
    }

    private func renderOnMainActor(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        guard latex.utf8.count <= Self.maximumLaTeXUTF8Bytes else {
            return nil
        }
        let normalized = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            fontSize.isFinite,
            fontSize > 0
        else {
            return nil
        }

        let isDarkMode = Self.currentIsDarkMode
        let activeColor =
            isDarkMode
            ? theme.latexDarkModeText
            : theme.latexLightModeText
        let key = CacheKey(
            latex: normalized,
            fontSize: fontSize,
            isDarkMode: isDarkMode,
            lightColorRGB: Self.colorFingerprint(theme.latexLightModeText),
            darkColorRGB: Self.colorFingerprint(theme.latexDarkModeText)
        )

        if let cached = cache[key] {
            markSeen(key)
            return cached
        }
        if terminalKeys.contains(key)
            || deferredKeys.contains(key)
        {
            markSeen(key)
            return nil
        }
        if let pendingGeneration = pendingRequests[key] {
            markSeen(key)
            guard pendingGeneration != renderingGeneration else {
                return nil
            }
            return enqueueReplacementForStalePendingKey(
                key: key,
                latex: normalized,
                fontSize: fontSize,
                colorHex: Self.colorHex(activeColor)
            )
        }

        let transientFailure = transientFailures[key]
        if let transientFailure,
            transientFailure.retryAfter > Date()
        {
            registerRetryCandidate(key, failure: transientFailure)
            scheduleRetryWakeupIfNeeded()
            return nil
        }

        if !primaryUnsupportedKeys.contains(key) {
            if let result = primary.render(
                latex: normalized,
                fontSize: fontSize,
                theme: theme
            ) {
                if let cacheCost = Self.cacheCost(for: result) {
                    _ = insert(
                        MathJaxFallbackRenderedOutput(
                            result: result,
                            cacheCost: cacheCost
                        ),
                        for: key
                    )
                }
                return result
            }
            if primaryUnsupportedKeys.count < Self.maximumTrackedEntries {
                primaryUnsupportedKeys.insert(key)
            }
        }
        markSeen(key)

        guard saturatedFallbackGeneration != presentationGeneration else {
            return nil
        }
        guard
            pendingRequests.count + deferredKeys.count
                < Self.maximumTrackedEntries
        else {
            return nil
        }

        let request = FallbackRequest(
            key: key,
            latex: normalized,
            fontSize: fontSize,
            colorHex: Self.colorHex(activeColor),
            presentationGeneration: presentationGeneration,
            renderingGeneration: renderingGeneration
        )
        if pendingRequests.count < Self.maximumPendingEntries {
            start(request)
        } else {
            deferredRequests.append(request)
            deferredKeys.insert(key)
        }
        return nil
    }

    private func enqueueReplacementForStalePendingKey(
        key: CacheKey,
        latex: String,
        fontSize: CGFloat,
        colorHex: String
    ) -> LatexRenderResult? {
        guard
            pendingRequests.count + deferredKeys.count
                < Self.maximumTrackedEntries
        else {
            return nil
        }
        deferredRequests.append(
            FallbackRequest(
                key: key,
                latex: latex,
                fontSize: fontSize,
                colorHex: colorHex,
                presentationGeneration: presentationGeneration,
                renderingGeneration: renderingGeneration
            )
        )
        deferredKeys.insert(key)
        return nil
    }

    private func start(_ request: FallbackRequest) {
        pendingRequests[request.key] = request.renderingGeneration
        Task { @MainActor [weak self, fallback] in
            let outcome = await fallback.render(
                latex: request.latex,
                fontSize: request.fontSize,
                colorHex: request.colorHex
            )
            self?.complete(outcome, for: request)
        }
    }

    private func complete(
        _ outcome: MathJaxFallbackRenderOutcome,
        for request: FallbackRequest
    ) {
        guard pendingRequests[request.key] == request.renderingGeneration else {
            return
        }
        pendingRequests[request.key] = nil
        guard requestIsRelevant(request) else {
            removeTrackedState(for: request.key)
            startDeferredRequests()
            scheduleRetryWakeupIfNeeded()
            publishWaveUpdatesIfNeeded()
            return
        }
        switch outcome {
        case .rendered(let output):
            removeTransientFailure(for: request.key)
            switch insert(output, for: request.key) {
            case .inserted:
                hasUnpublishedRenderedResults = true
            case .rejectedInvalidOutput:
                if terminalKeys.count < Self.maximumTrackedEntries {
                    terminalKeys.insert(request.key)
                }
            case .rejectedCapacity:
                saturatedFallbackGeneration = presentationGeneration
                discardDeferredRequestsForSaturatedPresentation()
            }
        case .unsupported:
            removeTransientFailure(for: request.key)
            if terminalKeys.count < Self.maximumTrackedEntries {
                terminalKeys.insert(request.key)
            }
        case .transientFailure:
            recordTransientFailure(for: request.key)
        }
        startDeferredRequests()
        scheduleRetryWakeupIfNeeded()
        publishWaveUpdatesIfNeeded()
    }

    private func startDeferredRequests() {
        guard saturatedFallbackGeneration != presentationGeneration else {
            discardDeferredRequestsForSaturatedPresentation()
            return
        }
        var requestsLeftToInspect =
            deferredRequests.count - deferredRequestIndex
        while pendingRequests.count < Self.maximumPendingEntries,
            deferredRequestIndex < deferredRequests.count,
            requestsLeftToInspect > 0
        {
            let request = deferredRequests[deferredRequestIndex]
            deferredRequestIndex += 1
            requestsLeftToInspect -= 1
            deferredKeys.remove(request.key)
            guard requestIsRelevant(request) else {
                removeTrackedState(for: request.key)
                continue
            }
            guard pendingRequests[request.key] == nil else {
                deferredRequests.append(request)
                deferredKeys.insert(request.key)
                continue
            }
            start(request)
        }
        if deferredRequestIndex == deferredRequests.count {
            deferredRequests.removeAll(keepingCapacity: true)
            deferredRequestIndex = 0
        } else if deferredRequestIndex >= 64,
            deferredRequestIndex * 2 >= deferredRequests.count
        {
            deferredRequests.removeFirst(deferredRequestIndex)
            deferredRequestIndex = 0
        }
    }

    private func discardDeferredRequestsForSaturatedPresentation() {
        discardDeferredRequests()
    }

    private func discardDeferredRequests() {
        guard deferredRequestIndex < deferredRequests.count else {
            deferredRequests.removeAll(keepingCapacity: true)
            deferredRequestIndex = 0
            deferredKeys.removeAll(keepingCapacity: true)
            return
        }
        for request in deferredRequests[deferredRequestIndex...] {
            deferredKeys.remove(request.key)
        }
        deferredRequests.removeAll(keepingCapacity: true)
        deferredRequestIndex = 0
    }

    private func publishWaveUpdatesIfNeeded() {
        if hasUnpublishedRenderedResults,
            !publishedInitialWaveUpdate
        {
            publishUpdateNotification()
            publishedInitialWaveUpdate = true
        }
        guard !hasOutstandingFallbackWork else { return }
        if hasUnpublishedRenderedResults {
            publishUpdateNotification()
        }
        publishedInitialWaveUpdate = false
    }

    private func publishUpdateNotification() {
        guard hasUnpublishedRenderedResults else { return }
        hasUnpublishedRenderedResults = false
        notificationCenter.post(
            name: updateNotification,
            object: self
        )
    }

    private var hasOutstandingFallbackWork: Bool {
        !pendingRequests.isEmpty
            || deferredRequestIndex < deferredRequests.count
    }

    private func insert(
        _ output: MathJaxFallbackRenderedOutput,
        for key: CacheKey
    ) -> CacheInsertionOutcome {
        guard output.cacheCost >= 0 else {
            return .rejectedInvalidOutput
        }
        guard output.cacheCost <= Self.maximumCacheCost else {
            return .rejectedCapacity
        }
        reclaimLeastRecentlyUsedEntriesIfNeeded(additionalCost: output.cacheCost)
        guard cache.count < Self.maximumCacheEntries else {
            return .rejectedCapacity
        }
        let (newCost, overflow) = cacheCost.addingReportingOverflow(
            output.cacheCost
        )
        guard !overflow, newCost <= Self.maximumCacheCost else {
            return .rejectedCapacity
        }
        cache[key] = output.result
        cacheCosts[key] = output.cacheCost
        cacheCost = newCost
        markSeen(key)
        return .inserted
    }

    private func markSeen(_ key: CacheKey) {
        if nextAccessOrder == .max {
            compactAccessOrder()
        }
        if lastAccessOrder[key] != nil
            || lastAccessOrder.count < Self.maximumTrackedEntries
        {
            nextAccessOrder &+= 1
            lastAccessOrder[key] = nextAccessOrder
        }
    }

    private func reclaimLeastRecentlyUsedEntriesIfNeeded(
        additionalCost: Int
    ) {
        guard !hasCacheCapacity(for: additionalCost) else { return }
        let candidates = cache.keys.sorted { lhs, rhs in
            (lastAccessOrder[lhs] ?? 0) < (lastAccessOrder[rhs] ?? 0)
        }
        for key in candidates {
            removeTrackedState(for: key)
            if hasCacheCapacity(for: additionalCost) {
                return
            }
        }
    }

    private func hasCacheCapacity(for additionalCost: Int) -> Bool {
        let (projectedCost, overflow) = cacheCost.addingReportingOverflow(
            additionalCost
        )
        return cache.count < Self.maximumCacheEntries
            && !overflow
            && projectedCost <= Self.maximumCacheCost
    }

    private func compactAccessOrder() {
        let orderedKeys = lastAccessOrder.keys.sorted {
            (lastAccessOrder[$0] ?? 0) < (lastAccessOrder[$1] ?? 0)
        }
        lastAccessOrder.removeAll(keepingCapacity: true)
        nextAccessOrder = 0
        for key in orderedKeys {
            nextAccessOrder &+= 1
            lastAccessOrder[key] = nextAccessOrder
        }
    }

    private func currentSourceContains(_ key: CacheKey) -> Bool {
        guard let currentSource else { return true }
        return currentSource.range(of: key.latex) != nil
    }

    private func requestIsRelevant(_ request: FallbackRequest) -> Bool {
        guard request.renderingGeneration == renderingGeneration else {
            return false
        }
        guard let renderingIdentity else {
            return currentSourceContains(request.key)
        }
        return !renderingIdentity.rawSourceMode
            && request.key.fontSize == renderingIdentity.fontSize
            && request.key.isDarkMode == renderingIdentity.isDarkMode
            && (request.presentationGeneration == presentationGeneration
                || currentSourceContains(request.key))
    }

    private func removeTrackedState(for key: CacheKey) {
        if cache.removeValue(forKey: key) != nil {
            cacheCost -= cacheCosts.removeValue(forKey: key) ?? 0
        } else {
            cacheCosts[key] = nil
        }
        primaryUnsupportedKeys.remove(key)
        terminalKeys.remove(key)
        transientFailures[key] = nil
        retryCandidates.remove(key)
        lastAccessOrder[key] = nil
    }

    private func recordTransientFailure(for key: CacheKey) {
        if transientFailures[key] == nil,
            transientFailures.count >= Self.maximumTrackedEntries,
            let leastRecentlyUsedKey = transientFailures.keys.min(
                by: { lhs, rhs in
                    (lastAccessOrder[lhs] ?? 0)
                        < (lastAccessOrder[rhs] ?? 0)
                }
            )
        {
            removeTrackedState(for: leastRecentlyUsedKey)
        }
        markSeen(key)
        let attempt = (transientFailures[key]?.attempt ?? 0) + 1
        let delay = min(pow(2, Double(attempt - 1)) * 0.25, 2)
        let retryAfter = Date().addingTimeInterval(delay)
        let failure = TransientFailure(
            attempt: attempt,
            retryAfter: retryAfter
        )
        transientFailures[key] = failure
        if attempt <= Self.maximumAutomaticRetryAttempts {
            registerRetryCandidate(key, failure: failure)
        }
    }

    private func removeTransientFailure(for key: CacheKey) {
        transientFailures[key] = nil
        retryCandidates.remove(key)
    }

    private func registerRetryCandidate(
        _ key: CacheKey,
        failure: TransientFailure
    ) {
        guard failure.attempt <= Self.maximumAutomaticRetryAttempts else {
            return
        }
        retryCandidates.insert(key)
    }

    private func scheduleRetryWakeupIfNeeded() {
        guard !hasOutstandingFallbackWork,
            renderingIdentity?.rawSourceMode != true
        else {
            return
        }
        guard retryWakeTask == nil else { return }
        let deadline = retryCandidates.compactMap { key -> Date? in
            guard let failure = transientFailures[key],
                failure.attempt <= Self.maximumAutomaticRetryAttempts
            else {
                return nil
            }
            return failure.retryAfter
        }.max()
        guard let deadline else {
            retryWakeTask?.cancel()
            retryWakeTask = nil
            retryWakeDeadline = nil
            return
        }

        retryWakeDeadline = deadline
        let delay = max(0, deadline.timeIntervalSinceNow)
        let expectedPresentationGeneration = presentationGeneration
        let expectedRenderingGeneration = renderingGeneration
        retryWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryWakeTask = nil
            self.retryWakeDeadline = nil
            guard
                self.presentationGeneration
                    == expectedPresentationGeneration,
                self.renderingGeneration == expectedRenderingGeneration,
                self.renderingIdentity?.rawSourceMode != true,
                !self.hasOutstandingFallbackWork
            else {
                return
            }
            let latestDeadline = self.retryCandidates.compactMap {
                self.transientFailures[$0]?.retryAfter
            }.max()
            if let latestDeadline, latestDeadline > Date() {
                self.scheduleRetryWakeupIfNeeded()
                return
            }

            let candidates = self.retryCandidates.filter { key in
                guard let failure = self.transientFailures[key] else {
                    return false
                }
                return failure.attempt
                    <= Self.maximumAutomaticRetryAttempts
            }
            guard !candidates.isEmpty else { return }
            self.retryCandidates.subtract(candidates)
            self.notificationCenter.post(
                name: self.updateNotification,
                object: self
            )
        }
    }

    private func resetRetryWakeup(clearFailures: Bool) {
        retryWakeTask?.cancel()
        retryWakeTask = nil
        retryWakeDeadline = nil
        retryCandidates.removeAll(keepingCapacity: true)
        if clearFailures {
            transientFailures.removeAll(keepingCapacity: true)
        }
    }

    private static func colorFingerprint(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return 0
        }
        let red = UInt32(clamping: Int((rgb.redComponent * 255).rounded()))
        let green = UInt32(clamping: Int((rgb.greenComponent * 255).rounded()))
        let blue = UInt32(clamping: Int((rgb.blueComponent * 255).rounded()))
        return (red << 16) | (green << 8) | blue
    }

    private static func cacheCost(
        for result: LatexRenderResult
    ) -> Int? {
        var total = 0
        var foundBitmapRepresentation = false
        for case let representation as NSBitmapImageRep
            in result.image.representations
        {
            foundBitmapRepresentation = true
            guard representation.bytesPerRow > 0,
                representation.pixelsHigh > 0
            else {
                return nil
            }
            let (representationCost, overflow) =
                representation.bytesPerRow.multipliedReportingOverflow(
                    by: representation.pixelsHigh
                )
            guard !overflow, representationCost >= 0 else { return nil }
            let (newTotal, totalOverflow) = total.addingReportingOverflow(
                representationCost
            )
            guard !totalOverflow,
                newTotal <= Self.maximumCacheCost
            else {
                return nil
            }
            total = newTotal
        }
        if foundBitmapRepresentation {
            return total
        }
        return MathJaxFallbackRenderer.estimatedCacheCost(
            svgByteCount: 0,
            width: result.size.width,
            height: result.size.height,
            backingScale: 2
        )
    }

    private static var currentIsDarkMode: Bool {
        let appearance =
            NSApp.keyWindow?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        return appearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
    }

    private static func colorHex(_ color: NSColor) -> String {
        String(
            format: "#%06X",
            colorFingerprint(color)
        )
    }
}
