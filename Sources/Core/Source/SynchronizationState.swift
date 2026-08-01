enum SynchronizationState: Sendable, Equatable {
    case idle
    case waitingToWrite
    case writing
    case checkingExternalChange
    case reloading
    case merging
    case recoveredConflict
    case readOnly
    case missing
    case failed(String)
    case limitedSyncSafety
    case synchronizationPaused
}
