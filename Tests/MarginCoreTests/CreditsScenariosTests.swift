import XCTest
@testable import MarginCore

/// Credit (pay-as-you-go) parsing from the Claude payload.
final class CreditsScenariosTests: XCTestCase {
    private func parse(_ utilizationJSON: String) -> Credits? {
        let data = Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1789746591289,"utilization":\#(utilizationJSON)}}"#.utf8)
        return ClaudeUsageParser.parseCachedUsage(data)?.credits
    }

    func testSpendBlockWhenEnabledWithRemaining() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 84, "resets_at": null } ],
          "spend": { "used": { "amount_minor": 742, "currency": "SGD", "exponent": 2 },
                     "limit": { "amount_minor": 5000, "currency": "SGD", "exponent": 2 },
                     "percent": 15, "enabled": true } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertTrue(credits.enabled)
        XCTAssertFalse(credits.spendLimitReached)
        XCTAssertEqual(credits.remaining ?? 0, 42.58, accuracy: 0.001)
        XCTAssertEqual(credits.formatted(credits.remaining ?? 0), "SGD 42.58")
        XCTAssertTrue(credits.isAvailable)
    }

    func testSpendBlockAtLimit() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 100, "resets_at": null } ],
          "spend": { "used": { "amount_minor": 5623, "currency": "SGD", "exponent": 2 },
                     "limit": { "amount_minor": 5000, "currency": "SGD", "exponent": 2 },
                     "percent": 100, "enabled": true } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertTrue(credits.spendLimitReached)
        XCTAssertEqual(credits.remaining ?? -1, 0)
        XCTAssertFalse(credits.isAvailable)
    }

    func testDisabledCredits() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 100, "resets_at": null } ],
          "spend": { "used": { "amount_minor": 5623, "currency": "SGD", "exponent": 2 },
                     "limit": { "amount_minor": 5000, "currency": "SGD", "exponent": 2 },
                     "percent": 100, "enabled": false, "disabled_reason": "org_level_disabled_until" } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertFalse(credits.enabled)
        XCTAssertFalse(credits.isAvailable)
    }

    func testExtraUsageFallback() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 50, "resets_at": null } ],
          "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": 2500,
                           "utilization": 50, "currency": "USD", "decimal_places": 2 } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertTrue(credits.enabled)
        XCTAssertEqual(credits.remaining ?? 0, 25.0, accuracy: 0.001)
        XCTAssertEqual(credits.currency, "USD")
        XCTAssertFalse(credits.spendLimitReached)
    }

    func testExtraUsageWithNoLimitIsUncapped() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 50, "resets_at": null } ],
          "extra_usage": { "is_enabled": true, "monthly_limit": null, "used_credits": 1200,
                           "utilization": 0, "currency": "USD", "decimal_places": 2 } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertTrue(credits.enabled)
        XCTAssertNil(credits.remaining)
        XCTAssertEqual(credits.used ?? 0, 12.0, accuracy: 0.001)
    }

    func testNoCreditsBlock() throws {
        let json = #"{ "limits": [ { "kind": "weekly_all", "percent": 10, "resets_at": null } ] }"#
        XCTAssertNil(parse(json))
    }

    func testUncappedCreditsAreAvailable() throws {
        // Real shape when credits are on with no spend limit: limit is null.
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 100, "resets_at": null } ],
          "spend": { "used": { "amount_minor": 8013, "currency": "SGD", "exponent": 2 },
                     "limit": null, "percent": 0, "enabled": true, "spend_limit_reached": false },
          "extra_usage": { "is_enabled": true, "monthly_limit": null, "used_credits": 8013.0,
                           "currency": "SGD", "decimal_places": 2, "spend_limit_reached": false } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertTrue(credits.enabled)
        XCTAssertNil(credits.remaining)
        XCTAssertEqual(credits.used ?? 0, 80.13, accuracy: 0.001)
        XCTAssertTrue(credits.isAvailable, "uncapped credits can absorb a cap")
    }

    func testSpendPreferredOverExtraUsage() throws {
        let json = """
        { "limits": [ { "kind": "weekly_all", "percent": 10, "resets_at": null } ],
          "spend": { "used": { "amount_minor": 100, "currency": "SGD", "exponent": 2 },
                     "limit": { "amount_minor": 200, "currency": "SGD", "exponent": 2 }, "percent": 50, "enabled": true },
          "extra_usage": { "is_enabled": false, "monthly_limit": 9999, "used_credits": 0, "decimal_places": 2, "currency": "USD" } }
        """
        let credits = try XCTUnwrap(parse(json))
        XCTAssertEqual(credits.currency, "SGD")
        XCTAssertTrue(credits.enabled)
    }
}
