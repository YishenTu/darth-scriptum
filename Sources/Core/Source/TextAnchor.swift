struct TextAnchor: Sendable, Equatable {
    var line: Int
    var column: Int
    var contextBefore: String
    var contextAfter: String
}
