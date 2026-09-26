import Foundation

/// A source of agent activity. Implementations must be:
/// - incremental (`since` bounds the read),
/// - idempotent (re-polling the same window yields the same events, same ids),
/// - cheap when nothing changed (mtime/size offsets, no full re-reads),
/// - crash-proof on malformed input (skip the line, never throw).
public protocol ActivitySource: Sendable {
    var id: String { get }
    func poll(since: Date) async -> ActivityBatch
}
