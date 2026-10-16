import AppKit
import MarginCore
import SwiftUI

public struct PopoverView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var selection: ProviderID?
    private let showsFooter: Bool

    public init(showsFooter: Bool = true) {
        self.showsFooter = showsFooter
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if showsFooter {
                Divider()
                footer
            }
        }
        .frame(width: 300)
    }

    private var selected: ProviderSnapshot? {
        store.snapshots.first { $0.provider == selection } ?? store.snapshots.first
    }

    private var header: some View {
        HStack(spacing: 10) {
            if store.snapshots.count > 1, let snapshot = selected {
                ProviderTabs(
                    providers: store.snapshots,
                    selection: snapshot.provider,
                    onSelect: { selection = $0 }
                )
            } else if let only = store.snapshots.first {
                Text(only.provider.displayName)
                    .font(.headline)
            }

            Spacer(minLength: 8)

            // Fixed width so switching providers never shifts the tabs under
            // the pointer (which caused hover to oscillate and flash).
            HStack(spacing: 8) {
                if let plan = selected?.planLabel {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let snapshot = selected {
                    Circle()
                        .fill(snapshot.provenance == .live ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .help(snapshot.provenance == .live
                              ? "Live from the provider"
                              : "From local files on this Mac")
                    // Shows when we last checked (updates on Refresh). Turns
                    // amber when the underlying data is old, so a fresh check
                    // of stale data can't look fresh.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        let checked = store.lastUpdated ?? snapshot.updatedAt
                        let sourceAge = Date().timeIntervalSince(snapshot.updatedAt)
                        Text(UsageFormat.relative(checked))
                            .font(.caption)
                            .foregroundStyle(sourceAge > 900 ? Color.orange : Color.secondary)
                            .help(sourceAge > 900
                                  ? "Usage data is \(UsageFormat.relative(snapshot.updatedAt)) old — run Claude Code or Codex to refresh it"
                                  : "Last checked \(UsageFormat.relative(checked))")
                    }
                }
            }
            .frame(width: 122, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = selected, !snapshot.windows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    WindowRow(
                        window: window,
                        forecast: store.forecasts[WindowForecast.key(provider: snapshot.provider, windowID: window.id)],
                        creditsAvailable: snapshot.credits?.isAvailable ?? false
                    )
                }

                if let credits = snapshot.credits,
                   credits.enabled || snapshot.windows.contains(where: { $0.usedPercent >= 99.5 }) {
                    Divider().padding(.leading, 14)
                    CreditsRow(credits: credits)
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text("Nothing to show yet")
                .font(.headline)
            Text("Sign in to Claude Code or Codex on this Mac once, and Margin will show your usage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            Spacer()
            Button {
                Task { await store.refresh(forceLive: true) }
            } label: {
                HStack(spacing: 4) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(store.isRefreshing ? "Checking…" : "Refresh")
                        .font(.subheadline)
                }
            }
            .disabled(store.isRefreshing)
            .help("Check live usage now (falls back to local data)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
