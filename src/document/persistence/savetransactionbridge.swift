import Foundation

final class SaveTransactionBridge: @unchecked Sendable {
    enum BridgeError: LocalizedError, Equatable {
        case pendingTransactionExists
        case missingTransaction
        case missingTypedTransaction
        case generationMismatch
        case effectTokenMismatch
        case duplicateResult

        var errorDescription: String? {
            switch self {
            case .pendingTransactionExists:
                "A file save is already in progress."
            case .missingTransaction:
                "The file save transaction is missing."
            case .missingTypedTransaction:
                "The file save transaction is not a typed commit request."
            case .generationMismatch:
                "The file save transaction generation does not match."
            case .effectTokenMismatch:
                "The file save transaction effect token does not match."
            case .duplicateResult:
                "The file save transaction already has a result."
            }
        }
    }

    private struct State {
        var token: PendingSaveToken?
        var commitRequest: DocumentSyncSaveCommitRequest?
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
            state.commitRequest = nil
            state.result = nil
        }
    }

    /// Installs the complete immutable commit capability issued by the
    /// reducer. Completion authority belongs to `request.token`, not the
    /// coincidental save generation.
    func install(_ request: DocumentSyncSaveCommitRequest) throws {
        try withLock {
            guard state.token == nil else {
                throw BridgeError.pendingTransactionExists
            }
            guard request.pendingSave.targetURL.standardizedFileURL
                == request.targetURL.standardizedFileURL,
                  request.identity.matches(url: request.targetURL),
                  request.commitGeneration
                    == request.pendingSave.generation else {
                throw BridgeError.generationMismatch
            }
            state.token = request.pendingSave
            state.commitRequest = request
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

    func currentCommitRequest() throws -> DocumentSyncSaveCommitRequest {
        try withLock {
            guard let request = state.commitRequest else {
                if state.token == nil {
                    throw BridgeError.missingTransaction
                }
                throw BridgeError.missingTypedTransaction
            }
            return request
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

    func store(
        _ result: FileCommitResult,
        for token: SyncEffectToken
    ) throws {
        try withLock {
            guard let pendingSave = state.token,
                  let request = state.commitRequest else {
                throw BridgeError.missingTransaction
            }
            guard request.token == token else {
                throw BridgeError.effectTokenMismatch
            }
            guard pendingSave.generation == result.generation else {
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

    func finish(token: SyncEffectToken) throws -> FileCommitResult {
        try withLock {
            guard let request = state.commitRequest,
                  let result = state.result else {
                throw BridgeError.missingTransaction
            }
            guard request.token == token else {
                throw BridgeError.effectTokenMismatch
            }
            guard request.pendingSave.generation == result.generation else {
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

    func cancel(token: SyncEffectToken) {
        withLock {
            guard state.commitRequest?.token == token else { return }
            state = State()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
