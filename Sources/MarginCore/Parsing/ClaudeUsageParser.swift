import Foundation

public enum ClaudeUsageParser {
    public struct CachedUsage: Sendable, Equatable {
        public let windows: [UsageWindow]
        public let updatedAt: Date
        public let credits: Credits?
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

        let windows = windows(from: utilization)
        guard !windows.isEmpty else { return nil }
        return CachedUsage(windows: windows, updatedAt: updatedAt, credits: credits(from: utilization))
    }

    /// Reads pay-as-you-go credit state. Handles both the live `spend` block and
    /// the `extra_usage` block (local cache and live payloads both carry these).
    static func credits(from container: [String: Any]) -> Credits? {
        if let spend = container["spend"] as? [String: Any],
           let credits = credits(fromSpend: spend) {
            return credits
        }
        if let extra = container["extra_usage"] as? [String: Any],
           let credits = credits(fromExtraUsage: extra) {
            return credits
        }
        return nil
    }

    private static func credits(fromSpend spend: [String: Any]) -> Credits? {
        let used = money(spend["used"])
        let limit = money(spend["limit"])
        guard used != nil || limit != nil else { return nil }
        let percent = (spend["percent"] as? NSNumber)?.doubleValue ?? 0
        return Credits(
            enabled: (spend["enabled"] as? Bool) ?? false,
            used: used?.amount,
            limit: limit?.amount,
            currency: used?.currency ?? limit?.currency,
            decimalPlaces: used?.exponent ?? limit?.exponent ?? 2,
            spendLimitReached: percent >= 99.5
        )
    }

    private static func credits(fromExtraUsage extra: [String: Any]) -> Credits? {
        let exponent = (extra["decimal_places"] as? NSNumber)?.intValue ?? 2
        let divisor = pow(10, Double(max(0, exponent)))
        let used = (extra["used_credits"] as? NSNumber).map { $0.doubleValue / divisor }
        let limit = (extra["monthly_limit"] as? NSNumber).map { $0.doubleValue / divisor }
        guard used != nil || limit != nil else { return nil }
        let utilization = (extra["utilization"] as? NSNumber)?.doubleValue ?? 0
        let reached = (extra["spend_limit_reached"] as? Bool) ?? (utilization >= 99.5)
        return Credits(
            enabled: (extra["is_enabled"] as? Bool) ?? false,
            used: used,
            limit: limit,
            currency: extra["currency"] as? String,
            decimalPlaces: exponent,
            spendLimitReached: reached
        )
    }

    private static func money(_ value: Any?) -> (amount: Double, currency: String?, exponent: Int)? {
        guard let dict = value as? [String: Any],
              let minor = (dict["amount_minor"] as? NSNumber)?.doubleValue else { return nil }
        let exponent = (dict["exponent"] as? NSNumber)?.intValue ?? 2
        return (minor / pow(10, Double(max(0, exponent))), dict["currency"] as? String, exponent)
    }

    /// Parses a Claude `utilization` object (used by both the local cache and
    /// the live OAuth usage endpoint, which share this shape).
    static func windows(from utilization: [String: Any]) -> [UsageWindow] {
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
        return windows
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
            return UsageFormat.date(fromEpoch: number)
        }
        guard let string = value as? String else { return nil }
        let cleaned = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: cleaned) ?? formatter.date(from: string)
    }
}
