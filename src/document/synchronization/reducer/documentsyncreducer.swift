import Foundation

// The pure synchronization reducer exposes one event dispatcher. Focused extension
// files hold its transition domains and share only reducer-internal helpers.
enum DocumentSyncReducer {
    static let localSaveDelay: Duration = .milliseconds(100)
    static let externalReadDelay: Duration = .zero
    static let closeDeadline: Duration = .seconds(30)

    static func reduce(
        _ state: DocumentSyncState,
        event: DocumentSyncEvent
    ) -> DocumentSyncTransition {
        switch event {
        case .closed(let token):
            return closeCommitted(state, token: token)
        case .closeCommitted(let token):
            return closeCommitted(state, token: token)
        case .closeCancelled(let token):
            return closeCancelled(state, token: token)
        default:
            guard state.lifecycle != .closed else { return unchanged(state) }
        }

        switch event {
        case .started:
            return started(state)
        case .saveRequested:
            return saveRequested(state)
        case .attach(let identity, let url, let durableBaseline):
            return attach(
                state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        case .fileMoved(let identity, let url, let durableBaseline):
            return relocate(
                state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        case .saveAsAttached(let identity, let url, let durableBaseline):
            return saveAsAttached(
                state,
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        case .detach:
            return detach(state)
        case .sourceChanged(let revision, let format):
            return sourceChanged(state, revision: revision, format: format)
        case .deadlineFired(let deadline):
            return deadlineFired(state, deadline: deadline)
        case .savePrepared(let token, let pendingSave):
            return savePrepared(state, token: token, pendingSave: pendingSave)
        case .saveFinished(let token, let completion):
            return saveFinished(state, token: token, completion: completion)
        case .commitFailed(let token, let disposition):
            return commitFailed(
                state,
                token: token,
                disposition: disposition
            )
        case .commitReconciliationFinished(let token, let result):
            return commitReconciliationFinished(
                state,
                token: token,
                result: result
            )
        case .monitorSignaled(let token):
            return monitorSignaled(state, token: token)
        case .externalReadFinished(let token, let result):
            return externalReadFinished(state, token: token, result: result)
        case .mergeFinished(let token, let result):
            return mergeFinished(state, token: token, result: result)
        case .recoveryFinished(let token, let result):
            return recoveryFinished(state, token: token, result: result)
        case .operationFailed(let token, let failure):
            return operationFailed(state, token: token, failure: failure)
        case .retry:
            return retry(state)
        case .restoreLocalRecovery:
            return restoreLocalRecovery(state)
        case .discardRawRecovery:
            return discardRawRecovery(state)
        case .requestClose:
            return requestClose(state)
        case .closeCommitted, .closeCancelled, .closed:
            return unchanged(state)
        }
    }
}
