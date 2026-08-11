import Foundation

/// Immutable source metadata computed from one exact document snapshot.
/// Callers may prepare this receipt off the main actor before installation.
struct PreparedSourceContent: Sendable, Equatable {
    static let synchronousLineIndexLimit = 2 * 1_024 * 1_024

    let snapshot: DocumentSnapshot
    let metrics: DocumentMetrics
    let lineIndex: SourceLineIndex?

    nonisolated init(snapshot: DocumentSnapshot) {
        self.snapshot = snapshot
        metrics = DocumentMetrics(text: snapshot.text)
        if (snapshot.text as NSString).length
            <= Self.synchronousLineIndexLimit
        {
            lineIndex = SourceLineIndex(text: snapshot.text)
        } else {
            lineIndex = nil
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.metrics == rhs.metrics
    }
}
