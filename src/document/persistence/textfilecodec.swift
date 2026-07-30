import Foundation

/// Immutable byte evidence minted only after the codec has encoded the exact
/// captured snapshot. Save commits consume this value instead of independently
/// supplied snapshot, data, and digest fields.
struct DocumentSyncPreparedSavePayload: Sendable, Equatable {
    let id: UUID
    let snapshot: DocumentSnapshot
    let encodedData: Data
    let contentFingerprint: FileFingerprint

    fileprivate init(
        id: UUID = UUID(),
        snapshot: DocumentSnapshot,
        encodedData: Data
    ) {
        self.id = id
        self.snapshot = snapshot
        self.encodedData = encodedData
        contentFingerprint = FileFingerprint.make(data: encodedData)
    }

    /// This defensive check is intentionally used only by off-main executors.
    /// Reducer transitions use the immutable receipt and never encode or hash.
    nonisolated func isExactEncoding() -> Bool {
        guard let expected = try? TextFileCodec.encode(snapshot) else {
            return false
        }
        return expected == encodedData
            && FileFingerprint.make(data: encodedData) == contentFingerprint
    }
}

/// A baseline minted from verified file bytes or a verified committed payload.
/// Reducer state never accepts an independently supplied snapshot/fingerprint
/// pair as durable file authority.
struct DocumentSyncDurableBaseline: Sendable, Equatable {
    let documentIdentity: DocumentIdentity
    let snapshot: DocumentSnapshot
    let fingerprint: FileFingerprint
    let sourceRevision: SourceRevision
    let commitGeneration: UInt64

    fileprivate init(
        documentIdentity: DocumentIdentity,
        snapshot: DocumentSnapshot,
        fingerprint: FileFingerprint,
        sourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) {
        self.documentIdentity = documentIdentity
        self.snapshot = snapshot
        self.fingerprint = fingerprint
        self.sourceRevision = sourceRevision
        self.commitGeneration = commitGeneration
    }

    var asDurableFileState: DurableFileState {
        DurableFileState(
            snapshot: snapshot,
            fingerprint: fingerprint,
            generation: commitGeneration
        )
    }

    static func fromExternalChange(
        _ change: DocumentSyncExternalChange,
        sourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) -> DocumentSyncDurableBaseline {
        DocumentSyncDurableBaseline(
            documentIdentity: change.identity,
            snapshot: change.snapshot,
            fingerprint: change.fingerprint,
            sourceRevision: sourceRevision,
            commitGeneration: commitGeneration
        )
    }

    static func fromCommittedPayload(
        _ pendingSave: PendingSaveToken,
        documentIdentity: DocumentIdentity,
        committedFingerprint: FileFingerprint,
        sourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) -> DocumentSyncDurableBaseline? {
        guard DocumentIdentity.make(url: pendingSave.targetURL)
                == documentIdentity,
              pendingSave.contentFingerprint.byteCount
                == committedFingerprint.byteCount,
              pendingSave.contentFingerprint.contentDigest
                == committedFingerprint.contentDigest else {
            return nil
        }
        return DocumentSyncDurableBaseline(
            documentIdentity: documentIdentity,
            snapshot: pendingSave.snapshot,
            fingerprint: committedFingerprint,
            sourceRevision: sourceRevision,
            commitGeneration: commitGeneration
        )
    }
}

/// A file observation whose fingerprint was computed from the same immutable
/// bytes consumed by the decoder. The reducer never accepts a loose
/// snapshot/fingerprint pair as disk authority.
struct DocumentSyncExternalReadObservation: Sendable, Equatable {
    let targetURL: URL
    let identity: DocumentIdentity
    let fingerprint: FileFingerprint

    fileprivate init(
        targetURL: URL,
        identity: DocumentIdentity,
        fingerprint: FileFingerprint
    ) {
        self.targetURL = targetURL
        self.identity = identity
        self.fingerprint = fingerprint
    }
}

/// A decoded external/raw file payload tied to the bytes that produced both
/// its snapshot and fingerprint.
struct DocumentSyncExternalChange: Sendable, Equatable {
    let targetURL: URL
    let identity: DocumentIdentity
    let snapshot: DocumentSnapshot
    let fingerprint: FileFingerprint

    fileprivate init(
        targetURL: URL,
        identity: DocumentIdentity,
        snapshot: DocumentSnapshot,
        fingerprint: FileFingerprint
    ) {
        self.targetURL = targetURL
        self.identity = identity
        self.snapshot = snapshot
        self.fingerprint = fingerprint
    }
}

enum TextFileCodec {
    enum EvidenceError: Error, Equatable {
        case fingerprintDoesNotMatchPayload
        case identityDoesNotMatchTarget
    }

