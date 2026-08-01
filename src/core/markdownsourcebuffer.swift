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

private final class SourceLineIndexNode {
    var offsets: [UInt32]
    var base: Int
    let priority: UInt64
    var left: SourceLineIndexNode?
    var right: SourceLineIndexNode?
    var pendingShift = 0
    var entryCount: Int

    init(values: [Int], priority: UInt64) {
        precondition(!values.isEmpty)
        let first = values[0]
        base = first
        offsets = values.map { UInt32($0 - first) }
        self.priority = priority
        entryCount = values.count
    }

    var blockCount: Int {
        offsets.count
    }

    func value(at index: Int) -> Int {
        base + Int(offsets[index])
    }

    func values(in range: Range<Int>) -> [Int] {
        range.map(value(at:))
    }

    func applyShift(_ delta: Int) {
        guard delta != 0 else { return }
        base += delta
        pendingShift += delta
    }

    func pushPendingShift() {
        guard pendingShift != 0 else { return }
        left?.applyShift(pendingShift)
        right?.applyShift(pendingShift)
        pendingShift = 0
    }

    func refreshCount() {
        entryCount = (left?.entryCount ?? 0)
            + blockCount
            + (right?.entryCount ?? 0)
    }
}

// Instances built off-actor are transferred exactly once to the main actor.
// The internal reference tree is never shared across actors after transfer.
private struct CompleteSourceLineIndex: @unchecked Sendable {
    private static let maximumBlockCount = 512
    static let maximumStoredLineStarts = 262_144
    private var root: SourceLineIndexNode?
    private(set) var textLength: Int
    private var priorityState: UInt64 = 0x243F_6A88_85A3_08D3

    init?(text: String) {
        root = nil
        textLength = (text as NSString).length
        root = makeTree(
            in: text as NSString,
            from: 0,
            through: textLength,
            cancellationChecksEnabled: false
        )
        guard root != nil else { return nil }
    }

    private init?(cancellableText text: String) {
        root = nil
        textLength = (text as NSString).length
        root = makeTree(
            in: text as NSString,
            from: 0,
            through: textLength,
            cancellationChecksEnabled: true
        )
        if Task.isCancelled {
            return nil
        }
        guard root != nil else { return nil }
    }

    static func buildCancellable(
        text: String
    ) -> CompleteSourceLineIndex? {
        CompleteSourceLineIndex(cancellableText: text)
    }

    var storedEntryCount: Int {
        root?.entryCount ?? 0
    }

    mutating func apply(
        _ edit: SourceEdit,
        previousText: String,
        updatedText: String
    ) -> Bool {
        let previous = previousText as NSString
        let updated = updatedText as NSString
        guard previous.length == textLength,
              edit.range.location >= 0,
              edit.range.length >= 0,
              NSMaxRange(edit.range) <= previous.length else {
            return reset(to: updated)
        }

        let startContext = max(0, edit.range.location - 1)
        var rescanStartIndex = lineIndex(containing: startContext)
        if rescanStartIndex > 0 {
            rescanStartIndex -= 1
        }
        guard let rescanStart = value(at: rescanStartIndex) else {
            return reset(to: updated)
        }

        let endContext = min(
            previous.length,
            NSMaxRange(edit.range) + 1
        )
        let firstStartAfterContext = upperBound(of: endContext)
        let preservedSuffixIndex = min(
            root?.entryCount ?? 0,
            firstStartAfterContext + 1
        )
        let oldRescanEnd = value(at: preservedSuffixIndex)
            ?? previous.length
        let lengthDelta = updated.length - previous.length
        let newRescanEnd = min(
            updated.length,
            max(rescanStart, oldRescanEnd + lengthDelta)
        )

        let (prefix, remaining) = split(root, at: rescanStartIndex)
        let (_, unshiftedSuffix) = split(
            remaining,
            at: preservedSuffixIndex - rescanStartIndex
        )
        unshiftedSuffix?.applyShift(lengthDelta)
        guard let rescannedRoot = makeTree(
            in: updated,
            from: rescanStart,
            through: newRescanEnd
        ) else {
            return false
        }
        var rescanned: SourceLineIndexNode? = rescannedRoot
        if let rescannedRoot = rescanned,
           let unshiftedSuffix,
           lastValue(in: rescannedRoot) == firstValue(in: unshiftedSuffix) {
            (rescanned, _) = split(
                rescannedRoot,
                at: rescannedRoot.entryCount - 1
            )
        }
        root = merge(prefix, merge(rescanned, unshiftedSuffix))
        textLength = updated.length
        return storedEntryCount <= Self.maximumStoredLineStarts
    }

