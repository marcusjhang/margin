import Foundation

public enum ClaudeUsageParser {
    public struct CachedUsage: Sendable, Equatable {
        public let windows: [UsageWindow]
        public let updatedAt: Date
    }

    private static let scopedKeys: [(key: String, label: String)] = [
        ("seven_day_opus", "weekly · opus"),
        ("seven_day_sonnet", "weekly · sonnet")
    ]

    public static func parseCachedUsage(_ data: Data, now: Date = Date()) -> CachedUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any] else {
            return nil
        }

        let updatedAt = (cached["fetchedAtMs"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? now

        // Prefer the generalized `limits` array — it carries provider-reported
        // severity and model-scoped weekly caps. Fall back to named windows.
        var windows = limits(from: utilization)
        if windows.isEmpty {
            if let window = window(id: "five_hour", label: "5-hour session", minutes: 300, from: utilization["five_hour"]) {
                windows.append(window)
            }
            if let window = window(id: "seven_day", label: "weekly", minutes: 10080, from: utilization["seven_day"]) {
                windows.append(window)
            }
            for scoped in scopedKeys {
                if let window = window(id: scoped.key, label: scoped.label, minutes: 10080, from: utilization[scoped.key]) {
                    windows.append(window)
                }
            }
        }

        guard !windows.isEmpty else { return nil }
        return CachedUsage(windows: windows, updatedAt: updatedAt)
    }

    private static func limits(from utilization: [String: Any]) -> [UsageWindow] {
        guard let limits = utilization["limits"] as? [[String: Any]] else { return [] }

        var windows: [UsageWindow] = []
        var seen = Set<String>()

        for limit in limits {
            guard let kind = limit["kind"] as? String,
                  let percent = doubleValue(limit["percent"]) else { continue }

            let severity = (limit["severity"] as? String).flatMap(Severity.init(rawValue:))
            let resetsAt = dateValue(limit["resets_at"])

            let id: String
            let label: String
            let minutes: Int
            switch kind {
            case "session":
                id = "session"
                label = "5-hour session"
                minutes = 300
            case "weekly_all":
                id = "weekly"
                label = "weekly"
                minutes = 10080
            case "weekly_scoped":
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                id = "weekly_scoped_\(model ?? "model")"
                label = model.map { "weekly · \($0)" } ?? "weekly · scoped"
                minutes = 10080
            default:
                continue
            }

            guard seen.insert(id).inserted else { continue }
            windows.append(UsageWindow(
                id: id,
                kind: UsageFormat.windowKind(minutes: minutes),
                label: label,
                usedPercent: percent,
                windowMinutes: minutes,
                resetsAt: resetsAt,
                reportedSeverity: severity
            ))
        }

        return windows
    }

    private static func window(id: String, label: String, minutes: Int, from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let used = doubleValue(dict["utilization"]) else { return nil }
        if id.hasPrefix("seven_day_") && used <= 0 { return nil }
        return UsageWindow(
            id: id,
            kind: UsageFormat.windowKind(minutes: minutes),
            label: label,
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: dateValue(dict["resets_at"])
        )
    }

    static func doubleValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func dateValue(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let string = value as? String else { return nil }
        let cleaned = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: cleaned) ?? formatter.date(from: string)
    }
}
