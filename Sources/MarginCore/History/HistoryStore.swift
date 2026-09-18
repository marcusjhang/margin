import Foundation
import SQLite3

/// Append-only local warehouse of usage snapshots, backed by SQLite.
///
/// Lives in Application Support and is retained for 30 days, so history
/// survives the source tools' own log cleanup. Access is serialised with a
/// lock so background backfill and the main-actor store can share it.
public final class HistoryStore: @unchecked Sendable {
    public static let retentionDays = 30

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String = HistoryStore.defaultPath()) {
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            // sqlite3_open_v2 may still hand back a handle on failure.
            if let db { sqlite3_close(db) }
            db = nil
            return
        }

        execute("CREATE TABLE IF NOT EXISTS samples (provider TEXT NOT NULL, window_id TEXT NOT NULL, used_percent REAL NOT NULL, recorded_at REAL NOT NULL);")
        // Collapse any pre-existing duplicates, then enforce uniqueness so
        // re-running backfill is idempotent.
        execute("DELETE FROM samples WHERE rowid NOT IN (SELECT MIN(rowid) FROM samples GROUP BY provider, window_id, recorded_at);")
        execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_samples_unique ON samples(provider, window_id, recorded_at);")
        execute("CREATE INDEX IF NOT EXISTS idx_samples_time ON samples(recorded_at);")
    }

    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Margin/history.sqlite3").path
    }

    public static func inMemory() -> HistoryStore { HistoryStore(path: ":memory:") }

    /// Records samples in a single transaction, ignoring duplicates (same
    /// provider/window/timestamp) and skipping steady readings so a flat window
    /// doesn't balloon the table.
    public func record(_ samples: [UsageSample]) {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !samples.isEmpty else { return }

        var insert: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO samples (provider, window_id, used_percent, recorded_at) VALUES (?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        execute("BEGIN IMMEDIATE;")
        var lastByWindow: [String: UsageSample] = [:]

        for sample in samples {
            let key = "\(sample.provider.rawValue)|\(sample.windowID)"
            let last = lastByWindow[key] ?? latestUnlocked(provider: sample.provider, windowID: sample.windowID)
            if let last {
                let age = sample.timestamp.timeIntervalSince(last.timestamp)
                if age >= 0, age < 300, abs(last.usedPercent - sample.usedPercent) < 0.1 {
                    continue
                }
            }

            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, (sample.provider.rawValue as NSString).utf8String, -1, sqliteTransient)
            sqlite3_bind_text(insert, 2, (sample.windowID as NSString).utf8String, -1, sqliteTransient)
            sqlite3_bind_double(insert, 3, sample.usedPercent)
            sqlite3_bind_double(insert, 4, sample.timestamp.timeIntervalSince1970)
            sqlite3_step(insert)
            lastByWindow[key] = sample
        }

        execute("COMMIT;")
    }

    public func latest(provider: ProviderID, windowID: String) -> UsageSample? {
        lock.lock()
        defer { lock.unlock() }
        return latestUnlocked(provider: provider, windowID: windowID)
    }

    /// The most recent `limit` samples in the range, returned oldest-first.
    public func samples(provider: ProviderID, windowID: String, since: Date, limit: Int = 1000) -> [UsageSample] {
        lock.lock()
        defer { lock.unlock() }
        let newest = query(provider: provider, windowID: windowID, since: since, limit: limit, descending: true)
        return Array(newest.reversed())
    }

    public func prune(before date: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE recorded_at < ?;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    // MARK: - Unlocked internals

    private func latestUnlocked(provider: ProviderID, windowID: String) -> UsageSample? {
        query(provider: provider, windowID: windowID, since: .distantPast, limit: 1, descending: true).first
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func query(provider: ProviderID, windowID: String, since: Date, limit: Int, descending: Bool) -> [UsageSample] {
        guard let db else { return [] }
        let order = descending ? "DESC" : "ASC"
        let sql = "SELECT used_percent, recorded_at FROM samples WHERE provider = ? AND window_id = ? AND recorded_at >= ? ORDER BY recorded_at \(order) LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (provider.rawValue as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, (windowID as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_double(statement, 3, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(clamping: max(0, limit)))

        var results: [UsageSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let percent = sqlite3_column_double(statement, 0)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            results.append(UsageSample(provider: provider, windowID: windowID, usedPercent: percent, timestamp: timestamp))
        }
        return results
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
