import Foundation
import XCTest
@testable import DarthScriptum

final class SafeFileCommitterTests: XCTestCase {
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
            snapshot: try TextFileCodec.decode(updated),
            encodedData: updated,
            expectedDurableState: state,
            targetURL: url
        )

        let result = try SafeFileCommitter().commit(token)
        XCTAssertEqual(try Data(contentsOf: url), updated)
        XCTAssertEqual(result.displacedPreimage, original)
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
            snapshot: try TextFileCodec.decode(local),
            encodedData: local,
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
            snapshot: try TextFileCodec.decode(updated),
            encodedData: updated,
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
        XCTAssertEqual(result.displacedPreimage, original)
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
            snapshot: try TextFileCodec.decode(Data("local\n".utf8)),
            encodedData: Data("local\n".utf8),
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
    func testContestedSwapKeepsDurablePreimageUntilRecoveryImportsIt() throws {
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
        XCTAssertEqual(result.displacedPreimage, external)
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
        XCTAssertEqual(
            reopenedStore.rawRecoveryEntries(for: identity).first?.data,
            external
        )
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
    func testPreparedButUnswappedJournalDoesNotCreateFalseRecovery() throws {
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
        try Data("local\n".utf8).write(to: candidateURL)
        let artifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: fixture.url,
            documentIdentity: .make(url: fixture.url),
            expectedContentDigest: FileFingerprint.make(
                data: fixture.original
            ).contentDigest,
            recoveryDirectory: recoveryDirectory
        )

        let reopenedStore = SessionRecoveryStore(
            persistenceDirectory: recoveryDirectory
        )

        XCTAssertTrue(
            reopenedStore.rawRecoveryEntries(
                for: .make(url: fixture.url)
            ).isEmpty
        )
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
        try Data("local\n".utf8).write(to: candidateURL)
        let artifact = try CommitRecoveryJournalStore.prepare(
            candidateURL: candidateURL,
            replacementDirectoryURL: replacementDirectory,
            targetURL: fixture.url,
            documentIdentity: .make(url: fixture.url),
            expectedContentDigest: FileFingerprint.make(
                data: fixture.original
            ).contentDigest,
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
            snapshot: try TextFileCodec.decode(updatedData),
            encodedData: updatedData,
            expectedDurableState: state,
            targetURL: url
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
