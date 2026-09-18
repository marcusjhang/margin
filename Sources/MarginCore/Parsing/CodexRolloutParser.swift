import Foundation

public enum CodexRolloutParser {
    public struct Snapshot: Sendable, Equatable {
        public let windows: [UsageWindow]
        public let planType: String?
        public let updatedAt: Date?
        /// True when Codex reported the allowance is exhausted.
        public let limitReached: Bool
        /// Reset time parsed from the limit error message, when present.
        public let resetHint: Date?
    }

    public static func latestSnapshot(inLines lines: [String]) -> Snapshot? {
        guard var snapshot = firstSnapshot(inLines: lines) else { return nil }
        // A capped (task_complete) snapshot carries no plan; borrow the most
        // recent plan the session reported.
        if snapshot.planType == nil, let plan = lastPlanType(inLines: lines) {
            snapshot = Snapshot(
                windows: snapshot.windows,
                planType: plan,
                updatedAt: snapshot.updatedAt,
                limitReached: snapshot.limitReached,
                resetHint: snapshot.resetHint
            )
        }
        return snapshot
    }

    private static func firstSnapshot(inLines lines: [String]) -> Snapshot? {
        for line in lines.reversed() {
            if let snapshot = snapshot(fromLine: line) { return snapshot }
        }
        return nil
    }

    static func lastPlanType(inLines lines: [String]) -> String? {
        for line in lines.reversed() where line.contains("\"plan_type\"") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let plan = rateLimits["plan_type"] as? String else { continue }
            return plan
        }
        return nil
    }

    /// Every timestamped usage sample on a line, for history backfill.
    public static func samples(fromLine line: String) -> [UsageSample] {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let timestamp = timestamp(from: root["timestamp"]) else {
            return []
        }

        if payload["type"] as? String == "token_count",
           let rateLimits = payload["rate_limits"] as? [String: Any] {
            var samples: [UsageSample] = []
            for id in ["primary", "secondary"] {
                guard let dict = rateLimits[id] as? [String: Any],
                      let used = ClaudeUsageParser.doubleValue(dict["used_percent"]) else { continue }
                samples.append(UsageSample(provider: .codex, windowID: id, usedPercent: used, timestamp: timestamp))
            }
            return samples
        }

        if payload["type"] as? String == "task_complete",
           let error = payload["error"] as? [String: Any],
           error["codex_error_info"] as? String == "usage_limit_exceeded" {
            return [UsageSample(provider: .codex, windowID: "primary", usedPercent: 100, timestamp: timestamp)]
        }

        return []
    }

    public static func snapshot(fromLine line: String) -> Snapshot? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let kind = payload["type"] as? String else {
            return nil
        }

        let updatedAt = timestamp(from: root["timestamp"])

        if kind == "token_count", let rateLimits = payload["rate_limits"] as? [String: Any] {
            var windows: [UsageWindow] = []
            if let window = window(id: "primary", from: rateLimits["primary"]) { windows.append(window) }
            if let window = window(id: "secondary", from: rateLimits["secondary"]) { windows.append(window) }

            // Null windows alone are NOT a cap: some plans (e.g. premium/team)
            // report no window data during normal use. The only unambiguous cap
            // signal is the explicit `usage_limit_exceeded` error below.
            guard !windows.isEmpty else { return nil }

            return Snapshot(
                windows: windows,
                planType: rateLimits["plan_type"] as? String,
                updatedAt: updatedAt,
                limitReached: false,
                resetHint: nil
            )
        }

        if kind == "task_complete",
           let error = payload["error"] as? [String: Any],
           error["codex_error_info"] as? String == "usage_limit_exceeded" {
            return Snapshot(
                windows: [],
                planType: nil,
                updatedAt: updatedAt,
                limitReached: true,
                resetHint: (error["message"] as? String).flatMap(parseReset)
            )
        }

        return nil
    }

    /// Parses "… try again at Sep 21st, 2026 10:59 PM."
    static func parseReset(_ message: String) -> Date? {
        guard let range = message.range(of: "try again at ") else { return nil }
        var rest = String(message[range.upperBound...])
        rest = rest.replacingOccurrences(
            of: #"(\d+)(st|nd|rd|th)"#,
            with: "$1",
            options: .regularExpression
        )
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.date(from: rest)
    }

    private static func window(id: String, from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let used = ClaudeUsageParser.doubleValue(dict["used_percent"]),
              let minutes = (dict["window_minutes"] as? NSNumber)?.intValue else {
            return nil
        }
        let resetsAt = (dict["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(
            id: id,
            kind: UsageFormat.windowKind(minutes: minutes),
            label: UsageFormat.windowLabel(minutes: minutes),
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }

    private static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
