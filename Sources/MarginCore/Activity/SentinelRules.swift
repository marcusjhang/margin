import Foundation

/// Pure, deterministic alert rules over a single poll's activity + live state.
///
/// Each rule first computes a set of *candidate* alerts. A candidate only
/// becomes an actual alert once it has been observed on **>= 2 consecutive
/// polls** — the previous poll's counts ride in `seenCounts`, keyed by the
/// candidate's stable id. This keeps the UI silent until a condition is
/// genuinely sustained rather than a one-tick fluke.
public enum SentinelRules {
    /// Spend (in currency units) above which a session trips the budget rule.
    public static var budgetThreshold: Double = 20.0

    public static func evaluate(
        events: [ActivityEvent],
        live: LiveState,
        seenCounts: [String: Int]
    ) -> (alerts: [Alert], seenCounts: [String: Int]) {
        var candidates: [String: Alert] = [:]
        let now = Date()

        // exposedPort — a listener bound to a non-loopback address.
        for listener in live.listeners where !listener.isLoopback {
            let target = "\(listener.address):\(listener.port)"
            candidates[target] = Alert(
                id: Alert.makeID(kind: .exposedPort, sessionID: "", target: target),
                kind: .exposedPort,
                severity: .warning,
                sessionID: "",
                provider: .claude,
                title: "Exposed port",
                detail: "A listener is bound to a non-loopback address",
                target: target,
                since: now
            )
        }

        // secretAccess — an agent read or wrote a secret-looking path.
        for event in events where isSecretAccess(event) {
            let target = event.target
            let id = Alert.makeID(kind: .secretAccess, sessionID: event.sessionID, target: target)
            candidates[id] = Alert(
                id: id,
                kind: .secretAccess,
                severity: .warning,
                sessionID: event.sessionID,
                provider: event.provider,
                title: "Secret access",
                detail: "An agent accessed a credential or key",
                target: target,
                since: event.timestamp
            )
        }

        // outOfWorktree — a file write landing outside the session's worktree.
        for event in events where isOutOfWorktree(event) {
            let id = Alert.makeID(kind: .outOfWorktree, sessionID: event.sessionID, target: event.target)
            candidates[id] = Alert(
                id: id,
                kind: .outOfWorktree,
                severity: .warning,
                sessionID: event.sessionID,
                provider: event.provider,
                title: "Outside worktree",
                detail: "An agent wrote outside its worktree",
                target: event.target,
                since: event.timestamp
            )
        }

        // leakedProcess — a live listener no session (via a portBound event) claims.
        let boundTargets = Set(events.filter { $0.kind == .portBound }.compactMap(\.target))
        for listener in live.listeners {
            let target = "\(listener.address):\(listener.port)"
            if !boundTargets.contains(target) {
                let id = Alert.makeID(kind: .leakedProcess, sessionID: "", target: target)
                candidates[id] = Alert(
                    id: id,
                    kind: .leakedProcess,
                    severity: .warning,
                    sessionID: "",
                    provider: .claude,
                    title: "Leaked process",
                    detail: "A listening process is not attached to any session",
                    target: target,
                    since: now
                )
            }
        }

        // budget — a session's spend (sum of spendDelta amounts) crossed the threshold.
        var spendBySession: [String: Double] = [:]
        var providerBySession: [String: ProviderID] = [:]
        for event in events {
            if let amount = spendAmount(event) {
                spendBySession[event.sessionID, default: 0] += amount
                providerBySession[event.sessionID] = event.provider
            }
        }
        for (sessionID, spend) in spendBySession where spend >= budgetThreshold {
            let id = Alert.makeID(kind: .budget, sessionID: sessionID, target: nil)
            candidates[id] = Alert(
                id: id,
                kind: .budget,
                severity: .critical,
                sessionID: sessionID,
                provider: providerBySession[sessionID] ?? .claude,
                title: "Budget",
                detail: "A session crossed the spend threshold",
                target: nil,
                since: now
            )
        }

        // Sustain each candidate: fire only after two consecutive observations.
        var next: [String: Int] = [:]
        var alerts: [Alert] = []
        for (_, alert) in candidates {
            let previous = seenCounts[alert.id] ?? 0
            let count = previous + 1
            next[alert.id] = count
            if count >= 2 {
                alerts.append(alert)
            }
        }

        // Carry forward only the counts of conditions still observed this poll.
        return (alerts, next)
    }

    /// The menu-bar "watch" severity derived from alerts, kept independent of
    /// the usage severity so a quiet usage meter can still show a watch dot.
    public static func watchSeverity(_ alerts: [Alert]) -> Severity {
        if alerts.contains(where: { $0.severity == .critical }) { return .critical }
        if alerts.contains(where: { $0.severity == .warning }) { return .warning }
        return .normal
    }

    // MARK: - Predicates

    /// Secret-looking paths: dotenv, keys, PEM certs, ssh material, netrc,
    /// cloud credentials, keychain. We record the *path* only, never the value.
    static func isSecretAccess(_ event: ActivityEvent) -> Bool {
        guard event.kind == .fileRead || event.kind == .fileWrite || event.kind == .command else {
            return false
        }
        let haystack = [event.target, event.cwd].compactMap { $0 }.joined(separator: " ")
        let lower = haystack.lowercased()
        let markers = [
            ".env", "id_rsa", "id_ed25519", "id_dsa", "id_ecdsa",
            ".pem", ".key", ".p12", ".pfx",
            ".netrc", "credentials", "credential",
            "keychain", "authorized_keys", "known_hosts",
            "aws/credentials", ".aws/config", "gcloud", "service_account",
            ".git-credentials", "token", "secret", "password"
        ]
        for marker in markers where lower.contains(marker) {
            return true
        }
        return false
    }

    /// A write whose target path is absolute and outside the session's worktree.
    static func isOutOfWorktree(_ event: ActivityEvent) -> Bool {
        guard event.kind == .fileWrite,
              let target = event.target,
              target.hasPrefix("/"),
              let worktree = event.worktree,
              worktree.hasPrefix("/") else {
            return false
        }
        return !(target == worktree || target.hasPrefix(worktree.hasSuffix("/") ? worktree : worktree + "/"))
    }

    public static func spendAmount(_ event: ActivityEvent) -> Double? {
        guard event.kind == .spendDelta,
              let raw = event.metadata["amount"],
              let value = Double(raw),
              value.isFinite else {
            return nil
        }
        return value
    }
}
