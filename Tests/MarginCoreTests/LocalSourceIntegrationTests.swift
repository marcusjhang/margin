import XCTest
@testable import MarginCore

/// Exercises the real local sources on the developer's machine.
/// Skips (rather than fails) when a source is unavailable, so CI stays green.
final class LocalSourceIntegrationTests: XCTestCase {
    func testReadsRealClaudeCache() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("~/.claude.json not present")
        }
        guard let usage = ClaudeUsageParser.parseCachedUsage(data) else {
            throw XCTSkip("no cachedUsageUtilization present")
        }
        print("Claude windows:", usage.windows.map { "\($0.label)=\($0.usedPercent)%" })
        XCTAssertFalse(usage.windows.isEmpty)
    }

    func testReadsRealCodexRollouts() throws {
        guard let snapshot = CodexRolloutScanner.latestSnapshot() else {
            throw XCTSkip("no codex rollouts with rate limits")
        }
        print("Codex limitReached:", snapshot.limitReached,
              "plan:", snapshot.planType ?? "?",
              "windows:", snapshot.windows.map { "\($0.label)=\($0.usedPercent)%" },
              "reset:", snapshot.resetHint.map(String.init(describing:)) ?? "-")
        // A capped session legitimately has no window data.
        XCTAssertFalse(snapshot.windows.isEmpty && !snapshot.limitReached)
    }

    func testReadsClaudePlanFromKeychain() throws {
        guard let label = ClaudeCredentials.planLabel() else {
            throw XCTSkip("keychain credential not available")
        }
        print("Claude plan:", label)
        XCTAssertFalse(label.isEmpty)
    }

    func testBackfillScannerFindsCodexSamples() throws {
        let since = Date().addingTimeInterval(-7 * 86_400)
        let samples = CodexRolloutScanner.samples(since: since)
        print("Codex backfill samples (7d):", samples.count)
        guard !samples.isEmpty else { throw XCTSkip("no codex rollouts in range") }
        XCTAssertGreaterThan(samples.count, 0)
    }

    func testCodexProviderResolvesPlanAndWindows() async throws {
        guard let snapshot = await CodexProvider(live: false).load(forceLive: false) else {
            throw XCTSkip("no codex data")
        }
        print("Codex provider plan:", snapshot.planLabel ?? "-",
              "windows:", snapshot.windows.map { "\($0.label)=\($0.usedPercent)%" })
        XCTAssertFalse(snapshot.windows.isEmpty)
    }

    /// The provider must render exactly what the raw source says.
    func testClaudeProviderMatchesRawSource() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let raw = ClaudeUsageParser.parseCachedUsage(data) else {
            throw XCTSkip("no claude cache")
        }
        let loaded = await ClaudeProvider(live: false).load(forceLive: false)
        let snapshot = try XCTUnwrap(loaded)

        XCTAssertEqual(snapshot.windows.map(\.id), raw.windows.map(\.id))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), raw.windows.map(\.usedPercent))
        XCTAssertTrue(snapshot.windows.allSatisfy { !$0.label.isEmpty })
        XCTAssertTrue(snapshot.windows.allSatisfy { (-5...200).contains($0.usedPercent) })
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, snapshot.windows.count)
        print("Claude provider:", snapshot.windows.map { "\($0.label)=\($0.usedPercent)%" })
    }
}
