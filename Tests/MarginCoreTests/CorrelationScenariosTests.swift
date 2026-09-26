import XCTest
@testable import MarginCore

/// Correlation and worktree behaviours: attribute listeners to sessions by
/// process ancestry, flag leaked ones, and parse porcelain worktree output.
final class CorrelationScenariosTests: XCTestCase {
    private func event(
        sessionID: String,
        cwd: String,
        provider: ProviderID = .claude,
        kind: ActivityKind = .command
    ) -> ActivityEvent {
        ActivityEvent(
            id: ActivityEvent.makeID(provider: provider, sessionID: sessionID, ordinal: 0, kind: kind, target: nil),
            provider: provider,
            sessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: kind,
            cwd: cwd,
            gitBranch: nil,
            worktree: nil,
            tool: nil,
            target: nil,
            provenance: .local,
            metadata: [:]
        )
    }

    private func listener(port: Int, address: String = "127.0.0.1", pid: Int32 = 100) -> LiveState.Listener {
        LiveState.Listener(port: port, address: address, pid: pid, processPath: "/bin/agent")
    }

    // MARK: Attribution

    func testListenerAttributedToSessionViaCwd() {
        let events = [event(sessionID: "s1", cwd: "/repo")]
        let listeners = [listener(port: 8080, pid: 100)]

        let result = ActivityCorrelator.correlate(
            events: events,
            listeners: listeners,
            activeSessions: ["s1"],
            processParent: { _ in nil },
            processCwd: { pid in pid == 100 ? "/repo" : nil }
        )

        XCTAssertEqual(result.alerts.count, 0)
        let bound = result.events.filter { $0.kind == .portBound }
        XCTAssertEqual(bound.count, 1)
        XCTAssertEqual(bound.first?.sessionID, "s1")
        XCTAssertEqual(bound.first?.target, "127.0.0.1:8080")
        XCTAssertEqual(bound.first?.metadata["pid"], "100")
    }

    func testListenerAttributedViaAncestorChain() {
        let events = [event(sessionID: "s1", cwd: "/repo")]
        let listeners = [listener(port: 8080, pid: 10)]

        let result = ActivityCorrelator.correlate(
            events: events,
            listeners: listeners,
            activeSessions: ["s1"],
            processParent: { pid in pid == 10 ? 11 : pid == 11 ? 12 : nil },
            processCwd: { pid in pid == 12 ? "/repo" : nil }
        )

        XCTAssertEqual(result.alerts.count, 0)
        XCTAssertEqual(result.events.filter { $0.kind == .portBound }.count, 1)
    }

    func testLeakedListenerIsFlagged() {
        let events = [event(sessionID: "s1", cwd: "/repo")]
        let listeners = [listener(port: 8080, pid: 10)]

        let result = ActivityCorrelator.correlate(
            events: events,
            listeners: listeners,
            activeSessions: ["s1"],
            processParent: { _ in nil },
            processCwd: { _ in nil }
        )

        XCTAssertEqual(result.alerts.count, 1)
        XCTAssertEqual(result.alerts.first?.kind, .leakedProcess)
        XCTAssertEqual(result.alerts.first?.target, "127.0.0.1:8080")
        XCTAssertTrue(result.events.filter { $0.kind == .portBound }.isEmpty)
    }

    func testListenerOwnedByInactiveSessionIsLeaked() {
        let events = [event(sessionID: "s1", cwd: "/repo")]
        let listeners = [listener(port: 8080, pid: 100)]

        let result = ActivityCorrelator.correlate(
            events: events,
            listeners: listeners,
            activeSessions: [],                       // s1 no longer active
            processParent: { _ in nil },
            processCwd: { pid in pid == 100 ? "/repo" : nil }
        )

        XCTAssertEqual(result.alerts.count, 1)
        XCTAssertEqual(result.alerts.first?.kind, .leakedProcess)
        XCTAssertEqual(result.alerts.first?.sessionID, "s1")
    }

    func testNoListenersNoAlerts() {
        let result = ActivityCorrelator.correlate(
            events: [],
            listeners: [],
            activeSessions: [],
            processParent: { _ in nil },
            processCwd: { _ in nil }
        )
        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertTrue(result.events.isEmpty)
    }

    // MARK: Worktree parsing

    func testWorktreeParsesDeepestPrefixAndBranch() {
        let porcelain = """
        worktree /Users/dev/repo
        HEAD abc123
        branch refs/heads/main

        worktree /Users/dev/repo/sub
        HEAD def456
        branch refs/heads/feature
        """
        let result = WorktreeSource.parse(porcelain, cwd: "/Users/dev/repo/sub/src")
        XCTAssertEqual(result?.worktree, "/Users/dev/repo/sub")
        XCTAssertEqual(result?.branch, "feature")
    }

    func testWorktreeFallsBackToRootWhenOnlyRootMatches() {
        let porcelain = """
        worktree /Users/dev/repo
        HEAD abc123
        branch refs/heads/main
        """
        let result = WorktreeSource.parse(porcelain, cwd: "/Users/dev/repo/src")
        XCTAssertEqual(result?.worktree, "/Users/dev/repo")
        XCTAssertEqual(result?.branch, "main")
    }

    func testWorktreeReturnsNilWhenNoPrefixMatches() {
        let porcelain = """
        worktree /other/project
        HEAD abc123
        branch refs/heads/main
        """
        XCTAssertNil(WorktreeSource.parse(porcelain, cwd: "/Users/dev/repo"))
        XCTAssertNil(WorktreeSource.parse("", cwd: "/Users/dev/repo"))
    }

    func testWorktreeDetachedHeadHasEmptyBranch() {
        let porcelain = """
        worktree /Users/dev/repo
        HEAD abc123
        """
        let result = WorktreeSource.parse(porcelain, cwd: "/Users/dev/repo/src")
        XCTAssertEqual(result?.worktree, "/Users/dev/repo")
        XCTAssertEqual(result?.branch, "")
    }
}
