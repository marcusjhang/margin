import Foundation

/// Usage fetched live from a provider's own endpoint.
struct LiveUsage {
    let windows: [UsageWindow]
    let planLabel: String?
    let fetchedAt: Date
}

/// Cache of live results that also bounds how often we hit the endpoints.
///
/// - A successful result is fresh for `ttl`.
/// - A user-initiated (forced) check is allowed at most once per `forceFloor`.
/// - The last good value is retained even when stale, so a failed refresh
///   doesn't discard it and fall back to older local data.
final class LiveUsageCache: @unchecked Sendable {
    static let shared = LiveUsageCache()

    let ttl: TimeInterval
    let forceFloor: TimeInterval

    private let lock = NSLock()
    private var entries: [ProviderID: (usage: LiveUsage, storedAt: Date)] = [:]
    private var attempts: [ProviderID: Date] = [:]

    init(ttl: TimeInterval = 120, forceFloor: TimeInterval = 20) {
        self.ttl = ttl
        self.forceFloor = forceFloor
    }

    /// Whether a network attempt is allowed now. Non-forced attempts are
    /// limited to once per `ttl` (so failures aren't retried every 60s tick);
    /// forced attempts to once per `forceFloor`.
    func shouldAttempt(_ provider: ProviderID, force: Bool, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = attempts[provider] else { return true }
        return now.timeIntervalSince(last) >= (force ? forceFloor : ttl)
    }

    func noteAttempt(_ provider: ProviderID, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        attempts[provider] = now
    }

    func store(_ provider: ProviderID, usage: LiveUsage, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[provider] = (usage, now)
    }

    /// The last stored usage. With `allowStale` false, only a fresh one.
    func usage(_ provider: ProviderID, allowStale: Bool, now: Date = Date()) -> LiveUsage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[provider] else { return nil }
        if allowStale { return entry.usage }
        return now.timeIntervalSince(entry.storedAt) < ttl ? entry.usage : nil
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        attempts.removeAll()
    }
}
