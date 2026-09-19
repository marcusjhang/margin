import XCTest
@testable import MarginCore

/// Parsing of the live provider payloads (fixtures captured from the real
/// endpoints) and the live cache TTL behaviour.
final class LiveUsageTests: XCTestCase {
    // MARK: Claude live

    private let claudePayload = """
    {
      "five_hour": { "utilization": 20.0, "resets_at": "2026-09-19T08:20:00.047242+00:00" },
      "seven_day": { "utilization": 84.0, "resets_at": "2026-09-23T11:00:00.047291+00:00" },
      "limits": [
        { "kind": "session", "percent": 20, "severity": "normal", "resets_at": "2026-09-19T08:20:00+00:00" },
        { "kind": "weekly_all", "percent": 84, "severity": "warning", "resets_at": "2026-09-23T11:00:00+00:00" },
        { "kind": "weekly_scoped", "percent": 0, "severity": "normal", "resets_at": "2026-09-23T11:00:00+00:00",
          "scope": { "model": { "display_name": "Fable" } } }
      ]
    }
    """

    func testClaudeLiveUsesLimitsArray() throws {
        let usage = try XCTUnwrap(ClaudeLiveClient.parse(data: Data(claudePayload.utf8), planLabel: "Max 20×"))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "weekly_scoped_Fable"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [20, 84, 0])
        XCTAssertEqual(usage.windows[1].reportedSeverity, .warning)
        XCTAssertEqual(usage.planLabel, "Max 20×")
    }

    func testClaudeLiveFallsBackToNamedWindows() throws {
        let payload = """
        { "five_hour": { "utilization": 5, "resets_at": null }, "seven_day": { "utilization": 9, "resets_at": null } }
        """
        let usage = try XCTUnwrap(ClaudeLiveClient.parse(data: Data(payload.utf8), planLabel: nil))
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertNil(usage.planLabel)
    }

    func testClaudeLiveRejectsGarbage() {
        XCTAssertNil(ClaudeLiveClient.parse(data: Data("not json".utf8), planLabel: nil))
        XCTAssertNil(ClaudeLiveClient.parse(data: Data("{}".utf8), planLabel: nil))
    }

    // MARK: Codex live

    private let codexPayload = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "allowed": false,
        "limit_reached": true,
        "primary_window": { "used_percent": 100, "limit_window_seconds": 604800, "reset_at": 1790002772 },
        "secondary_window": null
      }
    }
    """

    func testCodexLiveParsesWeeklyCap() throws {
        let usage = try XCTUnwrap(CodexLiveClient.parse(data: Data(codexPayload.utf8)))
        XCTAssertEqual(usage.planLabel, "Pro")
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.usedPercent, 100)
        XCTAssertEqual(usage.windows.first?.label, "weekly")
        XCTAssertEqual(usage.windows.first?.windowMinutes, 10080)
        XCTAssertEqual(usage.windows.first?.resetsAt?.timeIntervalSince1970 ?? 0, 1790002772, accuracy: 1)
    }

    func testCodexLiveParsesSessionWindow() throws {
        let payload = """
        { "plan_type": "plus",
          "rate_limit": { "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1790002772 } } }
        """
        let usage = try XCTUnwrap(CodexLiveClient.parse(data: Data(payload.utf8)))
        XCTAssertEqual(usage.planLabel, "Plus")
        XCTAssertEqual(usage.windows.first?.label, "5-hour session")
        XCTAssertEqual(usage.windows.first?.windowMinutes, 300)
        XCTAssertEqual(usage.windows.first?.usedPercent, 42)
    }

    func testCodexLiveParsesBothWindows() throws {
        let payload = """
        { "plan_type": "pro",
          "rate_limit": { "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1790002772 },
            "secondary_window": { "used_percent": 55, "limit_window_seconds": 604800, "reset_at": 1790002772 } } }
        """
        let usage = try XCTUnwrap(CodexLiveClient.parse(data: Data(payload.utf8)))
        XCTAssertEqual(usage.windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(usage.windows.map(\.label), ["5-hour session", "weekly"])
    }

    func testCodexLiveSynthesisesCapWithoutWindow() throws {
        let payload = """
        { "plan_type": "pro",
          "rate_limit": { "allowed": false, "limit_reached": true,
            "primary_window": { "reset_at": 1790002772 } } }
        """
        let usage = try XCTUnwrap(CodexLiveClient.parse(data: Data(payload.utf8)))
        XCTAssertEqual(usage.windows.first?.usedPercent, 100)
        XCTAssertEqual(usage.windows.first?.severity, .critical)
    }

    func testCodexLiveRejectsGarbage() {
        XCTAssertNil(CodexLiveClient.parse(data: Data("{}".utf8)))
        XCTAssertNil(CodexLiveClient.parse(data: Data("nope".utf8)))
    }

    // MARK: Cache

    func testCacheFreshWithinTTLAndInvalidates() {
        let cache = LiveUsageCache(ttl: 60, forceFloor: 20)
        XCTAssertNil(cache.usage(.claude, allowStale: false))
        cache.store(.claude, usage: LiveUsage(windows: [], planLabel: nil, fetchedAt: Date()))
        XCTAssertNotNil(cache.usage(.claude, allowStale: false))
        XCTAssertNil(cache.usage(.codex, allowStale: false), "providers are cached independently")
        cache.invalidate()
        XCTAssertNil(cache.usage(.claude, allowStale: false))
    }

    func testStaleValueIsReturnedOnlyWhenAllowed() {
        let cache = LiveUsageCache(ttl: 0, forceFloor: 0)
        cache.store(.codex, usage: LiveUsage(windows: [], planLabel: nil, fetchedAt: Date()))
        XCTAssertNil(cache.usage(.codex, allowStale: false), "ttl 0 is immediately stale")
        XCTAssertNotNil(cache.usage(.codex, allowStale: true), "stale is still available as a fallback")
    }

    func testForceFloorBoundsForcedAttempts() {
        let cache = LiveUsageCache(ttl: 120, forceFloor: 20)
        let now = Date()
        XCTAssertTrue(cache.shouldAttempt(.claude, force: false, now: now))
        cache.noteAttempt(.claude, now: now)

        XCTAssertFalse(cache.shouldAttempt(.claude, force: false, now: now.addingTimeInterval(30)),
                       "non-forced attempts are limited by ttl")
        XCTAssertFalse(cache.shouldAttempt(.claude, force: true, now: now.addingTimeInterval(5)),
                       "forced attempts are limited by forceFloor")
        XCTAssertTrue(cache.shouldAttempt(.claude, force: true, now: now.addingTimeInterval(25)))
        XCTAssertTrue(cache.shouldAttempt(.claude, force: false, now: now.addingTimeInterval(200)))
        XCTAssertTrue(cache.shouldAttempt(.codex, force: false, now: now), "independent per provider")
    }
}
