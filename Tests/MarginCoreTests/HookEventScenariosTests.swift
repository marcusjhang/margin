import XCTest
@testable import MarginCore

/// Hook event source coverage: parsing, deterministic ids, and opt-in behaviour.
final class HookEventScenariosTests: XCTestCase {
    private func line(
        kind: String,
        provider: String = "claude",
        sessionID: String = "s1",
        target: String? = "/a",
        timestamp: Double = 1_800_000_000,
        ordinal: Int = 5
    ) -> String {
        var root: [String: Any] = [
            "kind": kind,
            "provider": provider,
            "sessionID": sessionID,
            "timestamp": timestamp,
            "ordinal": ordinal
        ]
        if let target { root["target"] = target }
        return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
    }

    func testParsesValidHookLine() {
        let event = HookEventSource.parse(line(kind: "command", target: "make build"), lineIndex: 0)
        XCTAssertEqual(event?.kind, .command)
        XCTAssertEqual(event?.target, "make build")
        XCTAssertEqual(event?.sessionID, "s1")
        XCTAssertEqual(event?.provider, .claude)
    }

    func testDeterministicIdAcrossParses() {
        let a = HookEventSource.parse(line(kind: "fileRead", target: "/x"), lineIndex: 0)
        let b = HookEventSource.parse(line(kind: "fileRead", target: "/x"), lineIndex: 0)
        XCTAssertEqual(a?.id, b?.id)
    }

    func testMalformedLinesAreSkipped() {
        XCTAssertNil(HookEventSource.parse("", lineIndex: 0))
        XCTAssertNil(HookEventSource.parse("{bad", lineIndex: 0))
        XCTAssertNil(HookEventSource.parse(#"{"kind":"bogus","provider":"claude","sessionID":"s"}"#, lineIndex: 0))
        XCTAssertNil(HookEventSource.parse(#"{"kind":"command","provider":"claude"}"#, lineIndex: 0))
    }

    func testPollReadsFileAndAdvancesCursor() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("hooks.jsonl")
        try [line(kind: "command", target: "ls", timestamp: 1_800_000_000),
             line(kind: "fileWrite", target: "/a", timestamp: 1_800_000_100),
             "garbage"].joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let source = HookEventSource(url: file)
        let first = await source.poll(since: .distantPast)
        XCTAssertEqual(first.events.count, 2)

        let second = await source.poll(since: first.cursor)
        XCTAssertTrue(second.events.isEmpty)
    }
}
