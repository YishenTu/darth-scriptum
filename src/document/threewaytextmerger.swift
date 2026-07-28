import Foundation

enum ThreeWayMergeResult: Sendable, Equatable {
    case unchanged(String)
    case merged(String)
    case conflict
}

struct ThreeWayTextMerger: Sendable {
    private struct Change: Sendable, Equatable {
        var range: NSRange
        var replacement: String
    }

    private struct LineChange: Sendable, Equatable {
        var range: Range<Int>
        var replacement: [String]
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
        from base: [String],
        to updated: [String]
    ) -> [LineChange] {
        let difference = updated.difference(from: base)
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
        while baseIndex < base.count || updatedIndex < updated.count {
            if removals.contains(baseIndex) || insertions.contains(updatedIndex) {
                let start = baseIndex
                var replacement: [String] = []
                repeat {
                    var advanced = false
                    while updatedIndex < updated.count,
                          insertions.contains(updatedIndex) {
                        replacement.append(updated[updatedIndex])
                        updatedIndex += 1
                        advanced = true
                    }
                    while baseIndex < base.count, removals.contains(baseIndex) {
                        baseIndex += 1
                        advanced = true
                    }
                    if !advanced { break }
                } while removals.contains(baseIndex)
                    || insertions.contains(updatedIndex)
                changes.append(
                    LineChange(
                        range: start..<baseIndex,
                        replacement: replacement
                    )
                )
            } else if baseIndex < base.count, updatedIndex < updated.count {
                guard base[baseIndex] == updated[updatedIndex] else {
                    changes.append(
                        LineChange(
                            range: baseIndex..<base.count,
                            replacement: Array(updated[updatedIndex...])
                        )
                    )
                    break
                }
                baseIndex += 1
                updatedIndex += 1
            } else {
                changes.append(
                    LineChange(
                        range: baseIndex..<base.count,
                        replacement: updatedIndex < updated.count
                            ? Array(updated[updatedIndex...])
                            : []
                    )
                )
                break
            }
        }
        return changes
    }

    private func lineTokens(in text: String) -> [String] {
        let source = text as NSString
        var result: [String] = []
        var start = 0
        while start < source.length {
            var end = start
            while end < source.length {
                let unit = source.character(at: end)
                if unit == 0x000A || unit == 0x000D { break }
                end += 1
            }
            if end < source.length {
                if source.character(at: end) == 0x000D,
                   end + 1 < source.length,
                   source.character(at: end + 1) == 0x000A {
                    end += 2
                } else {
                    end += 1
                }
            }
            result.append(
                source.substring(
                    with: NSRange(location: start, length: end - start)
                )
            )
            start = end
        }
        return result
    }
}
