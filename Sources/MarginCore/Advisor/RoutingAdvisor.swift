import Foundation

public struct RoutingAdvice: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case useProvider
        case bothHealthy
        case bothConstrained
    }

    public let kind: Kind
    public let recommended: ProviderID?
    public let headline: String
    public let severity: Severity

    public init(kind: Kind, recommended: ProviderID?, headline: String, severity: Severity) {
        self.kind = kind
        self.recommended = recommended
        self.headline = headline
        self.severity = severity
    }
}

private struct AdvisorEntry {
    let snapshot: ProviderSnapshot
    let window: UsageWindow
    let forecast: WindowForecast?
}

/// The cross-provider answer: given both subscriptions' current windows and
/// projections, which one should you send work to right now?
public enum RoutingAdvisor {
    public static func advice(
        snapshots: [ProviderSnapshot],
        forecasts: [String: WindowForecast],
        now: Date = Date()
    ) -> RoutingAdvice? {
        let entries: [AdvisorEntry] = snapshots.compactMap { snapshot in
            guard let window = snapshot.bindingWindow else { return nil }
            let forecast = forecasts[WindowForecast.key(provider: snapshot.provider, windowID: window.id)]
            return AdvisorEntry(snapshot: snapshot, window: window, forecast: forecast)
        }
        guard !entries.isEmpty else { return nil }

        let capped = entries.filter(isCapped)
        let available = entries.filter { !isCapped($0) }

        if capped.count == entries.count {
            let reset = entries.compactMap { $0.window.resetsAt }.min()
            let headline = reset.map { "Both capped — reset \(UsageFormat.countdown(until: $0, now: now))" } ?? "Both capped"
            return RoutingAdvice(kind: .bothConstrained, recommended: nil, headline: headline, severity: .critical)
        }

        if capped.count == 1, let cappedEntry = capped.first,
           let best = available.min(by: { score($0) < score($1) }) {
            return RoutingAdvice(
                kind: .useProvider,
                recommended: best.snapshot.provider,
                headline: "Use \(name(best)) — \(short(cappedEntry))",
                severity: .warning
            )
        }

        guard let best = available.min(by: { score($0) < score($1) }) else { return nil }

        if available.count == 1 {
            if let forecast = best.forecast, forecast.willCapBeforeReset, let timeToCap = forecast.timeToCap {
                return RoutingAdvice(
                    kind: .useProvider,
                    recommended: best.snapshot.provider,
                    headline: "\(name(best)) caps in \(UsageFormat.approximateDuration(timeToCap))",
                    severity: .warning
                )
            }
            return RoutingAdvice(
                kind: .bothHealthy,
                recommended: best.snapshot.provider,
                headline: "\(name(best)) at \(UsageFormat.percent(best.window.usedPercent))",
                severity: .normal
            )
        }

        guard let worst = available.max(by: { score($0) < score($1) }) else { return nil }
        let worstBinding = (worst.forecast?.willCapBeforeReset ?? false) || worst.window.usedPercent >= 75

        if worstBinding {
            return RoutingAdvice(
                kind: .useProvider,
                recommended: best.snapshot.provider,
                headline: "Use \(name(best)) — \(short(worst))",
                severity: (worst.forecast?.willCapBeforeReset ?? false) ? .warning : .normal
            )
        }

        return RoutingAdvice(
            kind: .bothHealthy,
            recommended: best.snapshot.provider,
            headline: "\(name(best)) has more room",
            severity: .normal
        )
    }

    private static func isCapped(_ entry: AdvisorEntry) -> Bool {
        entry.window.usedPercent >= 99.5
    }

    private static func score(_ entry: AdvisorEntry) -> Double {
        max(entry.forecast?.projectedEndPercent ?? entry.window.usedPercent, entry.window.usedPercent)
    }

    private static func name(_ entry: AdvisorEntry) -> String {
        entry.snapshot.provider.displayName
    }

    /// Terse phrase for the constrained side, e.g. "Claude caps in ~3h".
    private static func short(_ entry: AdvisorEntry) -> String {
        let label = name(entry)
        if isCapped(entry) { return "\(label) capped" }
        if let forecast = entry.forecast, forecast.willCapBeforeReset, let timeToCap = forecast.timeToCap {
            return "\(label) caps in \(UsageFormat.approximateDuration(timeToCap))"
        }
        return "\(label) at \(UsageFormat.percent(entry.window.usedPercent))"
    }
}
