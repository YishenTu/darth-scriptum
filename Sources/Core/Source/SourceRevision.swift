struct SourceRevision: Sendable, Equatable, Hashable {
    let number: UInt64
    let text: String

    func advanced(to text: String) -> SourceRevision {
        SourceRevision(number: number &+ 1, text: text)
    }
}
