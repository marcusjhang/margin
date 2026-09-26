import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) into activity events.
/// Local files only; never touches the network.
public struct ClaudeActivitySource: ActivitySource {
    public let id = "claude.transcripts"
    /// Files modified this long before `since` are still re-read, to tolerate clock/mtime skew.
    static let overlap: TimeInterval = 60

    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public func poll(since: Date) async -> ActivityBatch {
        let threshold = since.addingTimeInterval(-Self.overlap)
        var cursor = since
        var seen = Set<String>()
        var events: [ActivityEvent] = []

        for (url, mtime) in Self.transcripts(under: root) where mtime >= threshold {
            cursor = max(cursor, mtime)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallbackSession = url.deletingPathExtension().lastPathComponent
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for event in Self.events(fromLine: String(line), lineIndex: index, fallbackSession: fallbackSession)
                where seen.insert(event.id).inserted {
                    events.append(event)
                }
            }
        }
        return ActivityBatch(events: events, cursor: cursor)
    }

    // MARK: - Parsing

    static func events(fromLine line: String, lineIndex: Int, fallbackSession: String) -> [ActivityEvent] {
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = record["type"] as? String,
              let message = record["message"] as? [String: Any]
        else { return [] }

        let sessionID = (record["sessionId"] as? String) ?? fallbackSession
        let timestamp = parseDate(record["timestamp"]) ?? Date(timeIntervalSince1970: 0)
        let cwd = record["cwd"] as? String
        let branch = record["gitBranch"] as? String
        var metadata: [String: String] = [:]
        if let parent = record["parentUuid"] as? String { metadata["parentUuid"] = parent }
        if let sidechain = record["isSidechain"] as? Bool { metadata["isSidechain"] = sidechain ? "true" : "false" }

        func make(_ ordinal: Int, _ kind: ActivityKind, tool: String?, target: String?) -> ActivityEvent {
            ActivityEvent(
                id: ActivityEvent.makeID(provider: .claude, sessionID: sessionID, ordinal: ordinal, kind: kind, target: target),
                provider: .claude, sessionID: sessionID, timestamp: timestamp, kind: kind,
                cwd: cwd, gitBranch: branch, tool: tool, target: target,
                provenance: .local, metadata: metadata
            )
        }

        switch type {
        case "assistant":
            guard let content = message["content"] as? [[String: Any]] else { return [] }
            return content.enumerated().compactMap { itemIndex, item in
                guard item["type"] as? String == "tool_use", let name = item["name"] as? String else { return nil }
                let input = item["input"] as? [String: Any] ?? [:]
                let ordinal = lineIndex * 1000 + itemIndex
                switch name {
                case "Read":
                    return make(ordinal, .fileRead, tool: name, target: input["file_path"] as? String)
                case "Edit", "Write", "NotebookEdit", "MultiEdit":
                    let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
                    return make(ordinal, .fileWrite, tool: name, target: path)
                case "Bash":
                    return make(ordinal, .command, tool: name, target: input["command"] as? String)
                default:
                    return make(ordinal, .command, tool: name, target: nil)
                }
            }
        case "user":
            // A human prompt: string content, or text items without tool results. Prompt text is not recorded.
            guard record["isMeta"] as? Bool != true else { return [] }
            let isPrompt: Bool
            if message["content"] is String {
                isPrompt = true
            } else if let items = message["content"] as? [[String: Any]] {
                isPrompt = !items.isEmpty && items.allSatisfy { $0["type"] as? String != "tool_result" }
            } else {
                isPrompt = false
            }
            return isPrompt ? [make(lineIndex * 1000, .prompt, tool: nil, target: nil)] : []
        default:
            return []
        }
    }

    static func transcripts(under root: URL) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate
            else { continue }
            result.append((url, mtime))
        }
        return result.sorted { $0.0.path < $1.0.path }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
