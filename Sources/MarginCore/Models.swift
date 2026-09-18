import Foundation

public enum ProviderID: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "terminal"
        }
    }
}

public enum WindowKind: String, Sendable {
    case session
    case daily
    case weekly
    case monthly
    case other
}

public enum Provenance: String, Sendable {
    case live
    case official
    case cached
    case local

    public var label: String {
        switch self {
        case .live: return "live"
        case .official: return "official"
        case .cached: return "cached"
        case .local: return "local"
        }
    }
}

public enum Severity: String, Sendable, Equatable {
    case normal
    case warning
    case critical

    public static func level(for percent: Double) -> Severity {
        if percent >= 90 { return .critical }
        if percent >= 75 { return .warning }
        return .normal
    }
}

public struct UsageWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: WindowKind
    public let label: String
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Severity reported by the provider, when it supplies one.
    public let reportedSeverity: Severity?

    public init(
        id: String,
        kind: WindowKind,
        label: String,
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        reportedSeverity: Severity? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.reportedSeverity = reportedSeverity
    }

    public var severity: Severity {
        reportedSeverity ?? Severity.level(for: usedPercent)
    }

    public var clampedPercent: Double { min(max(usedPercent, 0), 100) }
    public var fraction: Double { clampedPercent / 100 }

    /// Fraction of the window that has elapsed, i.e. the linear "on pace" mark.
    public var idealPaceFraction: Double? {
        guard let resetsAt, let windowMinutes, windowMinutes > 0 else { return nil }
        let duration = Double(windowMinutes) * 60
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = Date().timeIntervalSince(start)
        if elapsed <= 0 { return 0 }
        if elapsed >= duration { return 1 }
        return elapsed / duration
    }
}

public struct ProviderSnapshot: Identifiable, Sendable, Equatable {
    public let provider: ProviderID
    public let planLabel: String?
    public let windows: [UsageWindow]
    public let provenance: Provenance
    public let updatedAt: Date

    public init(
        provider: ProviderID,
        planLabel: String?,
        windows: [UsageWindow],
        provenance: Provenance,
        updatedAt: Date
    ) {
        self.provider = provider
        self.planLabel = planLabel
        self.windows = windows
        self.provenance = provenance
        self.updatedAt = updatedAt
    }

    public var id: String { provider.rawValue }

    public var bindingWindow: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    public var severity: Severity {
        Severity.level(for: bindingWindow?.usedPercent ?? 0)
    }
}
