import XCTest
@testable import MarginCore

/// Ledger store behaviours: idempotency, dedupe, kind/time filtering, session
/// liveness, and pruning.
final class LedgerScenariosTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ kind: ActivityKind,
        sessionID: String = "s1",
        offset: TimeInterval = 0,
        target: String? = nil,
        provider: ProviderID = .claude,
        metadata: [String: String] = [:]
    ) -> ActivityEvent {
        ActivityEvent(
            id: ActivityEvent.makeID(provider: provider, sessionID: sessionID, ordinal: Int(offset), kind: kind, target: target),
            provider: provider,
            sessionID: sessionID,
            timestamp: base.addingTimeInterval(offset),
            kind: kind,
            cwd: "/Users/dev/project",
            gitBranch: "main",
            worktree: nil,
            tool: nil,
            target: target,
            provenance: .local,
            metadata: metadata
        )
    }

    func testRoundtripPreservesFields() {
        let store = LedgerStore.inMemory()
        let original = event(.fileRead, offset: 10, target: "/a.txt", metadata: ["k": "v"])
        store.record([original])
        let read = store.events(sessionID: "s1")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, original.id)
        XCTAssertEqual(read[0].kind, .fileRead)
        XCTAssertEqual(read[0].target, "/a.txt")
        XCTAssertEqual(read[0].cwd, "/Users/dev/project")
        XCTAssertEqual(read[0].gitBranch, "main")
        XCTAssertEqual(read[0].metadata["k"], "v")
    }

    func testDuplicateBatchIsIdempotent() {
        let store = LedgerStore.inMemory()
        let batch = [event(.fileRead, offset: 1), event(.command, offset: 2), event(.fileWrite, offset: 3)]
        store.record(batch)
        store.record(batch)
        XCTAssertEqual(store.events(sessionID: "s1").count, 3)
    }

    func testEventsSinceAndKindFilter() {
        let store = LedgerStore.inMemory()
        store.record([
            event(.fileRead, offset: 10),
            event(.command, offset: 20),
            event(.fileRead, offset: 30)
        ])
        let since = store.events(since: base.addingTimeInterval(20), kind: nil)
        XCTAssertEqual(since.count, 2)
        let reads = store.events(since: base.addingTimeInterval(0), kind: .fileRead)
        XCTAssertEqual(reads.map(\.kind), [.fileRead, .fileRead])
    }

    func testActiveSessionsOnlyRecent() {
        let store = LedgerStore.inMemory()
        store.record([
            event(.fileRead, sessionID: "old", offset: -10_000),
            event(.fileRead, sessionID: "recent", offset: 10)
        ])
        let active = store.activeSessions(since: base.addingTimeInterval(-100))
        XCTAssertEqual(Set(active), ["recent"])
    }

    func testPruneRemovesOldRowsOnly() {
        let store = LedgerStore.inMemory()
        store.record([event(.fileRead, offset: -50), event(.fileRead, offset: 50)])
        store.prune(before: base.addingTimeInterval(-10))
        XCTAssertEqual(store.events(sessionID: "s1").count, 1)
    }

    func testProvidersAreIsolated() {
        let store = LedgerStore.inMemory()
        store.record([
            event(.fileRead, sessionID: "s1", provider: .claude),
            event(.fileRead, sessionID: "s2", provider: .codex)
        ])
        XCTAssertEqual(store.events(sessionID: "s1").first?.provider, .claude)
        XCTAssertEqual(store.events(sessionID: "s2").first?.provider, .codex)
    }

    func testLimitCapsResults() {
        let store = LedgerStore.inMemory()
        store.record((0..<10).map { event(.fileRead, offset: Double($0)) })
        XCTAssertEqual(store.events(sessionID: "s1", limit: 3).count, 3)
    }

    func testDefaultPathPointsAtAppSupport() {
        let path = LedgerStore.defaultPath()
        XCTAssertTrue(path.hasSuffix("Margin/ledger.sqlite3"))
        XCTAssertTrue(path.contains("Application Support"))
    }
}
