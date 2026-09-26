import AppKit
import MarginCore
import MarginUI
import SwiftUI

// Dev-only snapshot renderer. Produces PNGs of the popover for design review
// and the README. Usage: MarginPreview [outputDirectory]

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"

let now = Date()

let snapshots: [ProviderSnapshot] = [
    ProviderSnapshot(
        provider: .claude,
        planLabel: "Max 20×",
        windows: [
            UsageWindow(
                id: "five_hour",
                kind: .session,
                label: "5-hour session",
                usedPercent: 34,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 3600 + 12 * 60)
            ),
            UsageWindow(
                id: "seven_day",
                kind: .weekly,
                label: "weekly",
                usedPercent: 82,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(2 * 86400 + 23 * 3600)
            )
        ],
        provenance: .cached,
        updatedAt: now.addingTimeInterval(-12),
        credits: Credits(enabled: true, used: 42.42, limit: 50, currency: "SGD", decimalPlaces: 2, spendLimitReached: false)
    ),
    ProviderSnapshot(
        provider: .codex,
        planLabel: "Pro",
        windows: [
            UsageWindow(
                id: "primary",
                kind: .weekly,
                label: "weekly",
                usedPercent: 16,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(5 * 86400)
            )
        ],
        provenance: .local,
        updatedAt: now.addingTimeInterval(-40)
    )
]

let forecasts: [String: WindowForecast] = [
    WindowForecast.key(provider: .claude, windowID: "five_hour"): WindowForecast(
        burnRatePerHour: 1.2,
        timeToCap: nil,
        projectedEndPercent: 58,
        probabilityOfCap: 0.04,
        sampleCount: 9,
        isReliable: true
    ),
    WindowForecast.key(provider: .claude, windowID: "seven_day"): WindowForecast(
        burnRatePerHour: 5.4,
        timeToCap: 3 * 3600 + 20 * 60,
        projectedEndPercent: 118,
        probabilityOfCap: 0.71,
        sampleCount: 9,
        isReliable: true
    ),
    WindowForecast.key(provider: .codex, windowID: "primary"): WindowForecast(
        burnRatePerHour: 0.6,
        timeToCap: nil,
        projectedEndPercent: 41,
        probabilityOfCap: 0.02,
        sampleCount: 6,
        isReliable: true
    )
]


let previewNow = Date()
let activityEvents: [ActivityEvent] = [
    ActivityEvent(
        id: ActivityEvent.makeID(provider: .claude, sessionID: "s1", ordinal: 1, kind: .command, target: "npm run dev"),
        provider: .claude, sessionID: "s1", timestamp: previewNow.addingTimeInterval(-360),
        kind: .command, cwd: "/Users/me/src/api", gitBranch: "main",
        worktree: "/Users/me/src/api", tool: "Bash", target: "npm run dev",
        provenance: .local, metadata: ["port": "3000"]
    ),
    ActivityEvent(
        id: ActivityEvent.makeID(provider: .claude, sessionID: "s1", ordinal: 2, kind: .fileWrite, target: "Sources/server.ts"),
        provider: .claude, sessionID: "s1", timestamp: previewNow.addingTimeInterval(-240),
        kind: .fileWrite, cwd: "/Users/me/src/api", gitBranch: "main",
        worktree: "/Users/me/src/api", tool: "Edit", target: "Sources/server.ts",
        provenance: .local
    ),
    ActivityEvent(
        id: ActivityEvent.makeID(provider: .codex, sessionID: "c1", ordinal: 3, kind: .fileWrite, target: "src/app.ts"),
        provider: .codex, sessionID: "c1", timestamp: previewNow.addingTimeInterval(-120),
        kind: .fileWrite, cwd: "/Users/me/src/web", gitBranch: "feat/payments",
        worktree: "/Users/me/src/web", tool: "apply_patch", target: "src/app.ts",
        provenance: .local
    )
]
let activityAlerts: [MarginCore.Alert] = [
    MarginCore.Alert(
        id: MarginCore.Alert.makeID(kind: .exposedPort, sessionID: "s1", target: "0.0.0.0:3000"),
        kind: .exposedPort, severity: .warning, sessionID: "s1", provider: .claude,
        title: "Exposed port", detail: "Bound to 0.0.0.0:3000", target: "0.0.0.0:3000",
        since: previewNow.addingTimeInterval(-360)
    )
]
let activityLive = LiveState(
    listeners: [LiveState.Listener(port: 3000, address: "0.0.0.0", pid: 1234, processPath: "/usr/bin/node")],
    activeSessions: ["s1", "c1"]
)

MainActor.assumeIsolated {
    let captures: [(ColorScheme, String)] = [
        (.light, "margin-popover-light.png"),
        (.dark, "margin-popover-dark.png")
    ]

    for (scheme, filename) in captures {
        let store = UsageStore(
            previewSnapshots: snapshots,
            forecasts: forecasts
        )
        let activity = ActivityStore(
            previewEvents: activityEvents,
            alerts: activityAlerts,
            live: activityLive
        )
        let view = PopoverView(showsFooter: false)
            .environmentObject(store)
            .environmentObject(activity)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 1.0))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("failed to render \(filename)")
            continue
        }

        let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(filename)
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
