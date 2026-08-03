import AppKit
import ObjectiveC
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

private struct MarkdownEncodedDocument {
    let data: Data
    let snapshot: DocumentSnapshot
    let sourceRevision: SourceRevision
}

private struct MarkdownPendingCloseCallback {
    let delegate: Any
    let selector: Selector?
    let contextInfo: UnsafeMutableRawPointer?
}

/// `NSDocumentController` constructs concurrently-readable documents on its
/// opening queue. Keeping Swift state behind an associated reference lets the
/// subclass inherit AppKit's Objective-C `init` implementation, avoiding a
/// generated main-actor thunk while preserving main-actor ownership of live
/// document state.
private final class MarkdownDocumentState: @unchecked Sendable {
    let recoveryStore: SessionRecoveryStore
    let fileAccessLane: DocumentFileAccessLane
    let fileCommitter: any DocumentFileCommitting
    let managedWriteDidUnblock: (@Sendable () -> Void)?
    let initialContentStore = DocumentInitialContentStore()
    let saveBridge = SaveTransactionBridge()
    var syncCoordinatorStorage: DocumentSyncCoordinator?
    var sourceObservation: UUID?
    var lastEncodedDocument: MarkdownEncodedDocument?
    var pendingCloseCallbacks: [MarkdownPendingCloseCallback] = []
    var nativeCloseToken: SyncEffectToken?
    var committedCloseToken: SyncEffectToken?

    init(
        recoveryStore: SessionRecoveryStore = .shared,
        fileAccessLane: DocumentFileAccessLane =
            DocumentFileAccess.makeDocumentLane(),
        fileCommitter: any DocumentFileCommitting = SafeFileCommitter(),
        managedWriteDidUnblock: (@Sendable () -> Void)? = nil
    ) {
        self.recoveryStore = recoveryStore
        self.fileAccessLane = fileAccessLane
        self.fileCommitter = fileCommitter
        self.managedWriteDidUnblock = managedWriteDidUnblock
    }
}

private enum MarkdownDocumentStateAssociation {
    static let lock = NSLock()
    nonisolated(unsafe) static var key: UInt8 = 0

    nonisolated static func state(
        for document: MarkdownDocument
    ) -> MarkdownDocumentState {
        lock.withLock {
            if let state = objc_getAssociatedObject(document, &key)
                as? MarkdownDocumentState
            {
                return state
            }
            let state = MarkdownDocumentState()
            objc_setAssociatedObject(
                document,
                &key,
                state,
                .OBJC_ASSOCIATION_RETAIN
            )
            return state
        }
    }

    static func install(
        _ state: MarkdownDocumentState,
        on document: MarkdownDocument
    ) {
        lock.withLock {
            precondition(objc_getAssociatedObject(document, &key) == nil)
            objc_setAssociatedObject(
                document,
                &key,
                state,
                .OBJC_ASSOCIATION_RETAIN
            )
        }
    }
}

