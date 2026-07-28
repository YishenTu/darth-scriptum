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

        let crlfCount = text.components(separatedBy: "\r\n").count - 1
        let lfCount = text.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } - crlfCount

        return DocumentSnapshot(
            text: text,
            format: TextFileFormat(
                encoding: encoding,
                dominantNewline: crlfCount > lfCount ? .crlf : .lf,
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
        return Data(bom) + body
    }
}
