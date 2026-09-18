import XCTest
@testable import MarginCore

/// Forecast behaviour across ramp shapes, boundaries and degenerate inputs.
final class ForecastScenariosTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double, resetsInHours: Double, minutes: Int = 300) -> UsageWindow {
        UsageWindow(
            id: "w",
            kind: UsageFormat.windowKind(minutes: minutes),
            label: "w",
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: now.addingTimeInterval(resetsInHours * 3600)
        )
    }

    /// Builds hourly samples ending at `now`, starting `hoursAgo`.
    private func ramp(from: Double, to: Double, hoursAgo: Double, steps: Int) -> [UsageSample] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return UsageSample(
                provider: .claude,
                windowID: "w",
                usedPercent: from + (to - from) * t,
                timestamp: now.addingTimeInterval(-hoursAgo * 3600 + t * hoursAgo * 3600)
            )
        }
    }

    func testFlatUsageIsReliableWithZeroBurn() throws {
        let samples = ramp(from: 40, to: 40, hoursAgo: 2, steps: 4)
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 40, resetsInHours: 3), samples: samples, now: now))
        XCTAssertTrue(forecast.isReliable)
        XCTAssertEqual(forecast.burnRatePerHour, 0, accuracy: 0.01)
        XCTAssertEqual(forecast.projectedEndPercent, 40, accuracy: 0.5)
        XCTAssertFalse(forecast.willCapBeforeReset)
        XCTAssertEqual(WindowStatus.trailing(usedPercent: 40, forecast: forecast), "on pace 40%")
    }

    func testSlowRampProjectsBelowCap() throws {
        let samples = ramp(from: 20, to: 30, hoursAgo: 1, steps: 4)
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 30, resetsInHours: 4), samples: samples, now: now))
        XCTAssertTrue(forecast.isReliable)
        XCTAssertEqual(forecast.burnRatePerHour, 10, accuracy: 0.5)
        XCTAssertEqual(forecast.projectedEndPercent, 70, accuracy: 1)
        XCTAssertFalse(forecast.willCapBeforeReset)
    }

    func testFastRampFlagsCap() throws {
        let samples = ramp(from: 60, to: 95, hoursAgo: 1, steps: 4)
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 95, resetsInHours: 2), samples: samples, now: now))
        XCTAssertTrue(forecast.isReliable)
        XCTAssertTrue(forecast.willCapBeforeReset)
        XCTAssertGreaterThan(forecast.probabilityOfCap, 0.9)
        XCTAssertEqual(WindowStatus.trailing(usedPercent: 95, forecast: forecast)?.contains("until limit"), true)
    }

    func testNoisySpikeIsUnreliable() throws {
        let samples = [
            UsageSample(provider: .claude, windowID: "w", usedPercent: 0, timestamp: now.addingTimeInterval(-3 * 3600)),
            UsageSample(provider: .claude, windowID: "w", usedPercent: 0, timestamp: now.addingTimeInterval(-2 * 3600)),
            UsageSample(provider: .claude, windowID: "w", usedPercent: 80, timestamp: now.addingTimeInterval(-60))
        ]
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 80, resetsInHours: 4), samples: samples, now: now))
        XCTAssertFalse(forecast.isReliable)
        XCTAssertNil(WindowStatus.trailing(usedPercent: 80, forecast: forecast))
    }

    func testSingleSampleIsUnreliableButProjects() throws {
        let sample = UsageSample(provider: .claude, windowID: "w", usedPercent: 20, timestamp: now.addingTimeInterval(-3600))
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 20, resetsInHours: 3), samples: [sample], now: now))
        XCTAssertFalse(forecast.isReliable)
        XCTAssertEqual(forecast.projectedEndPercent, 80, accuracy: 2)
    }

    func testNoSamplesOrNoResetReturnsNil() {
        XCTAssertNil(ForecastEngine.forecast(for: window(used: 20, resetsInHours: 3), samples: [], now: now))
        let bare = UsageWindow(id: "w", kind: .session, label: "w", usedPercent: 20, windowMinutes: nil, resetsAt: nil)
        XCTAssertNil(ForecastEngine.forecast(for: bare, samples: [], now: now))
    }

    func testExpiredWindowDoesNotExplode() throws {
        // Reset already passed: hoursUntilReset clamps to 0, so the projection
        // equals current usage (no wild extrapolation).
        let samples = ramp(from: 10, to: 60, hoursAgo: 2, steps: 4)
        let forecast = try XCTUnwrap(ForecastEngine.forecast(
            for: window(used: 60, resetsInHours: -1),
            samples: samples,
            now: now
        ))
        XCTAssertEqual(forecast.projectedEndPercent, 60, accuracy: 0.5)
    }

    func testDecreasingUsageClampsBurnToZero() throws {
        let samples = ramp(from: 80, to: 40, hoursAgo: 1, steps: 4)
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 40, resetsInHours: 3), samples: samples, now: now))
        XCTAssertEqual(forecast.burnRatePerHour, 0, accuracy: 0.01)
        XCTAssertFalse(forecast.willCapBeforeReset)
    }

    func testSamplesOutsideWindowAreIgnored() throws {
        let stale = UsageSample(provider: .claude, windowID: "w", usedPercent: 0, timestamp: now.addingTimeInterval(-100 * 3600))
        let fresh = ramp(from: 20, to: 30, hoursAgo: 1, steps: 4)
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 30, resetsInHours: 4), samples: [stale] + fresh, now: now))
        XCTAssertEqual(forecast.projectedEndPercent, 70, accuracy: 1)
    }
}