nonisolated final class MarkdownDocument: NSDocument, DocumentSyncCoordinatorHost {
    private nonisolated var documentState: MarkdownDocumentState {
        MarkdownDocumentStateAssociation.state(for: self)
    }

    private nonisolated var recoveryStore: SessionRecoveryStore {
        documentState.recoveryStore
    }

    private nonisolated var fileAccessLane: DocumentFileAccessLane {
        documentState.fileAccessLane
    }

    private nonisolated var fileCommitter: any DocumentFileCommitting {
        documentState.fileCommitter
    }

    private nonisolated var managedWriteDidUnblock: (@Sendable () -> Void)? {
        documentState.managedWriteDidUnblock
    }

    private nonisolated var initialContentStore: DocumentInitialContentStore {
        documentState.initialContentStore
    }

    private nonisolated var saveBridge: SaveTransactionBridge {
        documentState.saveBridge
    }

    @MainActor private var syncCoordinatorStorage: DocumentSyncCoordinator? {
        get { documentState.syncCoordinatorStorage }
        set { documentState.syncCoordinatorStorage = newValue }
    }

    @MainActor private var sourceObservation: UUID? {
        get { documentState.sourceObservation }
        set { documentState.sourceObservation = newValue }
    }

    @MainActor private var lastEncodedDocument: MarkdownEncodedDocument? {
        get { documentState.lastEncodedDocument }
        set { documentState.lastEncodedDocument = newValue }
    }

    @MainActor private var pendingCloseCallbacks: [MarkdownPendingCloseCallback] {
        get { documentState.pendingCloseCallbacks }
        set { documentState.pendingCloseCallbacks = newValue }
    }

    @MainActor private var nativeCloseToken: SyncEffectToken? {
        get { documentState.nativeCloseToken }
        set { documentState.nativeCloseToken = newValue }
    }

    @MainActor private var committedCloseToken: SyncEffectToken? {
        get { documentState.committedCloseToken }
        set { documentState.committedCloseToken = newValue }
    }

    @MainActor var syncCoordinator: DocumentSyncCoordinator {
        let coordinator = initializeSyncCoordinatorIfNeeded()
        installStagedContentIfNeeded(into: coordinator)
        return coordinator
    }

    @MainActor var hasInitializedSynchronization: Bool {
        syncCoordinatorStorage != nil
    }

    @MainActor var markdownWindowController: MarkdownWindowController? {
        windowControllers.first as? MarkdownWindowController
    }

    @MainActor var synchronizationFileURL: URL? {
        fileURL
    }

    @MainActor var hasUnsavedUntitledContent: Bool {
        fileURL == nil && !syncCoordinator.sourceBuffer.revision.text.isEmpty
    }

    @MainActor var isReplaceableEmptyUntitledDocument: Bool {
        fileURL == nil && !hasUnsavedUntitledContent
    }

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }
    nonisolated override class var autosavesDrafts: Bool { false }

    nonisolated override class func canConcurrentlyReadDocuments(
        ofType typeName: String
    ) -> Bool {
        typeName == "net.daringfireball.markdown"
            || typeName == "public.plain-text"
    }

    @MainActor convenience init(
        recoveryStore: SessionRecoveryStore,
        fileAccessLane: DocumentFileAccessLane =
            DocumentFileAccess.makeDocumentLane(),
        fileCommitter: any DocumentFileCommitting = SafeFileCommitter(),
        managedWriteDidUnblock: (@Sendable () -> Void)? = nil
    ) {
        self.init()
        MarkdownDocumentStateAssociation.install(
            MarkdownDocumentState(
                recoveryStore: recoveryStore,
                fileAccessLane: fileAccessLane,
                fileCommitter: fileCommitter,
                managedWriteDidUnblock: managedWriteDidUnblock
            ),
            on: self
        )
    }

    @MainActor override func makeWindowControllers() {
        if let fileURL,
            syncCoordinator.fileURL?.standardizedFileURL
                != fileURL.standardizedFileURL
        {
            syncCoordinator.attach(to: fileURL)
        }
        let existingFrontWindow = NSApp.keyWindow
        let controller = MarkdownWindowController(
            document: self,
            onOpenMarkdownFile: { [weak self] url in
                ApplicationDocumentOpener.open(
                    url,
                    replacing: self
                )
            }
        )
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
            lastEncodedDocument = MarkdownEncodedDocument(
                data: data,
                snapshot: snapshot,
                sourceRevision: syncCoordinator.sourceBuffer.revision
            )
            return data
        }
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let decoded = try TextFileCodec.decode(data)
        initialContentStore.stage(
            .init(snapshot: decoded, data: data)
        )
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
            unblockUserInteraction()
            managedWriteDidUnblock?()
            try fileAccessLane.performSynchronously {
                let result = try self.fileCommitter.commit(
                    request.pendingSave
                )
                try self.saveBridge.store(result, for: request.token)
            }
            return
        }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }

    @MainActor override func save(
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

    @MainActor override func revert(
        toContentsOf url: URL,
        ofType typeName: String
    ) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        installStagedContentIfNeeded(into: initializeSyncCoordinatorIfNeeded())
    }

    @MainActor func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave request: DocumentSyncSaveCommitRequest
    ) {
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

    @MainActor func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    ) {
        if !hasLocalChanges {
            updateChangeCount(.changeCleared)
        }

        let acceptedURL = url.standardizedFileURL
        let lane = fileAccessLane
        Task { [weak self] in
            let modificationDate = try? await lane.perform {
                try acceptedURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            }
            guard
                let self,
                self.fileURL?.standardizedFileURL == acceptedURL
            else {
                return
            }
            if let modificationDate {
                self.fileModificationDate = modificationDate
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

    @MainActor override func close() {
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

    @MainActor override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        pendingCloseCallbacks.append(
            MarkdownPendingCloseCallback(
                delegate: delegate,
                selector: shouldCloseSelector,
                contextInfo: contextInfo
            )
        )
        syncCoordinator.requestClose()
    }

    @MainActor func flushNow() {
        guard fileURL != nil else { return }
        syncCoordinator.flushNow()
    }

    @MainActor override func save(_ sender: Any?) {
        guard fileURL != nil else {
            super.save(sender)
            return
        }
        flushNow()
    }

    @MainActor @objc func undoDocument(_ sender: Any?) {
        _ = sender
        syncCoordinator.sourceBuffer.undo()
    }

    @MainActor @objc func redoDocument(_ sender: Any?) {
        _ = sender
        syncCoordinator.sourceBuffer.redo()
    }

    @MainActor override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        if item.action == #selector(NSDocument.save(_:)) {
            guard fileURL != nil else {
                return super.validateUserInterfaceItem(item)
            }
            return syncCoordinator.hasLocalChanges
        }
        if item.action == #selector(undoDocument(_:)) {
            return syncCoordinator.sourceBuffer.canUndo
        }
        if item.action == #selector(redoDocument(_:)) {
            return syncCoordinator.sourceBuffer.canRedo
        }
        return super.validateUserInterfaceItem(item)
    }

    @MainActor func syncCoordinator(
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

    @MainActor private func beginNativeCloseReview(for token: SyncEffectToken) {
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

    @MainActor @objc private func nativeCanClose(
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

    @MainActor private func authorizedCloseToken() -> SyncEffectToken? {
        guard case .closing(let attempt) = syncCoordinator.reducerState.lifecycle,
            attempt.resolution == .allowManagedClose
                || attempt.resolution == .deferToNativeUntitledReview
        else {
            return nil
        }
        return attempt.token
    }

    @MainActor private func resolvePendingCloseCallbacks(_ shouldClose: Bool) {
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

    @MainActor private func sendShouldClose(
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

    @MainActor private func initializeSyncCoordinatorIfNeeded()
        -> DocumentSyncCoordinator
    {
        if let syncCoordinatorStorage {
            return syncCoordinatorStorage
        }
        hasUndoManager = true
        let stagedContent = initialContentStore.take()
        let coordinator = DocumentSyncCoordinator(
            snapshot: stagedContent?.snapshot
                ?? DocumentSnapshot(text: "", format: .newDocument),
            bridge: saveBridge,
            recoveryStore: recoveryStore,
            fileAccessLane: fileAccessLane
        )
        syncCoordinatorStorage = coordinator
        coordinator.delegate = self
        sourceObservation = coordinator.sourceBuffer.observe {
            [weak self] _, origin in
            switch origin {
            case .localEditor, .merge, .recovery:
                self?.updateChangeCount(.changeDone)
            case .undo:
                self?.updateChangeCount(.changeUndone)
            case .redo:
                self?.updateChangeCount(.changeRedone)
            case .initialLoad, .externalReload:
                return
            }
        }
        if let stagedContent {
            coordinator.loadInitial(
                stagedContent.snapshot,
                data: stagedContent.data,
                from: fileURL
            )
        }
        return coordinator
    }

    @MainActor private func installStagedContentIfNeeded(
        into coordinator: DocumentSyncCoordinator
    ) {
        guard let stagedContent = initialContentStore.take() else { return }
        coordinator.loadInitial(
            stagedContent.snapshot,
            data: stagedContent.data,
            from: fileURL
        )
    }
}
