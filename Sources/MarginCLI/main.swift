import Foundation
import MarginCore

// MarginCLI — a machine-friendly read-only surface over Margin's local data.
//
//   MarginCLI <command> [--json]
//
// Commands:
//   activity  recent agent activity events
//   receipt   local usage snapshot (no network)
//   ports     the calling user's listening sockets
//   watch     stream activity + alerts as JSON lines until interrupted
//
// All commands read only local files and kernel state; none touch the network
// or credentials.

let arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
let command = arguments.first(where: { !$0.hasPrefix("--") }) ?? "activity"

func run(_ body: @escaping () async throws -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { try await body() } catch { fputs("error: \(error)\n", stderr) }
        semaphore.signal()
    }
    semaphore.wait()
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    print(String(data: data, encoding: .utf8) ?? "")
}

func emitJSON(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return }
    print(string)
}

switch command {
case "activity":
    run {
        let sources: [ActivitySource] = [ClaudeActivitySource(), CodexActivitySource()]
        var events: [ActivityEvent] = []
        for source in sources {
            let batch = await source.poll(since: Date().addingTimeInterval(-3600))
            events.append(contentsOf: batch.events)
        }
        events.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        if json {
            emitJSON(events)
        } else {
            for event in events {
                let kind = event.kind.rawValue
                let target = event.target ?? "-"
                print("\(event.provider.rawValue)\t\(kind)\t\(target)\t\(event.sessionID)")
            }
        }
    }

case "receipt":
    run {
        async let claude = ClaudeProvider(live: false).load(forceLive: false)
        async let codex = CodexProvider(live: false).load(forceLive: false)
        let snapshots = [await claude, await codex].compactMap { $0 }
        if json {
            let payload = snapshots.map { snapshot -> [String: Any] in
                [
                    "provider": snapshot.provider.rawValue,
                    "plan": snapshot.planLabel ?? "",
                    "provenance": snapshot.provenance.rawValue,
                    "windows": snapshot.windows.map { window -> [String: Any] in
                        ["id": window.id, "label": window.label, "usedPercent": window.usedPercent]
                    }
                ]
            }
            emitJSON(payload)
        } else {
            for snapshot in snapshots {
                for window in snapshot.windows {
                    print("\(snapshot.provider.rawValue)\t\(window.id)\t\(UsageFormat.percent(window.usedPercent))")
                }
            }
        }
    }

case "ports":
    run {
        let listeners = await PortProcessSource().listeners()
        if json {
            emitJSON(listeners)
        } else {
            for listener in listeners {
                let path = listener.processPath ?? "-"
                print("\(listener.address):\(listener.port)\tpid \(listener.pid)\t\(path)")
            }
        }
    }

case "watch":
    run {
        let sources: [ActivitySource] = [ClaudeActivitySource(), CodexActivitySource()]
        let ledger = LedgerStore.inMemory()
        var cursors: [String: Date] = [:]
        var seenCounts: [String: Int] = [:]
        while true {
            var events: [ActivityEvent] = []
            for source in sources {
                let since = cursors[source.id] ?? Date().addingTimeInterval(-3600)
                let batch = await source.poll(since: since)
                cursors[source.id] = batch.cursor
                events.append(contentsOf: batch.events)
            }
            ledger.record(events)

            let listeners = await PortProcessSource().listeners()
            let activeSessions = ledger.activeSessions(since: Date().addingTimeInterval(-6 * 3600))
            let live = LiveState(listeners: listeners, activeSessions: activeSessions)

            let rule = SentinelRules.evaluate(events: events, live: live, seenCounts: seenCounts)
            seenCounts = rule.seenCounts

            let line: [String: Any] = [
                "events": events.map(\.id),
                "alerts": rule.alerts.map(\.id),
                "listeners": listeners.count,
                "activeSessions": activeSessions.count
            ]
            emitJSON(line)
            try await Task.sleep(for: .seconds(3))
        }
    }

default:
    fputs("usage: MarginCLI [activity|receipt|ports|watch] [--json]\n", stderr)
    exit(2)
}
