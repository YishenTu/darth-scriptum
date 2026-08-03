import Darwin
import Foundation

struct SafeFileCommitter: DocumentFileCommitting {
    private struct PreparedCandidate {
        let url: URL
        let resourceIdentifier: String
        let replacementDirectoryURL: URL
        let replacementDirectoryResourceIdentifier: String
    }

    enum Strategy: Sendable {
        case automatic
        case coordinatedReplacementOnly
    }

    enum CommitError: LocalizedError, Equatable {
        case invalidPreparedPayload
        case atomicSwapUnavailable
        case atomicSwapFailed
        case targetChangedBeforeCommit
        case targetMissingBeforeCommit

        var errorDescription: String? {
            switch self {
            case .invalidPreparedPayload:
                "The prepared save payload does not match its captured snapshot."
            case .atomicSwapUnavailable:
                "This filesystem cannot safely replace the file in place. Use Save As to write a new file."
            case .atomicSwapFailed:
                "The atomic file replacement failed before changing the destination."
            case .targetChangedBeforeCommit:
                "The file changed while DarthScriptum was preparing to save it."
            case .targetMissingBeforeCommit:
                "The file was removed while DarthScriptum was preparing to save it."
            }
        }
    }

    private let strategy: Strategy
    private let recoveryDirectory: URL
    private let beforeAtomicSwap: (@Sendable () throws -> Void)?
    private let afterAtomicSwap: (@Sendable () throws -> Void)?
    private let beforeRecoveryAcknowledgement: (@Sendable () throws -> Void)?

    init(
        strategy: Strategy = .automatic,
        recoveryDirectory: URL =
            CommitRecoveryJournalStore.defaultRecoveryDirectory,
        beforeAtomicSwap: (@Sendable () throws -> Void)? = nil,
        afterAtomicSwap: (@Sendable () throws -> Void)? = nil,
        beforeRecoveryAcknowledgement:
            (@Sendable () throws -> Void)? = nil
    ) {
        self.strategy = strategy
        self.recoveryDirectory = recoveryDirectory
        self.beforeAtomicSwap = beforeAtomicSwap
        self.afterAtomicSwap = afterAtomicSwap
        self.beforeRecoveryAcknowledgement =
            beforeRecoveryAcknowledgement
    }

    func commit(_ token: PendingSaveToken) throws -> FileCommitResult {
        guard token.preparedPayload.isExactEncoding() else {
            throw CommitError.invalidPreparedPayload
        }
        let fileManager = FileManager.default
        let requestedTargetURL = token.targetURL

        if token.expectedDurableState == nil {
            let committedFingerprint = try writeNewFileExclusively(
                token.encodedData,
                to: requestedTargetURL
            )
            return FileCommitResult(
                generation: token.generation,
                committedFingerprint: committedFingerprint,
                displacedPreimage: nil,
                safety: .coordinatedReplacement
            )
        }
        let targetURL = requestedTargetURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw CommitError.targetMissingBeforeCommit
        }

