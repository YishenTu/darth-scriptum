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
    static let maximumChangedCoreUTF8ByteCount = 8 * 1_024 * 1_024
    static let maximumChangedLineCount = 20_000
    static let maximumLineDifferenceWork = 4_000_000
    private static let cancellationStride = 64 * 1_024

    static func supportsLineDifference(
        baseLineCount: Int,
        updatedLineCount: Int
    ) -> Bool {
        guard baseLineCount >= 0, updatedLineCount >= 0 else {
            return false
        }
        let (work, overflow) = baseLineCount.multipliedReportingOverflow(
            by: updatedLineCount
        )
        return !overflow && work <= maximumLineDifferenceWork
    }

    nonisolated func result(
        for request: DocumentSyncMergeRequest
    ) -> DocumentSyncMergeResult {
        try! result(for: request, cancellationCheck: {})
    }

    nonisolated func cancellableResult(
        for request: DocumentSyncMergeRequest
    ) throws -> DocumentSyncMergeResult {
        try result(
            for: request,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    private nonisolated func result(
        for request: DocumentSyncMergeRequest,
        cancellationCheck: () throws -> Void
    ) throws -> DocumentSyncMergeResult {
        let outcome: DocumentSyncMergeResult.Outcome
        switch try mergeCancellable(
            base: request.base?.text ?? "",
            local: request.local.text,
            external: request.external.text,
            cancellationCheck: cancellationCheck
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
        try! mergeCancellable(
            base: base,
            local: local,
            external: external,
            cancellationCheck: {}
        )
    }

    func mergeCancellable(
        base: String,
        local: String,
        external: String,
        cancellationCheck: () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> ThreeWayMergeResult {
        try cancellationCheck()
        let localMatchesExternal = try stringsEqual(
            local,
            external,
            cancellationCheck
        )
        let localMatchesBase = try stringsEqual(local, base, cancellationCheck)
        let externalMatchesBase = try stringsEqual(
            external,
            base,
            cancellationCheck
        )

        let localChange = try change(
            from: base,
            to: local,
            cancellationCheck: cancellationCheck
        )
        let externalChange = try change(
            from: base,
            to: external,
            cancellationCheck: cancellationCheck
        )
        guard
            try changedCoreIsSupported(
                in: base,
                change: localChange,
                cancellationCheck: cancellationCheck
            ),
            try changedCoreIsSupported(
                in: base,
                change: externalChange,
                cancellationCheck: cancellationCheck
            )
        else {
            return .conflict
        }
        if localMatchesExternal {
            return .unchanged(local)
        }
        if localMatchesBase {
            return .unchanged(external)
        }
        if externalMatchesBase {
            return .unchanged(local)
        }
        if localChange == externalChange { return .unchanged(local) }
        if !overlaps(localChange, externalChange) {
            return .merged(
                try applying(
                    [localChange, externalChange],
                    to: base,
                    cancellationCheck: cancellationCheck
                )
            )
        }

        return try mergeLineHunks(
            base: base,
            local: local,
            external: external,
            localChange: localChange,
            externalChange: externalChange,
            cancellationCheck: cancellationCheck
        )
    }

    private func applying(
        _ changes: [Change],
        to base: String,
        cancellationCheck: () throws -> Void
    ) throws -> String {
        let mutable = NSMutableString(string: base)
        for change in changes.sorted(by: {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location > $1.range.location
        }) {
            try cancellationCheck()
            mutable.replaceCharacters(in: change.range, with: change.replacement)
        }
        try cancellationCheck()
        return mutable as String
    }

    private func mergeLineHunks(
        base: String,
        local: String,
        external: String,
        localChange: Change,
        externalChange: Change,
        cancellationCheck: () throws -> Void
    ) throws -> ThreeWayMergeResult {
        let baseText = base as NSString
        let localText = local as NSString
        let externalText = external as NSString
        let changedStart = min(
            localChange.range.location,
            externalChange.range.location
        )
        let changedEnd = max(
            NSMaxRange(localChange.range),
            NSMaxRange(externalChange.range)
        )
        let baseWindow = try lineWindow(
            in: baseText,
            containing: NSRange(
                location: changedStart,
                length: changedEnd - changedStart
            ),
            cancellationCheck: cancellationCheck
        )
        let localWindow = NSRange(
            location: baseWindow.location,
            length: baseWindow.length - localChange.range.length
                + (localChange.replacement as NSString).length
        )
        let externalWindow = NSRange(
            location: baseWindow.location,
            length: baseWindow.length - externalChange.range.length
                + (externalChange.replacement as NSString).length
        )
        guard NSMaxRange(localWindow) <= localText.length,
            NSMaxRange(externalWindow) <= externalText.length
        else {
            return .conflict
        }

        let baseCore = baseText.substring(with: baseWindow)
        let localCore = localText.substring(with: localWindow)
        let externalCore = externalText.substring(with: externalWindow)
        guard
            try textIsWithinChangedCoreLimits(
                baseCore,
                cancellationCheck: cancellationCheck
            ),
            try textIsWithinChangedCoreLimits(
                localCore,
                cancellationCheck: cancellationCheck
            ),
            try textIsWithinChangedCoreLimits(
                externalCore,
                cancellationCheck: cancellationCheck
            )
        else {
            return .conflict
        }

        let baseLines = try lineTokens(
            in: baseCore,
            cancellationCheck: cancellationCheck
        )
        guard
            let localChanges = try lineChanges(
                from: baseLines,
                to: lineTokens(
                    in: localCore,
                    cancellationCheck: cancellationCheck
                ),
                cancellationCheck: cancellationCheck
            ),
            let externalChanges = try lineChanges(
                from: baseLines,
                to: lineTokens(
                    in: externalCore,
                    cancellationCheck: cancellationCheck
                ),
                cancellationCheck: cancellationCheck
            )
        else {
            return .conflict
        }

        guard
            let uniqueChanges = try combineNonoverlapping(
                localChanges,
                externalChanges,
                cancellationCheck: cancellationCheck
            )
        else {
            return .conflict
        }
        var merged = baseLines
        for change in uniqueChanges.sorted(by: {
            if $0.range.lowerBound == $1.range.lowerBound {
                return $0.range.count > $1.range.count
            }
            return $0.range.lowerBound > $1.range.lowerBound
        }) {
            try cancellationCheck()
            merged.replaceSubrange(change.range, with: change.replacement)
        }
        try cancellationCheck()
        let prefix = baseText.substring(
            with: NSRange(location: 0, length: baseWindow.location)
        )
        let suffix = baseText.substring(
            from: NSMaxRange(baseWindow)
        )
        return .merged(prefix + merged.joined() + suffix)
    }

    private func lineWindow(
        in text: NSString,
        containing range: NSRange,
        cancellationCheck: () throws -> Void
    ) throws -> NSRange {
        var start = range.location
        var scanned = 0
        while start > 0, !isLineBoundary(start, in: text) {
            start -= 1
            scanned += 1
            if scanned.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }

        var end = NSMaxRange(range)
        while end < text.length, !isLineBoundary(end, in: text) {
            end += 1
            scanned += 1
            if scanned.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }
        try cancellationCheck()
        return NSRange(location: start, length: end - start)
    }

    private func isLineBoundary(_ location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return true }
        guard location < text.length else { return true }
        let previous = text.character(at: location - 1)
        if previous == 0x000A { return true }
        return previous == 0x000D && text.character(at: location) != 0x000A
    }

    private func change(
        from base: String,
        to updated: String,
        cancellationCheck: () throws -> Void
    ) throws -> Change {
        let baseText = base as NSString
        let updatedText = updated as NSString
        var prefix = 0
        let sharedLength = min(baseText.length, updatedText.length)
        while prefix < sharedLength,
            baseText.character(at: prefix) == updatedText.character(at: prefix)
        {
            prefix += 1
            if prefix.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }
        if UTF16TextDifference.splitsSurrogatePair(at: prefix, in: baseText)
            || UTF16TextDifference.splitsSurrogatePair(at: prefix, in: updatedText)
        {
            prefix -= 1
        }

        var suffix = 0
        while suffix < baseText.length - prefix,
            suffix < updatedText.length - prefix,
            baseText.character(at: baseText.length - suffix - 1)
                == updatedText.character(at: updatedText.length - suffix - 1)
        {
            suffix += 1
            if suffix.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }
        if UTF16TextDifference.splitsSurrogatePair(
            at: baseText.length - suffix,
            in: baseText
        )
            || UTF16TextDifference.splitsSurrogatePair(
                at: updatedText.length - suffix,
                in: updatedText
            )
        {
            suffix -= 1
        }
        try cancellationCheck()
        let originalRange = NSRange(
            location: prefix,
            length: baseText.length - prefix - suffix
        )
        let updatedRange = NSRange(
            location: prefix,
            length: updatedText.length - prefix - suffix
        )
        return Change(
            range: originalRange,
            replacement: updatedText.substring(with: updatedRange)
        )
    }

    private func changedCoreIsSupported(
        in base: String,
        change: Change,
        cancellationCheck: () throws -> Void
    ) throws -> Bool {
        let baseCore = (base as NSString).substring(with: change.range)
        guard
            try textIsWithinChangedCoreLimits(
                baseCore,
                cancellationCheck: cancellationCheck
            )
        else {
            return false
        }
        return try textIsWithinChangedCoreLimits(
            change.replacement,
            cancellationCheck: cancellationCheck
        )
    }

    private func textIsWithinChangedCoreLimits(
        _ text: String,
        cancellationCheck: () throws -> Void
    ) throws -> Bool {
        if let byteCount = text.utf8.withContiguousStorageIfAvailable({ $0.count }),
            byteCount > Self.maximumChangedCoreUTF8ByteCount
        {
            return false
        }

        var byteCount = 0
        var lineCount = 0
        var previousWasCarriageReturn = false
        var endedWithLineBreak = false
        for byte in text.utf8 {
            byteCount += 1
            guard byteCount <= Self.maximumChangedCoreUTF8ByteCount else {
                return false
            }
            if byte == 0x0A {
                lineCount += 1
                previousWasCarriageReturn = false
                endedWithLineBreak = true
            } else {
                if previousWasCarriageReturn {
                    lineCount += 1
                }
                previousWasCarriageReturn = byte == 0x0D
                endedWithLineBreak = previousWasCarriageReturn
            }
            guard lineCount <= Self.maximumChangedLineCount else {
                return false
            }
            if byteCount.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }
        if previousWasCarriageReturn {
            lineCount += 1
        } else if !text.isEmpty, !endedWithLineBreak {
            lineCount += 1
        }
        try cancellationCheck()
        return lineCount <= Self.maximumChangedLineCount
    }

    private func stringsEqual(
        _ lhs: String,
        _ rhs: String,
        _ cancellationCheck: () throws -> Void
    ) throws -> Bool {
        let lhsBytes = lhs.utf8
        let rhsBytes = rhs.utf8
        guard lhsBytes.count == rhsBytes.count else { return false }
        var lhsIndex = lhsBytes.startIndex
        var rhsIndex = rhsBytes.startIndex
        var compared = 0
        while lhsIndex < lhsBytes.endIndex {
            guard lhsBytes[lhsIndex] == rhsBytes[rhsIndex] else { return false }
            lhsBytes.formIndex(after: &lhsIndex)
            rhsBytes.formIndex(after: &rhsIndex)
            compared += 1
            if compared.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }
        try cancellationCheck()
        return true
    }

    private func combineNonoverlapping(
        _ local: [LineChange],
        _ external: [LineChange],
        cancellationCheck: () throws -> Void
    ) throws -> [LineChange]? {
        var localIndex = 0
        var externalIndex = 0
        var combined: [LineChange] = []
        combined.reserveCapacity(local.count + external.count)

        while localIndex < local.count, externalIndex < external.count {
            try cancellationCheck()
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
        to updated: [Substring],
        cancellationCheck: () throws -> Void
    ) throws -> [LineChange]? {
        var sharedPrefix = 0
        while sharedPrefix < min(base.count, updated.count),
            base[sharedPrefix] == updated[sharedPrefix]
        {
            sharedPrefix += 1
            if sharedPrefix.isMultiple(of: 1_024) {
                try cancellationCheck()
            }
        }
        var sharedSuffix = 0
        while sharedSuffix < base.count - sharedPrefix,
            sharedSuffix < updated.count - sharedPrefix,
            base[base.count - sharedSuffix - 1]
                == updated[updated.count - sharedSuffix - 1]
        {
            sharedSuffix += 1
            if sharedSuffix.isMultiple(of: 1_024) {
                try cancellationCheck()
            }
        }
        let baseCoreCount = base.count - sharedPrefix - sharedSuffix
        let updatedCoreCount = updated.count - sharedPrefix - sharedSuffix
        guard
            Self.supportsLineDifference(
                baseLineCount: baseCoreCount,
                updatedLineCount: updatedCoreCount
            )
        else {
            return nil
        }
        let baseCore = Array(base[sharedPrefix..<(base.count - sharedSuffix)])
        let updatedCore = Array(
            updated[sharedPrefix..<(updated.count - sharedSuffix)]
        )
        guard !baseCore.isEmpty || !updatedCore.isEmpty else { return [] }
        guard baseCore.count <= Self.maximumChangedLineCount,
            updatedCore.count <= Self.maximumChangedLineCount
        else {
            return [
                LineChange(
                    range: sharedPrefix..<(base.count - sharedSuffix),
                    replacement: updatedCore
                )
            ]
        }

        try cancellationCheck()
        let difference = updatedCore.difference(from: baseCore)
        try cancellationCheck()
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
            try cancellationCheck()
            switch change {
            case .remove(let offset, _, _):
                removals.insert(offset)
            case .insert(let offset, _, _):
                insertions.insert(offset)
            }
        }

        var changes: [LineChange] = []
        var baseIndex = 0
        var updatedIndex = 0
        while baseIndex < baseCore.count || updatedIndex < updatedCore.count {
            try cancellationCheck()
            if removals.contains(baseIndex) || insertions.contains(updatedIndex) {
                let start = sharedPrefix + baseIndex
                var replacement: [Substring] = []
                repeat {
                    var advanced = false
                    while updatedIndex < updatedCore.count,
                        insertions.contains(updatedIndex)
                    {
                        replacement.append(updatedCore[updatedIndex])
                        updatedIndex += 1
                        advanced = true
                    }
                    while baseIndex < baseCore.count,
                        removals.contains(baseIndex)
                    {
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
                updatedIndex < updatedCore.count
            {
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

    private func lineTokens(
        in text: String,
        cancellationCheck: () throws -> Void
    ) throws -> [Substring] {
        let scalars = text.unicodeScalars
        var result: [Substring] = []
        var lineStart = scalars.startIndex
        var cursor = scalars.startIndex
        var scannedScalarCount = 0
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            var tokenEnd = scalars.index(after: cursor)
            if scalar.value == 0x000D {
                if tokenEnd < scalars.endIndex,
                    scalars[tokenEnd].value == 0x000A
                {
                    tokenEnd = scalars.index(after: tokenEnd)
                }
                result.append(text[lineStart..<tokenEnd])
                lineStart = tokenEnd
            } else if scalar.value == 0x000A {
                result.append(text[lineStart..<tokenEnd])
                lineStart = tokenEnd
            }
            cursor = tokenEnd
            scannedScalarCount += 1
            if scannedScalarCount.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
        }
        if lineStart < scalars.endIndex {
            result.append(text[lineStart..<scalars.endIndex])
        }
        try cancellationCheck()
        return result
    }
}
