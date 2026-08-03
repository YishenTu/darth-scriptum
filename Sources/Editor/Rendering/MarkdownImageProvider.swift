import AppKit
import Darwin
import Dispatch
import Foundation
import MarkdownEngine

protocol MarkdownImageWatching: AnyObject, Sendable {
    func cancel()
}

protocol MarkdownImageWatcherCreating: Sendable {
    func makeWatcher(
        request: MarkdownImageLoadRequest,
        onChange: @escaping @Sendable () -> Void
    ) -> (any MarkdownImageWatching)?
}

struct MarkdownImageFileWatcherFactory: MarkdownImageWatcherCreating, Sendable {
    func makeWatcher(
        request: MarkdownImageLoadRequest,
        onChange: @escaping @Sendable () -> Void
    ) -> (any MarkdownImageWatching)? {
        MarkdownImageFileWatcher(request: request, onChange: onChange)
    }
}

private final class MarkdownImageFileWatcher: MarkdownImageWatching,
    @unchecked Sendable
{
    private let source: DispatchSourceFileSystemObject

    init?(
        request: MarkdownImageLoadRequest,
        onChange: @escaping @Sendable () -> Void
    ) {
        guard
            let descriptor = MarkdownImageSecureFileAccess.openRegularFile(
                for: request,
                flags: O_EVTONLY | O_NONBLOCK
            )
        else {
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: DispatchQueue(
                label: "com.yishentu.DarthScriptum.markdown-image-watch",
                qos: .utility
            )
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

private final class MarkdownImageLoadOperation: Operation, @unchecked Sendable {
    private let body: @Sendable (MarkdownImageLoadOperation) -> Void

    init(body: @escaping @Sendable (MarkdownImageLoadOperation) -> Void) {
        self.body = body
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        body(self)
    }
}

final class MarkdownImageProvider: EmbeddedImageProvider, @unchecked Sendable {
    static let maximumConcurrentLoads = 8
    static let maximumPendingLoads = 128

    private struct Fingerprint: Hashable {
        let providerID: UUID
        let documentPath: String?
        let contentGeneration: UInt64
    }

    private struct State {
        var documentURL: URL?
        var rootGeneration: UInt64 = 0
        var contentGeneration: UInt64 = 0
        var nextRequestID: UInt64 = 0
        var pendingRequestIDs: [URL: UInt64] = [:]
        var cache = MarkdownImageCache()
        var watchers: [URL: any MarkdownImageWatching] = [:]
        var isDisposed = false
        var lastPublicationWasOnMainThread = false
    }

    private struct ScheduledLoad {
        let request: MarkdownImageLoadRequest
        let rootGeneration: UInt64
        let requestID: UInt64
    }

    private enum ImageLookup {
        case cached(NSImage)
        case schedule(ScheduledLoad)
        case unavailable
    }

    private let stateLock = NSLock()
    private var state: State
    private let providerID = UUID()
    private let loader: any MarkdownImageLoading
    private let watcherFactory: any MarkdownImageWatcherCreating
    private let workerQueue: OperationQueue
    private let publishUpdate: @MainActor @Sendable () -> Void
    let updateNotification: Notification.Name

    init(
        documentURL: URL?,
        loader: any MarkdownImageLoading = MarkdownImageLoader(),
        watcherFactory: any MarkdownImageWatcherCreating =
            MarkdownImageFileWatcherFactory(),
        notificationCenter: NotificationCenter = .default,
        updateNotification: Notification.Name = .latexRendererDidUpdate,
        publishUpdate: (@MainActor @Sendable () -> Void)? = nil
    ) {
        state = State(documentURL: documentURL?.standardizedFileURL)
        self.loader = loader
        self.watcherFactory = watcherFactory
        self.updateNotification = updateNotification
        let workerQueue = OperationQueue()
        workerQueue.name = "com.yishentu.DarthScriptum.markdown-image-load"
        workerQueue.qualityOfService = .userInitiated
        workerQueue.maxConcurrentOperationCount = Self.maximumConcurrentLoads
        self.workerQueue = workerQueue
        self.publishUpdate =
            publishUpdate
            ?? {
                MarkdownEngineCompatibility.requestFullRestyle(
                    notificationCenter: notificationCenter,
                    notification: updateNotification
                )
            }
    }

    func update(documentURL: URL?) {
        let standardizedURL = documentURL?.standardizedFileURL
        let updateGeneration: UInt64? = stateLock.withLock {
            guard !state.isDisposed,
                state.documentURL != standardizedURL
            else {
                return nil
            }
            workerQueue.cancelAllOperations()
            for watcher in state.watchers.values {
                watcher.cancel()
            }
            state.watchers.removeAll(keepingCapacity: true)
            state.pendingRequestIDs.removeAll(keepingCapacity: true)
            state.cache.removeAll()
            state.documentURL = standardizedURL
            state.rootGeneration &+= 1
            state.contentGeneration &+= 1
            return state.contentGeneration
        }
        if let updateGeneration {
            scheduleUpdatePublication(for: updateGeneration)
        }
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let currentDocumentURL = stateLock.withLock {
            state.isDisposed ? nil : state.documentURL
        }
        guard
            let currentDocumentURL,
            let targetURL = MarkdownLinkResolver.resolveLocalFile(
                reference.name,
                relativeTo: currentDocumentURL
            )
        else {
            return nil
        }

        let lookup: ImageLookup = stateLock.withLock {
            guard !state.isDisposed,
                state.documentURL == currentDocumentURL
            else {
                return .unavailable
            }
            if let image = state.cache.image(for: targetURL) {
                return .cached(image)
            }
            guard state.pendingRequestIDs[targetURL] == nil,
                state.pendingRequestIDs.count < Self.maximumPendingLoads
            else {
                return .unavailable
            }
            state.nextRequestID &+= 1
            let requestID = state.nextRequestID
            state.pendingRequestIDs[targetURL] = requestID
            return .schedule(
                ScheduledLoad(
                    request: MarkdownImageLoadRequest(
                        rootURL: currentDocumentURL.deletingLastPathComponent(),
                        targetURL: targetURL
                    ),
                    rootGeneration: state.rootGeneration,
                    requestID: requestID
                )
            )
        }
        switch lookup {
        case .cached(let image):
            return image
        case .schedule(let scheduledLoad):
            schedule(scheduledLoad)
            return nil
        case .unavailable:
            return nil
        }
    }

    func fingerprint() -> AnyHashable {
        stateLock.withLock {
            Fingerprint(
                providerID: providerID,
                documentPath: state.documentURL?.path,
                contentGeneration: state.contentGeneration
            )
        }
    }

    func dispose() {
        stateLock.withLock {
            guard !state.isDisposed else { return }
            state.isDisposed = true
            workerQueue.cancelAllOperations()
            for watcher in state.watchers.values {
                watcher.cancel()
            }
            state.watchers.removeAll()
            state.pendingRequestIDs.removeAll()
            state.cache.removeAll()
            state.rootGeneration &+= 1
        }
    }

    #if DEBUG || TESTING
        var pendingLoadCountForTesting: Int {
            stateLock.withLock { state.pendingRequestIDs.count }
        }

        var lastPublicationWasOnMainThreadForTesting: Bool {
            stateLock.withLock { state.lastPublicationWasOnMainThread }
        }

        var isDisposedForTesting: Bool {
            stateLock.withLock { state.isDisposed }
        }
    #endif

    private func schedule(_ scheduledLoad: ScheduledLoad) {
        let loader = self.loader
        let watcherFactory = self.watcherFactory
        let operation = MarkdownImageLoadOperation { [weak self] operation in
            guard
                let self,
                self.isCurrent(scheduledLoad),
                !operation.isCancelled
            else {
                return
            }
            guard
                let authorizedRequest = loader.authorizedRequest(
                    for: scheduledLoad.request
                )
            else {
                Task { @MainActor [weak self] in
                    self?.publish(
                        nil,
                        watcher: nil,
                        scheduledLoad: scheduledLoad
                    )
                }
                return
            }
            let watcher = watcherFactory.makeWatcher(
                request: authorizedRequest
            ) { [weak self, weak operation] in
                operation?.cancel()
                self?.invalidateImage(
                    at: scheduledLoad.request.targetURL,
                    rootGeneration: scheduledLoad.rootGeneration
                )
            }
            guard let watcher else {
                Task { @MainActor [weak self] in
                    self?.publish(
                        nil,
                        watcher: nil,
                        scheduledLoad: scheduledLoad
                    )
                }
                return
            }
            guard !operation.isCancelled else {
                watcher.cancel()
                return
            }
            let decodedImage = loader.load(
                authorizedRequest,
                cancellationCheck: { operation.isCancelled }
            )
            guard !operation.isCancelled else {
                watcher.cancel()
                return
            }
            Task { @MainActor [weak self] in
                self?.publish(
                    decodedImage,
                    watcher: watcher,
                    scheduledLoad: scheduledLoad
                )
            }
        }
        workerQueue.addOperation(operation)
    }

    private func isCurrent(_ scheduledLoad: ScheduledLoad) -> Bool {
        stateLock.withLock {
            !state.isDisposed
                && state.rootGeneration == scheduledLoad.rootGeneration
                && state.pendingRequestIDs[scheduledLoad.request.targetURL]
                    == scheduledLoad.requestID
        }
    }

    @MainActor
    private func publish(
        _ decodedImage: MarkdownDecodedImage?,
        watcher: (any MarkdownImageWatching)?,
        scheduledLoad: ScheduledLoad
    ) {
        let image = decodedImage.map {
            NSImage(
                cgImage: $0.image,
                size: NSSize(width: $0.image.width, height: $0.image.height)
            )
        }
        var watchersToCancel: [any MarkdownImageWatching] = []
        let didPublish = stateLock.withLock {
            let targetURL = scheduledLoad.request.targetURL
            guard !state.isDisposed,
                state.rootGeneration == scheduledLoad.rootGeneration,
                state.pendingRequestIDs[targetURL] == scheduledLoad.requestID
            else {
                return false
            }
            state.pendingRequestIDs.removeValue(forKey: targetURL)
            guard let decodedImage, let image else { return false }
            if let existingWatcher = state.watchers.removeValue(forKey: targetURL) {
                watchersToCancel.append(existingWatcher)
            }
            let evictedURLs = state.cache.insert(
                image,
                for: targetURL,
                cost: decodedImage.decodedCost
            )
            for evictedURL in evictedURLs {
                if let evictedWatcher = state.watchers.removeValue(
                    forKey: evictedURL
                ) {
                    watchersToCancel.append(evictedWatcher)
                }
            }
            if let watcher {
                state.watchers[targetURL] = watcher
            }
            state.contentGeneration &+= 1
            state.lastPublicationWasOnMainThread = Thread.isMainThread
            return true
        }
        for watcherToCancel in watchersToCancel {
            watcherToCancel.cancel()
        }
        if didPublish {
            publishUpdate()
        } else {
            watcher?.cancel()
        }
    }

    private func invalidateImage(
        at targetURL: URL,
        rootGeneration: UInt64
    ) {
        var watcher: (any MarkdownImageWatching)?
        let updateGeneration: UInt64? = stateLock.withLock {
            guard !state.isDisposed,
                state.rootGeneration == rootGeneration
            else {
                return nil
            }
            let removedImage = state.cache.removeImage(for: targetURL)
            let removedRequest = state.pendingRequestIDs.removeValue(
                forKey: targetURL
            )
            watcher = state.watchers.removeValue(forKey: targetURL)
            guard removedImage != nil || removedRequest != nil || watcher != nil
            else {
                return nil
            }
            state.contentGeneration &+= 1
            return state.contentGeneration
        }
        watcher?.cancel()
        if let updateGeneration {
            scheduleUpdatePublication(for: updateGeneration)
        }
    }

    private func scheduleUpdatePublication(for generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let shouldPublish = stateLock.withLock {
                !state.isDisposed && state.contentGeneration == generation
            }
            if shouldPublish {
                publishUpdate()
            }
        }
    }

    deinit {
        dispose()
    }
}
