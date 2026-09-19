import XCTest
@testable import MarginCore

/// Exercises the live clients' network path (fetch, parse, cache, failure
/// fallback, force floor) with a stubbed URL protocol — no real network.
final class LiveClientBehaviorTests: XCTestCase {
    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var requestCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            MockURLProtocol.requestCount += 1
            let (status, data) = MockURLProtocol.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var session: URLSession!
    private var cache: LiveUsageCache!

    private let claudePayload = Data("""
    { "limits": [ { "kind": "session", "percent": 20, "severity": "normal", "resets_at": null },
                  { "kind": "weekly_all", "percent": 84, "severity": "warning", "resets_at": null } ] }
    """.utf8)

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        cache = LiveUsageCache(ttl: 120, forceFloor: 20)
        MockURLProtocol.requestCount = 0
        MockURLProtocol.handler = nil
    }

    private var hasClaudeToken: Bool { ClaudeCredentials.rawJSON() != nil }

    func testSuccessParsesAndCaches() async throws {
        try XCTSkipUnless(hasClaudeToken, "no Claude token on this machine")
        MockURLProtocol.handler = { _ in (200, self.claudePayload) }

        let usage = await ClaudeLiveClient.usage(cache: cache, session: session)
        let live = try XCTUnwrap(usage)
        XCTAssertEqual(live.windows.map(\.usedPercent), [20, 84])
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // Within TTL, no second request, and the cached value is returned.
        let again = await ClaudeLiveClient.usage(cache: cache, session: session)
        XCTAssertEqual(again?.windows.map(\.usedPercent), [20, 84])
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testFailureFallsBackToLastGoodLiveValue() async throws {
        try XCTSkipUnless(hasClaudeToken, "no Claude token on this machine")
        cache.store(.claude, usage: LiveUsage(
            windows: [UsageWindow(id: "weekly", kind: .weekly, label: "weekly", usedPercent: 84, windowMinutes: 10080, resetsAt: nil)],
            planLabel: "Max 20×",
            fetchedAt: Date(timeIntervalSinceNow: -600)
        ))
        MockURLProtocol.handler = { _ in (500, Data()) }

        let usage = await ClaudeLiveClient.usage(force: true, cache: cache, session: session)
        XCTAssertEqual(usage?.windows.first?.usedPercent, 84, "stale live value kept on failure")
    }

    func testFailureWithNoCacheReturnsNil() async throws {
        try XCTSkipUnless(hasClaudeToken, "no Claude token on this machine")
        MockURLProtocol.handler = { _ in (500, Data()) }
        let usage = await ClaudeLiveClient.usage(force: true, cache: cache, session: session)
        XCTAssertNil(usage)
    }

    func testForceFloorSuppressesRepeatedForcedAttempts() async throws {
        try XCTSkipUnless(hasClaudeToken, "no Claude token on this machine")
        MockURLProtocol.handler = { _ in (200, self.claudePayload) }

        _ = await ClaudeLiveClient.usage(force: true, cache: cache, session: session)
        let firstCount = MockURLProtocol.requestCount
        _ = await ClaudeLiveClient.usage(force: true, cache: cache, session: session)
        XCTAssertEqual(MockURLProtocol.requestCount, firstCount, "second forced call within forceFloor must not hit the network")
    }

    func testCodexSuccessParsesWeeklyCap() async throws {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: authURL.path), "no Codex token on this machine")
        let payload = Data("""
        { "plan_type": "pro", "rate_limit": { "allowed": false, "limit_reached": true,
          "primary_window": { "used_percent": 100, "limit_window_seconds": 604800, "reset_at": 1790002772 } } }
        """.utf8)
        MockURLProtocol.handler = { _ in (200, payload) }

        let usage = await CodexLiveClient.usage(cache: cache, session: session)
        XCTAssertEqual(usage?.planLabel, "Pro")
        XCTAssertEqual(usage?.windows.first?.label, "weekly")
        XCTAssertEqual(usage?.windows.first?.usedPercent, 100)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testCodexNormalWindowsFetchAndCache() async throws {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: authURL.path), "no Codex token on this machine")
        let payload = Data("""
        { "plan_type": "plus", "rate_limit": { "allowed": true, "limit_reached": false,
          "primary_window": { "used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1790002772 },
          "secondary_window": { "used_percent": 55, "limit_window_seconds": 604800, "reset_at": 1790002772 } } }
        """.utf8)
        MockURLProtocol.handler = { _ in (200, payload) }

        let usage = await CodexLiveClient.usage(cache: cache, session: session)
        XCTAssertEqual(usage?.planLabel, "Plus")
        XCTAssertEqual(usage?.windows.map(\.label), ["5-hour session", "weekly"])
        XCTAssertEqual(usage?.windows.map(\.usedPercent), [42, 55])

        // Cached: a second call within TTL makes no new request.
        _ = await CodexLiveClient.usage(cache: cache, session: session)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testCodexFailureKeepsLastGood() async throws {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: authURL.path), "no Codex token on this machine")
        cache.store(.codex, usage: LiveUsage(
            windows: [UsageWindow(id: "primary", kind: .weekly, label: "weekly", usedPercent: 77, windowMinutes: 10080, resetsAt: nil)],
            planLabel: "Pro",
            fetchedAt: Date(timeIntervalSinceNow: -600)
        ))
        MockURLProtocol.handler = { _ in (500, Data()) }

        let usage = await CodexLiveClient.usage(force: true, cache: cache, session: session)
        XCTAssertEqual(usage?.windows.first?.usedPercent, 77, "stale live value kept on failure")
    }
}