    /// Encodes the supplied immutable snapshot and returns the sole payload
    /// capability accepted by a save commit.
    nonisolated static func prepareSavePayload(
        for snapshot: DocumentSnapshot
    ) throws -> DocumentSyncPreparedSavePayload {
        DocumentSyncPreparedSavePayload(
            snapshot: snapshot,
            encodedData: try encode(snapshot)
        )
    }

    nonisolated static func durableBaseline(
        data: Data,
        targetURL: URL,
        fingerprint: FileFingerprint,
        documentIdentity: DocumentIdentity,
        sourceRevision: SourceRevision,
        commitGeneration: UInt64
    ) throws -> DocumentSyncDurableBaseline {
        guard fingerprintMatches(data: data, fingerprint: fingerprint) else {
            throw EvidenceError.fingerprintDoesNotMatchPayload
        }
        let canonicalTargetURL = canonicalTargetURL(targetURL)
        guard DocumentIdentity.make(url: canonicalTargetURL) == documentIdentity else {
            throw EvidenceError.identityDoesNotMatchTarget
        }
        return DocumentSyncDurableBaseline(
            documentIdentity: documentIdentity,
            snapshot: try decode(data),
            fingerprint: fingerprint,
            sourceRevision: sourceRevision,
            commitGeneration: commitGeneration
        )
    }

    nonisolated static func externalReadObservation(
        data: Data,
        targetURL: URL,
        identity: DocumentIdentity,
        fingerprint: FileFingerprint
    ) throws -> DocumentSyncExternalReadObservation {
        guard fingerprintMatches(data: data, fingerprint: fingerprint) else {
            throw EvidenceError.fingerprintDoesNotMatchPayload
        }
        let canonicalTargetURL = canonicalTargetURL(targetURL)
        guard DocumentIdentity.make(url: canonicalTargetURL) == identity else {
            throw EvidenceError.identityDoesNotMatchTarget
        }
        return DocumentSyncExternalReadObservation(
            targetURL: canonicalTargetURL,
            identity: identity,
            fingerprint: fingerprint
        )
    }

    nonisolated static func decodeExternalChange(
        data: Data,
        targetURL: URL,
        identity: DocumentIdentity,
        fingerprint: FileFingerprint
    ) throws -> DocumentSyncExternalChange {
        guard fingerprintMatches(data: data, fingerprint: fingerprint) else {
            throw EvidenceError.fingerprintDoesNotMatchPayload
        }
        let canonicalTargetURL = canonicalTargetURL(targetURL)
        guard DocumentIdentity.make(url: canonicalTargetURL) == identity else {
            throw EvidenceError.identityDoesNotMatchTarget
        }
        return DocumentSyncExternalChange(
            targetURL: canonicalTargetURL,
            identity: identity,
            snapshot: try decode(data),
            fingerprint: fingerprint
        )
    }

    private nonisolated static func canonicalTargetURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    nonisolated static func decode(_ data: Data) throws -> DocumentSnapshot {
        let encoding: TextEncoding
        let text: String

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8WithBOM
            guard let value = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            guard let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            guard let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        } else {
            encoding = .utf8
            guard let value = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        }

        let newlineCounts = countNewlines(in: text)

        return DocumentSnapshot(
            text: text,
            format: TextFileFormat(
                encoding: encoding,
                dominantNewline: newlineCounts.crlf > newlineCounts.lf
                    ? .crlf
                    : .lf,
                hasFinalNewline: text.utf16.last == 0x000A
            )
        )
    }

    nonisolated static func encode(_ snapshot: DocumentSnapshot) throws -> Data {
        let encoding: String.Encoding
        let bom: [UInt8]
        switch snapshot.format.encoding {
        case .utf8:
            encoding = .utf8
            bom = []
        case .utf8WithBOM:
            encoding = .utf8
            bom = [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian:
            encoding = .utf16LittleEndian
            bom = [0xFF, 0xFE]
        case .utf16BigEndian:
            encoding = .utf16BigEndian
            bom = [0xFE, 0xFF]
        }
        guard let body = snapshot.text.data(
            using: encoding,
            allowLossyConversion: false
        ) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        var encoded = Data()
        encoded.reserveCapacity(bom.count + body.count)
        encoded.append(contentsOf: bom)
        encoded.append(body)
        return encoded
    }

    private nonisolated static func countNewlines(
        in text: String
    ) -> (crlf: Int, lf: Int) {
        var crlf = 0
        var lf = 0
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x000A {
                if previousWasCarriageReturn {
                    crlf += 1
                } else {
                    lf += 1
                }
            }
            previousWasCarriageReturn = scalar.value == 0x000D
        }
        return (crlf, lf)
    }

    private nonisolated static func fingerprintMatches(
        data: Data,
        fingerprint: FileFingerprint
    ) -> Bool {
        let intrinsic = FileFingerprint.make(
            data: data,
            resourceIdentifier: fingerprint.resourceIdentifier
        )
        return intrinsic == fingerprint
    }
}
