import Foundation

enum TextFileCodec {
    nonisolated static func decode(_ data: Data) throws -> DocumentSnapshot {
        let encoding: TextEncoding
        let text: String

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8WithBOM
            guard let value = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            guard let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            guard let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        } else {
            encoding = .utf8
            guard let value = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = value
        }

        let newlineCounts = countNewlines(in: text)

        return DocumentSnapshot(
            text: text,
            format: TextFileFormat(
                encoding: encoding,
                dominantNewline: newlineCounts.crlf > newlineCounts.lf
                    ? .crlf
                    : .lf,
                hasFinalNewline: text.utf16.last == 0x000A
            )
        )
    }

    nonisolated static func encode(_ snapshot: DocumentSnapshot) throws -> Data {
        let encoding: String.Encoding
        let bom: [UInt8]
        switch snapshot.format.encoding {
        case .utf8:
            encoding = .utf8
            bom = []
        case .utf8WithBOM:
            encoding = .utf8
            bom = [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian:
            encoding = .utf16LittleEndian
            bom = [0xFF, 0xFE]
        case .utf16BigEndian:
            encoding = .utf16BigEndian
            bom = [0xFE, 0xFF]
        }
        guard let body = snapshot.text.data(
            using: encoding,
            allowLossyConversion: false
        ) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        var encoded = Data()
        encoded.reserveCapacity(bom.count + body.count)
        encoded.append(contentsOf: bom)
        encoded.append(body)
        return encoded
    }

    private nonisolated static func countNewlines(
        in text: String
    ) -> (crlf: Int, lf: Int) {
        var crlf = 0
        var lf = 0
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x000A {
                if previousWasCarriageReturn {
                    crlf += 1
                } else {
                    lf += 1
                }
            }
            previousWasCarriageReturn = scalar.value == 0x000D
        }
        return (crlf, lf)
    }
}
