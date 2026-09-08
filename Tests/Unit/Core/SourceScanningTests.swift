import Foundation
import XCTest

@testable import DarthScriptum

final class SourceScanningTests: XCTestCase {
    func testDifferenceMatchesReferenceAcrossBufferAndUnicodeBoundaries() {
        let fragments = ["", "x", "\r\n", "😀", "😁", "中", "e\u{301}", "é"]
        for padding in [0, 1, 1_023, 1_024, 1_025, 2_047, 2_048] {
            let prefix = String(repeating: "a", count: padding)
            let suffix = String(repeating: "z", count: padding)
            for old in fragments {
                for new in fragments {
                    let original = (prefix + old + suffix) as NSString
                    let updated = (prefix + new + suffix) as NSString
                    let difference = UTF16TextDifference.between(
                        original: original, updated: updated)
                    XCTAssertEqual(difference, referenceDifference(original, updated))
                    let reconstructed = NSMutableString(string: original)
                    reconstructed.replaceCharacters(
                        in: difference.originalRange,
                        with: updated.substring(with: difference.updatedRange))
                    XCTAssertEqual(reconstructed, updated)
                }
            }
        }
    }

    func testMetricsPreserveASCIIFoldingAndUnicodeLineSeparators() {
        let text =
            "mermermaid MERMAID mermaidmermaid mermMermaid\r\n"
            + "中文 😀 e\u{301}\u{2028}next\u{2029}\r\n\r\n\n\r"
        let metrics = DocumentMetrics(text: text)
        XCTAssertEqual(metrics.utf8ByteCount, text.utf8.count)
        XCTAssertEqual(metrics.lineCount, 8)
        XCTAssertEqual(metrics.mermaidCandidateCount, 5)
        XCTAssertEqual(DocumentMetrics(text: "").lineCount, 1)
        XCTAssertEqual(DocumentMetrics(text: "mermaİd").mermaidCandidateCount, 0)
    }

    func testLineIndexEditsPreserveCRLFAtEveryRescanBoundary() throws {
        let fragments = ["", "a", "\r", "\n", "\r\n", "\n\r", "😀e\u{301}"]
        for prefix in fragments {
            for suffix in fragments {
                let source = prefix + "\r\nx\r\n" + suffix
                let revision = SourceRevision(number: 0, text: source)
                let length = (source as NSString).length
                for location in 0...length {
                    for removal in 0...min(3, length - location) {
                        for replacement in fragments {
                            let edit = SourceEdit(
                                range: NSRange(location: location, length: removal),
                                replacement: replacement,
                                expectedRevision: 0,
                                origin: .localEditor(paneID: UUID())
                            )
                            guard let updated = try? edit.applying(to: revision) else { continue }
                            var index = SourceLineIndex(text: source)
                            XCTAssertTrue(
                                index.apply(edit, previousText: source, updatedText: updated.text))
                            let reference = SourceLineIndex(text: updated.text)
                            for offset in 0...(updated.text as NSString).length {
                                let actual = index.position(
                                    atUTF16Location: offset, in: updated.text)
                                let expected = reference.position(
                                    atUTF16Location: offset, in: updated.text)
                                XCTAssertEqual(actual.line, expected.line)
                                XCTAssertEqual(actual.column, expected.column)
                            }
                        }
                    }
                }
            }
        }
    }

    private func referenceDifference(_ original: NSString, _ updated: NSString)
        -> UTF16TextDifference
    {
        var prefix = 0
        while prefix < min(original.length, updated.length),
            original.character(at: prefix) == updated.character(at: prefix)
        {
            prefix += 1
        }
        if UTF16TextDifference.splitsSurrogatePair(at: prefix, in: original)
            || UTF16TextDifference.splitsSurrogatePair(at: prefix, in: updated)
        {
            prefix -= 1
        }
        var suffix = 0
        while suffix < min(original.length, updated.length) - prefix,
            original.character(at: original.length - suffix - 1)
                == updated.character(at: updated.length - suffix - 1)
        {
            suffix += 1
        }
        if UTF16TextDifference.splitsSurrogatePair(at: original.length - suffix, in: original)
            || UTF16TextDifference.splitsSurrogatePair(at: updated.length - suffix, in: updated)
        {
            suffix -= 1
        }
        return UTF16TextDifference(
            originalRange: NSRange(location: prefix, length: original.length - prefix - suffix),
            updatedRange: NSRange(location: prefix, length: updated.length - prefix - suffix)
        )
    }
}
