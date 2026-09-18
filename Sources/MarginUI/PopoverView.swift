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
                    Text(UsageFormat.relative(snapshot.updatedAt))
                        .font(.caption)
                        .foregroundStyle(Date().timeIntervalSince(snapshot.updatedAt) > 900 ? Color.orange : Color.secondary)
                        .help("When the source data was last written")
                }
            }
            .frame(width: 108, alignment: .trailing)
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
                        forecast: store.forecasts[WindowForecast.key(provider: snapshot.provider, windowID: window.id)]
                    )
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
            Text("Run Claude Code or Codex once and Margin will pick up local usage.")
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
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
