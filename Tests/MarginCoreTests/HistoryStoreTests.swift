import XCTest
@testable import MarginCore

final class HistoryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecordsAndReadsBackInOrder() {
        let store = HistoryStore.inMemory()
        store.record([
            UsageSample(provider: .claude, windowID: "five_hour", usedPercent: 10, timestamp: base),
            UsageSample(provider: .claude, windowID: "five_hour", usedPercent: 20, timestamp: base.addingTimeInterval(3600))
        ])

        let samples = store.samples(provider: .claude, windowID: "five_hour", since: base.addingTimeInterval(-60))
        XCTAssertEqual(samples.map(\.usedPercent), [10, 20])
    }

    func testSkipsNearDuplicateSamples() {
        let store = HistoryStore.inMemory()
        store.record([UsageSample(provider: .codex, windowID: "primary", usedPercent: 16, timestamp: base)])
        store.record([UsageSample(provider: .codex, windowID: "primary", usedPercent: 16, timestamp: base.addingTimeInterval(60))])

        let samples = store.samples(provider: .codex, windowID: "primary", since: base.addingTimeInterval(-60))
        XCTAssertEqual(samples.count, 1)
    }

    func testPruneRemovesOldSamples() {
        let store = HistoryStore.inMemory()
        store.record([
            UsageSample(provider: .codex, windowID: "primary", usedPercent: 5, timestamp: base.addingTimeInterval(-40 * 86_400)),
            UsageSample(provider: .codex, windowID: "primary", usedPercent: 90, timestamp: base)
        ])
        store.prune(before: base.addingTimeInterval(-30 * 86_400))

        let samples = store.samples(provider: .codex, windowID: "primary", since: base.addingTimeInterval(-60 * 86_400))
        XCTAssertEqual(samples.map(\.usedPercent), [90])
    }
}
