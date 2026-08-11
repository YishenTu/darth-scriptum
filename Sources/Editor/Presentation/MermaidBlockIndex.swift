import Foundation

@MainActor
final class MermaidBlockIndex {
    typealias Parser =
        @Sendable (
            _ source: String,
            _ shouldCancel: @Sendable () -> Bool
        ) -> [MermaidFencedBlock]

    private struct Request: Equatable {
        let revisionNumber: UInt64
        let sourceRange: NSRange
    }

    private let parser: Parser
    private var cachedRequest: Request?
    private var cachedBlocks: [MermaidFencedBlock] = []
    private var inFlightRequest: Request?
    private var inFlightTask: Task<[MermaidFencedBlock], Never>?

    init(
        parser: @escaping Parser = { source, shouldCancel in
            MermaidFencedBlockParser.blocks(
                in: source,
                shouldCancel: shouldCancel
            )
        }
    ) {
        self.parser = parser
    }

    deinit {
        inFlightTask?.cancel()
    }

    func blocks(
        revisionNumber: UInt64,
        sourceRange: NSRange,
        source: String,
        containsCandidate: Bool
    ) async -> [MermaidFencedBlock] {
        let request = Request(
            revisionNumber: revisionNumber,
            sourceRange: sourceRange
        )
        guard containsCandidate else {
            recordNoCandidates(
                revisionNumber: revisionNumber,
                sourceRange: sourceRange
            )
            return []
        }
        if cachedRequest == request {
            return cachedBlocks
        }

        let task: Task<[MermaidFencedBlock], Never>
        if inFlightRequest == request,
            let inFlightTask
        {
            task = inFlightTask
        } else {
            inFlightTask?.cancel()
            let parser = self.parser
            task = Task.detached(priority: .utility) {
                parser(source) { Task.isCancelled }
            }
            inFlightRequest = request
            inFlightTask = task
        }

        let blocks = await task.value
        if inFlightRequest == request {
            cachedRequest = request
            cachedBlocks = blocks
            inFlightRequest = nil
            inFlightTask = nil
        }
        return blocks
    }

    func recordNoCandidates(
        revisionNumber: UInt64,
        sourceRange: NSRange
    ) {
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightRequest = nil
        cachedRequest = Request(
            revisionNumber: revisionNumber,
            sourceRange: sourceRange
        )
        cachedBlocks = []
    }
}
