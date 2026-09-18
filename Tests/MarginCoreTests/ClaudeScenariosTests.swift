import XCTest
@testable import MarginCore

/// Table-driven coverage of Claude plan labels, limit shapes and boundaries.
final class ClaudeScenariosTests: XCTestCase {
    private let baseFetchedAt = 1789746591289.0

    private func cached(utilizationJSON: String) -> Data {
        Data(#"{"cachedUsageUtilization":{"fetchedAtMs":\#(baseFetchedAt),"utilization":\#(utilizationJSON)}}"#.utf8)
    }

    // MARK: Plan labels

    func testClaudePlanLabelMatrix() {
        func label(_ oauth: [String: Any]) -> String? { ClaudeCredentials.planLabel(fromOAuth: oauth) }

        XCTAssertEqual(label(["rateLimitTier": "default_claude_max_20x"]), "Max 20×")
        XCTAssertEqual(label(["rateLimitTier": "default_claude_max_5x"]), "Max 5×")
        XCTAssertEqual(label(["subscriptionType": "max"]), "Max")
        XCTAssertEqual(label(["subscriptionType": "pro"]), "Pro")
        XCTAssertEqual(label(["subscriptionType": "free"]), "Free")
        XCTAssertEqual(label(["subscriptionType": "MAX"]), "Max")
        XCTAssertEqual(label(["subscriptionType": "Pro"]), "Pro")
        // Tier wins over a generic subscription.
        XCTAssertEqual(label(["subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"]), "Max 5×")
        XCTAssertNil(label([:]))
        XCTAssertNil(label(["subscriptionType": ""]))
        XCTAssertNil(label(["subscriptionType": 42]))
    }

    // MARK: Limit shapes

    func testFullLimitsShape() throws {
        let json = """
        { "limits": [
          { "kind": "session", "percent": 34, "severity": "normal", "resets_at": "2026-09-18T17:20:00.805961+00:00" },
          { "kind": "weekly_all", "percent": 88, "severity": "warning", "resets_at": "2026-09-23T11:00:00.805981+00:00" },
          { "kind": "weekly_scoped", "percent": 12, "severity": "normal", "resets_at": "2026-09-23T11:00:00+00:00",
            "scope": { "model": { "id": "fable", "display_name": "Fable" } } }
        ] }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "weekly_scoped_Fable"])
        XCTAssertEqual(usage.windows.map(\.label), ["5-hour session", "weekly", "weekly · Fable"])
        XCTAssertEqual(usage.windows[1].reportedSeverity, .warning)
    }

    func testMultipleScopedModelsKeepDistinctIDs() throws {
        let json = """
        { "limits": [
          { "kind": "weekly_scoped", "percent": 10, "resets_at": null, "scope": { "model": { "display_name": "Fable" } } },
          { "kind": "weekly_scoped", "percent": 20, "resets_at": null, "scope": { "model": { "display_name": "Opus" } } }
        ] }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)))
        XCTAssertEqual(usage.windows.map(\.id), ["weekly_scoped_Fable", "weekly_scoped_Opus"])
    }

    func testUnknownKindsAndNullPercentsAreSkipped() throws {
        let json = """
        { "limits": [
          { "kind": "session", "percent": 5, "resets_at": null },
          { "kind": "weekly_all", "percent": null, "resets_at": null },
          { "kind": "mystery", "percent": 50, "resets_at": null }
        ] }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)))
        XCTAssertEqual(usage.windows.map(\.id), ["session"])
    }

    func testMissingLimitsFallsBackToNamedWindowsAndDropsZeroScoped() throws {
        let json = """
        {
          "five_hour": { "utilization": 12, "resets_at": null },
          "seven_day": { "utilization": 45, "resets_at": null },
          "seven_day_opus": { "utilization": 0, "resets_at": null },
          "seven_day_sonnet": { "utilization": 30, "resets_at": null }
        }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)))
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet"])
    }

    // MARK: Values & resets

    func testBoundaryPercentagesArePreserved() throws {
        for value in [0.0, 0.1, 74.9, 75.0, 89.9, 90.0, 99.5, 100.0, 100.4, 150.0, -5.0] {
            let json = #"{ "limits": [ { "kind": "weekly_all", "percent": \#(value), "resets_at": null } ] }"#
            let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)), "\(value)")
            XCTAssertEqual(usage.windows.first?.usedPercent, value)
        }
    }

    func testResetFormats() throws {
        let json = """
        { "limits": [
          { "kind": "session", "percent": 1, "resets_at": "2026-09-18T17:20:00+00:00" },
          { "kind": "weekly_all", "percent": 2, "resets_at": 1790002772000 },
          { "kind": "weekly_scoped", "percent": 3, "resets_at": null, "scope": { "model": { "display_name": "X" } } }
        ] }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)))
        XCTAssertNotNil(usage.windows[0].resetsAt)
        XCTAssertEqual(usage.windows[1].resetsAt?.timeIntervalSince1970 ?? 0, 1790002772, accuracy: 1)
        XCTAssertNil(usage.windows[2].resetsAt)
    }

    func testNonFiniteValuesAreRejected() throws {
        // 1e400 overflows to +inf in JSONSerialization; the window must be dropped.
        let json = #"{ "limits": [ { "kind": "weekly_all", "percent": 1e400, "resets_at": null } ] }"#
        XCTAssertNil(ClaudeUsageParser.parseCachedUsage(cached(utilizationJSON: json)))
        XCTAssertNil(ClaudeUsageParser.doubleValue(NSNumber(value: Double.infinity)))
        XCTAssertNil(ClaudeUsageParser.doubleValue(NSNumber(value: Double.nan)))
    }

    func testMissingUtilizationReturnsNil() {
        XCTAssertNil(ClaudeUsageParser.parseCachedUsage(Data("{}".utf8)))
        XCTAssertNil(ClaudeUsageParser.parseCachedUsage(Data(#"{"cachedUsageUtilization":{}}"#.utf8)))
    }

    // MARK: Model behaviour

    func testWindowSeverityPrefersReportedThenThresholds() {
        let reported = UsageWindow(id: "w", kind: .weekly, label: "w", usedPercent: 10, windowMinutes: 10080, resetsAt: nil, reportedSeverity: .critical)
        XCTAssertEqual(reported.severity, .critical)
        let computed = UsageWindow(id: "w", kind: .weekly, label: "w", usedPercent: 95, windowMinutes: 10080, resetsAt: nil)
        XCTAssertEqual(computed.severity, .critical)
        XCTAssertEqual(UsageWindow(id: "w", kind: .weekly, label: "w", usedPercent: 80, windowMinutes: 10080, resetsAt: nil).severity, .warning)
        XCTAssertEqual(UsageWindow(id: "w", kind: .weekly, label: "w", usedPercent: 10, windowMinutes: 10080, resetsAt: nil).severity, .normal)
    }

    func testBindingWindowIsTheHighestUsage() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planLabel: "Pro",
            windows: [
                UsageWindow(id: "session", kind: .session, label: "s", usedPercent: 10, windowMinutes: 300, resetsAt: nil),
                UsageWindow(id: "weekly", kind: .weekly, label: "w", usedPercent: 90, windowMinutes: 10080, resetsAt: nil)
            ],
            provenance: .cached,
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.bindingWindow?.id, "weekly")
    }
}
