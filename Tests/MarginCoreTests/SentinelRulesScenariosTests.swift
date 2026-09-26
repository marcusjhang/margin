import XCTest
@testable import MarginCore

/// SentinelRules behaviours: each rule fires only after two consecutive
/// observations, records paths (never values), and carries counts forward.
final class SentinelRulesScenariosTests: XCTestCase {
    private func event(
        kind: ActivityKind,
        sessionID: String = "s1",
        target: String? = nil,
        cwd: String? = nil,
        worktree: String? = nil,
        metadata: [String: String] = [:]
    ) -> ActivityEvent {
        ActivityEvent(
            id: ActivityEvent.makeID(provider: .claude, sessionID: sessionID, ordinal: Int.random(in: 0...1_000_000), kind: kind, target: target),
            provider: .claude,
            sessionID: sessionID,
            timestamp: Date(),
            kind: kind,
            cwd: cwd,
            gitBranch: nil,
            worktree: worktree,
            tool: nil,
            target: target,
            provenance: .local,
            metadata: metadata
        )
    }

    private func live(listeners: [LiveState.Listener] = [], sessions: [String] = []) -> LiveState {
        LiveState(listeners: listeners, activeSessions: sessions)
    }

    // MARK: Sustained gate

    func testAlertOnlyFiresAfterTwoConsecutivePolls() {
        let events = [event(kind: .fileWrite, target: "/tmp/outside", cwd: "/repo", worktree: "/repo")]
        let first = SentinelRules.evaluate(events: events, live: live(), seenCounts: [:])
        XCTAssertTrue(first.alerts.isEmpty)

        let second = SentinelRules.evaluate(events: events, live: live(), seenCounts: first.seenCounts)
        XCTAssertFalse(second.alerts.isEmpty)
        XCTAssertEqual(second.alerts.first?.kind, .outOfWorktree)
    }

    func testCountsResetWhenConditionDisappears() {
        let events = [event(kind: .fileWrite, target: "/tmp/outside", cwd: "/repo", worktree: "/repo")]
        let first = SentinelRules.evaluate(events: events, live: live(), seenCounts: [:])
        XCTAssertFalse(first.seenCounts.isEmpty)

        let second = SentinelRules.evaluate(events: [], live: live(), seenCounts: first.seenCounts)
        XCTAssertTrue(second.seenCounts.isEmpty)
        XCTAssertTrue(second.alerts.isEmpty)
    }

    // MARK: exposedPort

    func testExposedPortFiresOnlyWhenNotLoopback() {
        let exposed = [LiveState.Listener(port: 5432, address: "0.0.0.0", pid: 1, processPath: nil)]
        let loopback = [LiveState.Listener(port: 5432, address: "127.0.0.1", pid: 1, processPath: nil)]

        let first = SentinelRules.evaluate(events: [], live: live(listeners: exposed), seenCounts: [:])
        let second = SentinelRules.evaluate(events: [], live: live(listeners: exposed), seenCounts: first.seenCounts)
        XCTAssertTrue(second.alerts.contains { $0.kind == .exposedPort })

        let l1 = SentinelRules.evaluate(events: [], live: live(listeners: loopback), seenCounts: [:])
        let l2 = SentinelRules.evaluate(events: [], live: live(listeners: loopback), seenCounts: l1.seenCounts)
        XCTAssertFalse(l2.alerts.contains { $0.kind == .exposedPort })
    }

    // MARK: secretAccess

