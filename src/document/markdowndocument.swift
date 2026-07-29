import AppKit
import UniformTypeIdentifiers

enum MarkdownDocumentSaveError: LocalizedError, Equatable {
    case unmanagedInPlaceSave

    var errorDescription: String? {
        switch self {
        case .unmanagedInPlaceSave:
            return "The in-place save was not prepared by the document synchronizer."
        }
    }
}

@MainActor
final class MarkdownDocument: NSDocument, DocumentSyncCoordinatorDelegate {
    private struct EncodedDocument {
        let data: Data
        let snapshot: DocumentSnapshot
    }

    let syncCoordinator: DocumentSyncCoordinator
    private let saveBridge: SaveTransactionBridge
    private var sourceObservation: UUID?
    private var lastEncodedDocument: EncodedDocument?

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

    override init() {
        let bridge = SaveTransactionBridge()
        saveBridge = bridge
        syncCoordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(text: "", format: .newDocument),
            bridge: bridge,
            recoveryStore: .shared
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
            != fileURL.standardizedFileURL {
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
              let newWindow = controller.window else {
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
                snapshot: snapshot
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
        guard saveOperation == .saveOperation
                || saveOperation == .autosaveInPlaceOperation,
              let token = try? saveBridge.currentToken() else {
            return false
        }
        return token.targetURL.standardizedFileURL == url.standardizedFileURL
    }

    override nonisolated func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        if saveOperation == .saveOperation
            || saveOperation == .autosaveInPlaceOperation {
            guard let token = try? saveBridge.currentToken(),
                  token.targetURL.standardizedFileURL
                    == url.standardizedFileURL else {
                throw MarkdownDocumentSaveError.unmanagedInPlaceSave
            }
            let result = try SafeFileCommitter().commit(token)
            try saveBridge.store(result)
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
                        expectedSnapshot: encoded.snapshot
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
        requestSave token: PendingSaveToken
    ) {
        updateChangeCount(.changeDone)
        save(
            to: token.targetURL,
            ofType: fileType ?? "net.daringfireball.markdown",
            for: .saveOperation
        ) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let isFullySynchronized = self.syncCoordinator.handleSaveCompletion(
                    generation: token.generation,
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
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        if let modificationDate = values?.contentModificationDate {
            fileModificationDate = modificationDate
        }
        if !hasLocalChanges {
            updateChangeCount(.changeCleared)
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
        syncCoordinator.close()
        if let sourceObservation {
            syncCoordinator.sourceBuffer.removeObserver(sourceObservation)
        }
        sourceObservation = nil
        super.close()
    }

    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard fileURL != nil else {
            if !hasUnsavedUntitledContent {
                updateChangeCount(.changeCleared)
            }
            super.canClose(
                withDelegate: delegate,
                shouldClose: shouldCloseSelector,
                contextInfo: contextInfo
            )
            return
        }
        syncCoordinator.flushNow { [weak self] succeeded in
            guard let self else { return }
            guard succeeded else {
                self.sendShouldClose(
                    false,
                    to: delegate,
                    selector: shouldCloseSelector,
                    contextInfo: contextInfo
                )
                return
            }
            self.updateChangeCount(.changeCleared)
            self.completeCanClose(
                withDelegate: delegate,
                shouldClose: shouldCloseSelector,
                contextInfo: contextInfo
            )
        }
    }

    func flushNow() {
        guard fileURL != nil else { return }
        syncCoordinator.flushNow()
    }

    private func completeCanClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        super.canClose(
            withDelegate: delegate,
            shouldClose: shouldCloseSelector,
            contextInfo: contextInfo
        )
    }

    private func sendShouldClose(
        _ shouldClose: Bool,
        to delegate: Any,
        selector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let selector,
              let object = delegate as? NSObject else {
            return
        }
        typealias CloseCallback = @convention(c) (
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
