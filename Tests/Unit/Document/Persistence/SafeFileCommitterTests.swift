import Darwin
import Foundation
import XCTest

@testable import DarthScriptum

final class SafeFileCommitterTests: XCTestCase {
    func testCommitReportsIdentityOfWrittenCandidateWhenTargetIsReplacedAfterSwap()
        throws
    {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let committedIdentifier = ConcurrentValueRecorder<String>()
        let externalData = Data("external\n".utf8)

        let result = try SafeFileCommitter(
            recoveryDirectory: recoveryDirectory,
            afterAtomicSwap: {
                committedIdentifier.record(
                    try DurableFileIO.resourceIdentifier(for: fixture.url)
                )
                try externalData.write(to: fixture.url, options: .atomic)
            }
        ).commit(fixture.token(updated: "local\n"))

        let writtenIdentifier = try XCTUnwrap(committedIdentifier.value)
        let currentIdentifier = try DurableFileIO.resourceIdentifier(
            for: fixture.url
        )
        XCTAssertEqual(
            result.committedFingerprint,
            FileFingerprint.make(
                data: Data("local\n".utf8),
                resourceIdentifier: writtenIdentifier
            )
        )
        XCTAssertNotEqual(writtenIdentifier, currentIdentifier)
        XCTAssertEqual(try Data(contentsOf: fixture.url), externalData)
    }

