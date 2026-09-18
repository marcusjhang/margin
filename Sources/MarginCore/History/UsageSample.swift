import Foundation

public struct UsageSample: Sendable, Equatable {
    public let provider: ProviderID
    public let windowID: String
    public let usedPercent: Double
    public let timestamp: Date

    public init(provider: ProviderID, windowID: String, usedPercent: Double, timestamp: Date) {
        self.provider = provider
        self.windowID = windowID
        self.usedPercent = usedPercent
        self.timestamp = timestamp
    }
}
