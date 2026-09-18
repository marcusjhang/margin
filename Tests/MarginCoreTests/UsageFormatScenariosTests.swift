import XCTest
@testable import MarginCore

/// Boundary coverage for every formatter.
final class UsageFormatScenariosTests: XCTestCase {
    func testPercentMatrix() {
        XCTAssertEqual(UsageFormat.percent(0), "0%")
        XCTAssertEqual(UsageFormat.percent(42.4), "42%")
        XCTAssertEqual(UsageFormat.percent(42.5), "43%")
        XCTAssertEqual(UsageFormat.percent(99.6), "100%")
        XCTAssertEqual(UsageFormat.percent(150), "150%")
        XCTAssertEqual(UsageFormat.percent(-5), "0%")
        XCTAssertEqual(UsageFormat.percent(9999), "999%")
        XCTAssertEqual(UsageFormat.percent(.nan), "—")
        XCTAssertEqual(UsageFormat.percent(.infinity), "—")
        XCTAssertEqual(UsageFormat.percent(-.infinity), "—")
    }

    func testCountdownMatrix() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: TimeInterval) -> String {
            UsageFormat.countdown(until: now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(at(-1), "now")
        XCTAssertEqual(at(0), "now")
        XCTAssertEqual(at(30), "<1m")
        XCTAssertEqual(at(59), "<1m")
        XCTAssertEqual(at(60), "1m")
        XCTAssertEqual(at(5 * 60), "5m")
        XCTAssertEqual(at(3600 + 5 * 60), "1h 5m")
        XCTAssertEqual(at(86_400 + 6 * 3600), "1d 6h")
        XCTAssertFalse(at(9.0e18).isEmpty)          // must not trap
        XCTAssertEqual(UsageFormat.countdown(until: Date(timeIntervalSince1970: .nan)), "—")
    }

    func testApproximateDurationMatrix() {
        XCTAssertEqual(UsageFormat.approximateDuration(0), "now")
        XCTAssertEqual(UsageFormat.approximateDuration(-10), "now")
        XCTAssertEqual(UsageFormat.approximateDuration(30), "~1m")
        XCTAssertEqual(UsageFormat.approximateDuration(45 * 60), "~45m")
        XCTAssertEqual(UsageFormat.approximateDuration(3 * 3600), "~3h")
        XCTAssertEqual(UsageFormat.approximateDuration(26 * 3600), "~1d")
        XCTAssertEqual(UsageFormat.approximateDuration(.nan), "—")
        XCTAssertEqual(UsageFormat.approximateDuration(.infinity), "—")
    }

    func testRelativeMatrix() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            UsageFormat.relative(now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(ago(0), "just now")
        XCTAssertEqual(ago(4), "just now")
        XCTAssertEqual(ago(30), "30s ago")
        XCTAssertEqual(ago(5 * 60), "5m ago")
        XCTAssertEqual(ago(3 * 3600), "3h ago")
        XCTAssertEqual(ago(2 * 86_400), "2d ago")
        XCTAssertEqual(UsageFormat.relative(now.addingTimeInterval(60), now: now), "just now") // future
        XCTAssertEqual(UsageFormat.relative(Date(timeIntervalSince1970: .nan), now: now), "—")
    }

    func testWindowLabelsAndKinds() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300), "5-hour session")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 1440), "daily")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080), "weekly")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 43200), "monthly")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 120), "2-hour")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 2880), "2-day")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 90), "90m")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: nil), "usage")

        XCTAssertEqual(UsageFormat.windowKind(minutes: 300), .session)
        XCTAssertEqual(UsageFormat.windowKind(minutes: 1440), .daily)
        XCTAssertEqual(UsageFormat.windowKind(minutes: 10080), .weekly)
        XCTAssertEqual(UsageFormat.windowKind(minutes: 43200), .monthly)
        XCTAssertEqual(UsageFormat.windowKind(minutes: nil), .other)
    }

    func testIdealPaceFraction() {
        // Halfway through the window -> ~0.5
        let window = UsageWindow(
            id: "w", kind: .session, label: "w", usedPercent: 10,
            windowMinutes: 300,
            resetsAt: Date().addingTimeInterval(150 * 60)
        )
        let pace = window.idealPaceFraction ?? -1
        XCTAssertEqual(pace, 0.5, accuracy: 0.02)

        // No reset info -> nil
        XCTAssertNil(UsageWindow(id: "w", kind: .session, label: "w", usedPercent: 1, windowMinutes: nil, resetsAt: nil).idealPaceFraction)
    }
}
