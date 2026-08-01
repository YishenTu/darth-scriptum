import AppKit
import UniformTypeIdentifiers

enum MarkdownDocumentSaveError: LocalizedError, Equatable {
    case unmanagedInPlaceSave
    case synchronousWriteOnMainThread

    var errorDescription: String? {
        switch self {
        case .unmanagedInPlaceSave:
            return "The in-place save was not prepared by the document synchronizer."
        case .synchronousWriteOnMainThread:
            return "The managed file write cannot run on the main thread."
        }
    }
}

@MainActor
final class MarkdownDocument: NSDocument, DocumentSyncCoordinatorHost {
    private struct EncodedDocument {
        let data: Data
        let snapshot: DocumentSnapshot
        let sourceRevision: SourceRevision
    }

    private struct PendingCloseCallback {
        let delegate: Any
        let selector: Selector?
        let contextInfo: UnsafeMutableRawPointer?
    }

    let syncCoordinator: DocumentSyncCoordinator
    private let saveBridge: SaveTransactionBridge
    private var sourceObservation: UUID?
    private var lastEncodedDocument: EncodedDocument?
    private var pendingCloseCallbacks: [PendingCloseCallback] = []
    private var nativeCloseToken: SyncEffectToken?
    private var committedCloseToken: SyncEffectToken?

    var markdownWindowController: MarkdownWindowController? {
        windowControllers.first as? MarkdownWindowController
    }

    var synchronizationFileURL: URL? {
        fileURL
    }

