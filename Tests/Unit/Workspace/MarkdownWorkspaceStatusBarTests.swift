import XCTest

@testable import DarthScriptum

@MainActor
final class MarkdownWorkspaceStatusBarTests: XCTestCase {
    func testRenderWhenDocumentUsesDefaultFormatOmitsFormatIndicators() {
        let (workspace, syncCoordinator) = makeWorkspace()
        defer { syncCoordinator.close() }
        let textValues = reflectedStrings(in: workspace.body)

        XCTAssertTrue(textValues.contains("fixture.md"))
        XCTAssertFalse(textValues.contains("UTF-8"))
        XCTAssertFalse(textValues.contains("LF"))
    }

    func testRenderWhenFooterControlsAreAvailableOmitsSplitToggle() {
        let (workspace, syncCoordinator) = makeWorkspace()
        defer { syncCoordinator.close() }

        XCTAssertEqual(
            reflectedValueCount(
                withTypePrefix: "SwiftUI.Button<",
                in: workspace.body
            ),
            1
        )
    }

    private func makeWorkspace() -> (MarkdownWorkspace, DocumentSyncCoordinator) {
        let syncCoordinator = DocumentSyncCoordinator(
            snapshot: DocumentSnapshot(
                text: "",
                format: .newDocument
            )
        )
        return (
            MarkdownWorkspace(
                syncCoordinator: syncCoordinator,
                model: WorkspaceModel(),
                fileName: "fixture.md"
            ),
            syncCoordinator
        )
    }

    private func reflectedStrings(in value: Any, depth: Int = 0) -> [String] {
        if let string = value as? String {
            return [string]
        }
        guard depth < 40 else { return [] }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return [] }
        return mirror.children.flatMap {
            reflectedStrings(in: $0.value, depth: depth + 1)
        }
    }

    private func reflectedValueCount(
        withTypePrefix typePrefix: String,
        in value: Any,
        depth: Int = 0
    ) -> Int {
        guard depth < 40 else { return 0 }
        let currentCount =
            String(reflecting: type(of: value)).hasPrefix(typePrefix)
            ? 1
            : 0
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return currentCount }
        return currentCount
            + mirror.children.reduce(into: 0) { count, child in
                count += reflectedValueCount(
                    withTypePrefix: typePrefix,
                    in: child.value,
                    depth: depth + 1
                )
            }
    }
}
