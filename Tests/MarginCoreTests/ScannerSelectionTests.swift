import XCTest
@testable import MarginCore

/// Selection accuracy of the Codex scanner against controlled fixture trees.
final class ScannerSelectionTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ lines: [String], to root: URL, name: String, modified: TimeInterval) throws {
        let url = root.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: modified)],
            ofItemAtPath: url.path
        )
    }

    private func tokenCount(percent: Double, minutes: Int, plan: String, at timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(percent),"window_minutes":\#(minutes),"resets_at":1790002772},"secondary":null,"plan_type":"\#(plan)"}}}"#
    }

    private let limitError = #"{"timestamp":"2026-09-18T17:35:33Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"try again at Sep 21st, 2026 10:59 PM.","codex_error_info":"usage_limit_exceeded"}}}"#

    // MARK: Snapshot selection

    func testChoosesNewestSnapshotByTimestampNotFileMtime() throws {
        let root = try makeRoot()
        // Older file mtime, but newer snapshot timestamp.
        try write([tokenCount(percent: 80, minutes: 10080, plan: "pro", at: "2026-09-18T10:00:00Z")],
                  to: root, name: "a.jsonl", modified: 1000)
        // Newer file mtime, but older snapshot timestamp.
        try write([tokenCount(percent: 10, minutes: 10080, plan: "pro", at: "2026-09-10T10:00:00Z")],
                  to: root, name: "b.jsonl", modified: 9000)

        let snapshot = try XCTUnwrap(CodexRolloutScanner.latestSnapshot(root: root))
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 80)
    }

    func testCappedSessionIsDetected() throws {
        let root = try makeRoot()
        try write([tokenCount(percent: 16, minutes: 10080, plan: "pro", at: "2026-09-18T10:00:00Z"), limitError],
                  to: root, name: "capped.jsonl", modified: 9000)

        let snapshot = try XCTUnwrap(CodexRolloutScanner.latestSnapshot(root: root))
        XCTAssertTrue(snapshot.limitReached)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNotNil(snapshot.resetHint)
        XCTAssertEqual(snapshot.planType, "pro", "capped snapshot should borrow the earlier plan")
    }

    func testNullWindowFileFallsThroughToUsableFile() throws {
        let root = try makeRoot()
        let nullWindows = #"{"timestamp":"2026-09-19T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":"team"}}}"#
        try write([nullWindows], to: root, name: "premium.jsonl", modified: 9000)
        try write([tokenCount(percent: 42, minutes: 300, plan: "pro", at: "2026-09-18T10:00:00Z")],
                  to: root, name: "usable.jsonl", modified: 8000)

        let snapshot = try XCTUnwrap(CodexRolloutScanner.latestSnapshot(root: root))
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 42)
        XCTAssertFalse(snapshot.limitReached)
    }

    func testLastKnownPlanType() throws {
        let root = try makeRoot()
        try write([tokenCount(percent: 5, minutes: 10080, plan: "enterprise", at: "2026-09-01T10:00:00Z")],
                  to: root, name: "p.jsonl", modified: 9000)
        XCTAssertEqual(CodexRolloutScanner.lastKnownPlanType(root: root), "enterprise")
    }

    func testEmptyRootReturnsNil() throws {
        let root = try makeRoot()
        XCTAssertNil(CodexRolloutScanner.latestSnapshot(root: root))
        XCTAssertNil(CodexRolloutScanner.lastKnownPlanType(root: root))
        XCTAssertTrue(CodexRolloutScanner.samples(since: .distantPast, root: root).isEmpty)
    }

    // MARK: Backfill samples

    func testSamplesFilterByFileRecencyAndIncludeCapError() throws {
        let root = try makeRoot()
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let inside = tokenCount(percent: 30, minutes: 10080, plan: "pro", at: "2026-09-18T10:00:00Z")
        try write([inside, limitError], to: root, name: "new.jsonl", modified: 9_000_000_000)

        let stale = tokenCount(percent: 99, minutes: 10080, plan: "pro", at: "2020-01-01T00:00:00Z")
        try write([stale], to: root, name: "old.jsonl", modified: 1_000_000)

        let percents = CodexRolloutScanner.samples(since: since, root: root).map(\.usedPercent)
        XCTAssertTrue(percents.contains(30))
        XCTAssertTrue(percents.contains(100), "cap error yields a 100% sample")
        XCTAssertFalse(percents.contains(99), "files older than `since` are skipped")
    }
}