        let preparedCandidate = try TextFileCodec.withSupportedFileDescriptor(
            at: targetURL,
            followingSymbolicLinks: false
        ) { sourceDescriptor, byteCount in
            let replacementDirectory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: targetURL,
                create: true
            )
            let candidateURL = replacementDirectory.appendingPathComponent(
                "darth-scriptum-\(UUID().uuidString)"
            )
            var didPrepareCandidate = false
            defer {
                if !didPrepareCandidate {
                    _ = candidateURL.path.withCString { Darwin.unlink($0) }
                    _ = replacementDirectory.path.withCString {
                        Darwin.rmdir($0)
                    }
                }
            }
            let replacementDirectoryResourceIdentifier =
                try DurableFileIO.resourceIdentifier(
                    for: replacementDirectory
                )
            let candidateResourceIdentifier = try prepareCandidate(
                at: candidateURL,
                copyingMetadataFrom: sourceDescriptor,
                data: token.encodedData
            )
            let preimage = try TextFileCodec.readSupportedData(
                from: sourceDescriptor,
                expectedByteCount: byteCount
            )
            try validate(
                preimage: preimage,
                descriptor: sourceDescriptor,
                against: token.expectedDurableState
            )
            didPrepareCandidate = true
            return PreparedCandidate(
                url: candidateURL,
                resourceIdentifier: candidateResourceIdentifier,
                replacementDirectoryURL: replacementDirectory,
                replacementDirectoryResourceIdentifier:
                    replacementDirectoryResourceIdentifier
            )
        }
        let replacementDirectory = preparedCandidate.replacementDirectoryURL
        let replacementDirectoryResourceIdentifier =
            preparedCandidate.replacementDirectoryResourceIdentifier
        let candidateURL = preparedCandidate.url
        var retainedRecoveryArtifact: CommitRecoveryArtifact?
        defer {
            if retainedRecoveryArtifact == nil,
                let currentIdentifier =
                    try? DurableFileIO.resourceIdentifier(
                        for: replacementDirectory
                    ),
                currentIdentifier
                    == replacementDirectoryResourceIdentifier
            {
                if fileManager.fileExists(atPath: candidateURL.path) {
                    _ = candidateURL.path.withCString { Darwin.unlink($0) }
                }
                _ = replacementDirectory.path.withCString {
                    Darwin.rmdir($0)
                }
            }
        }

        guard
            let expectedPreimageFingerprint = token.expectedDurableState?
                .fingerprint
        else {
            throw CommitError.targetChangedBeforeCommit
        }
        let preparedRecoveryArtifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: targetURL,
            requestedTargetURL: requestedTargetURL,
            documentIdentity: .make(url: requestedTargetURL),
            commitGeneration: token.generation,
            expectedPreimageFingerprint: expectedPreimageFingerprint,
            committedPayloadFingerprint: token.contentFingerprint,
            recoveryDirectory: recoveryDirectory,
            registeringLiveCommit: true
        )
        defer {
            CommitRecoveryJournalStore.finishLiveCommit(
                preparedRecoveryArtifact
            )
        }
        // Once the prepared journal exists, its candidate must remain owned
        // until durable acknowledgement completes. Any intervening failure is
        // an uncertain commit that reconciliation must still be able to prove.
        retainedRecoveryArtifact = preparedRecoveryArtifact
        try beforeAtomicSwap?()

        let swapResult: Int32
        switch strategy {
        case .automatic:
            swapResult = candidateURL.path.withCString { candidatePath in
                targetURL.path.withCString { targetPath in
                    renameatx_np(
                        AT_FDCWD,
                        candidatePath,
                        AT_FDCWD,
                        targetPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        case .coordinatedReplacementOnly:
            swapResult = -1
            errno = ENOTSUP
        }

        if swapResult == 0 {
            try afterAtomicSwap?()
            try DurableFileIO.synchronizeDirectory(
                targetURL.deletingLastPathComponent()
            )
            try DurableFileIO.synchronizeDirectory(
                replacementDirectory
            )
            let displacedPayload =
                try TextFileCodec.readVerifiedFilePayload(
                    at: candidateURL,
                    followingSymbolicLinks: false
                )
            let verifiedDisplacedPreimage = VerifiedFilePayload(
                data: displacedPayload.data
            )
            let displacedFingerprint = verifiedDisplacedPreimage.fingerprint
            let hasUnexpectedPreimage =
                displacedFingerprint.contentDigest
                != expectedPreimageFingerprint.contentDigest
            if !hasUnexpectedPreimage {
                try acknowledge(preparedRecoveryArtifact)
                retainedRecoveryArtifact = nil
            }
            return FileCommitResult(
                generation: token.generation,
                committedFingerprint: FileFingerprint.make(
                    data: token.encodedData,
                    resourceIdentifier:
                        preparedCandidate.resourceIdentifier
                ),
                verifiedDisplacedPreimage: verifiedDisplacedPreimage,
                safety: .atomicSwap,
                recoveryArtifact: retainedRecoveryArtifact
            )
        }

        let swapError = errno
        try acknowledge(preparedRecoveryArtifact)
        retainedRecoveryArtifact = nil
        guard
            swapError == ENOTSUP
                || swapError == EXDEV
                || swapError == EINVAL
        else {
            throw CommitError.atomicSwapFailed
        }
        throw CommitError.atomicSwapUnavailable
    }

    private func acknowledge(
        _ artifact: CommitRecoveryArtifact
    ) throws {
        try beforeRecoveryAcknowledgement?()
        try CommitRecoveryJournalStore.acknowledge(artifact)
    }

    static func fingerprint(for url: URL, data: Data? = nil) throws -> FileFingerprint {
        let payload = try TextFileCodec.readVerifiedFilePayload(at: url)
        if let data {
            try TextFileCodec.validateSupportedSize(data)
            guard data == payload.data else {
                throw CommitError.targetChangedBeforeCommit
            }
        }
        return payload.fingerprint
    }

    private func validate(
        preimage: Data,
        descriptor: Int32,
        against expectedState: DurableFileState?
    ) throws {
        guard let expectedState else {
            throw CommitError.targetChangedBeforeCommit
        }
        guard preimage.count == expectedState.fingerprint.byteCount else {
            throw CommitError.targetChangedBeforeCommit
        }
        let observedFingerprint = try Self.fingerprint(
            for: descriptor,
            data: preimage
        )
        guard
            observedFingerprint.byteCount
                == expectedState.fingerprint.byteCount,
            observedFingerprint.contentDigest
                == expectedState.fingerprint.contentDigest,
            observedFingerprint.resourceIdentifier
                == expectedState.fingerprint.resourceIdentifier
        else {
            throw CommitError.targetChangedBeforeCommit
        }
    }

    private static func fingerprint(
        for descriptor: Int32,
        data: Data
    ) throws -> FileFingerprint {
        return .make(
            data: data,
            resourceIdentifier: try TextFileCodec.resourceIdentifier(
                for: descriptor
            )
        )
    }

    private func prepareCandidate(
        at url: URL,
        copyingMetadataFrom sourceDescriptor: Int32,
        data: Data
    ) throws -> String {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        guard
            fcopyfile(
                sourceDescriptor,
                descriptor,
                nil,
                copyfile_flags_t(COPYFILE_METADATA)
            ) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try TextFileCodec.resourceIdentifier(for: descriptor)
    }

    private func writeNewFileExclusively(
        _ data: Data,
        to url: URL
    ) throws -> FileFingerprint {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o666)
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw CommitError.targetChangedBeforeCommit
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var committed = false
        defer {
            if !committed {
                removeCreatedFileIfStillOwned(descriptor: descriptor, url: url)
                try? DurableFileIO.synchronizeDirectory(
                    url.deletingLastPathComponent()
                )
            }
            Darwin.close(descriptor)
        }

        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try DurableFileIO.synchronizeDirectory(
            url.deletingLastPathComponent()
        )
        let fingerprint = FileFingerprint.make(
            data: data,
            resourceIdentifier: try TextFileCodec.resourceIdentifier(
                for: descriptor
            )
        )
        committed = true
        return fingerprint
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
    }

    private func removeCreatedFileIfStillOwned(
        descriptor: Int32,
        url: URL
    ) {
        var openedFile = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedFile) == 0 else { return }
        var currentPath = Darwin.stat()
        let status = url.path.withCString {
            Darwin.lstat($0, &currentPath)
        }
        guard status == 0,
            openedFile.st_dev == currentPath.st_dev,
            openedFile.st_ino == currentPath.st_ino
        else {
            return
        }
        _ = url.path.withCString { Darwin.unlink($0) }
    }
}
