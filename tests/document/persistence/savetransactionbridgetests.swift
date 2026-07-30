import XCTest
@testable import DarthScriptum

final class SaveTransactionBridgeTests: XCTestCase {
    func testTypedTransactionRejectsACompletionForAnotherEffectToken() throws {
        let bridge = SaveTransactionBridge()
        let request = try makeCommitRequest(attempt: 4)
        let differentToken = SyncEffectToken(
            lifetime: request.token.lifetime,
            attachmentEpoch: request.token.attachmentEpoch,
            operation: .saveCommit,
            attempt: request.token.attempt + 1
        )

        try bridge.install(request)
        try bridge.store(
            FileCommitResult(
                generation: request.pendingSave.generation,
                committedFingerprint: request.pendingSave.contentFingerprint,
                displacedPreimage: nil,
                safety: .atomicSwap
            ),
            for: request.token
        )

        XCTAssertThrowsError(try bridge.finish(token: differentToken)) {
            XCTAssertEqual(
                $0 as? SaveTransactionBridge.BridgeError,
                .effectTokenMismatch
            )
        }
        XCTAssertEqual(
            try bridge.finish(token: request.token).generation,
            request.pendingSave.generation
        )
    }

    func testTokenResultOrderingAndGenerationValidation() throws {
        let bridge = SaveTransactionBridge()
        let data = Data("text".utf8)
        let token = PendingSaveToken(
            generation: 4,
            sourceRevision: SourceRevision(number: 2, text: "text"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: DocumentSnapshot(text: "text", format: .newDocument)
            ),
            expectedDurableState: nil,
            targetURL: URL(fileURLWithPath: "/tmp/file.md")
        )
        try bridge.install(token)
        XCTAssertThrowsError(
            try bridge.store(
                FileCommitResult(
                    generation: 5,
                    committedFingerprint: .make(data: data),
                    displacedPreimage: nil,
                    safety: .atomicSwap
                )
            )
        )
        let result = FileCommitResult(
            generation: 4,
            committedFingerprint: .make(data: data),
            displacedPreimage: nil,
            safety: .atomicSwap
        )
        try bridge.store(result)
        XCTAssertEqual(try bridge.finish(generation: 4), result)
        XCTAssertThrowsError(try bridge.currentToken())
    }

    private func makeCommitRequest(
        attempt: UInt64
    ) throws -> DocumentSyncSaveCommitRequest {
        let targetURL = URL(fileURLWithPath: "/tmp/typed-bridge.md")
        let identity = DocumentIdentity.make(url: targetURL)
        let snapshot = DocumentSnapshot(text: "typed", format: .newDocument)
        let pendingSave = PendingSaveToken(
            generation: attempt,
            sourceRevision: SourceRevision(number: attempt, text: "typed"),
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: snapshot
            ),
            expectedDurableState: nil,
            targetURL: targetURL
        )
        return DocumentSyncSaveCommitRequest(
            token: SyncEffectToken(
                lifetime: UUID(),
                attachmentEpoch: 2,
                operation: .saveCommit,
                attempt: attempt
            ),
            pendingSave: pendingSave,
            targetURL: targetURL,
            identity: identity,
            attachmentEpoch: 2,
            expectedBaseline: nil,
            commitGeneration: attempt
        )
    }
}
