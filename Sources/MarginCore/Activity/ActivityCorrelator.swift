import Foundation

/// Attributes live listeners (and the processes behind them) to the agent
/// session that owns them, and flags listeners no live session owns.
public enum ActivityCorrelator {
    /// Attributes each listener to a session by walking the process ancestor
    /// chain (via `processParent`) and matching each ancestor's cwd (via
    /// `processCwd`) against the cwds observed in `events`.
    ///
    /// - Attributed listeners (matching an active session) become `portBound`
    ///   events on the returned `events`.
    /// - Unattributed listeners become `leakedProcess` alerts.
    public static func correlate(
        events: [ActivityEvent],
        listeners: [LiveState.Listener],
        activeSessions: [String],
        processParent: (Int32) -> Int32?,
        processCwd: (Int32) -> String?
    ) -> (events: [ActivityEvent], alerts: [Alert]) {
        // cwd -> (sessionID, provider) from events that carry a cwd.
        var cwdToSession: [String: (sessionID: String, provider: ProviderID)] = [:]
        for event in events {
            if let cwd = event.cwd, cwdToSession[cwd] == nil {
                cwdToSession[cwd] = (event.sessionID, event.provider)
            }
        }

        var providerBySession: [String: ProviderID] = [:]
        for event in events where providerBySession[event.sessionID] == nil {
            providerBySession[event.sessionID] = event.provider
        }

        let activeSet = Set(activeSessions)
        let newest = events.map(\.timestamp).max() ?? Date()

        var outEvents = events
        var alerts: [Alert] = []

        for listener in listeners {
            guard let sessionID = ownerSession(
                of: listener.pid,
                cwdToSession: cwdToSession,
                processParent: processParent,
                processCwd: processCwd
            ) else {
                let target = "\(listener.address):\(listener.port)"
                alerts.append(Alert(
                    id: Alert.makeID(kind: .leakedProcess, sessionID: "", target: target),
                    kind: .leakedProcess,
                    severity: .warning,
                    sessionID: "",
                    provider: .claude,
                    title: "Leaked process",
                    detail: "A listening process is not attached to any live session",
                    target: target,
                    since: newest
                ))
                continue
            }

            guard activeSet.contains(sessionID) else {
                let target = "\(listener.address):\(listener.port)"
                alerts.append(Alert(
                    id: Alert.makeID(kind: .leakedProcess, sessionID: sessionID, target: target),
                    kind: .leakedProcess,
                    severity: .warning,
                    sessionID: sessionID,
                    provider: providerBySession[sessionID] ?? .claude,
                    title: "Leaked process",
                    detail: "A session's listener outlived the session",
                    target: target,
                    since: newest
                ))
                continue
            }

            let provider = providerBySession[sessionID] ?? .claude
            let target = "\(listener.address):\(listener.port)"
            outEvents.append(ActivityEvent(
                id: ActivityEvent.makeID(provider: provider, sessionID: sessionID, ordinal: listener.port, kind: .portBound, target: target),
                provider: provider,
                sessionID: sessionID,
                timestamp: newest,
                kind: .portBound,
                cwd: nil,
                gitBranch: nil,
                worktree: nil,
                tool: nil,
                target: target,
                provenance: .local,
                metadata: [
                    "pid": String(listener.pid),
                    "address": listener.address,
                    "port": String(listener.port)
                ]
            ))
        }

        return (outEvents, alerts)
    }

    private static func ownerSession(
        of pid: Int32,
        cwdToSession: [String: (sessionID: String, provider: ProviderID)],
        processParent: (Int32) -> Int32?,
        processCwd: (Int32) -> String?
    ) -> String? {
        var current: Int32? = pid
        var steps = 0
        while let pid = current, pid > 0, steps < 128 {
            if let cwd = processCwd(pid), let session = cwdToSession[cwd] {
                return session.sessionID
            }
            current = processParent(pid)
            steps += 1
        }
        return nil
    }
}
