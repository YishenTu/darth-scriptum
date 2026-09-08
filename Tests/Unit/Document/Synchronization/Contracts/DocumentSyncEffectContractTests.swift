import Foundation
import XCTest

@testable import DarthScriptum

final class DocumentSyncEffectContractTests: XCTestCase {
    func testEvidenceReceiptsRejectForeignDocumentIdentity() throws {
        let targetURL = URL(fileURLWithPath: "/tmp/evidence-target.md")
        let foreignIdentity = DocumentIdentity.make(
            url: URL(fileURLWithPath: "/tmp/evidence-foreign.md")
        )
        let source = SourceRevision(number: 3, text: "source")
        let snapshot = DocumentSnapshot(text: "source", format: .newDocument)
        let data = try TextFileCodec.encode(snapshot)
        let fingerprint = FileFingerprint.make(
            data: data,
            resourceIdentifier: "evidence-resource"
        )

        XCTAssertThrowsError(
            try TextFileCodec.durableBaseline(
                data: data,
                targetURL: targetURL,
                fingerprint: fingerprint,
                documentIdentity: foreignIdentity,
                sourceRevision: source,
                commitGeneration: 9
            )
        ) { error in
            XCTAssertEqual(
                error as? TextFileCodec.EvidenceError,
                .identityDoesNotMatchTarget
            )
        }

        let pendingSave = PendingSaveToken(
            generation: 9,
            sourceRevision: source,
            preparedPayload: try TextFileCodec.prepareSavePayload(
                for: snapshot
            ),
            expectedDurableState: nil,
            targetURL: targetURL
        )
        XCTAssertNil(
            DocumentSyncDurableBaseline.fromCommittedPayload(
                pendingSave,
                documentIdentity: foreignIdentity,
                committedFingerprint: pendingSave.contentFingerprint,
                sourceRevision: source,
                commitGeneration: 9
            )
        )
    }
}
