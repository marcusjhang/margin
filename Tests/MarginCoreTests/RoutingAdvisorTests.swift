import XCTest
@testable import MarginCore

final class RoutingAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ provider: ProviderID, used: Double, label: String = "weekly") -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planLabel: nil,
            windows: [
                UsageWindow(
                    id: provider == .claude ? "seven_day" : "primary",
                    kind: .weekly,
                    label: label,
                    usedPercent: used,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(4 * 3600)
                )
            ],
            provenance: .local,
            updatedAt: now
        )
    }

    func testRecommendsProviderWithMoreHeadroom() throws {
        let claude = snapshot(.claude, used: 82)
        let codex = snapshot(.codex, used: 16)
        let key = WindowForecast.key(provider: .claude, windowID: "seven_day")
        let forecast = WindowForecast(burnRatePerHour: 5, timeToCap: 3 * 3600, projectedEndPercent: 118, probabilityOfCap: 0.7, sampleCount: 8, isReliable: true)

        let advice = try XCTUnwrap(RoutingAdvisor.advice(snapshots: [claude, codex], forecasts: [key: forecast], now: now))
        XCTAssertEqual(advice.kind, .useProvider)
        XCTAssertEqual(advice.recommended, .codex)
        XCTAssertEqual(advice.severity, .warning)
        XCTAssertTrue(advice.headline.hasPrefix("Use Codex"))
        XCTAssertTrue(advice.headline.contains("caps in"))
    }

    func testCappedProviderStepsAside() throws {
        let claude = snapshot(.claude, used: 100)
        let codex = snapshot(.codex, used: 20)
        let advice = try XCTUnwrap(RoutingAdvisor.advice(snapshots: [claude, codex], forecasts: [:], now: now))
        XCTAssertEqual(advice.kind, .useProvider)
        XCTAssertEqual(advice.recommended, .codex)
        XCTAssertTrue(advice.headline.contains("capped"))
    }

    func testBothCapped() throws {
        let advice = try XCTUnwrap(RoutingAdvisor.advice(
            snapshots: [snapshot(.claude, used: 100), snapshot(.codex, used: 100)],
            forecasts: [:],
            now: now
        ))
        XCTAssertEqual(advice.kind, .bothConstrained)
        XCTAssertEqual(advice.severity, .critical)
        XCTAssertNil(advice.recommended)
    }

    func testBothHealthyPicksLower() throws {
        let advice = try XCTUnwrap(RoutingAdvisor.advice(
            snapshots: [snapshot(.claude, used: 40), snapshot(.codex, used: 12)],
            forecasts: [:],
            now: now
        ))
        XCTAssertEqual(advice.kind, .bothHealthy)
        XCTAssertEqual(advice.recommended, .codex)
        XCTAssertEqual(advice.severity, .normal)
    }

    func testNoWindowsReturnsNil() {
        let empty = ProviderSnapshot(provider: .claude, planLabel: nil, windows: [], provenance: .cached, updatedAt: now)
        XCTAssertNil(RoutingAdvisor.advice(snapshots: [empty], forecasts: [:], now: now))
    }
}
