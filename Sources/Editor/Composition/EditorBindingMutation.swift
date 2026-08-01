import Foundation

/// A character mutation reported by the native text storage.
///
/// The range is expressed in the editor's presented text. Revision and length
/// guards make the mutation safe to use as a fast-path hint; ambiguous or
/// transformed editor transactions fall back to full binding reconciliation.
struct EditorBindingMutation: Equatable {
    let range: NSRange
    let replacement: String
    let sourceRevisionNumber: UInt64
    let presentedSourceRange: NSRange
    let originalPresentedLength: Int
    let updatedPresentedLength: Int
}

@MainActor
final class EditorBindingMutationAccumulator {
    private var pendingMutation: EditorBindingMutation?
    private var isAmbiguous = false
    private(set) var mutationConsumptionCount = 0

    func record(_ mutation: EditorBindingMutation) {
        guard pendingMutation == nil, !isAmbiguous else {
            pendingMutation = nil
            isAmbiguous = true
            return
        }
        pendingMutation = mutation
    }

    func consume() -> EditorBindingMutation? {
        defer { reset() }
        guard !isAmbiguous, let pendingMutation else { return nil }
        mutationConsumptionCount += 1
        return pendingMutation
    }

    func reset() {
        pendingMutation = nil
        isAmbiguous = false
    }
}
