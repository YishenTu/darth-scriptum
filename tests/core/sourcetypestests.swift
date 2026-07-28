import Foundation
import XCTest
@testable import DarthScriptum

final class SourceTypesTests: XCTestCase {
    func testEditUsesUTF16Ranges() throws {
        let revision = SourceRevision(number: 4, text: "a😀中")
        let edit = SourceEdit(
            range: NSRange(location: 1, length: 2),
            replacement: "b",
            expectedRevision: 4,
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertEqual(
            try edit.applying(to: revision),
            SourceRevision(number: 5, text: "ab中")
        )
    }

    func testStaleEditIsRejected() {
        let edit = SourceEdit(
            range: NSRange(location: 0, length: 0),
            replacement: "x",
            expectedRevision: 1,
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertThrowsError(
            try edit.applying(to: SourceRevision(number: 2, text: ""))
        )
    }

    func testEditRejectsRangeThatSplitsSurrogatePair() {
        let revision = SourceRevision(number: 0, text: "😀")
        let edit = SourceEdit(
            range: NSRange(location: 1, length: 1),
            replacement: "x",
            expectedRevision: 0,
            origin: .localEditor(paneID: UUID())
        )
        XCTAssertThrowsError(try edit.applying(to: revision))
    }

    func testDurableStateIsIndependentOfNewerVisibleRevision() {
        let data = Data("base".utf8)
        let durable = DurableFileState(
            snapshot: DocumentSnapshot(text: "base", format: .newDocument),
            fingerprint: .make(data: data),
            generation: 7
        )
        let visible = SourceRevision(number: 8, text: "newer")
        XCTAssertEqual(durable.snapshot.text, "base")
        XCTAssertEqual(visible.text, "newer")
        XCTAssertNotEqual(durable.generation, visible.number)
    }

    func testFingerprintUsesContentsNotOnlySize() {
        XCTAssertNotEqual(
            FileFingerprint.make(data: Data("one".utf8)),
            FileFingerprint.make(data: Data("two".utf8))
        )
    }

    func testSnapshotContractsAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(SourceRevision.self)
        requireSendable(DocumentSnapshot.self)
        requireSendable(DurableFileState.self)
        requireSendable(PendingSaveToken.self)
    }
}
