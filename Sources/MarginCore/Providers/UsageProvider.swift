import Foundation

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func load() async -> ProviderSnapshot?
}
