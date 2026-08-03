import Combine
import Foundation

private struct SourceHistoryEntry {
    let undoRange: NSRange
    let undoReplacement: String
    let undoExpectedText: String
    let redoRange: NSRange
    let redoReplacement: String
    let redoExpectedText: String

    var storageCost: Int {
        undoReplacement.utf8.count + undoExpectedText.utf8.count
    }
}

@MainActor
final class MarkdownSourceBuffer: ObservableObject {
    typealias Observer = @MainActor (SourceRevision, DocumentChangeOrigin) -> Void
    typealias LineIndexObserver = @MainActor () -> Void

    private static let maximumHistoryEntries = 512
    private static let maximumHistoryBytes = 32 * 1_024 * 1_024
    private static let synchronousLineIndexLimit = 2 * 1_024 * 1_024

    @Published private(set) var revision: SourceRevision
    private(set) var metrics: DocumentMetrics
    private(set) var lastAppliedEdit: SourceEdit?
    private(set) var lastOrigin: DocumentChangeOrigin
    private var observers: [UUID: Observer] = [:]
    private var lineIndexObservers: [UUID: LineIndexObserver] = [:]
    private var undoHistory: [SourceHistoryEntry] = []
    private var redoHistory: [SourceHistoryEntry] = []
    private var undoHistoryBytes = 0
    private var redoHistoryBytes = 0
    private var lineIndex: SourceLineIndex?
    private var lineIndexTask: Task<Void, Never>?

    init(snapshot: DocumentSnapshot = DocumentSnapshot(text: "", format: .newDocument)) {
        revision = SourceRevision(number: 0, text: snapshot.text)
        metrics = DocumentMetrics(text: snapshot.text)
        lastAppliedEdit = nil
        lastOrigin = .initialLoad
        if (snapshot.text as NSString).length
            <= Self.synchronousLineIndexLimit
        {
            lineIndex = SourceLineIndex(text: snapshot.text)
        } else {
            lineIndex = nil
        }
        if lineIndex == nil {
            scheduleLineIndexBuild(for: revision)
        }
    }

    deinit {
        lineIndexTask?.cancel()
    }

    @discardableResult
    func apply(_ edit: SourceEdit) throws -> SourceRevision {
        let previous = revision
        let next = try edit.applying(to: revision)
        switch edit.origin {
        case .localEditor:
            recordHistory(edit, in: previous.text)
        case .undo, .redo:
            break
        case .initialLoad, .externalReload, .merge, .recovery:
            clearHistory()
        }
        metrics = metrics.applying(edit, to: previous.text)
        lastAppliedEdit = edit
        updateLineIndex(edit, previous: previous, next: next)
        publish(next, origin: edit.origin)
        if lineIndex == nil {
            scheduleLineIndexBuild(for: next)
        }
        return next
    }

    @discardableResult
    func replace(with text: String, origin: DocumentChangeOrigin) -> SourceRevision {
        guard text != revision.text else { return revision }
        let original = revision.text as NSString
        let updated = text as NSString
        let requiresIncrementalEdit: Bool
        switch origin {
        case .localEditor, .undo, .redo:
            requiresIncrementalEdit = true
        case .initialLoad, .externalReload, .merge, .recovery:
            requiresIncrementalEdit = false
        }
        if !requiresIncrementalEdit,
            max(original.length, updated.length)
                > Self.synchronousLineIndexLimit
        {
            let next = revision.advanced(to: text)
            replaceRevision(with: next, origin: origin)
            return next
        }
        let difference = UTF16TextDifference.between(
            original: original,
            updated: updated
        )
        let edit = SourceEdit(
            range: difference.originalRange,
            replacement: updated.substring(
                with: difference.updatedRange
            ),
            expectedRevision: revision.number,
            origin: origin
        )
        if let next = try? apply(edit) {
            return next
        }
        let next = revision.advanced(to: text)
        replaceRevision(with: next, origin: origin)
        return next
    }

    var canUndo: Bool {
        !undoHistory.isEmpty
    }

    var canRedo: Bool {
        !redoHistory.isEmpty
    }

    @discardableResult
    func undo() -> Bool {
        guard let entry = undoHistory.popLast() else { return false }
        undoHistoryBytes -= entry.storageCost
        guard
            applyHistoryMutation(
                range: entry.undoRange,
                replacement: entry.undoReplacement,
                expectedText: entry.undoExpectedText,
                origin: .undo
            )
        else {
            clearHistory()
            return false
        }
        redoHistory.append(entry)
        redoHistoryBytes += entry.storageCost
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let entry = redoHistory.popLast() else { return false }
        redoHistoryBytes -= entry.storageCost
        guard
            applyHistoryMutation(
                range: entry.redoRange,
                replacement: entry.redoReplacement,
                expectedText: entry.redoExpectedText,
                origin: .redo
            )
        else {
            clearHistory()
            return false
        }
        undoHistory.append(entry)
        undoHistoryBytes += entry.storageCost
        return true
    }

    func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    func observeLineIndex(_ observer: @escaping LineIndexObserver) -> UUID {
        let token = UUID()
        lineIndexObservers[token] = observer
        return token
    }

