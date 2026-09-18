import Foundation

public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex

    private let root: URL?

    public init(root: URL? = nil) {
        self.root = root
    }

    public func load() async -> ProviderSnapshot? {
        guard let snapshot = CodexRolloutScanner.latestSnapshot(root: root) else { return nil }

        let cache = PlanCache()
        let plan: String?
        if let fromSnapshot = snapshot.planType {
            plan = cache.resolve(fromSnapshot, for: .codex)
        } else if let stored = cache.resolve(nil, for: .codex) {
            plan = stored
        } else {
            plan = CodexRolloutScanner.lastKnownPlanType(root: root).flatMap { cache.resolve($0, for: .codex) }
        }

        // When Codex reports the allowance exhausted, the API returns no
        // window snapshot — synthesise a capped window using the reset time
        // from the limit error. Infer which window from how far out it resets.
        if snapshot.limitReached, snapshot.windows.isEmpty {
            let minutes = windowMinutes(forReset: snapshot.resetHint)
            let window = UsageWindow(
                id: "primary",
                kind: UsageFormat.windowKind(minutes: minutes),
                label: UsageFormat.windowLabel(minutes: minutes),
                usedPercent: 100,
                windowMinutes: minutes,
                resetsAt: snapshot.resetHint,
                reportedSeverity: .critical
            )
            return ProviderSnapshot(
                provider: .codex,
                planLabel: plan?.capitalized,
                windows: [window],
                provenance: .local,
                updatedAt: snapshot.updatedAt ?? Date()
            )
        }

        return ProviderSnapshot(
            provider: .codex,
            planLabel: plan?.capitalized,
            windows: snapshot.windows,
            provenance: .local,
            updatedAt: snapshot.updatedAt ?? Date()
        )
    }

    /// A reset more than half a day out is the weekly window, otherwise the
    /// short session window.
    private func windowMinutes(forReset reset: Date?) -> Int {
        guard let reset else { return 10080 }
        return reset.timeIntervalSinceNow > 12 * 3600 ? 10080 : 300
    }
}
