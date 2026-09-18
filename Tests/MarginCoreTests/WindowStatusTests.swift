import XCTest
@testable import MarginCore

final class WindowStatusTests: XCTestCase {
    private func forecast(
        reliable: Bool = true,
        willCap: Bool,
        timeToCap: TimeInterval?,
        projected: Double
    ) -> WindowForecast {
        WindowForecast(
            burnRatePerHour: 1,
            timeToCap: timeToCap,
            projectedEndPercent: projected,
            probabilityOfCap: willCap ? 0.9 : 0.1,
            sampleCount: reliable ? 5 : 2,
            isReliable: reliable
        )
    }

    func testCappedIsLimitReachedEvenWithoutForecast() {
        XCTAssertEqual(WindowStatus.trailing(usedPercent: 100, forecast: nil), "limit reached")
    }

    func testReliableCapForecastReadsUntilLimit() {
        let value = WindowStatus.trailing(
            usedPercent: 43,
            forecast: forecast(willCap: true, timeToCap: 3 * 3600, projected: 120)
        )
        XCTAssertEqual(value, "~3h until limit")
    }

    func testReliableOnPace() {
        let value = WindowStatus.trailing(
            usedPercent: 43,
            forecast: forecast(willCap: false, timeToCap: nil, projected: 60)
        )
        XCTAssertEqual(value, "on pace 60%")
    }

    func testUnreliableForecastSaysNothing() {
        let value = WindowStatus.trailing(
            usedPercent: 43,
            forecast: forecast(reliable: false, willCap: true, timeToCap: 3600, projected: 150)
        )
        XCTAssertNil(value)
    }

    func testSubMinuteCapIsLimitReachedNotNow() {
        let value = WindowStatus.trailing(
            usedPercent: 99,
            forecast: forecast(willCap: true, timeToCap: 10, projected: 120)
        )
        XCTAssertEqual(value, "limit reached")
    }

    func testNeverSaysNowUntilLimit() {
        let cases: [(Double, TimeInterval?)] = [(0, 0), (50, 0), (99, 0), (99.4, 1), (100, 0), (100, nil)]
        for (percent, timeToCap) in cases {
            let value = WindowStatus.trailing(
                usedPercent: percent,
                forecast: forecast(willCap: true, timeToCap: timeToCap, projected: 130)
            )
            XCTAssertNotEqual(value, "now until limit")
            XCTAssertEqual(value, "limit reached")
        }
    }
}
