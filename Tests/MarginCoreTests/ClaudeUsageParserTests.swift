import XCTest
@testable import MarginCore

final class ClaudeUsageParserTests: XCTestCase {
    private let json = """
    {
      "cachedUsageUtilization": {
        "fetchedAtMs": 1789746591289,
        "accountUuid": "abc",
        "utilization": {
          "five_hour": { "utilization": 34, "resets_at": "2026-09-18T17:20:00.805961+00:00" },
          "seven_day": { "utilization": 34, "resets_at": "2026-09-23T11:00:00.805981+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": { "utilization": 0, "resets_at": null }
        }
      }
    }
    """

    func testParsesSessionAndWeeklyWindows() throws {
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(json.utf8)))
        XCTAssertEqual(usage.windows.count, 2)
        let session = try XCTUnwrap(usage.windows.first { $0.id == "five_hour" })
        XCTAssertEqual(session.usedPercent, 34)
        XCTAssertEqual(session.windowMinutes, 300)
        XCTAssertNotNil(session.resetsAt)
        let weekly = try XCTUnwrap(usage.windows.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.usedPercent, 34)
        XCTAssertEqual(weekly.windowMinutes, 10080)
    }

    func testParsesFetchedTimestamp() throws {
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(json.utf8)))
        XCTAssertEqual(usage.updatedAt.timeIntervalSince1970, 1789746591.289, accuracy: 0.01)
    }

    func testSkipsZeroScopedWindows() throws {
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(json.utf8)))
        XCTAssertNil(usage.windows.first { $0.id == "seven_day_sonnet" })
    }

    func testReturnsNilWithoutUtilization() {
        XCTAssertNil(ClaudeUsageParser.parseCachedUsage(Data("{}".utf8)))
    }

    func testPrefersLimitsArrayWithScopedWindows() throws {
        let limitsJSON = """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": 1789746591289,
            "utilization": {
              "five_hour": { "utilization": 99, "resets_at": null },
              "limits": [
                { "kind": "session", "percent": 34, "severity": "normal", "resets_at": "2026-09-18T17:20:00+00:00" },
                { "kind": "weekly_all", "percent": 88, "severity": "warning", "resets_at": "2026-09-23T11:00:00+00:00" },
                { "kind": "weekly_scoped", "percent": 12, "severity": "normal", "resets_at": "2026-09-23T11:00:00+00:00",
                  "scope": { "model": { "id": null, "display_name": "Fable" } } }
              ]
            }
          }
        }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(limitsJSON.utf8)))
        XCTAssertEqual(usage.windows.count, 3)
        XCTAssertEqual(usage.windows.first?.id, "session")
        XCTAssertEqual(usage.windows.first?.usedPercent, 34)
        XCTAssertEqual(usage.windows.first?.reportedSeverity, .normal)
        let weekly = try XCTUnwrap(usage.windows.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.reportedSeverity, .warning)
        let scoped = try XCTUnwrap(usage.windows.first { $0.id == "weekly_scoped_Fable" })
        XCTAssertEqual(scoped.label, "weekly · Fable")
    }

    func testSkipsLimitsWithNullPercentAndKeepsFractional() throws {
        let json = """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": 1789746591289,
            "utilization": {
              "limits": [
                { "kind": "session", "percent": 42.5, "resets_at": null },
                { "kind": "weekly_all", "percent": null, "resets_at": null },
                { "kind": "mystery_kind", "percent": 10, "resets_at": null }
              ]
            }
          }
        }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(json.utf8)))
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.id, "session")
        XCTAssertEqual(usage.windows.first?.usedPercent, 42.5)
    }

    func testParsesEpochMillisecondReset() throws {
        let json = """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": 1789746591289,
            "utilization": {
              "limits": [ { "kind": "weekly_all", "percent": 5, "resets_at": 1790002772000 } ]
            }
          }
        }
        """
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(json.utf8)))
        let reset = try XCTUnwrap(usage.windows.first?.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1790002772, accuracy: 0.5)
    }

    func testIgnoresFieldsWithZeroScopedWindowsInFallback() throws {
        // No `limits`, so it falls back to named windows and drops zero scoped ones.
        let usage = try XCTUnwrap(ClaudeUsageParser.parseCachedUsage(Data(json.utf8)))
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "seven_day"])
    }
}
