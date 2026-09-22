import Foundation

/// Fetches Claude subscription usage from Anthropic's OAuth usage endpoint
/// using the token Claude Code already stored in the login Keychain.
///
/// Read-only — never refreshes or writes the token. On any failure it returns
/// the last known live value if there is one, otherwise nil so the caller can
/// fall back to local sources.
enum ClaudeLiveClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "claude-code/2.1.276"

    static func usage(
        force: Bool = false,
        cache: LiveUsageCache = .shared,
        session: URLSession = LiveSession.shared
    ) async -> LiveUsage? {
        guard cache.shouldAttempt(.claude, force: force) else {
            return cache.usage(.claude, allowStale: true)
        }
        cache.noteAttempt(.claude)

        if let token = accessToken(),
           let data = await fetch(token: token, session: session),
           let parsed = parse(data: data, planLabel: ClaudeCredentials.planLabel()) {
            cache.store(.claude, usage: parsed)
            return parsed
        }

        // Keep the last good value rather than dropping to older local data.
        return cache.usage(.claude, allowStale: true)
    }

    /// Pure parser (used by tests): the live payload shares the `limits` /
    /// `five_hour` / `seven_day` shape with the local cache.
    static func parse(data: Data, planLabel: String?, now: Date = Date()) -> LiveUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = ClaudeUsageParser.windows(from: root)
        guard !windows.isEmpty else { return nil }
        return LiveUsage(
            windows: windows,
            planLabel: planLabel,
            credits: ClaudeUsageParser.credits(from: root),
            fetchedAt: now
        )
    }

    private static func fetch(token: String, session: URLSession) async -> Data? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }
        return data
    }

    private static func accessToken() -> String? {
        guard let data = ClaudeCredentials.rawJSON(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        // Skip a token we know is expired; the CLI will refresh it next run.
        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expiresAt > 0,
           Date(timeIntervalSince1970: expiresAt / 1000) <= Date() {
            return nil
        }
        return token
    }
}
