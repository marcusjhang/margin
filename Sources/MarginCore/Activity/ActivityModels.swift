import Foundation

// MARK: - Activity

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case sessionEnd
    case prompt
    case fileRead
    case fileWrite
    case command
    case permissionRequest
    case permissionDenied
    /// Synthesised by the correlator, not read from a harness.
    case portBound
    case processSpawned
    case spendDelta
}

/// One thing an agent did. `id` is deterministic so the ledger can dedupe on it.
public struct ActivityEvent: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let provider: ProviderID
    public let sessionID: String
    public let timestamp: Date
    public let kind: ActivityKind
    public let cwd: String?
    public let gitBranch: String?
    public let worktree: String?
    public let tool: String?
    /// Path, command, port, model… never a secret value.
    public let target: String?
    public let provenance: Provenance
    public let metadata: [String: String]

    public init(
        id: String,
        provider: ProviderID,
        sessionID: String,
        timestamp: Date,
        kind: ActivityKind,
        cwd: String? = nil,
        gitBranch: String? = nil,
        worktree: String? = nil,
        tool: String? = nil,
        target: String? = nil,
        provenance: Provenance,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.kind = kind
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.worktree = worktree
        self.tool = tool
        self.target = target
        self.provenance = provenance
        self.metadata = metadata
    }

    /// Stable, dedupe-safe identity. Same logical event → same id, on re-poll.
    public static func makeID(
        provider: ProviderID,
        sessionID: String,
        ordinal: Int,
        kind: ActivityKind,
        target: String?
    ) -> String {
        "\(provider.rawValue)|\(sessionID)|\(ordinal)|\(kind.rawValue)|\(target ?? "")"
    }
}

public struct ActivityBatch: Sendable {
    public let events: [ActivityEvent]
    /// Next poll's `since` for this source.
    public let cursor: Date

    public init(events: [ActivityEvent], cursor: Date) {
        self.events = events
        self.cursor = cursor
    }
}

// MARK: - Live machine state

/// A snapshot of the machine side effects the rules reason over.
public struct LiveState: Sendable, Equatable, Codable {
    public struct Listener: Sendable, Equatable, Codable {
        public let port: Int
        /// "127.0.0.1", "::1", "0.0.0.0", "::", or a specific interface address.
        public let address: String
        public let pid: Int32
        public let processPath: String?

        public init(port: Int, address: String, pid: Int32, processPath: String?) {
            self.port = port
            self.address = address
            self.pid = pid
            self.processPath = processPath
        }

        public var isLoopback: Bool {
            address == "127.0.0.1" || address == "::1" || address.hasPrefix("127.")
        }
    }

    public let listeners: [Listener]
    /// Session ids currently considered live.
    public let activeSessions: [String]

    public init(listeners: [Listener], activeSessions: [String]) {
        self.listeners = listeners
        self.activeSessions = activeSessions
    }
}

// MARK: - Alerts

public enum AlertKind: String, Codable, Sendable, CaseIterable {
    case budget
    case exposedPort
    case secretAccess
    case outOfWorktree
    case leakedProcess
}

/// A sustained condition worth surfacing. Never fired from a single tick.
public struct Alert: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let kind: AlertKind
    public let severity: Severity
    public let sessionID: String
    public let provider: ProviderID
    public let title: String
    public let detail: String
    public let target: String?
    /// When the condition was first observed (for "sustained for Ns" copy).
    public let since: Date

    public init(
        id: String,
        kind: AlertKind,
        severity: Severity,
        sessionID: String,
        provider: ProviderID,
        title: String,
        detail: String,
        target: String? = nil,
        since: Date
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.sessionID = sessionID
        self.provider = provider
        self.title = title
        self.detail = detail
        self.target = target
        self.since = since
    }

    public static func makeID(kind: AlertKind, sessionID: String, target: String?) -> String {
        "\(kind.rawValue)|\(sessionID)|\(target ?? "")"
    }
}
