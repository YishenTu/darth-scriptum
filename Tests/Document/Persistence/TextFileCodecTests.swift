import XCTest

@testable import DarthScriptum

final class TextFileCodecTests: XCTestCase {
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
}
