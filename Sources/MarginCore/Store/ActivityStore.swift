import Combine
import Darwin
import Foundation

/// Aggregates activity from the sources, persists it to the ledger, correlates
/// live listeners to sessions, and evaluates the alert rules on a refresh loop.
/// Mirrors `UsageStore`'s shape: `@MainActor`, `ObservableObject`, timer-driven.
@MainActor
public final class ActivityStore: ObservableObject {
    @Published public private(set) var events: [ActivityEvent]
    @Published public private(set) var alerts: [Alert]
    @Published public private(set) var live: LiveState

    public var pollInterval: TimeInterval {
        didSet { schedule() }
    }

    private let sources: [ActivitySource]
    private let ledger: LedgerStore
    private let portSource: PortProcessSource
    private var cursors: [String: Date] = [:]
    private var seenCounts: [String: Int] = [:]
    private var timer: Timer?
    private var isRefreshing = false

    /// A session is "live" if it produced activity within this window.
    static let activeSessionWindow: TimeInterval = 6 * 3600

    /// A cold start only reads this much history; later polls advance the cursor.
    static let initialPollWindow: TimeInterval = 3600

    public init(
        sources: [ActivitySource] = [ClaudeActivitySource(), CodexActivitySource()],
        ledger: LedgerStore = LedgerStore(),
        pollInterval: TimeInterval = 3
    ) {
        self.sources = sources
        self.ledger = ledger
        self.portSource = PortProcessSource()
        self.pollInterval = pollInterval
        self.events = []
        self.alerts = []
        self.live = LiveState(listeners: [], activeSessions: [])
        ledger.prune(before: Date().addingTimeInterval(-Double(LedgerStore.retentionDays) * 86_400))
    }

    /// Fixture initializer for previews and tests.
    public init(
        previewEvents: [ActivityEvent],
        alerts: [Alert] = [],
        live: LiveState = LiveState(listeners: [], activeSessions: [])
    ) {
        self.sources = []
        self.ledger = LedgerStore.inMemory()
        self.portSource = PortProcessSource()
        self.pollInterval = 0
        self.events = previewEvents
        self.alerts = alerts
        self.live = live
    }

    public func start() {
        Task { await refresh() }
        schedule()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 1. Poll sources incrementally and persist new events. The first poll
        //    is bounded to the active-session window so a cold start never
        //    re-reads every transcript; later polls advance the per-source cursor.
        var collected: [ActivityEvent] = []
        for source in sources {
            let since = cursors[source.id] ?? Date().addingTimeInterval(-Self.initialPollWindow)
            let batch = await Task.detached(priority: .utility) {
                await source.poll(since: since)
            }.value
            cursors[source.id] = batch.cursor
            collected.append(contentsOf: batch.events)
        }
        var seen = Set<String>()
        let fresh = collected.filter { seen.insert($0.id).inserted }
        ledger.record(fresh)

        // 2. Live machine state.
        let portSource = self.portSource
        let listeners = await Task.detached(priority: .utility) {
            await portSource.listeners()
        }.value
        let activeSessions = ledger.activeSessions(since: Date().addingTimeInterval(-Self.activeSessionWindow))
        let liveState = LiveState(listeners: listeners, activeSessions: activeSessions)

        // 3. Correlate listeners to sessions (portBound events + leaked alerts).
        let correlated = ActivityCorrelator.correlate(
            events: fresh,
            listeners: listeners,
            activeSessions: activeSessions,
            processParent: Self.processParent,
            processCwd: Self.processCwd
        )

        // 4. Evaluate the sustained alert rules.
        let rule = SentinelRules.evaluate(
            events: correlated.events,
            live: liveState,
            seenCounts: seenCounts
        )
        seenCounts = rule.seenCounts

        // 5. Publish.
        events = correlated.events
        live = liveState
        var merged: [String: Alert] = [:]
        for alert in correlated.alerts { merged[alert.id] = alert }
        for alert in rule.alerts { merged[alert.id] = alert }
        alerts = merged.values.sorted { a, b in
            let ra = Self.severityRank(a.severity)
            let rb = Self.severityRank(b.severity)
            if ra != rb { return ra > rb }
            return a.kind.rawValue < b.kind.rawValue
        }
    }

    private static func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .critical: return 2
        case .warning: return 1
        case .normal: return 0
        }
    }

    // MARK: - Process inspection (libproc)

    static func processParent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { (ptr: UnsafeMutablePointer<proc_bsdinfo>) -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
        }
        guard written >= size else { return nil }
        return Int32(info.pbi_ppid)
    }

    static func processCwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { (ptr: UnsafeMutablePointer<proc_vnodepathinfo>) -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard written >= size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard pollInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }
}
