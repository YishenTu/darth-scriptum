import Foundation

@MainActor
final class SyncScheduler {
    private let onDeadline: @MainActor @Sendable (SyncDeadline) -> Void
    private var taskIdentifiers: [SyncDeadlineKind: UUID] = [:]
    private var tasks: [SyncDeadlineKind: Task<Void, Never>] = [:]
    private var deadlines: [SyncDeadlineKind: SyncDeadline] = [:]

    init(
        onDeadline: @escaping @MainActor @Sendable (SyncDeadline) -> Void
    ) {
        self.onDeadline = onDeadline
    }

    func schedule(_ request: SyncDeadlineRequest) {
        cancelCurrent(request.deadline.kind)
        let identifier = UUID()
        taskIdentifiers[request.deadline.kind] = identifier
        deadlines[request.deadline.kind] = request.deadline
        tasks[request.deadline.kind] = Task { [weak self] in
            do {
                try await Task.sleep(for: request.delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fire(request.deadline, identifier: identifier)
        }
    }

    func cancel(_ deadline: SyncDeadline) {
        guard deadlines[deadline.kind] == deadline else { return }
        cancelCurrent(deadline.kind)
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        taskIdentifiers.removeAll()
        deadlines.removeAll()
    }

    private func fire(_ deadline: SyncDeadline, identifier: UUID) {
        guard taskIdentifiers[deadline.kind] == identifier,
            deadlines[deadline.kind] == deadline
        else {
            return
        }
        tasks.removeValue(forKey: deadline.kind)
        taskIdentifiers.removeValue(forKey: deadline.kind)
        deadlines.removeValue(forKey: deadline.kind)
        onDeadline(deadline)
    }

    private func cancelCurrent(_ kind: SyncDeadlineKind) {
        tasks.removeValue(forKey: kind)?.cancel()
        taskIdentifiers.removeValue(forKey: kind)
        deadlines.removeValue(forKey: kind)
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}

@MainActor
final class ManualSyncScheduler {
    private struct ScheduledDeadline: Equatable {
        let deadline: SyncDeadline
        let due: Duration
        let order: UInt64
    }

    private var now: Duration = .zero
    private var nextOrder: UInt64 = 0
    private var scheduled: [SyncDeadlineKind: ScheduledDeadline] = [:]

    func schedule(_ deadline: SyncDeadline, after delay: Duration) {
        let scheduledDeadline = ScheduledDeadline(
            deadline: deadline,
            due: now + delay,
            order: nextOrder
        )
        nextOrder &+= 1
        scheduled[deadline.kind] = scheduledDeadline
    }

    func cancel(_ deadline: SyncDeadline) {
        guard scheduled[deadline.kind]?.deadline == deadline else { return }
        scheduled.removeValue(forKey: deadline.kind)
    }

    func cancelAll() {
        scheduled.removeAll()
    }

    func advance(by duration: Duration) -> [SyncDeadline] {
        now += duration
        let due = scheduled.values
            .filter { $0.due <= now }
            .sorted { lhs, rhs in
                if lhs.due == rhs.due {
                    return lhs.order < rhs.order
                }
                return lhs.due < rhs.due
            }
        for item in due {
            guard scheduled[item.deadline.kind] == item else { continue }
            scheduled.removeValue(forKey: item.deadline.kind)
        }
        return due.map(\.deadline)
    }
}
