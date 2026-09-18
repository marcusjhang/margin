import XCTest
@testable import MarginCore

final class CodexRolloutParserTests: XCTestCase {
    private let line = """
    {"timestamp":"2026-09-10T02:10:45.949Z","ordinal":18,"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":22.0,"window_minutes":10080,"resets_at":1789435712},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"pro","rate_limit_reached_type":null}}}
    """

    func testParsesPrimaryWindow() throws {
        let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: line))
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.windows.count, 1)
        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(window.usedPercent, 22)
        XCTAssertEqual(window.windowMinutes, 10080)
        XCTAssertEqual(window.label, "weekly")
        XCTAssertNotNil(window.resetsAt)
        XCTAssertNotNil(snapshot.updatedAt)
    }

    func testIgnoresNonTokenCountLines() {
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: #"{"type":"session_meta","payload":{}}"#))
    }

    func testSamplesExtractTimestampedWindows() throws {
        let samples = CodexRolloutParser.samples(fromLine: line)
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.provider, .codex)
        XCTAssertEqual(sample.windowID, "primary")
        XCTAssertEqual(sample.usedPercent, 22)
    }

    func testLatestSnapshotScansFromEnd() throws {
        let older = line.replacingOccurrences(of: "22.0", with: "5.0")
        let snapshot = try XCTUnwrap(CodexRolloutParser.latestSnapshot(inLines: [older, line]))
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 22)
    }

    func testParsesBothWindowsWhenPresent() throws {
        let dual = """
        {"timestamp":"2026-09-10T02:10:45.949Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1789435712},"secondary":{"used_percent":80.0,"window_minutes":10080,"resets_at":1789435712},"plan_type":"plus"}}}
        """
        let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: dual))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first?.label, "5-hour session")
    }

    func testNullWindowTokenCountIsNotCapped() throws {
        let capped = #"{"timestamp":"2026-09-18T17:35:33Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":null}}}"#
        // Null windows are not a cap signal; only the explicit limit error is.
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: capped))
        XCTAssertTrue(CodexRolloutParser.samples(fromLine: capped).isEmpty)
    }

    func testMalformedWindowIsNotTreatedAsCapped() throws {
        // A present-but-unparseable window must not be reported as 100%.
        let malformed = #"{"timestamp":"2026-09-18T17:35:33Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42},"secondary":null,"plan_type":"pro"}}}"#
        XCTAssertNil(CodexRolloutParser.snapshot(fromLine: malformed))
    }

    func testUsageLimitErrorCarriesResetTime() throws {
        let limit = #"{"timestamp":"2026-09-18T17:35:33.230Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 21st, 2026 10:59 PM.","codex_error_info":"usage_limit_exceeded"}}}"#
        let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: limit))
        XCTAssertTrue(snapshot.limitReached)
        XCTAssertNotNil(snapshot.resetHint)
    }

    func testMalformedAndIrrelevantLinesAreIgnored() {
        for bad in ["", "not json", "{}", #"{"type":"event_msg","payload":{"type":"token_count"}}"#, "[1,2,3]"] {
            XCTAssertNil(CodexRolloutParser.snapshot(fromLine: bad), bad)
            XCTAssertTrue(CodexRolloutParser.samples(fromLine: bad).isEmpty, bad)
        }
    }

    func testOnlySecondaryPresentStillParses() throws {
        let line = #"{"timestamp":"2026-09-10T02:10:45Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":null,"secondary":{"used_percent":7,"window_minutes":10080,"resets_at":1789435712},"plan_type":"pro"}}}"#
        let snapshot = try XCTUnwrap(CodexRolloutParser.snapshot(fromLine: line))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.id, "secondary")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 7)
        XCTAssertFalse(snapshot.limitReached)
    }

    func testResetParsingToleratesDifferentOrdinals() {
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 1st, 2026 1:05 AM."))
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 22nd, 2026 11:59 PM."))
        XCTAssertNotNil(CodexRolloutParser.parseReset("try again at Sep 23rd, 2026 12:00 PM."))
        XCTAssertNil(CodexRolloutParser.parseReset("no timestamp here"))
    }
}
