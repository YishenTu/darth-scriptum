import AppKit
import Foundation
import WebKit

@MainActor
enum LocalWebJavaScriptEvaluationOutcome: @unchecked Sendable {
    case value(Any?)
    case failure(String)
    case timedOut
    case cancelled
    case processTerminated
}

@MainActor
final class LocalWebRenderSession: NSObject {
    private struct ActiveJavaScriptEvaluation {
        let id: UInt64
        let continuation:
            CheckedContinuation<
                LocalWebJavaScriptEvaluationOutcome,
                Never
            >
    }

    private let resourcePolicy: LocalWebResourcePolicy?
    private let loadTimeout: Duration
    private let javaScriptTimeout: Duration
    private var webViewStorage: WKWebView?
    private var isReady = false
    private var isDisposed = false
    private var loadAttempt = 0
    private var activeLoadAttempt: Int?
    private var activeLoadNavigation: WKNavigation?
    private var loadTimeoutTask: Task<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var entryLoadCount = 0
    private var nextJavaScriptEvaluationID: UInt64 = 0
    private var activeJavaScriptEvaluation: ActiveJavaScriptEvaluation?
    private var javaScriptTimeoutTask: Task<Void, Never>?

    init(
        resourcePolicy: LocalWebResourcePolicy?,
        loadTimeout: Duration = .seconds(5),
        javaScriptTimeout: Duration = .seconds(6)
    ) {
        self.resourcePolicy = resourcePolicy
        self.loadTimeout = loadTimeout
        self.javaScriptTimeout = javaScriptTimeout
        super.init()
    }

    deinit {
        loadTimeoutTask?.cancel()
        javaScriptTimeoutTask?.cancel()
    }

    func waitUntilReady() async -> Bool {
        await waitForReadiness(loadsEntry: true)
    }

