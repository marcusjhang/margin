import XCTest
@testable import MarginCore

/// End-to-end accuracy: providers must render exactly what the source file says.
final class ProviderAccuracyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ai.margin.plan.codex")
    }

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-prov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let fetchedAtMs = 1_789_746_591_289.0

    private func claudeFixture() -> Data {
        Data("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(fetchedAtMs),
            "utilization": {
              "limits": [
                { "kind": "session", "percent": 3, "severity": "normal", "resets_at": "2026-09-18T22:20:00.014859+00:00" },
                { "kind": "weekly_all", "percent": 43, "severity": "normal", "resets_at": "2026-09-23T11:00:00+00:00" },
                { "kind": "weekly_scoped", "percent": 0, "severity": "normal", "resets_at": "2026-09-23T11:00:00+00:00",
                  "scope": { "model": { "display_name": "Fable" } } }
              ]
            }
          }
        }
        """.utf8)
    }

    // MARK: Claude

    func testClaudeProviderRendersExactlyTheSource() async throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent(".claude.json")
        try claudeFixture().write(to: url)

        let raw = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(claudeFixture()))
        let loaded = await ClaudeProvider(configURL: url, live: false).load()
        let snapshot = try XCTUnwrap(loaded)

        XCTAssertEqual(snapshot.windows.map(\.id), raw.windows.map(\.id))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), raw.windows.map(\.usedPercent))
        XCTAssertEqual(snapshot.windows.map(\.label), ["5-hour session", "weekly", "weekly · Fable"])
        XCTAssertEqual(snapshot.provenance, .cached)
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, fetchedAtMs / 1000, accuracy: 0.01)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt != nil })
    }

    func testClaudeProviderReturnsNilWhenFileMissing() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
        let loaded = await ClaudeProvider(configURL: missing, live: false).load()
        XCTAssertNil(loaded)
    }

    // MARK: Codex

    private func writeCodex(_ lines: [String], to root: URL, name: String = "rollout.jsonl", modified: TimeInterval = 9_000_000_000) throws {
        let url = root.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: modified)],
            ofItemAtPath: url.path
        )
    }

    private func tokenCount(percent: Double, minutes: Int, plan: String) -> String {
        #"{"timestamp":"2026-09-18T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(percent),"window_minutes":\#(minutes),"resets_at":1790002772},"secondary":null,"plan_type":"\#(plan)"}}}"#
    }

    private func capError(resetText: String) -> String {
        #"{"timestamp":"2026-09-18T17:35:33Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"try again at \#(resetText)","codex_error_info":"usage_limit_exceeded"}}}"#
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date) + "."
    }

    func testCodexProviderNormalWindowsAndPlan() async throws {
        let root = try makeDir()
        try writeCodex([tokenCount(percent: 16, minutes: 10080, plan: "pro")], to: root)

        let loaded = await CodexProvider(root: root, live: false).load()
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary"])
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 16)
        XCTAssertEqual(snapshot.windows.first?.label, "weekly")
        XCTAssertEqual(snapshot.planLabel, "Pro")
    }

    func testCodexProviderCappedWeeklyForFarReset() async throws {
        let root = try makeDir()
        try writeCodex([
            tokenCount(percent: 16, minutes: 10080, plan: "pro"),
            capError(resetText: formatted(Date().addingTimeInterval(2 * 86_400)))
        ], to: root)

        let loaded = await CodexProvider(root: root, live: false).load()
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 100)
        XCTAssertEqual(snapshot.windows.first?.label, "weekly")
        XCTAssertEqual(snapshot.windows.first?.severity, .critical)
        XCTAssertEqual(snapshot.planLabel, "Pro", "plan carried from the earlier record")
    }

    func testCodexProviderCappedSessionForNearReset() async throws {
        let root = try makeDir()
        try writeCodex([capError(resetText: formatted(Date().addingTimeInterval(2 * 3600)))], to: root)

        let loaded = await CodexProvider(root: root, live: false).load()
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.windows.first?.label, "5-hour session")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 100)
    }

    func testCodexProviderReturnsNilForEmptyRoot() async throws {
        let root = try makeDir()
        let loaded = await CodexProvider(root: root, live: false).load()
        XCTAssertNil(loaded)
    }
}
