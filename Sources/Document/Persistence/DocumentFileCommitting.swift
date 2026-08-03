import Foundation

protocol DocumentFileCommitting: Sendable {
    func commit(_ token: PendingSaveToken) throws -> FileCommitResult
}
