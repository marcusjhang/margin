import Foundation

/// Finds Codex rate-limit snapshots and samples from local rollout logs.
///
/// Codex writes a `rate_limits` block on every `token_count` event and an
/// explicit `usage_limit_exceeded` error on `task_complete` when capped.
public enum CodexRolloutScanner {
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// The most recent snapshot across the newest sessions, chosen by the
    /// snapshot's own timestamp (not just file mtime).
    public static func latestSnapshot(limit: Int = 40, root: URL? = nil) -> CodexRolloutParser.Snapshot? {
        var best: CodexRolloutParser.Snapshot?
        var checked = 0
        for file in rolloutFiles(root: root).prefix(limit) {
            guard let lines = lines(in: file) else { continue }
            if let snapshot = CodexRolloutParser.latestSnapshot(inLines: lines) {
                if let current = best,
                   (snapshot.updatedAt ?? .distantPast) <= (current.updatedAt ?? .distantPast) {
                    // keep current
                } else {
                    best = snapshot
                }
            }
            checked += 1
            // Only the newest few sessions can hold the current state.
            if best != nil, checked >= 3 { break }
        }
        return best
    }

    /// The newest non-null `plan_type` across recent sessions, used to label a
    /// capped session (which itself carries no plan).
    public static func lastKnownPlanType(limit: Int = 15, root: URL? = nil) -> String? {
        for file in rolloutFiles(root: root).prefix(limit) {
            guard let lines = lines(in: file) else { continue }
            if let plan = CodexRolloutParser.lastPlanType(inLines: lines) { return plan }
        }
        return nil
    }

    /// Every usage sample from rollout files modified since `since`, for backfill.
    public static func samples(since: Date, root: URL? = nil) -> [UsageSample] {
        var samples: [UsageSample] = []
        for file in rolloutFiles(root: root) where file.modified >= since {
            guard let text = text(at: file.url) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains("\"rate_limits\"") || line.contains("usage_limit_exceeded") {
                samples.append(contentsOf: CodexRolloutParser.samples(fromLine: String(line)))
            }
        }
        return samples
    }

    // MARK: - Internals

    private struct RolloutFile {
        let url: URL
        let modified: Date
    }

    private static func rolloutFiles(root: URL?) -> [RolloutFile] {
        let rootURL = root ?? defaultRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [RolloutFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            files.append(RolloutFile(url: url, modified: modified))
        }
        files.sort { $0.modified > $1.modified }
        return files
    }

    private static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func lines(in file: RolloutFile) -> [String]? {
        guard let text = text(at: file.url) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
