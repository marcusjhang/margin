import Foundation

/// Usage fetched live from a provider's own endpoint.
struct LiveUsage {
    let windows: [UsageWindow]
    let planLabel: String?
    let fetchedAt: Date
}

/// Short-lived cache so the 60s refresh doesn't hammer the endpoints. Anthropic
/// in particular rate-limits aggressively.
final class LiveUsageCache: @unchecked Sendable {
    static let shared = LiveUsageCache()

    let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [ProviderID: (storedAt: Date, usage: LiveUsage)] = [:]

    init(ttl: TimeInterval = 120) {
        self.ttl = ttl
    }

    func cached(_ provider: ProviderID, now: Date = Date()) -> LiveUsage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[provider], now.timeIntervalSince(entry.storedAt) < ttl else { return nil }
        return entry.usage
    }

    func store(_ provider: ProviderID, usage: LiveUsage) {
        lock.lock()
        defer { lock.unlock() }
        entries[provider] = (Date(), usage)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
