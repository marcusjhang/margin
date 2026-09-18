import Foundation

public enum ClaudeCredentials {
    static let service = "Claude Code-credentials"

    public static func rawJSON() -> Data? {
        Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        )
    }

    /// Derives a human plan label (e.g. "Max 5×") from the stored OAuth blob.
    /// Read-only; never writes back.
    public static func planLabel() -> String? {
        guard let data = rawJSON(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return planLabel(fromOAuth: oauth)
    }

    static func planLabel(fromOAuth oauth: [String: Any]) -> String? {
        let tier = (oauth["rateLimitTier"] as? String)?.lowercased() ?? ""
        let subscription = (oauth["subscriptionType"] as? String)?.lowercased() ?? ""

        if tier.contains("20x") { return "Max 20×" }
        if tier.contains("5x") { return "Max 5×" }
        if subscription == "max" { return "Max" }
        if subscription == "pro" { return "Pro" }
        if subscription.isEmpty { return nil }
        return subscription.capitalized
    }
}
