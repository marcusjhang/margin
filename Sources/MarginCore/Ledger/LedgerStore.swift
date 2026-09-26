import Foundation
import SQLite3

/// Append-only local warehouse of agent activity events, backed by SQLite.
///
/// Lives in Application Support and mirrors `HistoryStore`'s shape: access is
/// serialised with an `NSLock`, rows dedupe on the deterministic event id, and
/// old rows are pruned. Events outlive the source tools' own log cleanup.
public final class LedgerStore: @unchecked Sendable {
    public static let retentionDays = 30

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String = LedgerStore.defaultPath()) {
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            return
        }

        execute("""
        CREATE TABLE IF NOT EXISTS activity_events (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            kind TEXT NOT NULL,
            cwd TEXT,
            git_branch TEXT,
            worktree TEXT,
            tool TEXT,
            target TEXT,
            provenance TEXT NOT NULL,
            metadata TEXT
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_activity_time ON activity_events(timestamp);")
        execute("CREATE INDEX IF NOT EXISTS idx_activity_session ON activity_events(session_id);")
    }

    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Margin/ledger.sqlite3").path
    }

    public static func inMemory() -> LedgerStore { LedgerStore(path: ":memory:") }

    /// Records events in a single transaction, ignoring duplicates on `id`.
    public func record(_ events: [ActivityEvent]) {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !events.isEmpty else { return }

        var insert: OpaquePointer?
        let sql = """
        INSERT OR IGNORE INTO activity_events
            (id, provider, session_id, timestamp, kind, cwd, git_branch, worktree, tool, target, provenance, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        execute("BEGIN IMMEDIATE;")
        for event in events {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, (event.id as NSString).utf8String, -1, sqliteTransient)
            sqlite3_bind_text(insert, 2, (event.provider.rawValue as NSString).utf8String, -1, sqliteTransient)
            sqlite3_bind_text(insert, 3, (event.sessionID as NSString).utf8String, -1, sqliteTransient)
            sqlite3_bind_double(insert, 4, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(insert, 5, (event.kind.rawValue as NSString).utf8String, -1, sqliteTransient)
            bindOptional(insert, 6, event.cwd)
            bindOptional(insert, 7, event.gitBranch)
            bindOptional(insert, 8, event.worktree)
            bindOptional(insert, 9, event.tool)
            bindOptional(insert, 10, event.target)
            sqlite3_bind_text(insert, 11, (event.provenance.rawValue as NSString).utf8String, -1, sqliteTransient)
            if let metadata = event.metadata.isEmpty ? nil : event.metadata,
               let data = try? JSONSerialization.data(withJSONObject: metadata),
               let json = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(insert, 12, (json as NSString).utf8String, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(insert, 12)
            }
            sqlite3_step(insert)
        }
        execute("COMMIT;")
    }

    /// Events for a session, oldest-first, capped at `limit`.
    public func events(sessionID: String, limit: Int = 1000) -> [ActivityEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = "SELECT * FROM activity_events WHERE session_id = ? ORDER BY timestamp ASC, rowid ASC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(clamping: max(0, limit)))
        return rows(statement)
    }

    /// Events at or after `since`, optionally filtered by kind, oldest-first.
    public func events(since: Date, kind: ActivityKind?, limit: Int = 1000) -> [ActivityEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let kindClause = kind.map { _ in "AND kind = ?" } ?? ""
        let sql = "SELECT * FROM activity_events WHERE timestamp >= ? \(kindClause) ORDER BY timestamp ASC, rowid ASC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var nextIndex: Int32 = 2
        if let kind {
            sqlite3_bind_text(statement, nextIndex, (kind.rawValue as NSString).utf8String, -1, sqliteTransient)
            nextIndex += 1
        }
        sqlite3_bind_int(statement, nextIndex, Int32(clamping: max(0, limit)))
        return rows(statement)
    }

    /// Distinct session ids that had activity at or after `since`.
    public func activeSessions(since: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = "SELECT DISTINCT session_id FROM activity_events WHERE timestamp >= ? ORDER BY session_id;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                result.append(String(cString: text))
            }
        }
        return result
    }

    public func prune(before date: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM activity_events WHERE timestamp < ?;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    // MARK: - Internals

    private func bindOptional(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func rows(_ statement: OpaquePointer?) -> [ActivityEvent] {
        var result: [ActivityEvent] = []
        guard let statement else { return result }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let providerText = sqlite3_column_text(statement, 1),
                  let sessionText = sqlite3_column_text(statement, 2),
                  let kindText = sqlite3_column_text(statement, 4),
                  let provenanceText = sqlite3_column_text(statement, 10),
                  let provider = ProviderID(rawValue: String(cString: providerText)),
                  let kind = ActivityKind(rawValue: String(cString: kindText)),
                  let provenance = Provenance(rawValue: String(cString: provenanceText)) else {
                continue
            }

            var metadata: [String: String] = [:]
            if let metaText = sqlite3_column_text(statement, 11) {
                let json = String(cString: metaText)
                if let data = json.data(using: .utf8),
                   let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                    metadata = decoded
                }
            }

            result.append(ActivityEvent(
                id: String(cString: idText),
                provider: provider,
                sessionID: String(cString: sessionText),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                kind: kind,
                cwd: columnText(statement, 5),
                gitBranch: columnText(statement, 6),
                worktree: columnText(statement, 7),
                tool: columnText(statement, 8),
                target: columnText(statement, 9),
                provenance: provenance,
                metadata: metadata
            ))
        }
        return result
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
