import XCTest
@testable import MarginCore

final class UsageFormatTests: XCTestCase {
    func testWindowLabels() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300), "5-hour session")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 1440), "daily")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080), "weekly")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 43200), "monthly")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: nil), "usage")
    }

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(UsageFormat.countdown(until: Date(timeIntervalSince1970: 4 * 3600 + 12 * 60), now: now), "4h 12m")
        XCTAssertEqual(UsageFormat.countdown(until: Date(timeIntervalSince1970: 30 * 3600), now: now), "1d 6h")
        XCTAssertEqual(UsageFormat.countdown(until: Date(timeIntervalSince1970: -1), now: now), "now")
    }

    func testSeverityLevels() {
        XCTAssertEqual(Severity.level(for: 10), .normal)
        XCTAssertEqual(Severity.level(for: 80), .warning)
        XCTAssertEqual(Severity.level(for: 95), .critical)
    }

    func testApproximateDuration() {
        XCTAssertEqual(UsageFormat.approximateDuration(45 * 60), "~45m")
        XCTAssertEqual(UsageFormat.approximateDuration(3 * 3600 + 20 * 60), "~3h")
        XCTAssertEqual(UsageFormat.approximateDuration(2 * 86400 + 6 * 3600), "~2d")
        XCTAssertEqual(UsageFormat.approximateDuration(0), "now")
    }

    func testBindingWindowIsHighestUsage() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planLabel: "Max 5×",
            windows: [
                UsageWindow(id: "a", kind: .session, label: "5-hour session", usedPercent: 12, windowMinutes: 300, resetsAt: nil),
                UsageWindow(id: "b", kind: .weekly, label: "weekly", usedPercent: 88, windowMinutes: 10080, resetsAt: nil)
            ],
            provenance: .cached,
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.bindingWindow?.id, "b")
        XCTAssertEqual(snapshot.severity, .warning)
    }
}