    func position(
        atUTF16Location requestedLocation: Int,
        in text: String
    ) -> (line: Int, column: Int) {
        let location = min(max(requestedLocation, 0), textLength)
        let source = text as NSString
        if location > 0,
           location < source.length,
           source.character(at: location - 1) == 0x000D,
           source.character(at: location) == 0x000A {
            return (
                line: lineIndex(containing: location) + 2,
                column: 1
            )
        }
        let index = lineIndex(containing: location)
        let lineStart = value(at: index) ?? 0
        return (
            line: index + 1,
            column: location - lineStart + 1
        )
    }

    private mutating func reset(to text: NSString) -> Bool {
        priorityState = 0x243F_6A88_85A3_08D3
        textLength = text.length
        root = makeTree(in: text, from: 0, through: text.length)
        return root != nil
    }

    private func lineIndex(containing location: Int) -> Int {
        max(0, upperBound(of: location) - 1)
    }

    private func upperBound(of location: Int) -> Int {
        upperBound(in: root, of: location)
    }

    private func upperBound(
        in node: SourceLineIndexNode?,
        of location: Int
    ) -> Int {
        guard let node else { return 0 }
        node.pushPendingShift()
        let leftCount = node.left?.entryCount ?? 0
        let first = node.value(at: 0)
        if location < first {
            return upperBound(in: node.left, of: location)
        }
        let last = node.value(at: node.blockCount - 1)
        if location >= last {
            return leftCount
                + node.blockCount
                + upperBound(in: node.right, of: location)
        }

        var lower = 0
        var upper = node.blockCount
        let relativeLocation = UInt32(location - node.base)
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if node.offsets[middle] <= relativeLocation {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return leftCount + lower
    }

    private func value(at index: Int) -> Int? {
        guard index >= 0,
              let root,
              index < root.entryCount else {
            return nil
        }
        return value(in: root, at: index)
    }

    private func value(
        in node: SourceLineIndexNode,
        at index: Int
    ) -> Int {
        node.pushPendingShift()
        let leftCount = node.left?.entryCount ?? 0
        if index < leftCount, let left = node.left {
            return value(in: left, at: index)
        }
        if index < leftCount + node.blockCount {
            return node.value(at: index - leftCount)
        }
        return value(
            in: node.right!,
            at: index - leftCount - node.blockCount
        )
    }

    private func firstValue(in node: SourceLineIndexNode) -> Int {
        node.pushPendingShift()
        guard let left = node.left else {
            return node.value(at: 0)
        }
        return firstValue(in: left)
    }

    private func lastValue(in node: SourceLineIndexNode) -> Int {
        node.pushPendingShift()
        guard let right = node.right else {
            return node.value(at: node.blockCount - 1)
        }
        return lastValue(in: right)
    }

    private mutating func split(
        _ node: SourceLineIndexNode?,
        at requestedIndex: Int
    ) -> (SourceLineIndexNode?, SourceLineIndexNode?) {
        guard let node else { return (nil, nil) }
        node.pushPendingShift()
        let index = min(max(requestedIndex, 0), node.entryCount)
        let leftCount = node.left?.entryCount ?? 0

        if index < leftCount {
            let (prefix, remainder) = split(node.left, at: index)
            node.left = remainder
            node.refreshCount()
            return (prefix, node)
        }
        if index > leftCount + node.blockCount {
            let (prefix, suffix) = split(
                node.right,
                at: index - leftCount - node.blockCount
            )
            node.right = prefix
            node.refreshCount()
            return (node, suffix)
        }
        if index == leftCount {
            let prefix = node.left
            node.left = nil
            node.refreshCount()
            return (prefix, node)
        }
        if index == leftCount + node.blockCount {
            let suffix = node.right
            node.right = nil
            node.refreshCount()
            return (node, suffix)
        }

        let blockIndex = index - leftCount
        let prefixValues = node.values(in: 0..<blockIndex)
        let suffixValues = node.values(in: blockIndex..<node.blockCount)
        let prefixTree = merge(
            node.left,
            makeNode(values: prefixValues)
        )
        let suffixTree = merge(
            makeNode(values: suffixValues),
            node.right
        )
        return (prefixTree, suffixTree)
    }

    private func merge(
        _ left: SourceLineIndexNode?,
        _ right: SourceLineIndexNode?
    ) -> SourceLineIndexNode? {
        guard let left else { return right }
        guard let right else { return left }
        if left.priority >= right.priority {
            left.pushPendingShift()
            left.right = merge(left.right, right)
            left.refreshCount()
            return left
        }
        right.pushPendingShift()
        right.left = merge(left, right.left)
        right.refreshCount()
        return right
    }

    private mutating func makeTree(
        in text: NSString,
        from start: Int,
        through end: Int,
        cancellationChecksEnabled: Bool = false
    ) -> SourceLineIndexNode? {
        var tree: SourceLineIndexNode?
        var block = [start]
        block.reserveCapacity(Self.maximumBlockCount)
        var location = start
        let limit = min(max(end, start), text.length)
        var nextCancellationLocation = start + 4_096

        while location < limit {
            if cancellationChecksEnabled,
               location >= nextCancellationLocation,
               Task.isCancelled {
                return nil
            }
            if location >= nextCancellationLocation {
                nextCancellationLocation = location + 4_096
            }
            let unit = text.character(at: location)
            if unit == 0x000D {
                location += 1
                if location < text.length,
                   text.character(at: location) == 0x000A {
                    location += 1
                }
                if location <= limit {
                    guard (tree?.entryCount ?? 0) + block.count
                            < Self.maximumStoredLineStarts else {
                        return nil
                    }
                    if shouldFlush(block, beforeAppending: location) {
                        tree = merge(tree, makeNode(values: block))
                        block.removeAll(keepingCapacity: true)
                    }
                    block.append(location)
                }
            } else if unit == 0x000A {
                location += 1
                guard (tree?.entryCount ?? 0) + block.count
                        < Self.maximumStoredLineStarts else {
                    return nil
                }
                if shouldFlush(block, beforeAppending: location) {
                    tree = merge(tree, makeNode(values: block))
                    block.removeAll(keepingCapacity: true)
                }
                block.append(location)
            } else {
                location += 1
            }
        }
        if !block.isEmpty {
            tree = merge(tree, makeNode(values: block))
        }
        return tree
    }

    private func shouldFlush(
        _ block: [Int],
        beforeAppending value: Int
    ) -> Bool {
        guard let first = block.first else { return false }
        return block.count >= Self.maximumBlockCount
            || value - first > Int(UInt32.max)
    }

    private mutating func makeNode(
        values: [Int]
    ) -> SourceLineIndexNode {
        SourceLineIndexNode(
            values: values,
            priority: nextPriority()
        )
    }

    private mutating func nextPriority() -> UInt64 {
        priorityState &+= 0x9E37_79B9_7F4A_7C15
        var value = priorityState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct SourceLineCheckpoint: Sendable {
    let offset: Int
    let line: Int
    let lineStart: Int
}

private struct SampledSourceLineIndex: Sendable {
    private static let maximumCheckpointSpan = 1_024
    private static let cancellationCheckSpan = 4_096

    private(set) var checkpoints: [SourceLineCheckpoint]
    private(set) var textLength: Int

    init(text: String) {
        let source = text as NSString
        textLength = source.length
        checkpoints = Self.scanCheckpoints(
            in: source,
            from: SourceLineCheckpoint(
                offset: 0,
                line: 1,
                lineStart: 0
            ),
            through: source.length,
            cancellationChecksEnabled: false
        )!
    }

    private init?(cancellableText text: String) {
        let source = text as NSString
        textLength = source.length
        guard let checkpoints = Self.scanCheckpoints(
            in: source,
            from: SourceLineCheckpoint(
                offset: 0,
                line: 1,
                lineStart: 0
            ),
            through: source.length,
            cancellationChecksEnabled: true
        ) else {
            return nil
        }
        self.checkpoints = checkpoints
    }

    static func buildCancellable(
        text: String
    ) -> SampledSourceLineIndex? {
        SampledSourceLineIndex(cancellableText: text)
    }

    var storedEntryCount: Int {
        checkpoints.count
    }

    mutating func apply(
        _ edit: SourceEdit,
        previousText: String,
        updatedText: String
    ) -> Bool {
        let previous = previousText as NSString
        let updated = updatedText as NSString
        guard previous.length == textLength,
              edit.range.location >= 0,
              edit.range.length >= 0,
              NSMaxRange(edit.range) <= previous.length,
              !checkpoints.isEmpty else {
            self = SampledSourceLineIndex(text: updatedText)
            return true
        }

        let startContext = max(0, edit.range.location - 1)
        var rescanStartIndex = checkpointIndex(
            atOrBefore: startContext
        )
        if rescanStartIndex > 0 {
            rescanStartIndex -= 1
        }
        let rescanStart = checkpoints[rescanStartIndex]
        let endContext = min(
            previous.length,
            NSMaxRange(edit.range) + 1
        )
        let firstCheckpointAfterContext = upperBound(of: endContext)
        let boundaryIndex: Int
        if firstCheckpointAfterContext < checkpoints.count {
            boundaryIndex = firstCheckpointAfterContext
        } else {
            boundaryIndex = checkpoints.count - 1
        }
        let oldBoundary = checkpoints[boundaryIndex]
        let lengthDelta = updated.length - previous.length
        let newBoundaryOffset = min(
            updated.length,
            max(rescanStart.offset, oldBoundary.offset + lengthDelta)
        )
        guard let rescanned = Self.scanCheckpoints(
            in: updated,
            from: rescanStart,
            through: newBoundaryOffset,
            cancellationChecksEnabled: false
        ), let newBoundary = rescanned.last else {
            return false
        }

        var replacement = Array(checkpoints[0...rescanStartIndex])
        replacement.reserveCapacity(
            replacement.count
                + rescanned.count
                + checkpoints.count
                - boundaryIndex
        )
        replacement.append(contentsOf: rescanned.dropFirst())

        let lineDelta = newBoundary.line - oldBoundary.line
        if boundaryIndex + 1 < checkpoints.count {
            for checkpoint in checkpoints[(boundaryIndex + 1)...] {
                replacement.append(
                    SourceLineCheckpoint(
                        offset: checkpoint.offset + lengthDelta,
                        line: checkpoint.line + lineDelta,
                        lineStart: checkpoint.lineStart
                            == oldBoundary.lineStart
                            ? newBoundary.lineStart
                            : checkpoint.lineStart + lengthDelta
                    )
                )
            }
        }
        checkpoints = replacement
        textLength = updated.length

        assert(checkpoints.first?.offset == 0)
        assert(checkpoints.last?.offset == updated.length)
        return true
    }

    func position(
        atUTF16Location requestedLocation: Int,
        in text: String
    ) -> (line: Int, column: Int) {
        let location = min(max(requestedLocation, 0), textLength)
        let source = text as NSString
        let checkpoint = checkpoints[
            checkpointIndex(atOrBefore: location)
        ]
        var index = checkpoint.offset
        var line = checkpoint.line
        var lineStart = checkpoint.lineStart

        while index < location {
            let unit = source.character(at: index)
            if unit == 0x000D {
                index += 1
                if index < location,
                   source.character(at: index) == 0x000A {
                    index += 1
                }
                line += 1
                lineStart = index
            } else if unit == 0x000A {
                index += 1
                line += 1
                lineStart = index
            } else {
                index += 1
            }
        }
        return (
            line: line,
            column: location - lineStart + 1
        )
    }

    private func checkpointIndex(atOrBefore location: Int) -> Int {
        max(0, upperBound(of: location) - 1)
    }

    private func upperBound(of location: Int) -> Int {
        var lower = 0
        var upper = checkpoints.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if checkpoints[middle].offset <= location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func scanCheckpoints(
        in text: NSString,
        from initial: SourceLineCheckpoint,
        through requestedEnd: Int,
        cancellationChecksEnabled: Bool
    ) -> [SourceLineCheckpoint]? {
        let end = min(max(requestedEnd, initial.offset), text.length)
        var checkpoints = [initial]
        checkpoints.reserveCapacity(
            max(1, (end - initial.offset) / maximumCheckpointSpan + 2)
        )
        var location = initial.offset
        var line = initial.line
        var lineStart = initial.lineStart
        var nextCheckpointLocation = location + maximumCheckpointSpan
        var nextCancellationLocation = location + cancellationCheckSpan

        while location < end {
            if cancellationChecksEnabled,
               location >= nextCancellationLocation,
               Task.isCancelled {
                return nil
            }
            if location >= nextCancellationLocation {
                nextCancellationLocation = location + cancellationCheckSpan
            }

            let unit = text.character(at: location)
            if unit == 0x000D {
                location += 1
                if location < end,
                   text.character(at: location) == 0x000A {
                    location += 1
                }
                line += 1
                lineStart = location
            } else if unit == 0x000A {
                location += 1
                line += 1
                lineStart = location
            } else {
                location += 1
            }

            if location >= nextCheckpointLocation {
                checkpoints.append(
                    SourceLineCheckpoint(
                        offset: location,
                        line: line,
                        lineStart: lineStart
                    )
                )
                nextCheckpointLocation = location + maximumCheckpointSpan
            }
        }
        if checkpoints.last?.offset != end {
            checkpoints.append(
                SourceLineCheckpoint(
                    offset: end,
                    line: line,
                    lineStart: lineStart
                )
            )
        }
        if cancellationChecksEnabled, Task.isCancelled {
            return nil
        }
        return checkpoints
    }
}

struct SourceLineIndex: @unchecked Sendable {
    private enum Storage: @unchecked Sendable {
        case complete(CompleteSourceLineIndex)
        case sampled(SampledSourceLineIndex)
    }

    private var storage: Storage

    init(text: String) {
        if let complete = CompleteSourceLineIndex(text: text) {
            storage = .complete(complete)
        } else {
            storage = .sampled(SampledSourceLineIndex(text: text))
        }
    }

    private init?(cancellableText text: String) {
        if let complete = CompleteSourceLineIndex.buildCancellable(
            text: text
        ) {
            storage = .complete(complete)
            return
        }
        guard !Task.isCancelled,
              let sampled = SampledSourceLineIndex.buildCancellable(
                text: text
              ) else {
            return nil
        }
        storage = .sampled(sampled)
    }

    static func buildCancellable(text: String) -> SourceLineIndex? {
        SourceLineIndex(cancellableText: text)
    }

    var storedEntryCount: Int {
        switch storage {
        case let .complete(index):
            index.storedEntryCount
        case let .sampled(index):
            index.storedEntryCount
        }
    }

    mutating func apply(
        _ edit: SourceEdit,
        previousText: String,
        updatedText: String
    ) -> Bool {
        switch storage {
        case var .complete(index):
            guard index.apply(
                edit,
                previousText: previousText,
                updatedText: updatedText
            ) else {
                return false
            }
            storage = .complete(index)
        case var .sampled(index):
            guard index.apply(
                edit,
                previousText: previousText,
                updatedText: updatedText
            ) else {
                return false
            }
            storage = .sampled(index)
        }
        return true
    }

    func position(
        atUTF16Location location: Int,
        in text: String
    ) -> (line: Int, column: Int) {
        switch storage {
        case let .complete(index):
            return index.position(
                atUTF16Location: location,
                in: text
            )
        case let .sampled(index):
            return index.position(
                atUTF16Location: location,
                in: text
            )
        }
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
            <= Self.synchronousLineIndexLimit {
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
        case .undoRedo:
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
        case .localEditor, .undoRedo:
            requiresIncrementalEdit = true
        case .initialLoad, .externalReload, .merge, .recovery:
            requiresIncrementalEdit = false
        }
        if !requiresIncrementalEdit,
           max(original.length, updated.length)
            > Self.synchronousLineIndexLimit {
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
        case .undoRedo:
            break
        case .initialLoad, .externalReload, .merge, .recovery:
            clearHistory()
        }
        metrics = DocumentMetrics(text: next.text)
        lastAppliedEdit = nil
        lineIndexTask?.cancel()
        lineIndexTask = nil
        if (next.text as NSString).length
            <= Self.synchronousLineIndexLimit {
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
                    > Self.synchronousLineIndexLimit {
            lineIndexTask?.cancel()
            lineIndexTask = nil
            lineIndex = SourceLineIndex(text: next.text)
            return
        }
        guard max(edit.range.length, replacementLength)
                <= Self.synchronousLineIndexLimit else {
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
                  self.revision.number == revisionNumber else {
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
        expectedText: String
    ) -> Bool {
        let current = revision.text as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= current.length,
              current.substring(with: range) == expectedText else {
            return false
        }
        let edit = SourceEdit(
            range: range,
            replacement: replacement,
            expectedRevision: revision.number,
            origin: .undoRedo
        )
        return (try? apply(edit)) != nil
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
