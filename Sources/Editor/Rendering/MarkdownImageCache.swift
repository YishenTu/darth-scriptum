import AppKit
import Foundation

struct MarkdownImageCache {
    static let defaultMaximumEntryCount = 128
    static let defaultMaximumCost = 64 * 1_024 * 1_024

    private struct Entry {
        let image: NSImage
        let cost: Int
        var accessOrder: UInt64
    }

    private let maximumEntryCount: Int
    private let maximumCost: Int
    private var entries: [URL: Entry] = [:]
    private var nextAccessOrder: UInt64 = 0
    private(set) var totalCost = 0

    init(
        maximumEntryCount: Int = Self.defaultMaximumEntryCount,
        maximumCost: Int = Self.defaultMaximumCost
    ) {
        self.maximumEntryCount = max(maximumEntryCount, 0)
        self.maximumCost = max(maximumCost, 0)
    }

    var entryCount: Int {
        entries.count
    }

    mutating func image(for url: URL) -> NSImage? {
        guard var entry = entries[url] else { return nil }
        nextAccessOrder &+= 1
        entry.accessOrder = nextAccessOrder
        entries[url] = entry
        return entry.image
    }

    @discardableResult
    mutating func insert(
        _ image: NSImage,
        for url: URL,
        cost: Int
    ) -> [URL] {
        guard maximumEntryCount > 0,
            cost >= 0,
            cost <= maximumCost
        else {
            return []
        }
        var evictedURLs: [URL] = []
        if let existing = entries.removeValue(forKey: url) {
            totalCost -= existing.cost
        }
        while entries.count >= maximumEntryCount
            || totalCost + cost > maximumCost
        {
            guard
                let eviction = entries.min(by: {
                    $0.value.accessOrder < $1.value.accessOrder
                })
            else {
                return evictedURLs
            }
            entries.removeValue(forKey: eviction.key)
            totalCost -= eviction.value.cost
            evictedURLs.append(eviction.key)
        }
        nextAccessOrder &+= 1
        entries[url] = Entry(
            image: image,
            cost: cost,
            accessOrder: nextAccessOrder
        )
        totalCost += cost
        return evictedURLs
    }

    @discardableResult
    mutating func removeImage(for url: URL) -> NSImage? {
        guard let entry = entries.removeValue(forKey: url) else {
            return nil
        }
        totalCost -= entry.cost
        return entry.image
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        totalCost = 0
    }
}
