import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var snapshots: [ProviderSnapshot] = []
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var forecasts: [String: WindowForecast] = [:]
    @Published public private(set) var backfill: BackfillReport?

    public var refreshInterval: TimeInterval {
        didSet { schedule() }
    }

    private let providers: [UsageProvider]
    private let history: HistoryStore?
    private var timer: Timer?

    public init(
        providers: [UsageProvider] = [ClaudeProvider(), CodexProvider()],
        history: HistoryStore = HistoryStore(),
        refreshInterval: TimeInterval = 60
    ) {
        self.providers = providers
        self.history = history
        self.refreshInterval = refreshInterval
        history.prune(before: Date().addingTimeInterval(-Double(HistoryStore.retentionDays) * 86_400))
    }

    /// Fixture initializer for previews, snapshot rendering, and tests.
    public init(
        previewSnapshots: [ProviderSnapshot],
        forecasts: [String: WindowForecast] = [:]
    ) {
        self.providers = []
        self.history = nil
        self.refreshInterval = 0
        self.snapshots = previewSnapshots
        self.forecasts = forecasts
        self.lastUpdated = Date()
    }

    public func start() {
        Task {
            await backfillIfNeeded()
            await refresh()
        }
        schedule()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh(forceLive: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if forceLive { LiveUsageCache.shared.invalidate() }

        let providers = self.providers
        let loaded = await withTaskGroup(of: ProviderSnapshot?.self) { group -> [ProviderSnapshot] in
            for provider in providers {
                group.addTask { await provider.load() }
            }
            var results: [ProviderSnapshot] = []
            for await snapshot in group {
                if let snapshot { results.append(snapshot) }
            }
            return results
        }

        snapshots = ProviderID.allCases.compactMap { id in
            loaded.first { $0.provider == id }
        }
        let now = Date()
        lastUpdated = now
        analyze(now: now)
    }

    /// The provider with the least headroom, used for the glanceable glyph.
    public var bindingProvider: ProviderSnapshot? {
        snapshots.max {
            ($0.bindingWindow?.usedPercent ?? 0) < ($1.bindingWindow?.usedPercent ?? 0)
        }
    }

    private func analyze(now: Date) {
        guard let history else { return }

        let newSamples = snapshots.flatMap { snapshot in
            snapshot.windows.map {
                UsageSample(provider: snapshot.provider, windowID: $0.id, usedPercent: $0.usedPercent, timestamp: now)
            }
        }
        history.record(newSamples)

        var forecasts: [String: WindowForecast] = [:]

        for snapshot in snapshots {
            for window in snapshot.windows {
                let key = WindowForecast.key(provider: snapshot.provider, windowID: window.id)
                let samples = history.samples(
                    provider: snapshot.provider,
                    windowID: window.id,
                    since: windowStart(window, now: now)
                )
                if let forecast = ForecastEngine.forecast(for: window, samples: samples, now: now) {
                    forecasts[key] = forecast
                }
            }
        }

        self.forecasts = forecasts
    }

    static let backfillKey = "ai.margin.didBackfill"

    private func backfillIfNeeded() async {
        guard let history, !UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }
        let report = await Task.detached(priority: .utility) {
            HistoryBackfill.run(history: history, now: Date())
        }.value
        UserDefaults.standard.set(true, forKey: Self.backfillKey)
        backfill = report
    }

    private func windowStart(_ window: UsageWindow, now: Date) -> Date {
        guard let resetsAt = window.resetsAt, let minutes = window.windowMinutes else {
            return now.addingTimeInterval(-6 * 3600)
        }
        return resetsAt.addingTimeInterval(-Double(minutes) * 60)
    }

    private func schedule() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }
}
