import Foundation

enum DocumentFileAccessError: Error, Sendable, Equatable {
    case synchronousAccessFromMainThread
}

/// A serial ownership boundary for blocking file work belonging to one
/// document or one globally ordered persistence domain.
final class DocumentFileAccessLane: @unchecked Sendable {
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: queueKey, value: 1)
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `NSDocument` exposes a synchronous write override even when AppKit runs
    /// it on a worker. Reentrant calls execute inline to preserve FIFO without
    /// deadlocking the lane.
    func performSynchronously<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        guard !Thread.isMainThread else {
            throw DocumentFileAccessError.synchronousAccessFromMainThread
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}

enum DocumentFileAccess {
    /// Recovery has one durable journal and therefore deliberately shares one
    /// FIFO lane across store instances.
    static let recovery = DocumentFileAccessLane(
        label: "com.darthscriptum.recovery-file-access"
    )

    static func makeDocumentLane() -> DocumentFileAccessLane {
        DocumentFileAccessLane(
            label: "com.darthscriptum.document-file-access.\(UUID().uuidString)"
        )
    }

    /// Compatibility for recovery-owned call sites while document call sites
    /// migrate to an injected lane.
    static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await recovery.perform(operation)
    }

    static func performSynchronously<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        try recovery.performSynchronously(operation)
    }
}
