import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude

    public init() {}

    public func load() async -> ProviderSnapshot? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")

        guard let data = try? Data(contentsOf: configURL),
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