    func testPostSwapFailureLeavesBoundJournalForAuthoritativeReconciliation()
        throws
    {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let token = try fixture.token(updated: "local\n")

        XCTAssertThrowsError(
            try SafeFileCommitter(
                recoveryDirectory: recoveryDirectory,
                afterAtomicSwap: {
                    throw InjectedCommitError.afterAtomicSwap
                }
            ).commit(token)
        ) { error in
            XCTAssertEqual(error as? InjectedCommitError, .afterAtomicSwap)
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.url),
            Data("local\n".utf8)
        )
        let pending = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            ).only
        )
        defer {
            try? CommitRecoveryJournalStore.acknowledge(pending.artifact)
        }
        XCTAssertTrue(pending.swapCompleted)
        XCTAssertEqual(pending.commitGeneration, token.generation)
        XCTAssertEqual(
            pending.artifact.binding?.documentIdentity,
            .make(url: fixture.url)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.artifact.journalURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.artifact.candidateURL.path
            )
        )
    }

    func testCommitWhenRacedPreimageExceedsDocumentLimitRejectsBeforeFingerprinting()
        throws
    {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let targetURL = fixture.url
        let oversizedByteCount = TextFileCodec.maximumDocumentByteCount + 1

        XCTAssertThrowsError(
            try SafeFileCommitter(
                recoveryDirectory: recoveryDirectory,
                beforeAtomicSwap: {
                    let handle = try FileHandle(forWritingTo: targetURL)
                    try handle.truncate(atOffset: UInt64(oversizedByteCount))
                    try handle.close()
                }
            ).commit(fixture.token(updated: "local\n"))
        ) { error in
            guard
                case .documentTooLarge(let byteCount, let maximumByteCount) =
                    error as? TextFileCodec.CodecError
            else {
                return XCTFail("Expected an oversized-document error, got \(error)")
            }
            XCTAssertEqual(byteCount, oversizedByteCount)
            XCTAssertEqual(
                maximumByteCount,
                TextFileCodec.maximumDocumentByteCount
            )
        }

        XCTAssertEqual(try Data(contentsOf: targetURL), Data("local\n".utf8))
        let journalDirectory = recoveryDirectory.appendingPathComponent(
            "commit-journals",
            isDirectory: true
        )
        let journalURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: journalDirectory,
                includingPropertiesForKeys: nil
            ).only
        )
        let journal = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: journalURL)
            ) as? [String: Any]
        )
        let candidatePath = try XCTUnwrap(journal["candidatePath"] as? String)
        let candidateSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: candidatePath)[.size]
                as? NSNumber
        )
        XCTAssertEqual(candidateSize.intValue, oversizedByteCount)
    }

    func testCommitWhenTargetBecomesDirectoryRejectsBeforeCandidatePreparation()
        throws
    {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let token = try fixture.token(updated: "local\n")
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(
            at: fixture.url,
            withIntermediateDirectories: false
        )
        try Data("unbounded-copy-sentinel".utf8).write(
            to: fixture.url.appendingPathComponent("child")
        )
        var copiedCandidateDirectory: URL?
        defer {
            if let copiedCandidateDirectory,
                copiedCandidateDirectory.lastPathComponent.hasPrefix("NSIRD_")
            {
                try? FileManager.default.removeItem(
                    at: copiedCandidateDirectory
                )
            }
        }

        XCTAssertThrowsError(
            try SafeFileCommitter().commit(token)
        ) { error in
            if let path = (error as NSError).userInfo[NSFilePathErrorKey]
                as? String
            {
                copiedCandidateDirectory = URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
            }
            XCTAssertEqual(
                error as? TextFileCodec.CodecError,
                .unsupportedFileType
            )
        }
    }

    func testPendingRecoveryScanDoesNotClaimLiveCommitBeforeAtomicSwap() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let swapReached = DispatchSemaphore(value: 0)
        let allowSwap = DispatchSemaphore(value: 0)
        let commitFinished = DispatchSemaphore(value: 0)
        let resultRecorder = ConcurrentValueRecorder<FileCommitResult>()
        let errorRecorder = ConcurrentValueRecorder<Error>()
        defer {
            allowSwap.signal()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { commitFinished.signal() }
            do {
                resultRecorder.record(
                    try SafeFileCommitter(
                        recoveryDirectory: recoveryDirectory,
                        beforeAtomicSwap: {
                            swapReached.signal()
                            allowSwap.wait()
                        }
                    ).commit(fixture.token(updated: "local\n"))
                )
            } catch {
                errorRecorder.record(error)
            }
        }

        XCTAssertEqual(swapReached.wait(timeout: .now() + 2), .success)
        let pending: [PendingCommitRecovery]
        do {
            pending = try CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            )
        } catch {
            XCTFail("Pending recovery scan failed: \(error)")
            pending = []
        }
        XCTAssertTrue(pending.isEmpty)
        if let artifact = pending.first?.artifact {
            try CommitRecoveryJournalStore.acknowledge(artifact)
        }

        allowSwap.signal()
        XCTAssertEqual(commitFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(errorRecorder.value)
        XCTAssertNotNil(resultRecorder.value)
        XCTAssertEqual(
            try Data(contentsOf: fixture.url),
            Data("local\n".utf8)
        )
    }

    func testPendingRecoveryScanRejectsFIFOJournalWithoutWaitingForWriter() throws {
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let journalDirectory = recoveryDirectory.appendingPathComponent(
            "commit-journals",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let journalURL = journalDirectory.appendingPathComponent(
            "\(UUID().uuidString).commit.json"
        )
        XCTAssertEqual(
            journalURL.path.withCString {
                Darwin.mkfifo($0, mode_t(0o600))
            },
            0
        )
        let completion = DispatchSemaphore(value: 0)
        let errorRecorder = ConcurrentValueRecorder<Error>()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                _ = try CommitRecoveryJournalStore.pendingRecoveries(
                    in: recoveryDirectory
                )
            } catch {
                errorRecorder.record(error)
            }
        }

        let initialWait = completion.wait(
            timeout: .now() + .milliseconds(250)
        )
        if initialWait == .timedOut {
            let writer = journalURL.path.withCString {
                Darwin.open($0, O_WRONLY | O_NONBLOCK)
            }
            if writer >= 0 {
                Darwin.close(writer)
            }
            XCTAssertEqual(
                completion.wait(timeout: .now() + 2),
                .success
            )
        }

        XCTAssertEqual(initialWait, .success)
        XCTAssertNotNil(errorRecorder.value)
    }

    func testPendingRecoveryScanRejectsOversizedJournalBeforeDecoding() throws {
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let journalDirectory = recoveryDirectory.appendingPathComponent(
            "commit-journals",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let journalURL = journalDirectory.appendingPathComponent(
            "\(UUID().uuidString).commit.json"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: journalURL.path,
                contents: nil
            )
        )
        let handle = try FileHandle(forWritingTo: journalURL)
        let oversizedByteCount = TextFileCodec.maximumDocumentByteCount + 1
        try handle.truncate(atOffset: UInt64(oversizedByteCount))
        try handle.close()

        XCTAssertThrowsError(
            try CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            )
        ) { error in
            guard
                case .documentTooLarge(let byteCount, let maximumByteCount) =
                    error as? TextFileCodec.CodecError
            else {
                return XCTFail("Expected a size-limit error, got \(error)")
            }
            XCTAssertEqual(byteCount, oversizedByteCount)
            XCTAssertEqual(
                maximumByteCount,
                TextFileCodec.maximumDocumentByteCount
            )
        }
    }

    func testPostSwapJournalBindsTheRequestedSymlinkTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let referent = directory.appendingPathComponent("referent.md")
        let link = directory.appendingPathComponent("linked.md")
        let original = Data("base\n".utf8)
        let updated = Data("local\n".utf8)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try original.write(to: referent)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: referent
        )
        let token = PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: "local\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(updated)
            ),
            expectedDurableState: DurableFileState(
                snapshot: try TextFileCodec.decode(original),
                fingerprint: try SafeFileCommitter.fingerprint(
                    for: link,
                    data: original
                ),
                generation: 1
            ),
            targetURL: link
        )

        XCTAssertThrowsError(
            try SafeFileCommitter(
                recoveryDirectory: recoveryDirectory,
                afterAtomicSwap: {
                    throw InjectedCommitError.afterAtomicSwap
                }
            ).commit(token)
        )

        let pending = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            ).only
        )
        defer {
            try? CommitRecoveryJournalStore.acknowledge(pending.artifact)
        }
        XCTAssertEqual(
            pending.artifact.binding?.targetURL.standardizedFileURL,
            link.standardizedFileURL
        )
        XCTAssertNotEqual(
            pending.artifact.binding?.targetURL.standardizedFileURL,
            referent.standardizedFileURL
        )
        XCTAssertEqual(pending.swapEvidence, .targetOwnsPreparedCandidate)
    }

    func testCommitPreservesExactPreimageAndReplacesContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("sample.md")
        let original = Data("# Before\n".utf8)
        let updated = Data("# After\n".utf8)
        try original.write(to: url)
        let state = DurableFileState(
            snapshot: try TextFileCodec.decode(original),
            fingerprint: try SafeFileCommitter.fingerprint(for: url, data: original),
            generation: 1
        )
        let token = PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: "# After\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(updated)
            ),
            expectedDurableState: state,
            targetURL: url
        )

        let result = try SafeFileCommitter().commit(token)
        XCTAssertEqual(try Data(contentsOf: url), updated)
        let displacedPreimage = try XCTUnwrap(result.displacedPreimage)
        XCTAssertEqual(displacedPreimage.data, original)
        XCTAssertEqual(
            displacedPreimage.fingerprint,
            FileFingerprint.make(data: original)
        )
        XCTAssertEqual(
            result.committedFingerprint.contentDigest,
            FileFingerprint.make(data: updated).contentDigest
        )
        XCTAssertNil(result.recoveryArtifact)
    }

    func testCommitRejectsChangedTargetBeforeReplacingIt() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let token = try fixture.token(updated: "local\n")
        try Data("external\n".utf8).write(to: fixture.url)

        XCTAssertThrowsError(try SafeFileCommitter().commit(token)) { error in
            XCTAssertEqual(
                error as? SafeFileCommitter.CommitError,
                .targetChangedBeforeCommit
            )
        }
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "external\n"
        )
    }

    func testFallbackRefusesUnsafeInPlaceReplacement() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try SafeFileCommitter(
                strategy: .coordinatedReplacementOnly
            ).commit(fixture.token(updated: "local\n"))
        ) { error in
            XCTAssertEqual(
                error as? SafeFileCommitter.CommitError,
                .atomicSwapUnavailable
            )
        }
        XCTAssertEqual(
            try String(contentsOf: fixture.url, encoding: .utf8),
            "base\n"
        )
    }

    func testFailedSwapAcknowledgementFailureRetainsRetryableJournal()
        throws
    {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let pendingSave = try fixture.token(updated: "local\n")

        XCTAssertThrowsError(
            try SafeFileCommitter(
                strategy: .coordinatedReplacementOnly,
                recoveryDirectory: recoveryDirectory,
                beforeRecoveryAcknowledgement: {
                    throw InjectedCommitError.beforeRecoveryAcknowledgement
                }
            ).commit(pendingSave)
        ) { error in
            XCTAssertEqual(
                error as? InjectedCommitError,
                .beforeRecoveryAcknowledgement
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        let pending = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            ).only
        )
        XCTAssertEqual(pending.terminalState, .prepared)
        XCTAssertEqual(pending.swapEvidence, .preparedCandidateRemains)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.artifact.journalURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.artifact.candidateURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.artifact.replacementDirectoryURL.path
            )
        )

        let reconciliation = try CommitRecoveryJournalStore.reconcileCommit(
            fixture.reconciliationRequest(for: pendingSave),
            in: recoveryDirectory
        )

        guard case .notCommitted(let observation) = reconciliation else {
            return XCTFail("Expected exact retained evidence to prove no swap")
        }
        XCTAssertEqual(
            observation?.fingerprint,
            pendingSave.expectedDurableState?.fingerprint
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: pending.artifact.journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: pending.artifact.replacementDirectoryURL.path
            )
        )
    }

    func testUnclassifiedFailedSwapThrowsTypedNotStartedError() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try SafeFileCommitter(
                recoveryDirectory: recoveryDirectory,
                beforeAtomicSwap: {
                    let journalDirectory =
                        recoveryDirectory.appendingPathComponent(
                            "commit-journals",
                            isDirectory: true
                        )
                    let journalURL = try XCTUnwrap(
                        FileManager.default.contentsOfDirectory(
                            at: journalDirectory,
                            includingPropertiesForKeys: nil
                        ).only
                    )
                    let journal = try XCTUnwrap(
                        try JSONSerialization.jsonObject(
                            with: TextFileCodec.readSupportedData(
                                at: journalURL,
                                followingSymbolicLinks: false
                            )
                        ) as? [String: Any]
                    )
                    let candidatePath = try XCTUnwrap(
                        journal["candidatePath"] as? String
                    )
                    try FileManager.default.removeItem(
                        at: URL(fileURLWithPath: candidatePath)
                    )
                }
            ).commit(fixture.token(updated: "local\n"))
        ) { error in
            XCTAssertEqual(
                error as? SafeFileCommitter.CommitError,
                .atomicSwapFailed
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The atomic file replacement failed before changing the destination."
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        XCTAssertTrue(
            try CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            ).isEmpty
        )
    }

    func testCommitDoesNotRecreateAnExpectedFileThatWasDeleted() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let token = try fixture.token(updated: "local\n")
        try FileManager.default.removeItem(at: fixture.url)

        XCTAssertThrowsError(try SafeFileCommitter().commit(token)) { error in
            XCTAssertEqual(
                error as? SafeFileCommitter.CommitError,
                .targetMissingBeforeCommit
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testNewFileCommitDoesNotReplaceAConcurrentlyCreatedTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("new.md")
        let external = Data("created externally\n".utf8)
        try external.write(to: url)
        let local = Data("local draft\n".utf8)
        let token = PendingSaveToken(
            generation: 1,
            sourceRevision: SourceRevision(number: 1, text: "local draft\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(local)
            ),
            expectedDurableState: nil,
            targetURL: url
        )

        XCTAssertThrowsError(try SafeFileCommitter().commit(token)) { error in
            XCTAssertEqual(
                error as? SafeFileCommitter.CommitError,
                .targetChangedBeforeCommit
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testCommitThroughSymlinkPreservesLinkAndAtomicallyUpdatesReferent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let referent = directory.appendingPathComponent("referent.md")
        let link = directory.appendingPathComponent("linked.md")
        let original = Data("base\n".utf8)
        let updated = Data("local\n".utf8)
        try original.write(to: referent)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: referent
        )
        let token = PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: "local\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(updated)
            ),
            expectedDurableState: DurableFileState(
                snapshot: try TextFileCodec.decode(original),
                fingerprint: try SafeFileCommitter.fingerprint(
                    for: link,
                    data: original
                ),
                generation: 1
            ),
            targetURL: link
        )

        let result = try SafeFileCommitter().commit(token)

        let values = try link.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: referent), updated)
        XCTAssertEqual(try Data(contentsOf: link), updated)
        let displacedPreimage = try XCTUnwrap(result.displacedPreimage)
        XCTAssertEqual(displacedPreimage.data, original)
        XCTAssertEqual(
            displacedPreimage.fingerprint,
            FileFingerprint.make(data: original)
        )
    }

    func testRetargetedSymlinkCannotOverwriteAnIdenticalDifferentReferent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalReferent = directory.appendingPathComponent("original.md")
        let replacementReferent = directory.appendingPathComponent("replacement.md")
        let link = directory.appendingPathComponent("linked.md")
        let original = Data("same bytes\n".utf8)
        try original.write(to: originalReferent)
        try original.write(to: replacementReferent)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: originalReferent
        )
        let token = PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: "local\n"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(Data("local\n".utf8))
            ),
            expectedDurableState: DurableFileState(
                snapshot: try TextFileCodec.decode(original),
                fingerprint: try SafeFileCommitter.fingerprint(
                    for: link,
                    data: original
                ),
                generation: 1
            ),
            targetURL: link
        )
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: replacementReferent
        )

        XCTAssertThrowsError(try SafeFileCommitter().commit(token)) { error in
            XCTAssertEqual(
                error as? SafeFileCommitter.CommitError,
                .targetChangedBeforeCommit
            )
        }
        XCTAssertEqual(try Data(contentsOf: originalReferent), original)
        XCTAssertEqual(try Data(contentsOf: replacementReferent), original)
    }

    @MainActor
    func testContestedSwapKeepsDurablePreimageUntilRecoveryImportsIt() async throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let targetURL = fixture.url
        let external = Data("external\n".utf8)
        let result = try SafeFileCommitter(
            recoveryDirectory: recoveryDirectory,
            beforeAtomicSwap: {
                try external.write(to: targetURL, options: [.atomic])
            }
        ).commit(fixture.token(updated: "local\n"))

        XCTAssertEqual(try Data(contentsOf: fixture.url), Data("local\n".utf8))
        let displacedPreimage = try XCTUnwrap(result.displacedPreimage)
        XCTAssertEqual(displacedPreimage.data, external)
        XCTAssertEqual(
            displacedPreimage.fingerprint,
            FileFingerprint.make(data: external)
        )
        let artifact = try XCTUnwrap(result.recoveryArtifact)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifact.candidateURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: artifact.journalURL.path
            )
        )

        let reopenedStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )
        let identity = DocumentIdentity.make(url: fixture.url)
        let recoveredEntries = try await reopenedStore.rawRecoveryEntries(
            for: identity
        )
        let recoveredEntry = try XCTUnwrap(recoveredEntries.first)
        let recoveredData = try await recoveredEntry.loadData()
        XCTAssertEqual(recoveredData, external)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.candidateURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.journalURL.path
            )
        )
    }

    @MainActor
    func testPreparedButUnswappedJournalDoesNotCreateFalseRecovery() async throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let replacementDirectory = fixture.directory.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let candidateURL = replacementDirectory.appendingPathComponent(
            "candidate"
        )
        let candidateData = Data("local\n".utf8)
        try candidateData.write(to: candidateURL)
        let artifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: fixture.url,
            requestedTargetURL: fixture.url,
            documentIdentity: .make(url: fixture.url),
            commitGeneration: 2,
            expectedPreimageFingerprint: try SafeFileCommitter.fingerprint(
                for: fixture.url,
                data: fixture.original
            ),
            committedPayloadFingerprint: FileFingerprint.make(
                data: candidateData
            ),
            recoveryDirectory: recoveryDirectory
        )

        let reopenedStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )

        let rawEntries = try await reopenedStore.rawRecoveryEntries(
            for: .make(url: fixture.url)
        )
        XCTAssertTrue(rawEntries.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.candidateURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifact.journalURL.path
            )
        )
    }

    func testAcknowledgeDoesNotDeleteAReusedReplacementDirectory() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let replacementDirectory = fixture.directory.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let candidateURL = replacementDirectory.appendingPathComponent(
            "candidate"
        )
        let candidateData = Data("local\n".utf8)
        try candidateData.write(to: candidateURL)
        let artifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: fixture.url,
            requestedTargetURL: fixture.url,
            documentIdentity: .make(url: fixture.url),
            commitGeneration: 2,
            expectedPreimageFingerprint: try SafeFileCommitter.fingerprint(
                for: fixture.url,
                data: fixture.original
            ),
            committedPayloadFingerprint: FileFingerprint.make(
                data: candidateData
            ),
            recoveryDirectory: recoveryDirectory
        )
        try FileManager.default.removeItem(at: replacementDirectory)
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let unrelatedURL = replacementDirectory.appendingPathComponent(
            "unrelated"
        )
        try Data("keep\n".utf8).write(to: unrelatedURL)

        XCTAssertThrowsError(
            try CommitRecoveryJournalStore.acknowledge(artifact)
        ) { error in
            XCTAssertEqual(
                error as? CommitRecoveryJournalStore.JournalError,
                .unownedReplacementDirectory
            )
        }
        XCTAssertEqual(
            try String(contentsOf: unrelatedURL, encoding: .utf8),
            "keep\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.journalURL.path)
        )
    }

    func testPendingRecoveryScanSerializesConcurrentAcknowledgement() throws {
        let fixture = try CommitFixture(original: "base\n")
        defer { fixture.remove() }
        let recoveryDirectory = fixture.directory.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        XCTAssertThrowsError(
            try SafeFileCommitter(
                recoveryDirectory: recoveryDirectory,
                afterAtomicSwap: {
                    throw InjectedCommitError.afterAtomicSwap
                }
            ).commit(fixture.token(updated: "local\n"))
        )
        let artifact = try XCTUnwrap(
            CommitRecoveryJournalStore.pendingRecoveries(
                in: recoveryDirectory
            ).only?.artifact
        )
        let scanEntered = DispatchSemaphore(value: 0)
        let allowScan = DispatchSemaphore(value: 0)
        let acknowledgementStarted = DispatchSemaphore(value: 0)
        let acknowledgementFinished = DispatchSemaphore(value: 0)
        let scanRecorder = ConcurrentValueRecorder<[PendingCommitRecovery]>()
        let errorRecorder = ConcurrentValueRecorder<Error>()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                scanRecorder.record(
                    try CommitRecoveryJournalStore.pendingRecoveries(
                        in: recoveryDirectory,
                        beforeReadingJournals: {
                            scanEntered.signal()
                            allowScan.wait()
                        }
                    )
                )
            } catch {
                errorRecorder.record(error)
            }
        }
        XCTAssertEqual(scanEntered.wait(timeout: .now() + 2), .success)

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                acknowledgementFinished.signal()
                group.leave()
            }
            acknowledgementStarted.signal()
            do {
                try CommitRecoveryJournalStore.acknowledge(artifact)
            } catch {
                errorRecorder.record(error)
            }
        }
        XCTAssertEqual(
            acknowledgementStarted.wait(timeout: .now() + 2),
            .success
        )
        let earlyAcknowledgement = acknowledgementFinished.wait(
            timeout: .now() + .milliseconds(100)
        )
        allowScan.signal()

        XCTAssertEqual(earlyAcknowledgement, .timedOut)
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertNil(errorRecorder.value)
        XCTAssertEqual(scanRecorder.value?.count, 1)
    }
}

