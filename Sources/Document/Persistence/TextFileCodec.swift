import Darwin
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
        encodedData: Data,
        contentFingerprint: FileFingerprint
    ) {
        self.id = id
        self.snapshot = snapshot
        self.encodedData = encodedData
        self.contentFingerprint = contentFingerprint
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

    func rebased(
        to sourceRevision: SourceRevision
    ) -> DocumentSyncDurableBaseline? {
        guard sourceRevision.text == snapshot.text else { return nil }
        return DocumentSyncDurableBaseline(
            documentIdentity: documentIdentity,
            snapshot: snapshot,
            fingerprint: fingerprint,
            sourceRevision: sourceRevision,
            commitGeneration: commitGeneration
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
        guard
            DocumentIdentity.make(url: pendingSave.targetURL)
                == documentIdentity,
            pendingSave.contentFingerprint.byteCount
                == committedFingerprint.byteCount,
            pendingSave.contentFingerprint.contentDigest
                == committedFingerprint.contentDigest
        else {
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
    static let maximumDocumentByteCount = 64 * 1_024 * 1_024

    enum CodecError: LocalizedError, Equatable {
        case documentTooLarge(byteCount: Int, maximumByteCount: Int)
        case unsupportedFileType

        var errorDescription: String? {
            switch self {
            case .documentTooLarge(let byteCount, let maximumByteCount):
                return "The document is \(byteCount) bytes, exceeding the "
                    + "supported limit of \(maximumByteCount) bytes."
            case .unsupportedFileType:
                return "The document must be a regular file."
            }
        }
    }

    enum EvidenceError: Error, Equatable {
        case fingerprintDoesNotMatchPayload
        case identityDoesNotMatchTarget
    }

    /// Encodes the supplied immutable snapshot and returns the sole payload
    /// capability accepted by a save commit.
    nonisolated static func prepareSavePayload(
        for snapshot: DocumentSnapshot,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> DocumentSyncPreparedSavePayload {
        let encodedData = try encode(
            snapshot,
            cancellationCheck: cancellationCheck
        )
        return DocumentSyncPreparedSavePayload(
            snapshot: snapshot,
            encodedData: encodedData,
            contentFingerprint: try FileFingerprint.makeCancellable(
                data: encodedData,
                cancellationCheck: cancellationCheck
            )
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
        try validateSupportedSize(data)
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
        try validateSupportedSize(data)
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
        try validateSupportedSize(data)
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
        try validateSupportedSize(data)
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
        try encode(snapshot, cancellationCheck: {})
    }

    private nonisolated static func encode(
        _ snapshot: DocumentSnapshot,
        cancellationCheck: () throws -> Void
    ) throws -> Data {
        let chunkByteCount = 64 * 1_024
        try cancellationCheck()
        let expectedByteCount = try encodedByteCount(of: snapshot)
        try validateSupportedSize(expectedByteCount)
        try cancellationCheck()

        var encoded = Data()
        encoded.reserveCapacity(expectedByteCount)
        switch snapshot.format.encoding {
        case .utf8, .utf8WithBOM:
            if snapshot.format.encoding == .utf8WithBOM {
                encoded.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            let bytes = snapshot.text.utf8
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                let end =
                    bytes.index(
                        cursor,
                        offsetBy: chunkByteCount,
                        limitedBy: bytes.endIndex
                    ) ?? bytes.endIndex
                encoded.append(contentsOf: bytes[cursor..<end])
                try cancellationCheck()
                cursor = end
            }
        case .utf16LittleEndian, .utf16BigEndian:
            let isLittleEndian =
                snapshot.format.encoding == .utf16LittleEndian
            encoded.append(
                contentsOf: isLittleEndian
                    ? [0xFF, 0xFE]
                    : [0xFE, 0xFF]
            )
            let codeUnits = snapshot.text.utf16
            var chunk: [UInt8] = []
            chunk.reserveCapacity(chunkByteCount)
            for codeUnit in codeUnits {
                if isLittleEndian {
                    chunk.append(UInt8(truncatingIfNeeded: codeUnit))
                    chunk.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
                } else {
                    chunk.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
                    chunk.append(UInt8(truncatingIfNeeded: codeUnit))
                }
                if chunk.count == chunkByteCount {
                    encoded.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    try cancellationCheck()
                }
            }
            if !chunk.isEmpty {
                encoded.append(contentsOf: chunk)
                try cancellationCheck()
            }
        }
        guard encoded.count == expectedByteCount else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try cancellationCheck()
        return encoded
    }

    private nonisolated static func encodedByteCount(
        of snapshot: DocumentSnapshot
    ) throws -> Int {
        let bodyByteCount: Int
        let bomByteCount: Int
        switch snapshot.format.encoding {
        case .utf8:
            bodyByteCount = snapshot.text.utf8.count
            bomByteCount = 0
        case .utf8WithBOM:
            bodyByteCount = snapshot.text.utf8.count
            bomByteCount = 3
        case .utf16LittleEndian, .utf16BigEndian:
            let (count, overflow) = snapshot.text.utf16.count
                .multipliedReportingOverflow(by: 2)
            guard !overflow else {
                throw CodecError.documentTooLarge(
                    byteCount: .max,
                    maximumByteCount: maximumDocumentByteCount
                )
            }
            bodyByteCount = count
            bomByteCount = 2
        }
        let (byteCount, overflow) = bodyByteCount.addingReportingOverflow(
            bomByteCount
        )
        guard !overflow else {
            throw CodecError.documentTooLarge(
                byteCount: .max,
                maximumByteCount: maximumDocumentByteCount
            )
        }
        return byteCount
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

    nonisolated static func validateSupportedSize(_ data: Data) throws {
        try validateSupportedSize(data.count)
    }

    nonisolated static func validateSupportedSize(
        _ byteCount: Int
    ) throws {
        guard byteCount <= maximumDocumentByteCount else {
            throw CodecError.documentTooLarge(
                byteCount: byteCount,
                maximumByteCount: maximumDocumentByteCount
            )
        }
    }

    nonisolated static func readSupportedData(
        at url: URL,
        followingSymbolicLinks: Bool = true
    ) throws -> Data {
        try withSupportedFileDescriptor(
            at: url,
            followingSymbolicLinks: followingSymbolicLinks
        ) { descriptor, byteCount in
            try readSupportedData(
                from: descriptor,
                expectedByteCount: byteCount
            )
        }
    }

    /// Reads bytes and file identity from one open descriptor. A caller that
    /// needs durable evidence must not combine these bytes with a later path
    /// lookup because the path may have been atomically replaced meanwhile.
    nonisolated static func readVerifiedFilePayload(
        at url: URL,
        followingSymbolicLinks: Bool = true,
        afterReading: () throws -> Void = {}
    ) throws -> VerifiedFilePayload {
        try withSupportedFileDescriptor(
            at: url,
            followingSymbolicLinks: followingSymbolicLinks
        ) { descriptor, byteCount in
            let data = try readSupportedData(
                from: descriptor,
                expectedByteCount: byteCount
            )
            try afterReading()
            return VerifiedFilePayload(
                data: data,
                resourceIdentifier: try resourceIdentifier(
                    for: descriptor
                )
            )
        }
    }

    nonisolated static func resourceIdentifier(
        for descriptor: Int32
    ) throws -> String {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return "\(metadata.st_dev):\(metadata.st_ino)"
    }

    nonisolated static func resourceIdentifier(
        at url: URL,
        followingSymbolicLinks: Bool = true
    ) throws -> String {
        try withSupportedFileDescriptor(
            at: url,
            followingSymbolicLinks: followingSymbolicLinks
        ) { descriptor, _ in
            try resourceIdentifier(for: descriptor)
        }
    }

    nonisolated static func withSupportedFileDescriptor<Value>(
        at url: URL,
        followingSymbolicLinks: Bool = true,
        _ operation: (Int32, Int) throws -> Value
    ) throws -> Value {
        let openFlags =
            O_RDONLY | O_CLOEXEC | O_NONBLOCK
            | (followingSymbolicLinks ? 0 : O_NOFOLLOW)
        let descriptor = url.path.withCString {
            Darwin.open($0, openFlags)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw CodecError.unsupportedFileType
        }
        guard metadata.st_size >= 0,
            UInt64(metadata.st_size) <= UInt64(Int.max)
        else {
            throw CodecError.documentTooLarge(
                byteCount: Int.max,
                maximumByteCount: maximumDocumentByteCount
            )
        }
        try validateSupportedSize(Int(metadata.st_size))

        return try operation(descriptor, Int(metadata.st_size))
    }

    nonisolated static func readSupportedData(
        from descriptor: Int32,
        expectedByteCount: Int
    ) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try validateSupportedSize(expectedByteCount)

        var data = Data()
        data.reserveCapacity(expectedByteCount)
        let readChunkSize = 64 * 1_024
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        while data.count <= maximumDocumentByteCount {
            let allowance = maximumDocumentByteCount - data.count + 1
            guard
                let chunk = try handle.read(
                    upToCount: min(readChunkSize, allowance)
                ), !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
        }
        try validateSupportedSize(data)
        return data
    }
}
