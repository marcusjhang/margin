import XCTest
@testable import MarginCore

/// Table-driven coverage of Codex plan types, window combinations, and caps.
final class CodexScenariosTests: XCTestCase {
    private func tokenCount(
        plan: String?,
        primary: (Double, Int, Int)?,
        secondary: (Double, Int, Int)?,
        timestamp: String = "2026-09-10T02:10:45Z",
        limitID: String = "codex"
    ) -> String {
        func win(_ value: (Double, Int, Int)?) -> String {
            guard let value else { return "null" }
            return #"{"used_percent":\#(value.0),"window_minutes":\#(value.1),"resets_at":\#(value.2)}"#
        }
        let planLiteral = plan.map { #""\#($0)""# } ?? "null"
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"\#(limitID)","primary":\#(win(primary)),"secondary":\#(win(secondary)),"plan_type":\#(planLiteral)}}}"#
    }

    private func limitError(timestamp: String = "2026-09-18T17:35:33Z",
                            message: String = "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 21st, 2026 10:59 PM.") -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_complete","error":{"message":"\#(message)","codex_error_info":"usage_limit_exceeded"}}}"#
    }

    // MARK: Plans

    func testEveryPlanTypeIsParsed() throws {
        for plan in ["pro", "plus", "team", "business", "enterprise", "free", "edu", "guest", "prolite"] {
            let line = tokenCount(plan: plan, primary: (42, 300, 1789435712), secondary: nil)
            let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: line), plan)
            XCTAssertEqual(snapshot.planType, plan)
            XCTAssertFalse(snapshot.limitReached)
        }
    }

    func testMissingPlanTypeIsNil() throws {
        let line = tokenCount(plan: nil, primary: (5, 10080, 1789435712), secondary: nil)
        let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: line))
        XCTAssertNil(snapshot.planType)
    }

    // MARK: Window combinations

    func testWindowCombinations() throws {
        // primary only
        var snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: tokenCount(plan: "pro", primary: (10, 300, 1), secondary: nil)))
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary"])

        // secondary only
        snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: tokenCount(plan: "pro", primary: nil, secondary: (20, 10080, 1))))
        XCTAssertEqual(snapshot.windows.map(\.id), ["secondary"])

        // both
        snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: tokenCount(plan: "pro", primary: (10, 300, 1), secondary: (20, 10080, 1))))
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary", "secondary"])

        // neither -> no snapshot (and definitely not "capped")
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: tokenCount(plan: "premium", primary: nil, secondary: nil, limitID: "premium")))
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: tokenCount(plan: "team", primary: nil, secondary: nil, limitID: "premium")))
    }

    func testNullWindowsDuringNormalUseAreNotCapped() {
        // Real premium/team sessions report null windows with no limit error.
        let line = tokenCount(plan: "team", primary: nil, secondary: nil, limitID: "premium")
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: line))
        XCTAssertTrue(CodexRolloutParser.samples(fromLine: line).isEmpty)
    }

    func testMalformedWindowIsNotCapped() {
        let line = #"{"timestamp":"2026-09-18T17:35:33Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42},"secondary":null,"plan_type":"pro"}}}"#
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: line))
    }

    // MARK: Caps

    func testExplicitLimitErrorIsCapped() throws {
        let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: limitError()))
        XCTAssertTrue(snapshot.limitReached)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNotNil(snapshot.resetHint)
    }

    func testCappedSnapshotBorrowsEarlierPlan() throws {
        let lines = [
            tokenCount(plan: "pro", primary: (16, 10080, 1790002772), secondary: nil),
            limitError()
        ]
        let snapshot = try XCTUnwrap(CodexRolloutParser.latestSnapshot(inLines: lines))
        XCTAssertTrue(snapshot.limitReached)
        XCTAssertEqual(snapshot.planType, "pro")
    }

    func testResetParsingAcrossOrdinalsAndFormats() {
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 1st, 2026 1:05 AM."))
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 22nd, 2026 11:59 PM."))
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 23rd, 2026 12:00 PM."))
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 24th, 2026 12:00 PM."))
        XCTAssertNil(CodexRolloutParser.parseReset("no reset here"))
    }

    // MARK: Samples

    func testSamplesEmitOnlyRealWindows() {
        let both = tokenCount(plan: "pro", primary: (10, 300, 1), secondary: (20, 10080, 1))
        XCTAssertEqual(CodexRolloutParser.samples(fromLine: both).map(\.windowID), ["primary", "secondary"])

        let none = tokenCount(plan: "team", primary: nil, secondary: nil, limitID: "premium")
        XCTAssertTrue(CodexRolloutParser.samples(fromLine: none).isEmpty)

        let cap = limitError()
        let capSamples = CodexRolloutParser.samples(fromLine: cap)
        XCTAssertEqual(capSamples.count, 1)
        XCTAssertEqual(capSamples.first?.usedPercent, 100)
        XCTAssertEqual(capSamples.first?.windowID, "primary")
    }

    func testBoundaryPercentagesArePreserved() throws {
        for value in [0.0, 0.1, 74.9, 75.0, 90.0, 99.9, 100.0, 100.4, 150.0, -5.0] {
            let line = tokenCount(plan: "pro", primary: (value, 300, 1), secondary: nil)
            let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: line), "\(value)")
            XCTAssertEqual(snapshot.windows.first?.usedPercent, value)
        }
    }
}
