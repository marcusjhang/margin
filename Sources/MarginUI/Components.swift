import MarginCore
import SwiftUI

/// A capacity bar in the system style: thin capsule, semantic tint, and a
/// critically-damped value change.
struct CapacityBar: View {
    let fraction: Double
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: 4)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width, height: 4)
            }
            .frame(height: 4)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1.0), value: fraction)
        }
        .frame(height: 4)
    }
}

/// Provider switch, styled like the system segmented control.
struct ProviderTabs: View {
    let providers: [ProviderSnapshot]
    let selection: ProviderID
    let onSelect: (ProviderID) -> Void

    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(providers) { snapshot in
                let isSelected = snapshot.provider == selection
                Button {
                    onSelect(snapshot.provider)
                } label: {
                    HStack(spacing: 5) {
                        ProviderMark(provider: snapshot.provider, tint: isSelected ? .primary : .secondary)
                        Text(snapshot.provider.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
                    )
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoverTask?.cancel()
                    guard hovering, snapshot.provider != selection else { return }
                    // Dwell before switching so a quick pass doesn't flip providers.
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        guard !Task.isCancelled else { return }
                        onSelect(snapshot.provider)
                    }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

/// One usage window, laid out as a plain row (no card) so the popover's
/// material reads as a single surface.
struct WindowRow: View {
    let window: UsageWindow
    let forecast: WindowForecast?

    var body: some View {
        let tint = Theme.tint(for: window.severity)

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(window.label.capitalized)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(UsageFormat.percent(window.usedPercent))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            CapacityBar(fraction: window.fraction, color: tint)

            HStack(spacing: 8) {
                if let resetsAt = window.resetsAt {
                    Text(resetsAt <= Date()
                        ? "Resetting now"
                        : "Resets in \(UsageFormat.countdown(until: resetsAt))")
                }
                Spacer(minLength: 8)
                if let trailing = WindowStatus.trailing(usedPercent: window.usedPercent, forecast: forecast) {
                    Text(trailing)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var icon: String {
        switch window.kind {
        case .session: return "clock"
        case .weekly: return "calendar"
        case .daily: return "calendar.day.timeline.left"
        case .monthly: return "calendar.badge.clock"
        case .other: return "chart.bar"
        }
    }
}
