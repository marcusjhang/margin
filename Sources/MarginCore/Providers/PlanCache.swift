import Foundation

/// Remembers the last plan a provider reported, so a capped session (which
/// carries no plan type) still shows the right plan label.
struct PlanCache {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resolve(_ plan: String?, for provider: ProviderID) -> String? {
        let key = "ai.margin.plan.\(provider.rawValue)"
        if let plan, !plan.isEmpty {
            defaults.set(plan, forKey: key)
            return plan
        }
        return defaults.string(forKey: key)
    }
}
