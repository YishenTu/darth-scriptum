import Foundation

final class SaveTransactionBridge: @unchecked Sendable {
    enum BridgeError: LocalizedError {
        case pendingTransactionExists
        case missingTransaction
        case generationMismatch
        case duplicateResult

        var errorDescription: String? {
            switch self {
            case .pendingTransactionExists:
                "A file save is already in progress."
            case .missingTransaction:
                "The file save transaction is missing."
            case .generationMismatch:
                "The file save transaction generation does not match."
            case .duplicateResult:
                "The file save transaction already has a result."
            }
        }
    }

    private struct State {
        var token: PendingSaveToken?
        var result: FileCommitResult?
    }

    private let lock = NSLock()
    private var state = State()

    func install(_ token: PendingSaveToken) throws {
        try withLock {
            guard state.token == nil else {
                throw BridgeError.pendingTransactionExists
            }
            state.token = token
            state.result = nil
        }
    }

    func currentToken() throws -> PendingSaveToken {
        try withLock {
            guard let token = state.token else {
                throw BridgeError.missingTransaction
            }
            return token
        }
    }

    func store(_ result: FileCommitResult) throws {
        try withLock {
            guard let token = state.token else {
                throw BridgeError.missingTransaction
            }
            guard token.generation == result.generation else {
                throw BridgeError.generationMismatch
            }
            guard state.result == nil else {
                throw BridgeError.duplicateResult
            }
            state.result = result
        }
    }

    func finish(generation: UInt64) throws -> FileCommitResult {
        try withLock {
            guard let token = state.token, let result = state.result else {
                throw BridgeError.missingTransaction
            }
            guard token.generation == generation, result.generation == generation else {
                throw BridgeError.generationMismatch
            }
            state = State()
            return result
        }
    }

    func cancel(generation: UInt64) {
        withLock {
            guard state.token?.generation == generation else { return }
            state = State()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