private enum InjectedCommitError: Error, Equatable {
    case afterAtomicSwap
    case beforeRecoveryAcknowledgement
}

extension Array {
    fileprivate var only: Element? {
        count == 1 ? self[0] : nil
    }
}

private struct CommitFixture {
    let directory: URL
    let url: URL
    let original: Data

    init(original: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("sample.md")
        self.original = Data(original.utf8)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try self.original.write(to: url)
    }

    func token(updated: String) throws -> PendingSaveToken {
        let updatedData = Data(updated.utf8)
        let state = DurableFileState(
            snapshot: try TextFileCodec.decode(original),
            fingerprint: try SafeFileCommitter.fingerprint(
                for: url,
                data: original
            ),
            generation: 1
        )
        return PendingSaveToken(
            generation: 2,
            sourceRevision: SourceRevision(number: 2, text: updated),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: TextFileCodec.decode(updatedData)
            ),
            expectedDurableState: state,
            targetURL: url
        )
    }

    func reconciliationRequest(
        for pendingSave: PendingSaveToken
    ) throws -> DocumentSyncCommitReconciliationRequest {
        let identity = DocumentIdentity.make(url: url)
        let fingerprint = try SafeFileCommitter.fingerprint(
            for: url,
            data: original
        )
        let originalSnapshot = try TextFileCodec.decode(original)
        let baseline = try TextFileCodec.durableBaseline(
            data: original,
            targetURL: url,
            fingerprint: fingerprint,
            documentIdentity: identity,
            sourceRevision: SourceRevision(
                number: 1,
                text: originalSnapshot.text
            ),
            commitGeneration: 1
        )
        let lifetime = UUID()
        return DocumentSyncCommitReconciliationRequest(
            token: SyncEffectToken(
                lifetime: lifetime,
                attachmentEpoch: 1,
                operation: .commitReconciliation,
                attempt: 2
            ),
            originalCommitToken: SyncEffectToken(
                lifetime: lifetime,
                attachmentEpoch: 1,
                operation: .saveCommit,
                attempt: 1
            ),
            pendingSave: pendingSave,
            targetURL: url,
            identity: identity,
            attachmentEpoch: 1,
            expectedBaseline: baseline,
            commitGeneration: pendingSave.generation
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ConcurrentValueRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: Value?

    var value: Value? {
        lock.withLock { recordedValue }
    }

    func record(_ value: Value) {
        lock.withLock {
            recordedValue = value
        }
    }
}
