import CryptoKit
import Foundation

struct FileFingerprint: Sendable, Equatable, Hashable {
    let byteCount: Int
    let contentDigest: String
    let resourceIdentifier: String?

    static func make(data: Data, resourceIdentifier: String? = nil) -> FileFingerprint {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return FileFingerprint(
            byteCount: data.count,
            contentDigest: digest,
            resourceIdentifier: resourceIdentifier
        )
    }
}

struct DocumentIdentity: Sendable, Equatable, Hashable {
    let stableKey: String

    static func make(url: URL, resourceIdentifier: String? = nil) -> DocumentIdentity {
        _ = resourceIdentifier
        let canonicalPath = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return DocumentIdentity(stableKey: "path:\(canonicalPath)")
    }

    func matches(url: URL) -> Bool {
        self == Self.make(url: url)
    }
}
