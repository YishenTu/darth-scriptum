import Foundation

enum DocumentFileAccessError: Error, Sendable, Equatable {
    case synchronousAccessFromMainThread
}

/// The sole asynchronous boundary for blocking document and recovery I/O.
///
/// Foundation file APIs and Darwin durability calls can block for arbitrary
/// durations. Work submitted here runs on a dedicated utility queue instead
/// of the main actor or Swift's cooperative executor.
enum DocumentFileAccess {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.darthscriptum.document-file-access",
            qos: .utility
        )
        queue.setSpecific(key: queueKey, value: 1)
        return queue
    }()

    static func perform<Value: Sendable>(
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

    /// NSDocument invokes an asynchronous write on its write worker after
    /// `canAsynchronouslyWrite` returns true. Its synchronous override shape
    /// cannot await, so it is explicitly routed through the same owned queue.
    static func performSynchronously<Value: Sendable>(
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
