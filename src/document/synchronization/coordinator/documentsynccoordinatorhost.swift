import Foundation

/// Compatibility host used by existing non-AppKit coordinator tests. New
/// document hosts should conform to `DocumentSyncCoordinatorHost` so commits
/// and close decisions retain their full reducer token.
@MainActor
protocol DocumentSyncCoordinatorDelegate: AnyObject {
    var synchronizationFileURL: URL? { get }

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave token: PendingSaveToken
    )

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        acceptedExternalFileAt url: URL,
        hasLocalChanges: Bool
    )
}

/// The narrow AppKit host boundary. A host receives the complete immutable
/// request issued by the reducer and returns only the matching full token.
@MainActor
protocol DocumentSyncCoordinatorHost: DocumentSyncCoordinatorDelegate {
    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave request: DocumentSyncSaveCommitRequest
    )

    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        resolveClose resolution: DocumentSyncCloseResolution
    )
}

extension DocumentSyncCoordinatorHost {
    func syncCoordinator(
        _ coordinator: DocumentSyncCoordinator,
        requestSave token: PendingSaveToken
    ) {
        // Typed hosts never receive the legacy generation-only callback.
    }
}
