import Foundation

/// Resolves a session's git worktree root and current branch from a cwd by
/// asking `git worktree list --porcelain`.
public struct WorktreeSource: Sendable {
    public init() {}

    /// The worktree whose path is the deepest prefix of `cwd`, plus its branch.
    /// Returns nil when git isn't available, the cwd isn't in a worktree, or
    /// the porcelain output can't be parsed.
    public func worktree(cwd: String) async -> (worktree: String, branch: String)? {
        guard let output = Shell.run("/usr/bin/git", ["-C", cwd, "worktree", "list", "--porcelain"]) else {
            return nil
        }
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        return Self.parse(text, cwd: cwd)
    }

    // MARK: - Parsing (internal, unit-tested)

    static func parse(_ porcelain: String, cwd: String) -> (worktree: String, branch: String)? {
        var best: (worktree: String, branch: String)? = nil
        var currentWorktree: String? = nil
        var currentBranch: String? = nil

        func flush() {
            defer { currentWorktree = nil; currentBranch = nil }
            guard let worktree = currentWorktree,
                  cwd.hasPrefix(worktree) else { return }
            // Prefer the deepest (longest) matching prefix.
            if let existing = best, existing.worktree.count >= worktree.count { return }
            best = (worktree: worktree, branch: currentBranch ?? "")
        }

        for line in porcelain.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("worktree ") {
                flush()
                currentWorktree = String(trimmed.dropFirst("worktree ".count))
            } else if trimmed.hasPrefix("branch ") {
                let ref = String(trimmed.dropFirst("branch ".count))
                currentBranch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
        }
        flush()

        guard let result = best else { return nil }
        return (worktree: result.worktree, branch: result.branch)
    }
}
