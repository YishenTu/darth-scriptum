import Foundation

struct DocumentSyncFileAttachment: Sendable, Equatable {
    let identity: DocumentIdentity
    let url: URL
    let epoch: UInt64
}

/// A host has selected a managed file URL, but its canonical identity and
/// durable baseline are still being verified on `DocumentFileAccess`. It is
/// sufficient to keep close handling managed, but must never authorize I/O.
struct DocumentSyncProvisionalFileAttachment: Sendable, Equatable {
    let url: URL
    let epoch: UInt64
}

enum DocumentSyncAttachment: Sendable, Equatable {
    case untitled
    case provisional(DocumentSyncProvisionalFileAttachment)
    case file(DocumentSyncFileAttachment)

    var file: DocumentSyncFileAttachment? {
        guard case .file(let attachment) = self else { return nil }
        return attachment
    }

    var managedFileURL: URL? {
        switch self {
        case .untitled:
            nil
        case .provisional(let attachment):
            attachment.url
        case .file(let attachment):
            attachment.url
        }
    }

    var isManagedFile: Bool {
        managedFileURL != nil
    }
}

/// A host attachment notification that arrived after a save commit became
/// uncancellable. The reducer applies the latest queued transition once that
/// commit has an authoritative result.
enum DocumentSyncPendingAttachmentTransition: Sendable, Equatable {
    case attach(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )
    case detach
    case detachThenAttach(
        identity: DocumentIdentity,
        url: URL,
        durableBaseline: DocumentSyncDurableBaseline?
    )

    func appending(
        _ next: DocumentSyncPendingAttachmentTransition
    ) -> DocumentSyncPendingAttachmentTransition {
        switch (self, next) {
        case (.detach, .attach(let identity, let url, let durableBaseline)),
            (
                .detachThenAttach(_, _, _),
                .attach(
                    let identity,
                    let url,
                    let durableBaseline
                )
            ):
            return .detachThenAttach(
                identity: identity,
                url: url,
                durableBaseline: durableBaseline
            )
        default:
            return next
        }
    }
}
