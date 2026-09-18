import XCTest
@testable import MarginCore

final class ForecastEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double, resetsInHours: Double, minutes: Int) -> UsageWindow {
        UsageWindow(
            id: "w",
            kind: .session,
            label: "window",
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: now.addingTimeInterval(resetsInHours * 3600)
        )
    }

    func testSteadyRampProjectsBelowCap() throws {
        // 1h of history at 10%/h, 4h left, currently 30%.
        let samples = stride(from: 0.0, through: 1.0, by: 0.25).map { hours -> UsageSample in
            UsageSample(provider: .claude, windowID: "w", usedPercent: 20 + 10 * hours, timestamp: now.addingTimeInterval(-3600 + hours * 3600))
        }
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 30, resetsInHours: 4, minutes: 300), samples: samples, now: now))
        XCTAssertEqual(forecast.burnRatePerHour, 10, accuracy: 0.5)
        XCTAssertEqual(forecast.projectedEndPercent, 70, accuracy: 1.0)
        XCTAssertFalse(forecast.willCapBeforeReset)
        XCTAssertLessThan(forecast.probabilityOfCap, 0.05)
        XCTAssertTrue(forecast.isReliable)
    }

    func testFastRampFlagsCap() throws {
        // 1h of history at 35%/h, currently 95%, 2h left.
        let samples = stride(from: 0.0, through: 1.0, by: 0.25).map { hours -> UsageSample in
            UsageSample(provider: .claude, windowID: "w", usedPercent: 60 + 35 * hours, timestamp: now.addingTimeInterval(-3600 + hours * 3600))
        }
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 95, resetsInHours: 2, minutes: 300), samples: samples, now: now))
        XCTAssertTrue(forecast.willCapBeforeReset)
        XCTAssertGreaterThan(forecast.probabilityOfCap, 0.9)
        XCTAssertEqual(try XCTUnwrap(forecast.timeToCap), 3600 * 5 / 35, accuracy: 120)
    }

    func testSingleSampleFallsBackToLowConfidence() throws {
        let sample = UsageSample(provider: .claude, windowID: "w", usedPercent: 20, timestamp: now.addingTimeInterval(-3600))
        let forecast = try XCTUnwrap(ForecastEngine.forecast(for: window(used: 20, resetsInHours: 3, minutes: 300), samples: [sample], now: now))
        XCTAssertFalse(forecast.isReliable)
        XCTAssertEqual(forecast.projectedEndPercent, 80, accuracy: 2.0)
    }

    func testNoSamplesReturnsNil() {
        XCTAssertNil(ForecastEngine.forecast(for: window(used: 20, resetsInHours: 3, minutes: 300), samples: [], now: now))
    }

    func testNoisySpikeIsNotReliable() throws {
        // Flat, then a single spike — a line fits poorly, so it must not be
        // trusted for "until limit" copy.
        let samples = [
            UsageSample(provider: .claude, windowID: "w", usedPercent: 0, timestamp: now.addingTimeInterval(-3 * 3600)),
            UsageSample(provider: .claude, windowID: "w", usedPercent: 0, timestamp: now.addingTimeInterval(-2 * 3600)),
            UsageSample(provider: .claude, windowID: "w", usedPercent: 80, timestamp: now.addingTimeInterval(-60))
        ]
        let forecast = try XCTUnwrap(ForecastEngine.forecast(
            for: window(used: 80, resetsInHours: 4, minutes: 300),
            samples: samples,
            now: now
        ))
        XCTAssertFalse(forecast.isReliable)
        XCTAssertNil(WindowStatus.trailing(usedPercent: 80, forecast: forecast))
    }

    func testMissingResetReturnsNil() {
        let window = UsageWindow(id: "w", kind: .session, label: "window", usedPercent: 20, windowMinutes: nil, resetsAt: nil)
        XCTAssertNil(ForecastEngine.forecast(for: window, samples: [], now: now))
    }
}
