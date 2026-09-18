import XCTest
@testable import MarginCore

/// Thorough coverage of the refresh lifecycle: ordering, coalescing, failure
/// handling, timer ticks, and the analyze/forecast pass.
@MainActor
final class RefreshBehaviorTests: XCTestCase {
    /// A provider we fully control: fixed or scripted results, optional delay,
    /// and a load counter.
    final class StubProvider: UsageProvider, @unchecked Sendable {
        let id: ProviderID
        private let lock = NSLock()
        private var script: [ProviderSnapshot?]
        private var _loads = 0
        var delay: TimeInterval = 0

        init(id: ProviderID, results: [ProviderSnapshot?] = []) {
            self.id = id
            self.script = results
        }

        var loads: Int {
            lock.lock(); defer { lock.unlock() }
            return _loads
        }

        func load() async -> ProviderSnapshot? {
            lock.lock()
            _loads += 1
            let delay = self.delay
            let result: ProviderSnapshot?
            if script.isEmpty {
                result = nil
            } else {
                result = script.removeFirst()
            }
            lock.unlock()

            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            return result
        }
    }

    override func setUp() {
        super.setUp()
        // Keep tests hermetic: don't run the real backfill scan.
        UserDefaults.standard.set(true, forKey: UsageStore.backfillKey)
    }

    // MARK: Helpers

    private func snapshot(_ provider: ProviderID, _ percent: Double, resetsInHours: Double = 4, updatedAt: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planLabel: "Pro",
            windows: [
                UsageWindow(
                    id: provider == .claude ? "weekly" : "primary",
                    kind: .weekly,
                    label: "weekly",
                    usedPercent: percent,
                    windowMinutes: 10080,
                    resetsAt: Date().addingTimeInterval(resetsInHours * 3600)
                )
            ],
            provenance: .local,
            updatedAt: updatedAt
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Tests

    func testSnapshotsFollowProviderOrderRegardlessOfCompletionOrder() async {
        let claude = StubProvider(id: .claude, results: [snapshot(.claude, 10)])
        claude.delay = 0.20
        let codex = StubProvider(id: .codex, results: [snapshot(.codex, 20)])

        let store = UsageStore(providers: [claude, codex], history: .inMemory())
        await store.refresh()

        XCTAssertEqual(store.snapshots.map(\.provider), [.claude, .codex])
        XCTAssertEqual(store.snapshots.map { $0.bindingWindow?.usedPercent }, [10, 20])
    }

    func testProviderReturningNilIsDropped() async {
        let claude = StubProvider(id: .claude, results: [snapshot(.claude, 10)])
        let codex = StubProvider(id: .codex, results: [nil])

        let store = UsageStore(providers: [claude, codex], history: .inMemory())
        await store.refresh()

        XCTAssertEqual(store.snapshots.map(\.provider), [.claude])
        XCTAssertFalse(store.isRefreshing)
    }

    func testValuesUpdateAcrossRefreshes() async {
        let claude = StubProvider(id: .claude, results: [snapshot(.claude, 10), snapshot(.claude, 25)])
        let codex = StubProvider(id: .codex)

        let store = UsageStore(providers: [claude, codex], history: .inMemory())
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.bindingWindow?.usedPercent, 10)

        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.bindingWindow?.usedPercent, 25)
        XCTAssertEqual(claude.loads, 2)
    }

    func testConcurrentRefreshIsCoalesced() async {
        let claude = StubProvider(id: .claude, results: [snapshot(.claude, 10)])
        claude.delay = 0.15

        let store = UsageStore(providers: [claude], history: .inMemory())
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        XCTAssertEqual(claude.loads, 1, "a refresh in flight must not be started again")
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.snapshots.count, 1)
    }

    func testIsRefreshingResetsOnEveryOutcome() async {
        let store = UsageStore(providers: [StubProvider(id: .claude, results: [nil])], history: .inMemory())
        await store.refresh()
        XCTAssertFalse(store.isRefreshing)

        let store2 = UsageStore(providers: [StubProvider(id: .claude, results: [snapshot(.claude, 5)])], history: .inMemory())
        await store2.refresh()
        XCTAssertFalse(store2.isRefreshing)
    }

    func testLastUpdatedAdvancesOnEachRefresh() async {
        let claude = StubProvider(id: .claude, results: [snapshot(.claude, 1), snapshot(.claude, 2)])
        let store = UsageStore(providers: [claude], history: .inMemory())
        await store.refresh()
        let first = try? XCTUnwrap(store.lastUpdated)
        try? await Task.sleep(for: .milliseconds(50))
        await store.refresh()
        XCTAssertNotNil(store.lastUpdated)
        if let first, let second = store.lastUpdated {
            XCTAssertGreaterThan(second, first)
        }
    }

    func testStartTicksOnScheduleAndStopHalts() async {
        let claude = StubProvider(id: .claude, results: [])
        let store = UsageStore(providers: [claude], history: .inMemory(), refreshInterval: 0.15)

        store.start()
        await waitUntil { claude.loads >= 1 }        // initial
        await waitUntil { claude.loads >= 2 }        // at least one tick
        XCTAssertGreaterThanOrEqual(claude.loads, 2)

        store.stop()
        let afterStop = claude.loads
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(claude.loads, afterStop, "no ticks after stop()")
    }

    func testAnalyzeProducesForecastFromSeededHistory() async {
        let history = HistoryStore.inMemory()
        let now = Date()
        // Two hours of history at ~10%/h, 4h left on a weekly window.
        history.record([
            UsageSample(provider: .claude, windowID: "weekly", usedPercent: 10, timestamp: now.addingTimeInterval(-3600)),
            UsageSample(provider: .claude, windowID: "weekly", usedPercent: 20, timestamp: now)
        ])

        let claude = StubProvider(id: .claude, results: [snapshot(.claude, 20, resetsInHours: 4)])
        let store = UsageStore(providers: [claude], history: history)
        await store.refresh()

        let key = WindowForecast.key(provider: .claude, windowID: "weekly")
        let forecast = try? XCTUnwrap(store.forecasts[key])
        XCTAssertNotNil(forecast)
        XCTAssertGreaterThan(forecast?.burnRatePerHour ?? 0, 0)
    }

    func testRefreshWithNoProvidersPublishesEmpty() async {
        let store = UsageStore(providers: [], history: .inMemory())
        await store.refresh()
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertFalse(store.isRefreshing)
    }
}
