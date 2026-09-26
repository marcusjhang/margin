import Foundation

/// Reads Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) into activity events.
/// Local files only; never touches the network.
public struct CodexActivitySource: ActivitySource {
    public let id = "codex.rollouts"
    /// Files modified this long before `since` are still re-read, to tolerate clock/mtime skew.
    static let overlap: TimeInterval = 60
    static let maxTargetLength = 300
    static let commandTools: Set<String> = ["exec", "exec_command", "shell", "local_shell", "container.exec", "shell_command"]

    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public func poll(since: Date) async -> ActivityBatch {
        let threshold = since.addingTimeInterval(-Self.overlap)
        var cursor = since
        var seen = Set<String>()
        var events: [ActivityEvent] = []

        for (url, mtime) in Self.rollouts(under: root) where mtime >= threshold {
            cursor = max(cursor, mtime)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var session = Session(id: Self.sessionID(fromFilename: url.deletingPathExtension().lastPathComponent))
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let event = Self.event(fromLine: String(line), lineIndex: index, session: &session),
                      seen.insert(event.id).inserted
                else { continue }
                events.append(event)
            }
        }
        return ActivityBatch(events: events, cursor: cursor)
    }

    // MARK: - Parsing

    struct Session {
        var id: String
        var cwd: String?
        var gitBranch: String?
    }

    static func event(fromLine line: String, lineIndex: Int, session: inout Session) -> ActivityEvent? {
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = record["type"] as? String,
              let payload = record["payload"] as? [String: Any]
        else { return nil }

        if type == "session_meta" {
            if let id = payload["id"] as? String { session.id = id }
            if let cwd = payload["cwd"] as? String { session.cwd = cwd }
            if let branch = (payload["git"] as? [String: Any])?["branch"] as? String { session.gitBranch = branch }
            return nil
        }
        guard type == "response_item", let name = payload["name"] as? String else { return nil }

        let kind: ActivityKind
        var target: String?
        switch payload["type"] as? String {
        case "custom_tool_call":
            let input = payload["input"] as? String ?? ""
            if name == "apply_patch" {
                kind = .fileWrite
                target = patchPath(input)
            } else if commandTools.contains(name) {
                kind = .command
                target = execCommand(fromScript: input) ?? input
            } else {
                return nil
            }
        case "function_call":
            let arguments = (payload["arguments"] as? String)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            if name == "apply_patch" {
                kind = .fileWrite
                target = ((arguments["input"] ?? arguments["patch"]) as? String).flatMap(patchPath)
            } else if commandTools.contains(name) {
                kind = .command
                target = commandString(arguments["cmd"] ?? arguments["command"])
            } else {
                return nil
            }
        default:
            return nil
        }
        target = target.map { String($0.prefix(maxTargetLength)) }

        let ordinal = (record["ordinal"] as? Int) ?? lineIndex
        let timestamp = parseDate(record["timestamp"]) ?? Date(timeIntervalSince1970: 0)
        return ActivityEvent(
            id: ActivityEvent.makeID(provider: .codex, sessionID: session.id, ordinal: ordinal, kind: kind, target: target),
            provider: .codex, sessionID: session.id, timestamp: timestamp, kind: kind,
            cwd: session.cwd, gitBranch: session.gitBranch, tool: name, target: target,
            provenance: .local
        )
    }

    /// Extracts `cmd` from a JS snippet like `tools.exec_command({"cmd":"ls"})`.
    static func execCommand(fromScript script: String) -> String? {
        guard let call = script.range(of: "exec_command("),
              let open = script[call.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < script.endIndex {
            let char = script[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    let object = String(script[open...index])
                    guard let data = object.data(using: .utf8),
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    else { return nil }
                    return commandString(json["cmd"] ?? json["command"])
                }
            }
            index = script.index(after: index)
        }
        return nil
    }

    private static func commandString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [String] { return parts.joined(separator: " ") }
        return nil
    }

    private static func patchPath(_ patch: String) -> String? {
        for line in patch.split(separator: "\n") {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func sessionID(fromFilename name: String) -> String {
        name.hasPrefix("rollout-") ? String(name.dropFirst("rollout-".count)) : name
    }

    static func rollouts(under root: URL) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
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
