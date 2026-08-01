import Foundation

/// A typed, durable failure that is safe to project to synchronization.
///
/// The store deliberately does not expose Foundation or POSIX errors to the
/// reducer. Those errors do not identify whether recovery evidence remains
/// intact, while each value below has a fail-closed recovery policy.
enum RecoveryStoreIssue: LocalizedError, Sendable, Equatable {
    case malformedData
    case unsupportedSchema
    case unavailable
    case unexpectedMutationGeneration
    case unexpectedRecoveryRecords
    case conflictingEntryID
    case missingRecoveryEntry
    case recoveryEntryEvicted
    case mutationGenerationExhausted
    case unreadableMigrationJournal
    case unreadableDeletionJournal

    var errorDescription: String? {
        switch self {
        case .malformedData:
            "Recovery data is malformed and has been preserved for retry."
        case .unsupportedSchema:
            "Recovery data uses a newer unsupported schema and has been preserved."
        case .unavailable:
            "Recovery storage is temporarily unavailable."
        case .unexpectedMutationGeneration:
            "The recovery store changed before the requested mutation."
        case .unexpectedRecoveryRecords:
            "The recovery records changed before the requested mutation."
        case .conflictingEntryID:
            "The recovery entry identifier is already in use."
        case .missingRecoveryEntry:
            "The requested recovery entry is unavailable."
        case .recoveryEntryEvicted:
            "The recovery entry could not be retained."
        case .mutationGenerationExhausted:
            "The recovery store generation cannot advance further."
        case .unreadableMigrationJournal:
            "The recovery migration journal is unreadable."
        case .unreadableDeletionJournal:
            "The recovery deletion journal is unreadable."
        }
    }
}

/// Kept as a source-compatible name for narrow diagnostic callers. New code
/// should use `RecoveryStoreIssue`, which also models startup failures.
typealias SessionRecoveryStoreError = RecoveryStoreIssue
