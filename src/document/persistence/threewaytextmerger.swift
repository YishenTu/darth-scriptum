import Foundation

/// Merge evidence minted by the worker that consumed one exact immutable
/// merge request. A reducer cannot be handed an unrelated snapshot as a
/// purported merge result.
struct DocumentSyncMergeResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case merged(DocumentSnapshot)
        case conflict
    }

    let request: DocumentSyncMergeRequest
    let outcome: Outcome

    var token: SyncEffectToken {
        request.token
    }

    fileprivate init(
        request: DocumentSyncMergeRequest,
        outcome: Outcome
    ) {
        self.request = request
        self.outcome = outcome
    }
}

enum ThreeWayMergeResult: Sendable, Equatable {
    case unchanged(String)
    case merged(String)
    case conflict
}

struct ThreeWayTextMerger: Sendable {
    nonisolated func result(
        for request: DocumentSyncMergeRequest
    ) -> DocumentSyncMergeResult {
        let outcome: DocumentSyncMergeResult.Outcome
        switch merge(
            base: request.base?.text ?? "",
            local: request.local.text,
            external: request.external.text
        ) {
        case .conflict:
            outcome = .conflict
        case .unchanged(let text), .merged(let text):
            outcome = .merged(
                DocumentSnapshot(text: text, format: request.local.format)
            )
        }
        return DocumentSyncMergeResult(request: request, outcome: outcome)
    }

    private struct Change: Sendable, Equatable {
        var range: NSRange
        var replacement: String
    }

    private struct LineChange: Sendable, Equatable {
        var range: Range<Int>
        var replacement: [Substring]
    }

    func merge(base: String, local: String, external: String) -> ThreeWayMergeResult {
        if local == external { return .unchanged(local) }
        if local == base { return .unchanged(external) }
        if external == base { return .unchanged(local) }

        let localChange = change(from: base, to: local)
        let externalChange = change(from: base, to: external)
        if localChange == externalChange { return .unchanged(local) }
        if !overlaps(localChange, externalChange) {
            return .merged(applying([localChange, externalChange], to: base))
        }

        return mergeLineHunks(base: base, local: local, external: external)
    }

    private func applying(_ changes: [Change], to base: String) -> String {
        let mutable = NSMutableString(string: base)
        for change in changes.sorted(by: {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location > $1.range.location
        }) {
            mutable.replaceCharacters(in: change.range, with: change.replacement)
        }
        return mutable as String
    }

    private func mergeLineHunks(
        base: String,
        local: String,
        external: String
    ) -> ThreeWayMergeResult {
        let baseLines = lineTokens(in: base)
        let localChanges = lineChanges(from: baseLines, to: lineTokens(in: local))
        let externalChanges = lineChanges(
            from: baseLines,
            to: lineTokens(in: external)
        )

        guard let uniqueChanges = combineNonoverlapping(
            localChanges,
            externalChanges
        ) else {
            return .conflict
        }
        var merged = baseLines
        for change in uniqueChanges.sorted(by: {
            if $0.range.lowerBound == $1.range.lowerBound {
                return $0.range.count > $1.range.count
            }
            return $0.range.lowerBound > $1.range.lowerBound
        }) {
            merged.replaceSubrange(change.range, with: change.replacement)
        }
        return .merged(merged.joined())
    }

    private func change(from base: String, to updated: String) -> Change {
        let baseText = base as NSString
        let updatedText = updated as NSString
        let difference = UTF16TextDifference.between(
            original: baseText,
            updated: updatedText
        )
        return Change(
            range: difference.originalRange,
            replacement: updatedText.substring(
                with: difference.updatedRange
            )
        )
    }

    private func combineNonoverlapping(
        _ local: [LineChange],
        _ external: [LineChange]
    ) -> [LineChange]? {
        var localIndex = 0
        var externalIndex = 0
        var combined: [LineChange] = []
        combined.reserveCapacity(local.count + external.count)

        while localIndex < local.count, externalIndex < external.count {
            let localChange = local[localIndex]
            let externalChange = external[externalIndex]
            if localChange == externalChange {
                combined.append(localChange)
                localIndex += 1
                externalIndex += 1
            } else if overlaps(localChange, externalChange) {
                return nil
            } else if precedes(localChange, externalChange) {
                combined.append(localChange)
                localIndex += 1
            } else {
                combined.append(externalChange)
                externalIndex += 1
            }
        }
        combined.append(contentsOf: local[localIndex...])
        combined.append(contentsOf: external[externalIndex...])
        return combined
    }

