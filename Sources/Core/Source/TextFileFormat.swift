enum NewlineStyle: String, Sendable, Equatable {
    case lf
    case crlf

    var sequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        }
    }
}

enum TextEncoding: String, Sendable, Equatable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian
}

struct TextFileFormat: Sendable, Equatable {
    var encoding: TextEncoding
    var dominantNewline: NewlineStyle
    var hasFinalNewline: Bool

    static let newDocument = TextFileFormat(
        encoding: .utf8,
        dominantNewline: .lf,
        hasFinalNewline: false
    )
}

struct DocumentSnapshot: Sendable, Equatable {
    var text: String
    var format: TextFileFormat
}