    func testSecretAccessRecordsPathNeverValue() {
        let secret = event(kind: .fileRead, target: "/home/user/.env", cwd: "/repo")
        let first = SentinelRules.evaluate(events: [secret], live: live(), seenCounts: [:])
        let second = SentinelRules.evaluate(events: [secret], live: live(), seenCounts: first.seenCounts)

        let alert = second.alerts.first { $0.kind == .secretAccess }
        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.target, "/home/user/.env")
        XCTAssertFalse((alert?.detail ?? "").contains("SECRET"))
        XCTAssertFalse((alert?.detail ?? "").contains("PASSWORD_VALUE"))
    }

    func testSecretMarkersDetected() {
        XCTAssertTrue(SentinelRules.isSecretAccess(event(kind: .fileRead, target: "/x/id_rsa")))
        XCTAssertTrue(SentinelRules.isSecretAccess(event(kind: .fileWrite, target: "/x/.env")))
        XCTAssertTrue(SentinelRules.isSecretAccess(event(kind: .command, target: "cat ~/.aws/credentials")))
        XCTAssertTrue(SentinelRules.isSecretAccess(event(kind: .fileRead, target: "/x/server.pem")))
        XCTAssertFalse(SentinelRules.isSecretAccess(event(kind: .fileRead, target: "/x/README.md")))
        XCTAssertFalse(SentinelRules.isSecretAccess(event(kind: .prompt, target: nil)))
    }

    // MARK: outOfWorktree

    func testOutOfWorktreeRequiresAbsoluteWriteOutsideTree() {
        XCTAssertTrue(SentinelRules.isOutOfWorktree(event(kind: .fileWrite, target: "/tmp/other", worktree: "/repo")))
        XCTAssertFalse(SentinelRules.isOutOfWorktree(event(kind: .fileWrite, target: "/repo/src/a", worktree: "/repo")))
        XCTAssertFalse(SentinelRules.isOutOfWorktree(event(kind: .fileWrite, target: "relative", worktree: "/repo")))
        XCTAssertFalse(SentinelRules.isOutOfWorktree(event(kind: .fileRead, target: "/tmp/other", worktree: "/repo")))
    }

    // MARK: leakedProcess

    func testLeakedProcessFiresWhenListenerUnclaimed() {
        let listener = LiveState.Listener(port: 9000, address: "127.0.0.1", pid: 5, processPath: nil)
        let first = SentinelRules.evaluate(events: [], live: live(listeners: [listener]), seenCounts: [:])
        let second = SentinelRules.evaluate(events: [], live: live(listeners: [listener]), seenCounts: first.seenCounts)
        XCTAssertTrue(second.alerts.contains { $0.kind == .leakedProcess })
    }

    func testLeakedProcessDoesNotFireWhenPortBoundEventExists() {
        let listener = LiveState.Listener(port: 9000, address: "127.0.0.1", pid: 5, processPath: nil)
        let bound = event(kind: .portBound, target: "127.0.0.1:9000")
        let first = SentinelRules.evaluate(events: [bound], live: live(listeners: [listener]), seenCounts: [:])
        let second = SentinelRules.evaluate(events: [bound], live: live(listeners: [listener]), seenCounts: first.seenCounts)
        XCTAssertFalse(second.alerts.contains { $0.kind == .leakedProcess })
    }

    // MARK: budget

    func testBudgetFiresWhenSpendCrossesThreshold() {
        let spend = event(kind: .spendDelta, sessionID: "s1", metadata: ["amount": "25.0"])
        let first = SentinelRules.evaluate(events: [spend], live: live(), seenCounts: [:])
        let second = SentinelRules.evaluate(events: [spend], live: live(), seenCounts: first.seenCounts)
        XCTAssertTrue(second.alerts.contains { $0.kind == .budget })
    }

    func testBudgetSilentBelowThreshold() {
        let spend = event(kind: .spendDelta, sessionID: "s1", metadata: ["amount": "5.0"])
        let first = SentinelRules.evaluate(events: [spend], live: live(), seenCounts: [:])
        let second = SentinelRules.evaluate(events: [spend], live: live(), seenCounts: first.seenCounts)
        XCTAssertFalse(second.alerts.contains { $0.kind == .budget })
    }

    // MARK: watch severity

    func testWatchSeverityIsIndependent() {
        XCTAssertEqual(SentinelRules.watchSeverity([]), .normal)
        let warning = Alert(id: "a", kind: .exposedPort, severity: .warning, sessionID: "", provider: .claude, title: "", detail: "", target: nil, since: Date())
        XCTAssertEqual(SentinelRules.watchSeverity([warning]), .warning)
        let critical = Alert(id: "b", kind: .budget, severity: .critical, sessionID: "", provider: .claude, title: "", detail: "", target: nil, since: Date())
        XCTAssertEqual(SentinelRules.watchSeverity([warning, critical]), .critical)
    }
}
