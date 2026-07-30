import Darwin
import Foundation

struct SafeFileCommitter: Sendable {
    enum Strategy: Sendable {
        case automatic
        case coordinatedReplacementOnly
    }

    enum CommitError: LocalizedError, Equatable {
        case invalidPreparedPayload
        case atomicSwapUnavailable
        case targetChangedBeforeCommit
        case targetMissingBeforeCommit

        var errorDescription: String? {
            switch self {
            case .invalidPreparedPayload:
                "The prepared save payload does not match its captured snapshot."
            case .atomicSwapUnavailable:
                "This filesystem cannot safely replace the file in place. Use Save As to write a new file."
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

    init(
        strategy: Strategy = .automatic,
        recoveryDirectory: URL =
            CommitRecoveryJournalStore.defaultRecoveryDirectory,
        beforeAtomicSwap: (@Sendable () throws -> Void)? = nil
    ) {
        self.strategy = strategy
        self.recoveryDirectory = recoveryDirectory
        self.beforeAtomicSwap = beforeAtomicSwap
    }

    func commit(_ token: PendingSaveToken) throws -> FileCommitResult {
        guard token.preparedPayload.isExactEncoding() else {
            throw CommitError.invalidPreparedPayload
        }
        let fileManager = FileManager.default
        let requestedTargetURL = token.targetURL

        if token.expectedDurableState == nil {
            try writeNewFileExclusively(
                token.encodedData,
                to: requestedTargetURL
            )
            return FileCommitResult(
                generation: token.generation,
                committedFingerprint: try Self.fingerprint(
                    for: requestedTargetURL,
                    data: token.encodedData
                ),
                displacedPreimage: nil,
                safety: .coordinatedReplacement
            )
        }
        let targetURL = requestedTargetURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw CommitError.targetMissingBeforeCommit
        }

        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: targetURL,
            create: true
        )
        let replacementDirectoryResourceIdentifier =
            try DurableFileIO.resourceIdentifier(for: replacementDirectory)
        let candidateURL = replacementDirectory
            .appendingPathComponent("darth-scriptum-\(UUID().uuidString)")
        var retainedRecoveryArtifact: CommitRecoveryArtifact?
        defer {
            if retainedRecoveryArtifact == nil,
               let currentIdentifier =
                try? DurableFileIO.resourceIdentifier(
                    for: replacementDirectory
                ),
               currentIdentifier
                == replacementDirectoryResourceIdentifier {
                if fileManager.fileExists(atPath: candidateURL.path) {
                    _ = candidateURL.path.withCString { Darwin.unlink($0) }
                }
                _ = replacementDirectory.path.withCString {
                    Darwin.rmdir($0)
                }
            }
        }

        try fileManager.copyItem(at: targetURL, to: candidateURL)
        let handle = try FileHandle(forWritingTo: candidateURL)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: token.encodedData)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let preflight = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
        try validate(
            preimage: preflight,
            at: targetURL,
            against: token.expectedDurableState
        )
        guard let expectedPreimageFingerprint = token.expectedDurableState?
            .fingerprint else {
            throw CommitError.targetChangedBeforeCommit
        }
        let preparedRecoveryArtifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: targetURL,
            documentIdentity: .make(url: requestedTargetURL),
            expectedPreimageFingerprint: expectedPreimageFingerprint,
            committedPayloadFingerprint: token.contentFingerprint,
            recoveryDirectory: recoveryDirectory
        )
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
            retainedRecoveryArtifact = preparedRecoveryArtifact
            try DurableFileIO.synchronizeDirectory(
                targetURL.deletingLastPathComponent()
            )
            try DurableFileIO.synchronizeDirectory(
                replacementDirectory
            )
            let displacedPreimage = try Data(
                contentsOf: candidateURL,
                options: [.mappedIfSafe]
            )
            let displacedFingerprint = FileFingerprint.make(
                data: displacedPreimage
            )
            let hasUnexpectedPreimage =
                displacedFingerprint.contentDigest
                    != expectedPreimageFingerprint.contentDigest
            if !hasUnexpectedPreimage {
                try CommitRecoveryJournalStore.acknowledge(
                    preparedRecoveryArtifact
                )
                retainedRecoveryArtifact = nil
            }
            return FileCommitResult(
                generation: token.generation,
                committedFingerprint: try Self.fingerprint(
                    for: targetURL,
                    data: token.encodedData
                ),
                displacedPreimage: displacedPreimage,
                safety: .atomicSwap,
                recoveryArtifact: retainedRecoveryArtifact
            )
        }

        let swapError = errno
        try? CommitRecoveryJournalStore.acknowledge(
            preparedRecoveryArtifact
        )
        guard swapError == ENOTSUP || swapError == EXDEV || swapError == EINVAL else {
            throw POSIXError(POSIXErrorCode(rawValue: swapError) ?? .EIO)
        }
        throw CommitError.atomicSwapUnavailable
    }

    static func fingerprint(for url: URL, data: Data? = nil) throws -> FileFingerprint {
        let contents = try data ?? Data(contentsOf: url, options: [.mappedIfSafe])
        let identityURL = url.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: identityURL.path
        )
        let device = attributes?[.systemNumber] as? NSNumber
        let inode = attributes?[.systemFileNumber] as? NSNumber
        let resourceIdentifier: String? = if let device, let inode {
            "\(device):\(inode)"
        } else {
            nil
        }
        return .make(data: contents, resourceIdentifier: resourceIdentifier)
    }

    private func validate(
        preimage: Data,
        at url: URL,
        against expectedState: DurableFileState?
    ) throws {
        guard let expectedState else {
            throw CommitError.targetChangedBeforeCommit
        }
        let observedFingerprint = try Self.fingerprint(
            for: url,
            data: preimage
        )
        guard observedFingerprint.contentDigest
                == expectedState.fingerprint.contentDigest,
              observedFingerprint.resourceIdentifier
                == expectedState.fingerprint.resourceIdentifier else {
            throw CommitError.targetChangedBeforeCommit
        }
    }

    private func writeNewFileExclusively(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
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
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try DurableFileIO.synchronizeDirectory(
            url.deletingLastPathComponent()
        )
        committed = true
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
              openedFile.st_ino == currentPath.st_ino else {
            return
        }
        _ = url.path.withCString { Darwin.unlink($0) }
    }
}
