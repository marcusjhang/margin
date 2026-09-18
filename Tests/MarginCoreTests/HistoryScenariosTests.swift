import XCTest
@testable import MarginCore

/// History store behaviours: idempotency, dedupe, ordering, pruning.
final class HistoryScenariosTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ percent: Double,
        _ offset: TimeInterval,
        provider: ProviderID = .claude,
        window: String = "w"
    ) -> UsageSample {
        UsageSample(provider: provider, windowID: window, usedPercent: percent, timestamp: base.addingTimeInterval(offset))
    }

    func testDuplicateBatchIsIdempotent() {
        let store = HistoryStore.inMemory()
        let batch = [sample(10, 0), sample(20, 3600), sample(30, 7200)]
        store.record(batch)
        store.record(batch) // re-run (e.g. interrupted backfill)
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-1))
        XCTAssertEqual(read.map(\.usedPercent), [10, 20, 30])
    }

    func testSteadyReadingWithinFiveMinutesIsSkipped() {
        let store = HistoryStore.inMemory()
        store.record([sample(16, 0)])
        store.record([sample(16, 60)])
        store.record([sample(16.05, 120)])
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-1))
        XCTAssertEqual(read.count, 1)
    }

    func testChangedReadingIsKeptEvenWithinFiveMinutes() {
        let store = HistoryStore.inMemory()
        store.record([sample(16, 0)])
        store.record([sample(20, 120)])
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-1))
        XCTAssertEqual(read.map(\.usedPercent), [16, 20])
    }

    func testSameReadingAfterFiveMinutesIsKept() {
        let store = HistoryStore.inMemory()
        store.record([sample(16, 0)])
        store.record([sample(16, 400)])
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-1))
        XCTAssertEqual(read.count, 2)
    }

    func testOutOfOrderInsertsReadBackChronologically() {
        let store = HistoryStore.inMemory()
        store.record([sample(30, 7200), sample(10, 0), sample(20, 3600)])
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-1))
        XCTAssertEqual(read.map(\.usedPercent), [10, 20, 30])
    }

    func testSamplesReturnsNewestWithinLimit() {
        let store = HistoryStore.inMemory()
        // Five day-spaced points so dedupe never collapses them.
        store.record((0..<5).map { sample(Double($0 * 10), Double($0) * 86_400) })
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-1), limit: 3)
        XCTAssertEqual(read.map(\.usedPercent), [20, 30, 40]) // newest 3, ascending
    }

    func testProvidersAndWindowsAreIsolated() {
        let store = HistoryStore.inMemory()
        store.record([
            sample(10, 0, window: "session"),
            sample(20, 0, window: "weekly"),
            sample(30, 0, provider: .codex, window: "primary")
        ])
        XCTAssertEqual(store.samples(provider: .claude, windowID: "session", since: base.addingTimeInterval(-1)).map(\.usedPercent), [10])
        XCTAssertEqual(store.samples(provider: .claude, windowID: "weekly", since: base.addingTimeInterval(-1)).map(\.usedPercent), [20])
        XCTAssertEqual(store.samples(provider: .codex, windowID: "primary", since: base.addingTimeInterval(-1)).map(\.usedPercent), [30])
    }

    func testPruneRemovesOldRowsOnly() {
        let store = HistoryStore.inMemory()
        store.record([sample(5, -40 * 86_400), sample(90, 0)])
        store.prune(before: base.addingTimeInterval(-30 * 86_400))
        let read = store.samples(provider: .claude, windowID: "w", since: base.addingTimeInterval(-60 * 86_400))
        XCTAssertEqual(read.map(\.usedPercent), [90])
    }

    func testLatestReturnsMostRecent() {
        let store = HistoryStore.inMemory()
        store.record([sample(10, 0), sample(20, 86_400)])
        XCTAssertEqual(store.latest(provider: .claude, windowID: "w")?.usedPercent, 20)
    }

    func testBackfillIsIdempotentAcrossProviders() {
        let store = HistoryStore.inMemory()
        let batch = [
            sample(10, 0, provider: .codex, window: "primary"),
            sample(40, 3600, provider: .codex, window: "primary"),
            sample(5, 0, provider: .codex, window: "secondary")
        ]
        store.record(batch)
        store.record(batch)
        XCTAssertEqual(store.samples(provider: .codex, windowID: "primary", since: base.addingTimeInterval(-1)).count, 2)
        XCTAssertEqual(store.samples(provider: .codex, windowID: "secondary", since: base.addingTimeInterval(-1)).count, 1)
    }
}
