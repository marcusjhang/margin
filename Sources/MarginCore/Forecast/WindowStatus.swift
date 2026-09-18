import Foundation

/// The short right-hand status line under a window card.
///
/// Kept as pure logic (not view code) so the copy is unit-tested and can never
/// regress into nonsense like "now until limit".
public enum WindowStatus {
    public static func trailing(usedPercent: Double, forecast: WindowForecast?) -> String? {
        if usedPercent >= 99.5 { return "limit reached" }

        guard let forecast, forecast.isReliable else { return nil }

        if forecast.willCapBeforeReset {
            if let timeToCap = forecast.timeToCap, timeToCap >= 30 {
                return "\(UsageFormat.approximateDuration(timeToCap)) until limit"
            }
            return "limit reached"
        }

        return "on pace \(UsageFormat.percent(forecast.projectedEndPercent))"
    }
}