    var hasUnsavedUntitledContent: Bool {
        fileURL == nil && !syncCoordinator.sourceBuffer.revision.text.isEmpty
    }

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }
    nonisolated override class var autosavesDrafts: Bool { false }

    override convenience init() {
        self.init(recoveryStore: .shared)
    }

    init(recoveryStore: SessionRecoveryStore) {
        let bridge = SaveTransactionBridge()
        saveBridge = bridge
        syncCoordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            bridge: bridge,
            recoveryStore: recoveryStore
        )
        super.init()
        hasUndoManager = true
        syncCoordinator.delegate = self
        sourceObservation = syncCoordinator.sourceBuffer.observe { [weak self] _, origin in
            switch origin {
            case .localEditor, .undoRedo, .merge, .recovery:
                self?.updateChangeCount(.changeDone)
            case .initialLoad, .externalReload:
                return
            }
        }
    }

    override func makeWindowControllers() {
        if let fileURL,
            syncCoordinator.fileURL?.standardizedFileURL
                != fileURL.standardizedFileURL
        {
            syncCoordinator.attach(to: fileURL)
        }
        let existingFrontWindow = NSApp.keyWindow
        let controller = MarkdownWindowController(document: self)
        addWindowController(controller)

        let opensSeparately = (NSApp.delegate as? AppDelegate)?.opensSeparately == true
        guard !opensSeparately,
            !NSEvent.modifierFlags.contains(.option),
            let existingFrontWindow,
            existingFrontWindow !== controller.window,
            existingFrontWindow.windowController?.document !== self,
            let newWindow = controller.window
        else {
            return
        }
        existingFrontWindow.addTabbedWindow(newWindow, ordered: .above)
        controller.refreshTabShortcuts()
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        return try MainActor.assumeIsolated {
            let snapshot = syncCoordinator.currentSnapshot
            let data = try TextFileCodec.encode(snapshot)
            lastEncodedDocument = EncodedDocument(
                data: data,
                snapshot: snapshot,
                sourceRevision: syncCoordinator.sourceBuffer.revision
            )
            return data
        }
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let decoded = try TextFileCodec.decode(data)
        MainActor.assumeIsolated {
            syncCoordinator.loadInitial(decoded, data: data, from: fileURL)
        }
    }

    override nonisolated func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        guard
            saveOperation == .saveOperation
                || saveOperation == .autosaveInPlaceOperation,
            let request = try? saveBridge.currentCommitRequest()
        else {
            return false
        }
        return request.targetURL.standardizedFileURL == url.standardizedFileURL
    }

    override nonisolated func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        if saveOperation == .saveOperation
            || saveOperation == .autosaveInPlaceOperation
        {
            guard let request = try? saveBridge.currentCommitRequest(),
                request.targetURL.standardizedFileURL
                    == url.standardizedFileURL
            else {
                throw MarkdownDocumentSaveError.unmanagedInPlaceSave
            }
            guard !Thread.isMainThread else {
                throw MarkdownDocumentSaveError.synchronousWriteOnMainThread
            }
            try DocumentFileAccess.performSynchronously {
                let result = try SafeFileCommitter().commit(request.pendingSave)
                try self.saveBridge.store(result, for: request.token)
            }
            return
        }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if saveOperation == .saveAsOperation {
            lastEncodedDocument = nil
        }
        super.save(
            to: url,
            ofType: typeName,
            for: saveOperation
        ) { [weak self] error in
            let encoded = self?.lastEncodedDocument
            self?.lastEncodedDocument = nil
            guard error == nil, saveOperation == .saveAsOperation else {
                completionHandler(error)
                return
            }
            guard let self, let encoded else {
                self?.syncCoordinator.attach(to: url)
                completionHandler(nil)
                return
            }
            Task { @MainActor [weak self] in
                do {
                    try await self?.syncCoordinator.attachAfterSaveAs(
                        to: url,
                        expectedData: encoded.data,
                        expectedSnapshot: encoded.snapshot,
                        expectedSourceRevision: encoded.sourceRevision
                    )
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave request: DocumentSyncSaveCommitRequest
    ) {
        updateChangeCount(.changeDone)
        save(
            to: request.targetURL,
            ofType: fileType ?? "net.daringfireball.markdown",
            for: .saveOperation
        ) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let isFullySynchronized = self.syncCoordinator.handleSaveCompletion(
                    token: request.token,
                    error: error
                )
                if error == nil, isFullySynchronized {
                    self.updateChangeCount(.changeCleared)
                }
            }
        }
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    ) {
        Task { [weak self] in
            let modificationDate = try? await DocumentFileAccess.perform {
                try url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            }
            guard let self else { return }
            if let modificationDate {
                self.fileModificationDate = modificationDate
            }
            if !hasLocalChanges {
                self.updateChangeCount(.changeCleared)
            }
        }
    }

    override nonisolated func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            self?.syncCoordinator.noteCoordinatedExternalChange()
        }
    }

    override nonisolated func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        Task { @MainActor [weak self] in
            self?.syncCoordinator.noteFileMoved(to: newURL)
        }
    }

    override func close() {
        let closeToken = committedCloseToken ?? authorizedCloseToken()
        super.close()
        if let closeToken {
            syncCoordinator.completeClose(token: closeToken, didCommit: true)
        }
        committedCloseToken = nil
        syncCoordinator.close()
        if let sourceObservation {
            syncCoordinator.sourceBuffer.removeObserver(sourceObservation)
        }
        sourceObservation = nil
    }

    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        pendingCloseCallbacks.append(
            PendingCloseCallback(
                delegate: delegate,
                selector: shouldCloseSelector,
                contextInfo: contextInfo
            )
        )
        syncCoordinator.requestClose()
    }

    func flushNow() {
        guard fileURL != nil else { return }
        syncCoordinator.flushNow()
    }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        resolveClose resolution: DocumentSyncCloseResolution
    ) {
        guard !pendingCloseCallbacks.isEmpty else {
            if resolution.disposition == .refuseManagedClose {
                coordinator.completeClose(token: resolution.token, didCommit: false)
            }
            return
        }

        switch resolution.disposition {
        case .allowManagedClose:
            // The reducer has already proven the managed document durable.
            // Clear AppKit's independent dirty marker before it asks again.
            updateChangeCount(.changeCleared)
            beginNativeCloseReview(for: resolution.token)
        case .refuseManagedClose:
            resolvePendingCloseCallbacks(false)
            coordinator.completeClose(token: resolution.token, didCommit: false)
        case .deferToNativeUntitledReview:
            if !hasUnsavedUntitledContent {
                updateChangeCount(.changeCleared)
            }
            beginNativeCloseReview(for: resolution.token)
        }
    }

    private func beginNativeCloseReview(for token: SyncEffectToken) {
        guard nativeCloseToken == nil else { return }
        nativeCloseToken = token
        super.canClose(
            withDelegate: self,
            shouldClose: #selector(
                nativeCanClose(_:shouldClose:contextInfo:)
            ),
            contextInfo: nil
        )
    }

    @objc private func nativeCanClose(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        _ = document
        _ = contextInfo
        guard let token = nativeCloseToken else { return }
        nativeCloseToken = nil
        if shouldClose {
            // Forwarding this answer may cause NSDocumentController to call
            // `close()` reentrantly. Store the token first; `close()` emits
            // `closeCommitted` only after AppKit has completed that call.
            committedCloseToken = token
            resolvePendingCloseCallbacks(true)
        } else {
            resolvePendingCloseCallbacks(false)
            syncCoordinator.completeClose(token: token, didCommit: false)
        }
    }

    private func authorizedCloseToken() -> SyncEffectToken? {
        guard case .closing(let attempt) = syncCoordinator.reducerState.lifecycle,
            attempt.resolution == .allowManagedClose
                || attempt.resolution == .deferToNativeUntitledReview
        else {
            return nil
        }
        return attempt.token
    }

    private func resolvePendingCloseCallbacks(_ shouldClose: Bool) {
        let callbacks = pendingCloseCallbacks
        pendingCloseCallbacks.removeAll()
        for callback in callbacks {
            sendShouldClose(
                shouldClose,
                to: callback.delegate,
                selector: callback.selector,
                contextInfo: callback.contextInfo
            )
        }
    }

    private func sendShouldClose(
        _ shouldClose: Bool,
        to delegate: Any,
        selector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let selector,
            let object = delegate as? NSObject
        else {
            return
        }
        typealias CloseCallback =
            @convention(c) (
                AnyObject,
                Selector,
                NSDocument,
                Bool,
                UnsafeMutableRawPointer?
            ) -> Void
        let callback = unsafeBitCast(
            object.method(for: selector),
            to: CloseCallback.self
        )
        callback(object, selector, self, shouldClose, contextInfo)
    }
}
