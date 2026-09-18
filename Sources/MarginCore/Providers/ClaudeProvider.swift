import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude

    private let configURL: URL?

    public init(configURL: URL? = nil) {
        self.configURL = configURL
    }

    public func load() async -> ProviderSnapshot? {
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
