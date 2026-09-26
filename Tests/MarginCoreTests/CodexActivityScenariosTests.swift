import XCTest
@testable import MarginCore

/// Synthetic-fixture coverage of Codex rollout → activity mapping.
final class CodexActivityScenariosTests: XCTestCase {
    private var root: URL!
    private var dayDir: URL { root.appendingPathComponent("2026/09/20", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026/09/20"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let meta = #"{"ordinal":0,"timestamp":"2026-09-20T10:00:00Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/tmp/work","git":{"branch":"main"}}}"#

    private func customCall(_ ordinal: Int, name: String = "exec", input: String) -> String {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [input], options: []), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"ordinal":\#(ordinal),"timestamp":"2026-09-20T10:00:0\#(ordinal % 10).000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"\#(name)","call_id":"c\#(ordinal)","input":\#(encoded)}}"#
    }

    private func functionCall(_ ordinal: Int, name: String, arguments: [String: Any]) -> String {
        let args = String(data: try! JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [args]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"ordinal":\#(ordinal),"timestamp":"2026-09-20T10:00:00Z","type":"response_item","payload":{"type":"function_call","name":"\#(name)","call_id":"f\#(ordinal)","arguments":\#(encoded)}}"#
    }

    private func write(_ lines: [String], name: String = "rollout-2026-09-20T10-00-00-sess-1.jsonl", mtime: Date = Date()) throws {
        let url = dayDir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private var since: Date { Date().addingTimeInterval(-10) }

    func testCustomExecCallExtractsCmd() async throws {
        try write([meta, customCall(1, input: #"const r = await tools.exec_command({"cmd":"git status --short","yield_time_ms":1000}); text(r);"#)])
        let events = await CodexActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .command)
        XCTAssertEqual(event.target, "git status --short")
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.cwd, "/tmp/work")
        XCTAssertEqual(event.gitBranch, "main")
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.id, ActivityEvent.makeID(provider: .codex, sessionID: "sess-1", ordinal: 1, kind: .command, target: "git status --short"))
    }

    func testFunctionCallCommandIsTruncated() async throws {
        let long = String(repeating: "x", count: 1000)
        try write([
            meta,
            functionCall(1, name: "exec_command", arguments: ["cmd": "ls -la"]),
            functionCall(2, name: "shell", arguments: ["command": ["bash", "-lc", "echo \(long)"]]),
        ])
        let events = await CodexActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.map(\.kind), [.command, .command])
        XCTAssertEqual(events[0].target, "ls -la")
        let truncated = try XCTUnwrap(events[1].target)
        XCTAssertEqual(truncated.count, 300)
        XCTAssertTrue(truncated.hasPrefix("bash -lc echo xxx"))
    }

    func testApplyPatchMapsToFileWrite() async throws {
        let patch = "*** Begin Patch\n*** Update File: Sources/a.swift\n@@\n-a\n+b\n*** End Patch"
        try write([
            meta,
            customCall(1, name: "apply_patch", input: patch),
            functionCall(2, name: "apply_patch", arguments: ["input": patch.replacingOccurrences(of: "a.swift", with: "b.swift")]),
        ])
        let events = await CodexActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.map(\.kind), [.fileWrite, .fileWrite])
        XCTAssertEqual(events.map(\.target), ["Sources/a.swift", "Sources/b.swift"])
    }

    func testRepollingSameSinceYieldsSameIDsWithoutDuplicates() async throws {
        try write([
            meta,
            customCall(1, input: #"tools.exec_command({"cmd":"ls"})"#),
            customCall(2, input: #"tools.exec_command({"cmd":"ls"})"#),
            functionCall(3, name: "exec_command", arguments: ["cmd": "pwd"]),
        ])
        let source = CodexActivitySource(root: root)
        let fixed = since
        let first = await source.poll(since: fixed).events.map(\.id)
        let second = await source.poll(since: fixed).events.map(\.id)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(Set(first).count, first.count)
        XCTAssertEqual(first, second)
    }

    func testMalformedLineIsSkipped() async throws {
        try write([
            meta,
            customCall(1, input: #"tools.exec_command({"cmd":"ls"})"#),
            #"{"ordinal":2,"type":"response_item","payload":{"type":"custom_tool_call""#,
            functionCall(3, name: "exec_command", arguments: ["cmd": "pwd"]),
        ])
        let events = await CodexActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.map(\.target), ["ls", "pwd"])
    }

    func testOldFilesAreSkippedByMtime() async throws {
        let now = Date()
        try write([meta, functionCall(1, name: "exec_command", arguments: ["cmd": "old"])],
                  name: "rollout-old.jsonl", mtime: now.addingTimeInterval(-3600))
        try write([meta, functionCall(1, name: "exec_command", arguments: ["cmd": "new"])],
                  name: "rollout-new.jsonl", mtime: now)
        let events = await CodexActivitySource(root: root).poll(since: now.addingTimeInterval(-120)).events
        XCTAssertEqual(events.map(\.target), ["new"])
    }

    func testDefaultInitBuilds() {
        XCTAssertFalse(CodexActivitySource().id.isEmpty)
    }
}
