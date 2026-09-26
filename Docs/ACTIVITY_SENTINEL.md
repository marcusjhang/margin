# Agent Activity Sentinel — build contract

Adds a local, unprivileged **agent-activity layer** to Margin. Margin answers
"how much runway is left?"; this adds "what did my agents actually do?" — per
session: what it touched, spawned, spent, and was allowed to do.

**Non-negotiable:** no root, no TCC, no entitlements, **no network**, no new
dependencies (Foundation / SQLite3 / Darwin / AppKit / SwiftUI only). The usage
path must not change; `make test` must stay green.

## Frozen types (already on `main`, do not edit)

- `Sources/MarginCore/Activity/ActivityModels.swift` — `ActivityKind`,
  `ActivityEvent` (+ `makeID`), `ActivityBatch`, `LiveState`, `LiveState.Listener`
  (+ `isLoopback`), `AlertKind`, `Alert` (+ `makeID`).
- `Sources/MarginCore/Activity/ActivitySource.swift` — the `poll(since:)` protocol.
- `ProviderID`, `Provenance`, `Severity` are now `Codable`.

## Required public APIs (implement exactly; other tasks compile against these)

```swift
// W3 — Sources/MarginCore/Ledger/LedgerStore.swift  (mirror HistoryStore)
public final class LedgerStore: @unchecked Sendable {
    public init(path: String = LedgerStore.defaultPath())
    public static func defaultPath() -> String          // ~/Library/Application Support/Margin/ledger.sqlite3
    public static func inMemory() -> LedgerStore
    public func record(_ events: [ActivityEvent])       // INSERT OR IGNORE on id, single txn
    public func events(sessionID: String, limit: Int = 1000) -> [ActivityEvent]
    public func events(since: Date, kind: ActivityKind?, limit: Int = 1000) -> [ActivityEvent]
    public func activeSessions(since: Date) -> [String]
    public func prune(before date: Date)
}

// W3 — Sources/MarginCore/Store/ActivityStore.swift  (mirror UsageStore)
@MainActor public final class ActivityStore: ObservableObject {
    public init(sources: [ActivitySource] = [ClaudeActivitySource(), CodexActivitySource()],
                ledger: LedgerStore = LedgerStore(), pollInterval: TimeInterval = 3)
    @Published public private(set) var events: [ActivityEvent]
    @Published public private(set) var alerts: [Alert]
    @Published public private(set) var live: LiveState
    public func start()
    public func stop()
    public func refresh() async
}

// W1/W2 — Sources/MarginCore/Activity/*ActivitySource.swift
public struct ClaudeActivitySource: ActivitySource { public init(); … }
public struct CodexActivitySource:  ActivitySource { public init(); … }

// W4 — Sources/MarginCore/Activity/PortProcessSource.swift
public struct PortProcessSource: Sendable {
    public init()
    /// Same-user listeners only; PID 0 (other users) must be skipped.
    public func listeners() async -> [LiveState.Listener]
}

// W4 — Sources/MarginCore/Activity/WorktreeSource.swift
public struct WorktreeSource: Sendable {
    public init()
    public func worktree(cwd: String) async -> (worktree: String, branch: String)?
}

// W4 — Sources/MarginCore/Activity/ActivityCorrelator.swift
public enum ActivityCorrelator {
    /// Attributes listeners + spawns to sessions, flags leaked ones.
    public static func correlate(
        events: [ActivityEvent],
        listeners: [LiveState.Listener],
        activeSessions: [String],
        processParent: (Int32) -> Int32?,
        processCwd: (Int32) -> String?
    ) -> (events: [ActivityEvent], alerts: [Alert])
}

// W5 — Sources/MarginCore/Activity/SentinelRules.swift  (pure, testable)
public enum SentinelRules {
    /// `seenCounts` carries the previous poll's observation counts so a rule
    /// only fires once a condition is SUSTAINED (>= 2 consecutive polls).
    public static func evaluate(
        events: [ActivityEvent],
        live: LiveState,
        seenCounts: [String: Int]
    ) -> (alerts: [Alert], seenCounts: [String: Int])
}
```

## File ownership (disjoint — do not touch files you don't own)

| Task | Owns |
|---|---|
| W1 | `Activity/ClaudeActivitySource.swift`, `Tests/MarginCoreTests/ClaudeActivityScenariosTests.swift` |
| W2 | `Activity/CodexActivitySource.swift`, `Tests/MarginCoreTests/CodexActivityScenariosTests.swift` |
| W3 | `Ledger/LedgerStore.swift`, `Store/ActivityStore.swift`, `Tests/MarginCoreTests/LedgerScenariosTests.swift` |
| W4 | `Activity/PortProcessSource.swift`, `Activity/WorktreeSource.swift`, `Activity/ActivityCorrelator.swift`, `Tests/MarginCoreTests/CorrelationScenariosTests.swift` |
| W5 | `Activity/SentinelRules.swift`, `MarginUI/ActivitySection.swift`, edits to `MarginUI/PopoverView.swift` + `MarginApp/StatusItemGlyph.swift`, `Tests/MarginCoreTests/SentinelRulesScenariosTests.swift` |
| W6 | `Sources/MarginCLI/main.swift`, `project.yml` (add the tool target), `Makefile` (optional) |
| coordinator | the frozen files above, integration, build, release |

## Source notes (verified on the owner's machine)

- **Claude transcripts:** `~/.claude/projects/**/<session>.jsonl` (+ `subagents/agent-*.jsonl`).
  Tool calls live in `type == "assistant"` messages: `message.content[*].type == "tool_use"`
  with `name` and `input` (`file_path`, `command`, `pattern`…). Map
  `Read→fileRead`, `Edit/Write/NotebookEdit→fileWrite`, `Bash→command`,
  `Task`/`Agent→spawn`, and record `cwd`, `gitBranch`, `sessionId`, `timestamp`.
  `~/.claude/` transcripts are pruned after ~30 days.
- **Codex rollouts:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, records
  `{ordinal, timestamp, type, payload}`. Activity lives in `type == "response_item"`
  with `payload.type == "custom_tool_call"` (name `"exec"`, `input` is a JS string —
  extract `tools.exec_command({"cmd": "…"})`) and `payload.type == "function_call"`
  (`name`, `arguments` JSON). Also `payload.type == "message"`.
- **Ports:** only the **calling user's** PIDs are readable
  (`sysctl net.inet.tcp.pcblist_n`); other users show pid 0 → skip. Bounds-check
  every record on `xgn_len`/`xgn_kind`. Keep a libproc fallback behind the same API.
- **Worktrees:** `git worktree list --porcelain` from the session cwd.

## UI spec (W5) — follow HIG / native

- New **Activity** section *below* the usage section in the popover; do not alter
  usage rows. Same visual language: flat rows, system `Divider`, semantic text
  styles (`.headline`/`.subheadline`/`.caption`), system colors, monospaced digits.
- Per session row: provider mark, cwd/worktree (abbreviated), `files N`,
  `ports N`, spend, and an alert dot. Warnings use `.orange`/`.red`; loopback vs
  exposed labelled explicitly.
- Status glyph gets an independent **watch state** (SentinelRules), not mixed with
  usage severity.
- Silent by default: no alerts unless a rule is sustained; no notifications in M-mvp.

## Acceptance (per task)

- Fixture-based unit tests named `*ScenariosTests.swift`, using **synthetic**
  fixtures only (never real transcripts).
- Re-polling the same window yields **no duplicate ids**.
- Malformed lines are skipped, never crash.
- `make test` green; usage path untouched.
- Worker final message ends with the `SUPERSET_WORKER_DONE` / `_BLOCKED` envelope.
