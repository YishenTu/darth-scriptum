import XCTest
@testable import DarthScriptum

@MainActor
final class SyncSchedulerTests: XCTestCase {
    func testManualSchedulerOrdersDeadlinesAndReplacesNamedWork() {
        let scheduler = ManualSyncScheduler()
        let localOriginal = deadline(kind: .localSave, attempt: 1)
        let localReplacement = deadline(kind: .localSave, attempt: 2)
        let external = deadline(kind: .externalRead, attempt: 3)

        scheduler.schedule(localOriginal, after: .seconds(5))
        scheduler.schedule(external, after: .seconds(2))
        scheduler.schedule(localReplacement, after: .seconds(3))

        XCTAssertEqual(scheduler.advance(by: .seconds(2)), [external])
        XCTAssertEqual(scheduler.advance(by: .seconds(1)), [localReplacement])
        XCTAssertTrue(scheduler.advance(by: .seconds(10)).isEmpty)
    }

    func testManualSchedulerCancelsOneDeadlineAndCanClearAllWork() {
        let scheduler = ManualSyncScheduler()
        let local = deadline(kind: .localSave, attempt: 1)
        let external = deadline(kind: .externalRead, attempt: 2)

        scheduler.schedule(local, after: .seconds(1))
        scheduler.schedule(external, after: .seconds(1))
        scheduler.cancel(local)
        XCTAssertEqual(scheduler.advance(by: .seconds(1)), [external])

        scheduler.schedule(local, after: .seconds(1))
        scheduler.cancelAll()
        XCTAssertTrue(scheduler.advance(by: .seconds(1)).isEmpty)
    }

    func testManualSchedulerRejectsStaleCancellationAfterReplacement() {
        let scheduler = ManualSyncScheduler()
        let original = deadline(kind: .localSave, attempt: 1)
        let replacement = deadline(kind: .localSave, attempt: 2)

        scheduler.schedule(original, after: .seconds(1))
        scheduler.schedule(replacement, after: .seconds(1))
        scheduler.cancel(original)

        XCTAssertEqual(scheduler.advance(by: .seconds(1)), [replacement])
    }

    private func deadline(
        kind: SyncDeadlineKind,
        attempt: UInt64
    ) -> SyncDeadline {
        SyncDeadline(
            kind: kind,
            token: SyncEffectToken(
                lifetime: UUID(),
                attachmentEpoch: 1,
                operation: kind.operation,
                attempt: attempt
            )
        )
    }
}
