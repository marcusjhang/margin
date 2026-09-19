import XCTest
@testable import MarginCore

/// On-demand EVAL against the real Claude and Codex endpoints.
///
/// Skipped by default so CI and normal runs stay hermetic. Run it explicitly:
///
///     TEST_RUNNER_MARGIN_LIVE=1 xcodebuild -project Margin.xcodeproj \
///       -scheme Margin -derivedDataPath .build test \
///       -only-testing:MarginCoreTests/LiveEndpointEvalTests
///
/// It uses the tokens already on this Mac (Keychain / ~/.codex/auth.json) and
/// prints the parsed windows so you can eyeball them against the web page.
final class LiveEndpointEvalTests: XCTestCase {
    private func enabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARGIN_LIVE"] == "1",
            "set MARGIN_LIVE=1 to run live endpoint evals"
        )
    }

    func testClaudeEndpointReturnsUsableWindows() async throws {
        try enabled()
        let cache = LiveUsageCache() // fresh, bypasses any TTL
        let usage = await ClaudeLiveClient.usage(force: true, cache: cache, session: LiveSession.shared)

        let live = try XCTUnwrap(usage, "Claude endpoint returned nothing (missing/expired token?)")
        print("CLAUDE LIVE:", live.windows.map { "\($0.label)=\($0.usedPercent)%" },
              "| plan:", live.planLabel ?? "-")
        XCTAssertFalse(live.windows.isEmpty)
        XCTAssertTrue(live.windows.allSatisfy { $0.usedPercent.isFinite })
        XCTAssertTrue(live.windows.contains { $0.kind == .session || $0.kind == .weekly })
    }

    func testCodexEndpointReturnsUsableWindows() async throws {
        try enabled()
        let cache = LiveUsageCache()
        let usage = await CodexLiveClient.usage(force: true, cache: cache, session: LiveSession.shared)

        let live = try XCTUnwrap(usage, "Codex endpoint returned nothing (missing/expired token?)")
        print("CODEX LIVE:", live.windows.map { "\($0.label)=\($0.usedPercent)%" },
              "| plan:", live.planLabel ?? "-")
        XCTAssertFalse(live.windows.isEmpty)
        XCTAssertTrue(live.windows.allSatisfy { $0.usedPercent.isFinite })
        XCTAssertNotNil(live.planLabel, "Codex should report a plan")
    }

    /// Prints both providers side by side — the cheapest "does it work" check.
    func testBothProvidersAgreeWithExpectations() async throws {
        try enabled()
        let claude = await ClaudeLiveClient.usage(force: true, cache: LiveUsageCache(), session: LiveSession.shared)
        let codex = await CodexLiveClient.usage(force: true, cache: LiveUsageCache(), session: LiveSession.shared)
        print("""
        ── LIVE EVAL ──
        Claude: \(claude.map { $0.windows.map { "\($0.label)=\($0.usedPercent)%" }.joined(separator: ", ") } ?? "unavailable")
        Codex : \(codex.map { $0.windows.map { "\($0.label)=\($0.usedPercent)%" }.joined(separator: ", ") } ?? "unavailable")
        """)
        XCTAssertTrue(claude != nil || codex != nil, "at least one provider must be reachable")
    }
}
