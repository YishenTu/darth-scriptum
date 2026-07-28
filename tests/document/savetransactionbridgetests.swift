import XCTest
@testable import DarthScriptum

final class SaveTransactionBridgeTests: XCTestCase {
    func testTokenResultOrderingAndGenerationValidation() throws {
        let bridge = SaveTransactionBridge()
        let data = Data("text".utf8)
        let token = PendingSaveToken(
            generation: 4,
            sourceRevision: SourceRevision(number: 2, text: "text"),
            snapshot: DocumentSnapshot(text: "text", format: .newDocument),
            encodedData: data,
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
}
