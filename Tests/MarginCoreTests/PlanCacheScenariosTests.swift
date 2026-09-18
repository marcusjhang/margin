import XCTest
@testable import MarginCore

/// The persisted "last known plan" fallback.
final class PlanCacheScenariosTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "margin.tests.plan.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testStoresAndReturnsPlan() {
        let cache = PlanCache(defaults: freshDefaults())
        XCTAssertEqual(cache.resolve("pro", for: .codex), "pro")
        XCTAssertEqual(cache.resolve(nil, for: .codex), "pro")
    }

    func testUpdatesToNewestPlan() {
        let cache = PlanCache(defaults: freshDefaults())
        XCTAssertEqual(cache.resolve("plus", for: .codex), "plus")
        XCTAssertEqual(cache.resolve("enterprise", for: .codex), "enterprise")
        XCTAssertEqual(cache.resolve(nil, for: .codex), "enterprise")
    }

    func testEmptyStringIsTreatedAsMissing() {
        let cache = PlanCache(defaults: freshDefaults())
        XCTAssertNil(cache.resolve("", for: .codex))
        XCTAssertEqual(cache.resolve("pro", for: .codex), "pro")
        XCTAssertEqual(cache.resolve("", for: .codex), "pro")
    }

    func testProvidersAreIsolated() {
        let cache = PlanCache(defaults: freshDefaults())
        XCTAssertEqual(cache.resolve("pro", for: .codex), "pro")
        XCTAssertNil(cache.resolve(nil, for: .claude))
    }

    func testNoPlanYetReturnsNil() {
        let cache = PlanCache(defaults: freshDefaults())
        XCTAssertNil(cache.resolve(nil, for: .codex))
    }
}
