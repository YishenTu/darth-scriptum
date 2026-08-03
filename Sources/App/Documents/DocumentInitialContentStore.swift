import Foundation

/// Bridges AppKit's background document initialization to main-actor live
/// document state without exposing the coordinator across threads.
final class DocumentInitialContentStore: @unchecked Sendable {
    struct Content: Sendable {
        let snapshot: DocumentSnapshot
        let data: Data
    }

    private let lock = NSLock()
    private var content: Content?

    func stage(_ content: Content) {
        lock.withLock {
            self.content = content
        }
    }

    func take() -> Content? {
        lock.withLock {
            defer { content = nil }
            return content
        }
    }
}
