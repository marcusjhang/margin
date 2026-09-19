import Foundation

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Loads a snapshot. `forceLive` asks the provider to bypass its live cache
    /// TTL for a user-initiated check.
    func load(forceLive: Bool) async -> ProviderSnapshot?
}