    func evaluateJavaScript(
        _ javaScript: String,
        arguments: [String: Any]
    ) async -> LocalWebJavaScriptEvaluationOutcome {
        guard isReady,
            !isDisposed,
            let webView = webViewIfNeeded()
        else {
            return .cancelled
        }

        return await beginJavaScriptEvaluation(
            timeout: javaScriptTimeout
        ) { [weak self, weak webView] evaluationID in
            guard let self, let webView else {
                return
            }
            webView.callAsyncJavaScript(
                javaScript,
                arguments: arguments,
                in: nil,
                in: .page,
                completionHandler: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let value):
                        self.finishJavaScriptEvaluation(
                            id: evaluationID,
                            outcome: .value(value)
                        )
                    case .failure(let error):
                        self.finishJavaScriptEvaluation(
                            id: evaluationID,
                            outcome: .failure(error.localizedDescription)
                        )
                    }
                }
            )
        }
    }

    func reload() {
        guard !isDisposed else { return }
        finishLoading(succeeded: false)
        replaceWebView(
            activeEvaluationOutcome: .cancelled
        )
        beginLoadAttemptIfNeeded(loadsEntry: true)
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        finishLoading(succeeded: false)
        finishJavaScriptEvaluation(
            id: activeJavaScriptEvaluation?.id,
            outcome: .cancelled
        )
        if let webViewStorage {
            discard(webViewStorage)
        }
        webViewStorage = nil
    }

    #if DEBUG || TESTING
        var webViewForTesting: WKWebView? {
            webViewStorage
        }

        var isReadyForTesting: Bool {
            isReady
        }

        var entryLoadCountForTesting: Int {
            entryLoadCount
        }

        var loadWaiterCountForTesting: Int {
            loadWaiters.count
        }

        var hasLoadTimeoutForTesting: Bool {
            loadTimeoutTask != nil
        }

        var hasActiveJavaScriptEvaluationForTesting: Bool {
            activeJavaScriptEvaluation != nil
        }

        func waitForReadinessForTesting(loadsEntry: Bool) async -> Bool {
            await waitForReadiness(loadsEntry: loadsEntry)
        }

        func waitForJavaScriptEvaluationForTesting(
            timeout: Duration? = nil
        ) async -> LocalWebJavaScriptEvaluationOutcome {
            await beginJavaScriptEvaluation(
                timeout: timeout ?? javaScriptTimeout
            ) { _ in }
        }

        func cancelJavaScriptEvaluationForTesting() {
            guard let activeJavaScriptEvaluation else { return }
            cancelJavaScriptEvaluation(id: activeJavaScriptEvaluation.id)
        }
    #endif

    private func waitForReadiness(loadsEntry: Bool) async -> Bool {
        guard !isDisposed else { return false }
        if isReady {
            return true
        }

        return await withCheckedContinuation { continuation in
            guard !isDisposed else {
                continuation.resume(returning: false)
                return
            }
            loadWaiters.append(continuation)
            beginLoadAttemptIfNeeded(loadsEntry: loadsEntry)
        }
    }

    private func beginLoadAttemptIfNeeded(loadsEntry: Bool) {
        guard !isDisposed,
            !isReady,
            activeLoadAttempt == nil
        else {
            return
        }

        if loadsEntry && resourcePolicy == nil {
            finishLoading(succeeded: false)
            return
        }
        guard let webView = webViewIfNeeded() else { return }

        loadAttempt &+= 1
        let attempt = loadAttempt
        activeLoadAttempt = attempt

        if loadsEntry {
            guard let resourcePolicy else { return }
            entryLoadCount &+= 1
            guard let navigation = resourcePolicy.loadEntry(in: webView) else {
                finishLoading(succeeded: false)
                replaceWebView(
                    activeEvaluationOutcome: .cancelled
                )
                return
            }
            activeLoadNavigation = navigation
        }

        scheduleLoadTimeout(for: attempt)
    }

    private func scheduleLoadTimeout(for attempt: Int) {
        loadTimeoutTask?.cancel()
        let timeout = loadTimeout
        loadTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled,
                let self,
                self.activeLoadAttempt == attempt
            else {
                return
            }
            self.webViewStorage?.stopLoading()
            self.finishLoading(succeeded: false)
            self.replaceWebView(
                activeEvaluationOutcome: .cancelled
            )
        }
    }

    private func finishLoading(succeeded: Bool) {
        activeLoadAttempt = nil
        activeLoadNavigation = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        isReady = succeeded
        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume(returning: succeeded)
        }
    }

    private func beginJavaScriptEvaluation(
        timeout: Duration,
        start: @escaping @MainActor (UInt64) -> Void
    ) async -> LocalWebJavaScriptEvaluationOutcome {
        guard webViewIfNeeded() != nil else {
            return .cancelled
        }
        nextJavaScriptEvaluationID &+= 1
        let evaluationID = nextJavaScriptEvaluationID

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isDisposed,
                    !Task.isCancelled,
                    activeJavaScriptEvaluation == nil
                else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                activeJavaScriptEvaluation = ActiveJavaScriptEvaluation(
                    id: evaluationID,
                    continuation: continuation
                )
                scheduleJavaScriptTimeout(
                    for: evaluationID,
                    timeout: timeout
                )
                start(evaluationID)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelJavaScriptEvaluation(id: evaluationID)
            }
        }
    }

    private func scheduleJavaScriptTimeout(
        for evaluationID: UInt64,
        timeout: Duration
    ) {
        javaScriptTimeoutTask?.cancel()
        javaScriptTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled,
                let self,
                self.activeJavaScriptEvaluation?.id == evaluationID
            else {
                return
            }
            self.finishJavaScriptEvaluation(
                id: evaluationID,
                outcome: .timedOut
            )
            self.replaceWebView(
                activeEvaluationOutcome: .cancelled
            )
        }
    }

    private func cancelJavaScriptEvaluation(id: UInt64) {
        guard activeJavaScriptEvaluation?.id == id else { return }
        finishJavaScriptEvaluation(id: id, outcome: .cancelled)
        replaceWebView(activeEvaluationOutcome: .cancelled)
    }

    private func finishJavaScriptEvaluation(
        id: UInt64?,
        outcome: LocalWebJavaScriptEvaluationOutcome
    ) {
        guard let activeJavaScriptEvaluation,
            id == nil || activeJavaScriptEvaluation.id == id
        else {
            return
        }
        self.activeJavaScriptEvaluation = nil
        javaScriptTimeoutTask?.cancel()
        javaScriptTimeoutTask = nil
        activeJavaScriptEvaluation.continuation.resume(returning: outcome)
    }

    private func replaceWebView(
        activeEvaluationOutcome: LocalWebJavaScriptEvaluationOutcome
    ) {
        guard !isDisposed else { return }
        finishJavaScriptEvaluation(
            id: activeJavaScriptEvaluation?.id,
            outcome: activeEvaluationOutcome
        )
        if let webViewStorage {
            discard(webViewStorage)
        }
        webViewStorage = makeWebView()
        isReady = false
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 4_096, height: 2_048),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.uiDelegate = resourcePolicy
        return webView
    }

    private func webViewIfNeeded() -> WKWebView? {
        guard !isDisposed else { return nil }
        if let webViewStorage {
            return webViewStorage
        }
        let webView = makeWebView()
        webViewStorage = webView
        return webView
    }

    private func discard(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func isActiveLoad(_ navigation: WKNavigation?) -> Bool {
        guard activeLoadAttempt != nil else { return false }
        guard let activeLoadNavigation else {
            return navigation == nil
        }
        return navigation === activeLoadNavigation
    }
}

extension LocalWebRenderSession: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        guard webView === webViewStorage,
            isActiveLoad(navigation),
            webView.url == resourcePolicy?.entryURL
        else {
            return
        }
        finishLoading(succeeded: true)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        handleLoadFailure(webView, navigation: navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        handleLoadFailure(webView, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === webViewStorage else { return }
        finishLoading(succeeded: false)
        replaceWebView(
            activeEvaluationOutcome: .processTerminated
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === webViewStorage,
            let resourcePolicy,
            !isDisposed
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(resourcePolicy.navigationPolicy(for: navigationAction))
    }

    private func handleLoadFailure(
        _ webView: WKWebView,
        navigation: WKNavigation?
    ) {
        guard webView === webViewStorage,
            isActiveLoad(navigation)
        else {
            return
        }
        finishLoading(succeeded: false)
        replaceWebView(activeEvaluationOutcome: .cancelled)
    }
}
