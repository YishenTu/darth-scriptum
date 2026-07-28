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

    private static let maximumHistoryEntries = 512
    private static let maximumHistoryBytes = 32 * 1_024 * 1_024

    @Published private(set) var revision: SourceRevision
    @Published private(set) var lastOrigin: DocumentChangeOrigin
    private var observers: [UUID: Observer] = [:]
    private var undoHistory: [SourceHistoryEntry] = []
    private var redoHistory: [SourceHistoryEntry] = []
    private var undoHistoryBytes = 0
    private var redoHistoryBytes = 0

    init(snapshot: DocumentSnapshot = DocumentSnapshot(text: "", format: .newDocument)) {
        revision = SourceRevision(number: 0, text: snapshot.text)
        lastOrigin = .initialLoad
    }

    @discardableResult
    func apply(_ edit: SourceEdit) throws -> SourceRevision {
        let next = try edit.applying(to: revision)
        replaceRevision(with: next, origin: edit.origin)
        return next
    }

    @discardableResult
    func replace(with text: String, origin: DocumentChangeOrigin) -> SourceRevision {
        guard text != revision.text else { return revision }
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
        guard applyHistoryMutation(
            range: entry.undoRange,
            replacement: entry.undoReplacement,
            expectedText: entry.undoExpectedText
        ) else {
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
        guard applyHistoryMutation(
            range: entry.redoRange,
            replacement: entry.redoReplacement,
            expectedText: entry.redoExpectedText
        ) else {
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

    private func replaceRevision(
        with next: SourceRevision,
        origin: DocumentChangeOrigin
    ) {
        switch origin {
        case .localEditor:
            recordHistory(from: revision.text, to: next.text)
        case .undoRedo:
            break
        case .initialLoad, .externalReload, .merge, .recovery:
            clearHistory()
        }
        publish(next, origin: origin)
    }

    private func recordHistory(from previous: String, to next: String) {
        let oldText = previous as NSString
        let newText = next as NSString
        let difference = UTF16TextDifference.between(
            original: oldText,
            updated: newText
        )
        let oldFragment = oldText.substring(
            with: difference.originalRange
        )
        let newFragment = newText.substring(
            with: difference.updatedRange
        )
        let entry = SourceHistoryEntry(
            undoRange: difference.updatedRange,
            undoReplacement: oldFragment,
            undoExpectedText: newFragment,
            redoRange: difference.originalRange,
            redoReplacement: newFragment,
            redoExpectedText: oldFragment
        )
        undoHistory.append(entry)
        undoHistoryBytes += entry.storageCost
        redoHistory.removeAll()
        redoHistoryBytes = 0
        trimUndoHistory()
    }

    private func applyHistoryMutation(
        range: NSRange,
        replacement: String,
        expectedText: String
    ) -> Bool {
        let current = revision.text as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= current.length,
              current.substring(with: range) == expectedText else {
            return false
        }
        let updated = NSMutableString(string: current)
        updated.replaceCharacters(in: range, with: replacement)
        publish(
            revision.advanced(to: updated as String),
            origin: .undoRedo
        )
        return true
    }

    private func trimUndoHistory() {
        while undoHistory.count > 1,
              undoHistory.count > Self.maximumHistoryEntries
                || undoHistoryBytes > Self.maximumHistoryBytes {
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
