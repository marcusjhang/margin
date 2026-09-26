import Foundation

/// An opt-in source that replays agent activity from an external hooks file.
///
/// Not part of `ActivityStore`'s default sources: the owner must construct it
/// explicitly and point it at a JSONL file, one object per line:
/// `{ "timestamp": <epoch>, "provider": "claude|codex", "sessionID": "...",
///   "kind": "<ActivityKind>", "target": "...", "cwd": "...", ... }`.
public struct HookEventSource: ActivitySource {
    public let id = "hooks"

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func poll(since: Date) async -> ActivityBatch {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ActivityBatch(events: [], cursor: since)
        }

        var events: [ActivityEvent] = []
        var cursor = since
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            guard let event = Self.parse(String(line), lineIndex: index) else { continue }
            guard event.timestamp > since else { continue }
            events.append(event)
            if event.timestamp > cursor { cursor = event.timestamp }
        }
        events.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        return ActivityBatch(events: events, cursor: cursor)
    }

    static func parse(_ line: String, lineIndex: Int) -> ActivityEvent? {
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = root["kind"] as? String,
              let kind = ActivityKind(rawValue: kindRaw),
              let sessionID = root["sessionID"] as? String,
              let providerRaw = root["provider"] as? String,
              let provider = ProviderID(rawValue: providerRaw) else {
            return nil
        }

        let timestamp = (root["timestamp"] as? NSNumber).map { UsageFormat.date(fromEpoch: $0) } ?? .distantPast
        let target = root["target"] as? String
        let ordinal = (root["ordinal"] as? NSNumber)?.intValue ?? lineIndex

        return ActivityEvent(
            id: ActivityEvent.makeID(provider: provider, sessionID: sessionID, ordinal: ordinal, kind: kind, target: target),
            provider: provider,
            sessionID: sessionID,
            timestamp: timestamp,
            kind: kind,
            cwd: root["cwd"] as? String,
            gitBranch: root["gitBranch"] as? String,
            worktree: root["worktree"] as? String,
            tool: root["tool"] as? String,
            target: target,
            provenance: .local,
            metadata: (root["metadata"] as? [String: String]) ?? [:]
        )
    }
}
