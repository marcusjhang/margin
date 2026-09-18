import Foundation

public struct BackfillReport: Sendable, Equatable {
    public let codex: Int
    public let claude: Int

    public init(codex: Int, claude: Int) {
        self.codex = codex
        self.claude = claude
    }

    public var total: Int { codex + claude }
}

/// Seeds the local history from logs that already exist on disk, so charts
/// have shape on first launch.
///
/// Codex rollout logs carry timestamped `rate_limits` snapshots, so they
/// backfill richly. Claude only exposes its latest cached utilization, so it
/// contributes a single snapshot; its history builds forward from now.
public enum HistoryBackfill {
    /// Charts span 24h and forecasts look back at most one window, so a few
    /// days of history is plenty — and keeps the scan fast.
    public static let windowDays = 7

    @discardableResult
    public static func run(
        history: HistoryStore,
        windowDays: Int = HistoryBackfill.windowDays,
        now: Date = Date()
    ) -> BackfillReport {
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)

        let codex = CodexRolloutScanner.samples(since: since)
            .filter { $0.timestamp >= since && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        history.record(codex)

        let claude = claudeSnapshot(since: since, now: now)
        history.record(claude)

        return BackfillReport(codex: codex.count, claude: claude.count)
    }

    private static func claudeSnapshot(since: Date, now: Date) -> [UsageSample] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              let cached = ClaudeUsageParser.parseCachedUsage(data, now: now),
              cached.updatedAt >= since else {
            return []
        }
        return cached.windows.map {
            UsageSample(provider: .claude, windowID: $0.id, usedPercent: $0.usedPercent, timestamp: cached.updatedAt)
        }
    }
}
