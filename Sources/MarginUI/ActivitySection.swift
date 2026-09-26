import MarginCore
import SwiftUI

/// The Activity section of the popover: one flat row per agent session, showing
/// what it touched, spawned, and is allowed to do. Rendered below usage, in the
/// same native/HIG language (flat rows, system `Divider`, semantic text styles,
/// system colors).
public struct ActivitySection: View {
    @EnvironmentObject private var store: ActivityStore

    public init() {}

    public var body: some View {
        let summaries = Self.summaries(events: store.events, alerts: store.alerts)
        if summaries.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Activity")
                        .font(.headline)
                    Spacer(minLength: 8)
                    if let watch = watchBadge {
                        Text(watch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                ForEach(Array(summaries.enumerated()), id: \.element.sessionID) { index, summary in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    SessionRow(summary: summary)
                }
            }
        )
    }

    private var watchBadge: String? {
        switch SentinelRules.watchSeverity(store.alerts) {
        case .normal: return nil
        case .warning: return "watching"
        case .critical: return "alert"
        }
    }

    // MARK: - Aggregation

    struct Summary {
        let sessionID: String
        let provider: ProviderID
        let location: String?
        let files: Int
        let ports: Int
        let spend: Double
        let severity: Severity
    }

    private static func rank(_ severity: Severity) -> Int {
        switch severity {
        case .critical: return 2
        case .warning: return 1
        case .normal: return 0
        }
    }

    static func summaries(events: [ActivityEvent], alerts: [MarginCore.Alert]) -> [Summary] {
        var bySession: [String: [ActivityEvent]] = [:]
        var provider: [String: ProviderID] = [:]
        var location: [String: String] = [:]
        for event in events {
            bySession[event.sessionID, default: []].append(event)
            if provider[event.sessionID] == nil { provider[event.sessionID] = event.provider }
            if location[event.sessionID] == nil {
                location[event.sessionID] = event.worktree ?? event.cwd
            }
        }

        var alertSeverity: [String: Severity] = [:]
        for alert in alerts {
            let severity = alert.severity
            if alertSeverity[alert.sessionID].map({ Self.rank(severity) > Self.rank($0) }) ?? true {
                alertSeverity[alert.sessionID] = severity
            }
        }

        let order = bySession.keys.sorted()

        return order.map { sessionID in
            let events = bySession[sessionID] ?? []
            let files = events.filter { $0.kind == .fileRead || $0.kind == .fileWrite }.count
            let ports = events.filter { $0.kind == .portBound }.count
            let spend = events.reduce(0.0) { $0 + (SentinelRules.spendAmount($1) ?? 0) }
            let severity = alertSeverity[sessionID] ?? .normal
            return Summary(
                sessionID: sessionID,
                provider: provider[sessionID] ?? .claude,
                location: location[sessionID],
                files: files,
                ports: ports,
                spend: spend,
                severity: severity
            )
        }
    }
}

/// One session row: provider mark, abbreviated location, activity counts, an
/// alert dot when the session is under watch.
private struct SessionRow: View {
    let summary: ActivitySection.Summary

    var body: some View {
        HStack(spacing: 8) {
            ProviderMark(provider: summary.provider, tint: .primary)

            Text(summary.location.flatMap(ActivitySection.abbreviate) ?? summary.provider.displayName)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("files \(summary.files)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("ports \(summary.ports)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if summary.spend > 0 {
                Text(String(format: "$%.2f", summary.spend))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if summary.severity != .normal {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .help(summary.severity == .critical ? "Critical alert" : "Warning")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var tint: Color {
        switch summary.severity {
        case .normal: return .clear
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

extension ActivitySection {
    static func abbreviate(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/")
        if components.count <= 2 { return path }
        let last = components.suffix(2).joined(separator: "/")
        return "…/\(last)"
    }
}