    private func precedes(_ lhs: LineChange, _ rhs: LineChange) -> Bool {
        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound < rhs.range.lowerBound
        }
        return lhs.range.count > rhs.range.count
    }

    private func overlaps(_ lhs: Change, _ rhs: Change) -> Bool {
        if lhs.range.length == 0, rhs.range.length == 0 {
            return lhs.range.location == rhs.range.location
        }
        let lhsEnd = NSMaxRange(lhs.range)
        let rhsEnd = NSMaxRange(rhs.range)
        if lhs.range.length == 0 {
            return lhs.range.location > rhs.range.location
                && lhs.range.location < rhsEnd
        }
        if rhs.range.length == 0 {
            return rhs.range.location > lhs.range.location
                && rhs.range.location < lhsEnd
        }
        return max(lhs.range.location, rhs.range.location) < min(lhsEnd, rhsEnd)
    }

    private func overlaps(_ lhs: LineChange, _ rhs: LineChange) -> Bool {
        if lhs.range.isEmpty, rhs.range.isEmpty {
            return lhs.range.lowerBound == rhs.range.lowerBound
        }
        if lhs.range.isEmpty {
            return lhs.range.lowerBound > rhs.range.lowerBound
                && lhs.range.lowerBound < rhs.range.upperBound
        }
        if rhs.range.isEmpty {
            return rhs.range.lowerBound > lhs.range.lowerBound
                && rhs.range.lowerBound < lhs.range.upperBound
        }
        return max(lhs.range.lowerBound, rhs.range.lowerBound)
            < min(lhs.range.upperBound, rhs.range.upperBound)
    }

    private func lineChanges(
        from base: [Substring],
        to updated: [Substring]
    ) -> [LineChange] {
        var sharedPrefix = 0
        while sharedPrefix < min(base.count, updated.count),
              base[sharedPrefix] == updated[sharedPrefix] {
            sharedPrefix += 1
        }
        var sharedSuffix = 0
        while sharedSuffix < base.count - sharedPrefix,
              sharedSuffix < updated.count - sharedPrefix,
              base[base.count - sharedSuffix - 1]
                == updated[updated.count - sharedSuffix - 1] {
            sharedSuffix += 1
        }
        let baseCore = Array(
            base[sharedPrefix..<(base.count - sharedSuffix)]
        )
        let updatedCore = Array(
            updated[sharedPrefix..<(updated.count - sharedSuffix)]
        )
        guard !baseCore.isEmpty || !updatedCore.isEmpty else { return [] }

        let difference = updatedCore.difference(from: baseCore)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removals.insert(offset)
            case let .insert(offset, _, _):
                insertions.insert(offset)
            }
        }

        var changes: [LineChange] = []
        var baseIndex = 0
        var updatedIndex = 0
        while baseIndex < baseCore.count || updatedIndex < updatedCore.count {
            if removals.contains(baseIndex) || insertions.contains(updatedIndex) {
                let start = sharedPrefix + baseIndex
                var replacement: [Substring] = []
                repeat {
                    var advanced = false
                    while updatedIndex < updatedCore.count,
                          insertions.contains(updatedIndex) {
                        replacement.append(updatedCore[updatedIndex])
                        updatedIndex += 1
                        advanced = true
                    }
                    while baseIndex < baseCore.count,
                          removals.contains(baseIndex) {
                        baseIndex += 1
                        advanced = true
                    }
                    if !advanced { break }
                } while removals.contains(baseIndex)
                    || insertions.contains(updatedIndex)
                changes.append(
                    LineChange(
                        range: start..<(sharedPrefix + baseIndex),
                        replacement: replacement
                    )
                )
            } else if baseIndex < baseCore.count,
                      updatedIndex < updatedCore.count {
                guard baseCore[baseIndex] == updatedCore[updatedIndex] else {
                    changes.append(
                        LineChange(
                            range: (sharedPrefix + baseIndex)..<(base.count - sharedSuffix),
                            replacement: Array(
                                updatedCore[updatedIndex...]
                            )
                        )
                    )
                    break
                }
                baseIndex += 1
                updatedIndex += 1
            } else {
                changes.append(
                    LineChange(
                        range: (sharedPrefix + baseIndex)..<(base.count - sharedSuffix),
                        replacement: updatedIndex < updatedCore.count
                            ? Array(updatedCore[updatedIndex...])
                            : []
                    )
                )
                break
            }
        }
        return changes
    }

    private func lineTokens(in text: String) -> [Substring] {
        let scalars = text.unicodeScalars
        var result: [Substring] = []
        var lineStart = scalars.startIndex
        var cursor = scalars.startIndex
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            var tokenEnd = scalars.index(after: cursor)
            if scalar.value == 0x000D {
                if tokenEnd < scalars.endIndex,
                   scalars[tokenEnd].value == 0x000A {
                    tokenEnd = scalars.index(after: tokenEnd)
                }
                result.append(text[lineStart..<tokenEnd])
                lineStart = tokenEnd
            } else if scalar.value == 0x000A {
                result.append(text[lineStart..<tokenEnd])
                lineStart = tokenEnd
            }
            cursor = tokenEnd
        }
        if lineStart < scalars.endIndex {
            result.append(text[lineStart..<scalars.endIndex])
        }
        return result
    }
}
