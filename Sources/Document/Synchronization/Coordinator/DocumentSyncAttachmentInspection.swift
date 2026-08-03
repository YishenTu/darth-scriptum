import Foundation

enum DocumentSyncAttachmentInspection: Sendable {
    struct Verified: Sendable {
        let targetURL: URL
        let identity: DocumentIdentity
        let sourceRevision: SourceRevision
        let durableBaseline: DocumentSyncDurableBaseline?
        let dataMatchesExpectedBytes: Bool
        let verifiedExternalChange: DocumentSyncExternalChange?
    }

    struct Target: Sendable {
        let targetURL: URL
        let identity: DocumentIdentity
        let sourceRevision: SourceRevision
    }

    case verified(Verified)
    case unavailable(Target)

    var target: Target {
        switch self {
        case .verified(let attachment):
            Target(
                targetURL: attachment.targetURL,
                identity: attachment.identity,
                sourceRevision: attachment.sourceRevision
            )
        case .unavailable(let target):
            target
        }
    }

    var durableBaseline: DocumentSyncDurableBaseline? {
        if case .verified(let attachment) = self {
            return attachment.durableBaseline
        }
        return nil
    }

    var didReadData: Bool {
        if case .verified = self {
            return true
        }
        return false
    }

    static func inspect(
        at targetURL: URL,
        knownData: Data?,
        sourceRevision: SourceRevision,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64,
        requiresFreshTargetObservation: Bool = false
    ) -> DocumentSyncAttachmentInspection {
        let target = attachmentTarget(
            at: targetURL,
            sourceRevision: sourceRevision
        )
        do {
            if requiresFreshTargetObservation, let knownData {
                return .verified(
                    try verifiedAttachmentComparingCurrentData(
                        target: target,
                        knownData: knownData,
                        sourceFormat: sourceFormat,
                        baselineSourceRevision: baselineSourceRevision,
                        commitGeneration: commitGeneration
                    )
                )
            }
            let payload = try TextFileCodec.readVerifiedFilePayload(
                at: targetURL
            )
            return .verified(
                try verifiedAttachment(
                    target: target,
                    data: payload.data,
                    fingerprint: payload.fingerprint,
                    sourceFormat: sourceFormat,
                    baselineSourceRevision: baselineSourceRevision,
                    commitGeneration: commitGeneration
                )
            )
        } catch {
            return .unavailable(target)
        }
    }

    private static func verifiedAttachmentComparingCurrentData(
        target: Target,
        knownData: Data,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> Verified {
        let currentPayload = try TextFileCodec.readVerifiedFilePayload(
            at: target.targetURL
        )
        try TextFileCodec.validateSupportedSize(knownData)
        if currentPayload.data == knownData {
            return try verifiedAttachment(
                target: target,
                data: currentPayload.data,
                fingerprint: currentPayload.fingerprint,
                sourceFormat: sourceFormat,
                baselineSourceRevision: baselineSourceRevision,
                commitGeneration: commitGeneration
            )
        }

        // The captured bytes predate this inspection, so they cannot safely
        // inherit the target's current resource identifier. Keep their
        // intrinsic fingerprint as the provisional baseline and carry the
        // current target as a separate immutable external observation.
        let expected = try verifiedAttachment(
            target: target,
            data: knownData,
            fingerprint: FileFingerprint.make(data: knownData),
            sourceFormat: sourceFormat,
            baselineSourceRevision: baselineSourceRevision,
            commitGeneration: commitGeneration
        )
        let currentChange = try? TextFileCodec.decodeExternalChange(
            data: currentPayload.data,
            targetURL: target.targetURL,
            identity: target.identity,
            fingerprint: currentPayload.fingerprint
        )
        return Verified(
            targetURL: target.targetURL,
            identity: target.identity,
            sourceRevision: target.sourceRevision,
            durableBaseline: expected.durableBaseline,
            dataMatchesExpectedBytes: false,
            verifiedExternalChange: currentChange
        )
    }

    static func inspectSaveAs(
        at targetURL: URL,
        expectedData: Data,
        expectedSnapshot: DocumentSnapshot,
        sourceRevision: SourceRevision,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> DocumentSyncAttachmentInspection {
        guard try TextFileCodec.decode(expectedData) == expectedSnapshot else {
            throw DocumentSyncCoordinatorAttachmentError.invalidSaveAsEvidence
        }
        let target = attachmentTarget(
            at: targetURL,
            sourceRevision: sourceRevision
        )
        do {
            return .verified(
                try verifiedAttachmentComparingCurrentData(
                    target: target,
                    knownData: expectedData,
                    sourceFormat: sourceFormat,
                    baselineSourceRevision: baselineSourceRevision,
                    commitGeneration: commitGeneration
                )
            )
        } catch {
            return .unavailable(target)
        }
    }

    private static func attachmentTarget(
        at targetURL: URL,
        sourceRevision: SourceRevision
    ) -> Target {
        Target(
            targetURL: targetURL,
            identity: DocumentIdentity.make(url: targetURL),
            sourceRevision: sourceRevision
        )
    }

    private static func verifiedAttachment(
        target: Target,
        data: Data,
        fingerprint: FileFingerprint,
        sourceFormat: TextFileFormat,
        baselineSourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> Verified {
        try TextFileCodec.validateSupportedSize(data)
        let snapshot = try? TextFileCodec.decode(data)
        let stampedSourceRevision: SourceRevision?
        if let snapshot {
            stampedSourceRevision =
                snapshot
                    == DocumentSnapshot(
                        text: baselineSourceRevision.text,
                        format: sourceFormat
                    )
                ? baselineSourceRevision
                : SourceRevision(
                    number: baselineSourceRevision.number,
                    text: snapshot.text
                )
        } else {
            stampedSourceRevision = nil
        }
        let durableBaseline = stampedSourceRevision.flatMap { revision in
            try? TextFileCodec.durableBaseline(
                data: data,
                targetURL: target.targetURL,
                fingerprint: fingerprint,
                documentIdentity: target.identity,
                sourceRevision: revision,
                commitGeneration: commitGeneration
            )
        }
        return Verified(
            targetURL: target.targetURL,
            identity: target.identity,
            sourceRevision: target.sourceRevision,
            durableBaseline: durableBaseline,
            dataMatchesExpectedBytes: true,
            verifiedExternalChange: nil
        )
    }
}
