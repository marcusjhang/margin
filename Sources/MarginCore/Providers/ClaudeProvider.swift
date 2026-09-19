import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude

    private let configURL: URL?
    private let live: Bool

    public init(configURL: URL? = nil, live: Bool = true) {
        self.configURL = configURL
        self.live = live
    }

    public func load() async -> ProviderSnapshot? {
        if live, let usage = await ClaudeLiveClient.usage() {
            return ProviderSnapshot(
                provider: .claude,
                planLabel: usage.planLabel,
                windows: usage.windows,
                provenance: .live,
                updatedAt: usage.fetchedAt
            )
        }
        return localSnapshot()
    }

    private func localSnapshot() -> ProviderSnapshot? {
        let url = configURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

        guard let data = try? Data(contentsOf: url),
              let cached = ClaudeUsageParser.parseCachedUsage(data) else {
            return nil
        }

        return ProviderSnapshot(
            provider: .claude,
            planLabel: ClaudeCredentials.planLabel(),
            windows: cached.windows,
            provenance: .cached,
            updatedAt: cached.updatedAt
        )
    }
}