    func removeLineIndexObserver(_ token: UUID) {
        lineIndexObservers[token] = nil
    }

    func position(
        atUTF16Location location: Int
    ) -> (line: Int, column: Int)? {
        lineIndex?.position(
            atUTF16Location: location,
            in: revision.text
        )
    }

    var lineIndexStorageEntryCount: Int? {
        lineIndex?.storedEntryCount
    }

    private func replaceRevision(
        with next: SourceRevision,
        origin: DocumentChangeOrigin
    ) {
        switch origin {
        case .localEditor:
            recordHistory(from: revision.text, to: next.text)
        case .undo, .redo:
            break
        case .initialLoad, .externalReload, .merge, .recovery:
            clearHistory()
        }
        metrics = DocumentMetrics(text: next.text)
        lastAppliedEdit = nil
        lineIndexTask?.cancel()
        lineIndexTask = nil
        if (next.text as NSString).length
            <= Self.synchronousLineIndexLimit
        {
            lineIndex = SourceLineIndex(text: next.text)
        } else {
            lineIndex = nil
        }
        publish(next, origin: origin)
        if lineIndex == nil {
            scheduleLineIndexBuild(for: next)
        }
    }

    private func updateLineIndex(
        _ edit: SourceEdit,
        previous: SourceRevision,
        next: SourceRevision
    ) {
        let replacementLength = (edit.replacement as NSString).length
        if (next.text as NSString).length
            <= Self.synchronousLineIndexLimit,
            lineIndex == nil
                || max(edit.range.length, replacementLength)
                    > Self.synchronousLineIndexLimit
        {
            lineIndexTask?.cancel()
            lineIndexTask = nil
            lineIndex = SourceLineIndex(text: next.text)
            return
        }
        guard
            max(edit.range.length, replacementLength)
                <= Self.synchronousLineIndexLimit
        else {
            lineIndex = nil
            return
        }
        if lineIndex?.apply(
            edit,
            previousText: previous.text,
            updatedText: next.text
        ) == false {
            lineIndex = nil
        }
    }

    private func scheduleLineIndexBuild(for target: SourceRevision) {
        lineIndexTask?.cancel()
        let text = target.text
        let revisionNumber = target.number
        lineIndexTask = Task { @MainActor [weak self] in
            let buildTask = Task.detached(priority: .userInitiated) {
                SourceLineIndex.buildCancellable(text: text)
            }
            let built = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard !Task.isCancelled,
                let built,
                let self,
                self.revision.number == revisionNumber
            else {
                return
            }
            self.lineIndex = built
            self.lineIndexTask = nil
            for observer in self.lineIndexObservers.values {
                observer()
            }
        }
    }

    private func recordHistory(_ edit: SourceEdit, in previous: String) {
        let oldFragment = (previous as NSString).substring(
            with: edit.range
        )
        let newFragment = edit.replacement
        let entry = SourceHistoryEntry(
            undoRange: NSRange(
                location: edit.range.location,
                length: (newFragment as NSString).length
            ),
            undoReplacement: oldFragment,
            undoExpectedText: newFragment,
            redoRange: edit.range,
            redoReplacement: newFragment,
            redoExpectedText: oldFragment
        )
        undoHistory.append(entry)
        undoHistoryBytes += entry.storageCost
        redoHistory.removeAll()
        redoHistoryBytes = 0
        trimUndoHistory()
    }

    private func recordHistory(from previous: String, to next: String) {
        let oldText = previous as NSString
        let newText = next as NSString
        let difference = UTF16TextDifference.between(
            original: oldText,
            updated: newText
        )
        recordHistory(
            SourceEdit(
                range: difference.originalRange,
                replacement: newText.substring(
                    with: difference.updatedRange
                ),
                expectedRevision: revision.number,
                origin: .localEditor(paneID: UUID())
            ),
            in: previous
        )
    }

    private func applyHistoryMutation(
        range: NSRange,
        replacement: String,
        expectedText: String,
        origin: DocumentChangeOrigin
    ) -> Bool {
        let current = revision.text as NSString
        guard range.location >= 0,
            range.length >= 0,
            NSMaxRange(range) <= current.length,
            current.substring(with: range) == expectedText
        else {
            return false
        }
        let edit = SourceEdit(
            range: range,
            replacement: replacement,
            expectedRevision: revision.number,
            origin: origin
        )
        return (try? apply(edit)) != nil
    }

    private func trimUndoHistory() {
        while undoHistory.count > 1,
            undoHistory.count > Self.maximumHistoryEntries
                || undoHistoryBytes > Self.maximumHistoryBytes
        {
            undoHistoryBytes -= undoHistory.removeFirst().storageCost
        }
    }

    private func clearHistory() {
        undoHistory.removeAll()
        redoHistory.removeAll()
        undoHistoryBytes = 0
        redoHistoryBytes = 0
    }

    private func publish(_ next: SourceRevision, origin: DocumentChangeOrigin) {
        revision = next
        lastOrigin = origin
        for observer in observers.values {
            observer(next, origin)
        }
    }
}
