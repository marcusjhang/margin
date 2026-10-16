import XCTest
@testable import MarginCore

/// The keychain is read by spawning `/usr/bin/security`, so it must happen at
/// most once per process — this pins that behaviour.
final class ClaudeCredentialsCacheTests: XCTestCase {
    private static let blob = Data("""
    { "claudeAiOauth": { "accessToken": "tok", "expiresAt": 9999999999999,
      "rateLimitTier": "default_claude_max_20x" } }
    """.utf8)

    private var reads = 0

    override func setUp() {
        super.setUp()
        reads = 0
        ClaudeCredentials.invalidateCache()
        ClaudeCredentials.blobReader = { [self] in
            reads += 1
            return Self.blob
        }
    }

    override func tearDown() {
        ClaudeCredentials.blobReader = { ClaudeCredentials.rawJSON() }
        ClaudeCredentials.invalidateCache()
        super.tearDown()
    }

    func testBlobIsReadOnceAcrossRepeatedReads() {
        for _ in 0..<5 { _ = ClaudeCredentials.oauth() }
        XCTAssertEqual(reads, 1, "the keychain must be read once, not per fetch")
        XCTAssertEqual(ClaudeCredentials.planLabel(), "Max 20×")
        XCTAssertEqual(reads, 1, "planLabel reuses the cached blob")
    }

    func testForceReloadReReadsAfterInvalidation() {
        _ = ClaudeCredentials.oauth()
        ClaudeCredentials.invalidateCache()
        _ = ClaudeCredentials.oauth()
        XCTAssertEqual(reads, 2)
    }

    func testForceReloadFlagBypassesCache() {
        _ = ClaudeCredentials.oauth()
        _ = ClaudeCredentials.oauth(forceReload: true)
        XCTAssertEqual(reads, 2)
    }

    func testMissIsNotCachedSoLockedKeychainRecovers() {
        ClaudeCredentials.blobReader = { [self] in reads += 1; return nil }
        XCTAssertNil(ClaudeCredentials.oauth())
        ClaudeCredentials.blobReader = { [self] in reads += 1; return Self.blob }
        XCTAssertNotNil(ClaudeCredentials.oauth(), "a later read must retry after a miss")
    }
}
