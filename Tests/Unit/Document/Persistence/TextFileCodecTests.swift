import Darwin
import Foundation
import XCTest

@testable import DarthScriptum

final class TextFileCodecTests: XCTestCase {
    func testVerifiedFilePayloadKeepsDescriptorIdentityWhenPathIsReplacedAfterRead()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("document.md")
        let displacedURL = directory.appendingPathComponent("displaced.md")
        let replacementURL = directory.appendingPathComponent("replacement.md")
        let originalData = Data("original\n".utf8)
        let replacementData = Data("replacement\n".utf8)
        try originalData.write(to: targetURL)
        try replacementData.write(to: replacementURL)
        let originalIdentifier = try DurableFileIO.resourceIdentifier(
            for: targetURL
        )
        let replacementIdentifier = try DurableFileIO.resourceIdentifier(
            for: replacementURL
        )

        let payload = try TextFileCodec.readVerifiedFilePayload(
            at: targetURL,
            afterReading: {
                try FileManager.default.moveItem(
                    at: targetURL,
                    to: displacedURL
                )
                try FileManager.default.moveItem(
                    at: replacementURL,
                    to: targetURL
                )
            }
        )

        XCTAssertEqual(payload.data, originalData)
        XCTAssertEqual(
            payload.fingerprint.resourceIdentifier,
            originalIdentifier
        )
        XCTAssertNotEqual(originalIdentifier, replacementIdentifier)
        XCTAssertEqual(
            try DurableFileIO.resourceIdentifier(for: targetURL),
            replacementIdentifier
        )
    }

    func testDecodeRejectsPayloadBeyondSupportedLimit() {
        let data = Data(
            count: TextFileCodec.maximumDocumentByteCount + 1
        )

        XCTAssertThrowsError(try TextFileCodec.decode(data)) { error in
            XCTAssertEqual(
                error as? TextFileCodec.CodecError,
                .documentTooLarge(
                    byteCount: data.count,
                    maximumByteCount: TextFileCodec.maximumDocumentByteCount
                )
            )
        }
    }

    func testUTF8BOMAndMixedNewlinesRoundTrip() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\n".utf8)
        let snapshot = try TextFileCodec.decode(original)
        XCTAssertEqual(snapshot.format.encoding, .utf8WithBOM)
        XCTAssertEqual(snapshot.text, "a\r\nb\n")
        XCTAssertEqual(try TextFileCodec.encode(snapshot), original)
    }

    func testInvalidUTF8FailsWithoutLossyConversion() {
        XCTAssertThrowsError(try TextFileCodec.decode(Data([0xFF, 0x00, 0x41])))
    }

    func testUTF16LittleEndianRoundTrips() throws {
        let snapshot = DocumentSnapshot(
            text: "Hello 中\r\n",
            format: TextFileFormat(
                encoding: .utf16LittleEndian,
                dominantNewline: .crlf,
                hasFinalNewline: true
            )
        )
        XCTAssertEqual(
            try TextFileCodec.decode(TextFileCodec.encode(snapshot)),
            snapshot
        )
    }

    func testUTF16BigEndianRoundTrips() throws {
        let snapshot = DocumentSnapshot(
            text: "😀\n",
            format: TextFileFormat(
                encoding: .utf16BigEndian,
                dominantNewline: .lf,
                hasFinalNewline: true
            )
        )
        XCTAssertEqual(
            try TextFileCodec.decode(TextFileCodec.encode(snapshot)),
            snapshot
        )
    }

    func testPrepareSavePayloadStopsWhenEncodingIsCancelled() {
        let snapshot = DocumentSnapshot(
            text: String(repeating: "abcdef\n", count: 20_000),
            format: .newDocument
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try TextFileCodec.prepareSavePayload(
                for: snapshot,
                cancellationCheck: {
                    cancellationChecks += 1
                    if cancellationChecks == 3 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 3)
    }

    func testPrepareSavePayloadRejectsOversizedEncodingAtPreflightWithExactByteCount() {
        let codeUnitCount = TextFileCodec.maximumDocumentByteCount / 2 + 100_000
        let snapshot = DocumentSnapshot(
            text: String(repeating: "a", count: codeUnitCount),
            format: TextFileFormat(
                encoding: .utf16LittleEndian,
                dominantNewline: .lf,
                hasFinalNewline: false
            )
        )
        let expectedByteCount = 2 + codeUnitCount * 2

        XCTAssertThrowsError(
            try TextFileCodec.prepareSavePayload(for: snapshot)
        ) { error in
            XCTAssertEqual(
                error as? TextFileCodec.CodecError,
                .documentTooLarge(
                    byteCount: expectedByteCount,
                    maximumByteCount: TextFileCodec.maximumDocumentByteCount
                )
            )
        }
    }

    func testExternalEvidenceRejectsOversizedPayloadBeforeFingerprintValidation() {
        let data = Data(count: TextFileCodec.maximumDocumentByteCount + 1)
        let targetURL = URL(fileURLWithPath: "/tmp/oversized.md")
        let fingerprint = FileFingerprint(
            byteCount: 0,
            contentDigest: "not-the-payload",
            resourceIdentifier: nil
        )

        XCTAssertThrowsError(
            try TextFileCodec.decodeExternalChange(
                data: data,
                targetURL: targetURL,
                identity: .make(url: targetURL),
                fingerprint: fingerprint
            )
        ) { error in
            XCTAssertEqual(
                error as? TextFileCodec.CodecError,
                .documentTooLarge(
                    byteCount: data.count,
                    maximumByteCount: TextFileCodec.maximumDocumentByteCount
                )
            )
        }
    }

    func testDurableBaselineRejectsOversizedPayloadBeforeFingerprintValidation() {
        let data = Data(count: TextFileCodec.maximumDocumentByteCount + 1)
        let targetURL = URL(fileURLWithPath: "/tmp/oversized-baseline.md")
        let fingerprint = FileFingerprint(
            byteCount: 0,
            contentDigest: "not-the-payload",
            resourceIdentifier: nil
        )

        XCTAssertThrowsError(
            try TextFileCodec.durableBaseline(
                data: data,
                targetURL: targetURL,
                fingerprint: fingerprint,
                documentIdentity: .make(url: targetURL),
                sourceRevision: SourceRevision(number: 1, text: ""),
                commitGeneration: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? TextFileCodec.CodecError,
                .documentTooLarge(
                    byteCount: data.count,
                    maximumByteCount: TextFileCodec.maximumDocumentByteCount
                )
            )
        }
    }

    func testReadSupportedDataWhenURLIsFIFORejectsWithoutWaitingForWriter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifoURL = directory.appendingPathComponent("document.md")
        XCTAssertEqual(
            fifoURL.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) },
            0
        )
        let recorder = TextFileReadResultRecorder()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                recorder.recordSuccess(
                    try TextFileCodec.readSupportedData(at: fifoURL)
                )
            } catch {
                recorder.recordFailure(error)
            }
            finished.signal()
        }

        let earlyResult = finished.wait(timeout: .now() + .milliseconds(500))
        if earlyResult == .timedOut {
            let releaseDescriptor = fifoURL.path.withCString {
                Darwin.open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            }
            if releaseDescriptor >= 0 {
                Darwin.close(releaseDescriptor)
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        }

        XCTAssertEqual(earlyResult, .success)
        XCTAssertFalse(recorder.didSucceed)
        XCTAssertNotNil(recorder.error)
    }
}

private final class TextFileReadResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false
    private var recordedError: Error?

    var didSucceed: Bool {
        lock.withLock { succeeded }
    }

    var error: Error? {
        lock.withLock { recordedError }
    }

    func recordSuccess(_ data: Data) {
        _ = data
        lock.withLock { succeeded = true }
    }

    func recordFailure(_ error: Error) {
        lock.withLock { recordedError = error }
    }
}
