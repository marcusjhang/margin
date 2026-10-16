import Foundation

public enum ClaudeCredentials {
    static let service = "Claude Code-credentials"

    /// Parsed view of the OAuth blob Claude Code stores in the login keychain.
    struct OAuth {
        let token: String?
        let planLabel: String?
        /// Milliseconds since the epoch, as stored by Claude Code.
        let expiresAt: Double?
    }

    private static let lock = NSLock()
    private static var cached: OAuth?

    /// How the raw blob is obtained. Defaults to the keychain; tests swap in a
    /// counter to prove the blob is read once.
    static var blobReader: () -> Data? = { rawJSON() }

    /// The stored OAuth blob, read at most once per process.
    ///
    /// Reading the keychain means spawning `/usr/bin/security` (plus the
    /// Security framework it loads), so the parsed result is cached for the
    /// process lifetime instead of on every fetch. `forceReload` re-reads after
    /// a failure — e.g. a 401, once the CLI has refreshed the token — so a
    /// rotated token is picked up without restarting the app.
    static func oauth(forceReload: Bool = false) -> OAuth? {
        lock.lock()
        if !forceReload, let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let data = blobReader(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            // Don't cache a miss: the keychain may simply be locked right now.
            return nil
        }

        let value = OAuth(
            token: (oauth["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            planLabel: planLabel(fromOAuth: oauth),
            expiresAt: (oauth["expiresAt"] as? NSNumber)?.doubleValue
        )

        lock.lock()
        cached = value
        lock.unlock()
        return value
    }

    /// Drop the cached blob so the next read hits the keychain again.
    static func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    public static func rawJSON() -> Data? {
        Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        )
    }

    /// Human plan label (e.g. "Max 5×") derived from the stored OAuth blob.
    /// Read-only; never writes back.
    public static func planLabel() -> String? {
        oauth()?.planLabel
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
