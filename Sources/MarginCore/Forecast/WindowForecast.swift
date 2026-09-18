import Foundation

/// A projection for one usage window: how fast it is burning, where it lands
/// by reset, and how likely it is to hit the cap first.
public struct WindowForecast: Sendable, Equatable {
    public let burnRatePerHour: Double
    public let timeToCap: TimeInterval?
    public let projectedEndPercent: Double
    public let probabilityOfCap: Double
    public let sampleCount: Int
    public let isReliable: Bool

    public init(
        burnRatePerHour: Double,
        timeToCap: TimeInterval?,
        projectedEndPercent: Double,
        probabilityOfCap: Double,
        sampleCount: Int,
        isReliable: Bool
    ) {
        self.burnRatePerHour = burnRatePerHour
        self.timeToCap = timeToCap
        self.projectedEndPercent = projectedEndPercent
        self.probabilityOfCap = probabilityOfCap
        self.sampleCount = sampleCount
        self.isReliable = isReliable
    }

    public var willCapBeforeReset: Bool { projectedEndPercent >= 100 }

    public static func key(provider: ProviderID, windowID: String) -> String {
        "\(provider.rawValue):\(windowID)"
    }
}

/// Fits a burn rate from recorded samples and projects it to the window reset.
///
/// With two or more samples it uses least squares and reports a confidence from
/// the residual spread. With a single usable sample it falls back to the average
/// rate since the window opened, flagged as low confidence.
public enum ForecastEngine {
    public static func forecast(
        for window: UsageWindow,
        samples: [UsageSample],
        now: Date = Date()
    ) -> WindowForecast? {
        guard let resetsAt = window.resetsAt,
              let minutes = window.windowMinutes,
              minutes > 0 else { return nil }

        let duration = Double(minutes) * 60
        let start = resetsAt.addingTimeInterval(-duration)
        let inWindow = samples
            .filter { $0.timestamp >= start && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }

        let hoursUntilReset = max(0, resetsAt.timeIntervalSince(now) / 3600)

        let points = inWindow.map {
            (x: $0.timestamp.timeIntervalSince(start) / 3600, y: $0.usedPercent)
        }

        let burn: Double
        let spread: Double
        let count: Int
        let reliable: Bool

        if points.count >= 2, let fit = linearFit(points) {
            burn = max(0, fit.slope)
            spread = max(fit.residualStd, 1.0)
            count = points.count
            // Reliability requires both enough history AND a fit that actually
            // tracks the points — otherwise a single spike reads as a trend.
            let span = points[points.count - 1].x - points[0].x
            let rise = burn * span
            reliable = points.count >= 3
                && span >= 0.25
                && fit.residualStd <= max(1.5, 0.35 * rise)
        } else if let last = points.last, last.x >= 0.1 {
            burn = max(0, last.y / last.x)
            spread = max(last.y * 0.5, 2.0)
            count = points.count
            reliable = false
        } else {
            return nil
        }

        let projectedEnd = window.usedPercent + burn * hoursUntilReset
        let probability = probabilityAtLeast(100, mean: projectedEnd, standardDeviation: spread)

        let timeToCap: TimeInterval? = burn > 0.05
            ? max(0, (100 - window.usedPercent) / burn) * 3600
            : nil

        return WindowForecast(
            burnRatePerHour: burn,
            timeToCap: timeToCap,
            projectedEndPercent: projectedEnd,
            probabilityOfCap: probability,
            sampleCount: count,
            isReliable: reliable
        )
    }

    struct Fit {
        let slope: Double
        let intercept: Double
        let residualStd: Double
    }

    static func linearFit(_ points: [(x: Double, y: Double)]) -> Fit? {
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count

        var sxx = 0.0
        var sxy = 0.0
        for point in points {
            sxx += (point.x - meanX) * (point.x - meanX)
            sxy += (point.x - meanX) * (point.y - meanY)
        }
        guard sxx > 1e-9 else { return nil }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX

        var sumSquares = 0.0
        for point in points {
            let predicted = intercept + slope * point.x
            sumSquares += (point.y - predicted) * (point.y - predicted)
        }
        let residualStd = sqrt(sumSquares / max(1.0, count - 2))
        return Fit(slope: slope, intercept: intercept, residualStd: residualStd)
    }

    static func probabilityAtLeast(_ threshold: Double, mean: Double, standardDeviation: Double) -> Double {
        let sigma = max(standardDeviation, 0.001)
        let z = (threshold - mean) / sigma
        return min(max(0.5 * (1 - erf(z / 1.4142135623730951)), 0), 1)
    }
}
