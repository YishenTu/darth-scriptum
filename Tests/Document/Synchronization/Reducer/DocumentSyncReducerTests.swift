import Foundation
import XCTest

@testable import DarthScriptum

@MainActor
final class DocumentSyncReducerTests: XCTestCase {
    let lifetime = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let documentURL = URL(fileURLWithPath: "/tmp/document-sync-contract.md")
}
