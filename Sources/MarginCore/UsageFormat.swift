import Foundation

public enum UsageFormat {
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(min(max(value, 0), 999).rounded()))%"
    }

    public static func windowLabel(minutes: Int?) -> String {
        guard let minutes else { return "usage" }
        switch minutes {
        case 300: return "5-hour session"
        case 1440: return "daily"
        case 10080: return "weekly"
        case 43200: return "monthly"
        default: break
        }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)m"
    }

    public static func windowKind(minutes: Int?) -> WindowKind {
        guard let minutes else { return .other }
        switch minutes {
        case ...360: return .session
        case ...1440: return .daily
        case ...10080: return .weekly
        case ...43200: return .monthly
        default: return .other
        }
    }

    public static func countdown(until date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return "—" }
        guard interval > 0 else { return "now" }
        if interval < 60 { return "<1m" }
        let totalMinutes = Int(min(interval / 60, 9.0e15))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite else { return "—" }
        if interval < 5 { return "just now" }
        let seconds = Int(min(interval, 9.0e15))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Coarse, human duration for projections, e.g. "~3h" or "~45m".
    public static func approximateDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        guard seconds > 0 else { return "now" }
        let hours = seconds / 3600
        if hours >= 24 { return "~\(Int((hours / 24).rounded()))d" }
        if hours >= 1 { return "~\(Int(hours.rounded()))h" }
        let minutes = max(1, (seconds / 60).rounded())
        return "~\(Int(minutes))m"
    }
}
