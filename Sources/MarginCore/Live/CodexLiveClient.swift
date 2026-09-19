import Foundation

/// Fetches Codex subscription usage from OpenAI's ChatGPT backend using the
/// token in `~/.codex/auth.json`.
///
/// Read-only — never refreshes or writes the token. On any failure it returns
/// the last known live value if there is one, otherwise nil so the caller can
/// fall back to local rollout logs.
enum CodexLiveClient {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func usage(
        force: Bool = false,
        cache: LiveUsageCache = .shared,
        session: URLSession = LiveSession.shared
    ) async -> LiveUsage? {
        guard cache.shouldAttempt(.codex, force: force) else {
            return cache.usage(.codex, allowStale: true)
        }
        cache.noteAttempt(.codex)

        if let auth = auth(),
           let data = await fetch(auth: auth, session: session),
           let parsed = parse(data: data) {
            cache.store(.codex, usage: parsed)
            return parsed
        }

        return cache.usage(.codex, allowStale: true)
    }

    /// Pure parser (used by tests).
    static func parse(data: Data, now: Date = Date()) -> LiveUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plan = (root["plan_type"] as? String)?.capitalized
        let rateLimit = root["rate_limit"] as? [String: Any]
        var windows = windows(from: rateLimit)

        // A reached limit with no window data still means "capped". Infer the
        // window from how far out it resets, like the local path.
        if windows.isEmpty,
           (rateLimit?["limit_reached"] as? Bool) == true || (rateLimit?["allowed"] as? Bool) == false,
           let reset = (rateLimit?["primary_window"] as? [String: Any])?["reset_at"] as? NSNumber {
            let resetsAt = UsageFormat.date(fromEpoch: reset)
            let minutes = UsageFormat.windowMinutes(forReset: resetsAt, now: now)
            windows = [UsageWindow(
                id: "primary",
                kind: UsageFormat.windowKind(minutes: minutes),
                label: UsageFormat.windowLabel(minutes: minutes),
                usedPercent: 100,
                windowMinutes: minutes,
                resetsAt: resetsAt,
                reportedSeverity: .critical
            )]
        }

        guard !windows.isEmpty else { return nil }
        return LiveUsage(windows: windows, planLabel: plan, fetchedAt: now)
    }

    private static func windows(from rateLimit: [String: Any]?) -> [UsageWindow] {
        guard let rateLimit else { return [] }
        var result: [UsageWindow] = []
        if let window = window(id: "primary", from: rateLimit["primary_window"]) { result.append(window) }
        if let window = window(id: "secondary", from: rateLimit["secondary_window"]) { result.append(window) }
        return result
    }

    private static func window(id: String, from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let used = (dict["used_percent"] as? NSNumber)?.doubleValue,
              used.isFinite else { return nil }
        let seconds = (dict["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
        let minutes = seconds > 0 ? seconds / 60 : nil
        let resetsAt = (dict["reset_at"] as? NSNumber).map { UsageFormat.date(fromEpoch: $0) }
        return UsageWindow(
            id: id,
            kind: minutes.map(UsageFormat.windowKind) ?? .weekly,
            label: UsageFormat.windowLabel(minutes: minutes),
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }

    private static func fetch(auth: (token: String, accountID: String), session: URLSession) async -> Data? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Margin", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }
        return data
    }

    private static func auth() -> (token: String, accountID: String)? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            return nil
        }
        return (token, tokens["account_id"] as? String ?? "")
    }
}
