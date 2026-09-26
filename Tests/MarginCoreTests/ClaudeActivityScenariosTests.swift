import XCTest
@testable import MarginCore

/// Synthetic-fixture coverage of Claude transcript → activity mapping.
final class ClaudeActivityScenariosTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("proj"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func toolUse(_ name: String, _ input: String, session: String = "s1", uuid: String = "u1") -> String {
        #"{"type":"assistant","sessionId":"\#(session)","cwd":"/tmp/work","gitBranch":"feat/x","timestamp":"2026-09-20T10:00:00.123Z","parentUuid":"p0","isSidechain":false,"uuid":"\#(uuid)","message":{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func prompt(session: String = "s1") -> String {
        #"{"type":"user","sessionId":"\#(session)","cwd":"/tmp/work","timestamp":"2026-09-20T09:59:00Z","message":{"role":"user","content":"please fix it"}}"#
    }

    @discardableResult
    private func write(_ lines: [String], name: String = "s1.jsonl", mtime: Date = Date()) throws -> URL {
        let url = root.appendingPathComponent("proj").appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private var since: Date { Date().addingTimeInterval(-10) }

    func testReadMapsToFileReadWithSessionContext() async throws {
        try write([toolUse("Read", #"{"file_path":"/tmp/work/a.swift"}"#)])
        let events = await ClaudeActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .fileRead)
        XCTAssertEqual(event.target, "/tmp/work/a.swift")
        XCTAssertEqual(event.sessionID, "s1")
        XCTAssertEqual(event.cwd, "/tmp/work")
        XCTAssertEqual(event.gitBranch, "feat/x")
        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.metadata["parentUuid"], "p0")
        XCTAssertEqual(event.metadata["isSidechain"], "false")
    }

    func testWriteToolsMapToFileWrite() async throws {
        try write([
            toolUse("Edit", #"{"file_path":"/w/e.swift","old_string":"a","new_string":"b"}"#),
            toolUse("Write", #"{"file_path":"/w/w.swift","content":"x"}"#),
            toolUse("NotebookEdit", #"{"file_path":"/w/n.ipynb"}"#),
        ])
        let events = await ClaudeActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.map(\.kind), [.fileWrite, .fileWrite, .fileWrite])
        XCTAssertEqual(events.map(\.target), ["/w/e.swift", "/w/w.swift", "/w/n.ipynb"])
    }

    func testBashAndUnknownToolsMapToCommand() async throws {
        try write([
            toolUse("Bash", #"{"command":"swift test"}"#),
            toolUse("Grep", #"{"pattern":"foo"}"#),
        ])
        let events = await ClaudeActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .command)
        XCTAssertEqual(events[0].target, "swift test")
        XCTAssertEqual(events[1].kind, .command)
        XCTAssertEqual(events[1].tool, "Grep")
    }

    func testUserPromptMapsToPrompt() async throws {
        let toolResult = #"{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#
        try write([prompt(), toolResult])
        let events = await ClaudeActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.map(\.kind), [.prompt])
        XCTAssertEqual(events.first?.sessionID, "s1")
    }

    func testRepollingSameSinceYieldsSameIDsWithoutDuplicates() async throws {
        try write([prompt(), toolUse("Read", #"{"file_path":"/a"}"#), toolUse("Read", #"{"file_path":"/a"}"#, uuid: "u2")])
        let source = ClaudeActivitySource(root: root)
        let fixed = since
        let first = await source.poll(since: fixed).events.map(\.id)
        let second = await source.poll(since: fixed).events.map(\.id)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(Set(first).count, first.count)
        XCTAssertEqual(first, second)
    }

    func testMalformedLineIsSkipped() async throws {
        try write([
            toolUse("Read", #"{"file_path":"/a"}"#),
            #"{"type":"assistant","message":{"content":[{"type":"tool_use""#,
            "not json at all",
            toolUse("Bash", #"{"command":"ls"}"#),
        ])
        let events = await ClaudeActivitySource(root: root).poll(since: since).events
        XCTAssertEqual(events.map(\.kind), [.fileRead, .command])
    }

    func testOldFilesAreSkippedByMtime() async throws {
        let now = Date()
        try write([toolUse("Read", #"{"file_path":"/old"}"#)], name: "old.jsonl", mtime: now.addingTimeInterval(-3600))
        try write([toolUse("Read", #"{"file_path":"/new"}"#)], name: "new.jsonl", mtime: now)
        let events = await ClaudeActivitySource(root: root).poll(since: now.addingTimeInterval(-120)).events
        XCTAssertEqual(events.map(\.target), ["/new"])
    }

    func testDefaultInitBuilds() {
        XCTAssertFalse(ClaudeActivitySource().id.isEmpty)
    }
}
