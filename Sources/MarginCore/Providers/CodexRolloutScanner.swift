import Foundation

/// Finds the most recent Codex rate-limit snapshot from local rollout logs.
///
/// Codex writes a `rate_limits` block on every `token_count` event. We scan the
/// newest session files first and return the last snapshot found, which is the
/// CLI's own view of the current windows.
public enum CodexRolloutScanner {
    public static func latestSnapshot(limit: Int = 40) -> CodexRolloutParser.Snapshot? {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
        files.sort { $0.modified > $1.modified }

        var best: CodexRolloutParser.Snapshot?
        var checked = 0
        for file in files.prefix(limit) {
            guard let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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
    public static func lastKnownPlanType(limit: Int = 15) -> String? {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
        files.sort { $0.modified > $1.modified }

        for file in files.prefix(limit) {
            guard let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if let plan = CodexRolloutParser.lastPlanType(inLines: lines) { return plan }
        }
        return nil
    }

    /// Every usage sample from rollout files modified since `since`, for backfill.
    public static func samples(since: Date) -> [UsageSample] {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var samples: [UsageSample] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard modified >= since else { continue }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains("\"rate_limits\"") || line.contains("usage_limit_exceeded") {
                samples.append(contentsOf: CodexRolloutParser.samples(fromLine: String(line)))
            }
        }
        return samples
    }
}
