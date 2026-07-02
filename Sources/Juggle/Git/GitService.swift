import Foundation

/// A repo's volatile git state. Held in memory only, never persisted.
struct GitSnapshot: Equatable, Sendable {
    var isRepo: Bool
    var branch: String?
    var isDirty: Bool

    static let none = GitSnapshot(isRepo: false, branch: nil, isDirty: false)
}

/// One worktree as reported by `git worktree list`.
struct WorktreeRef: Sendable, Equatable {
    let path: String
    let branch: String
}

/// Reads git state by shelling out to `git` via a shared `ShellRunner`.
final class GitService: Sendable {
    static let shared = GitService()

    private let runner = ShellRunner()
    private let gitPath: String?

    init() { gitPath = runner.locate("git") }

    func snapshot(at path: String) async -> GitSnapshot {
        guard let gitPath else { return .none }
        guard let branchOutput = await runner.runAsync(
            gitPath, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], cwd: path
        ) else { return .none }

        let branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return .none }

        let status = (await runner.runAsync(gitPath, ["-C", path, "status", "--porcelain"], cwd: path) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitSnapshot(isRepo: true, branch: branch, isDirty: !status.isEmpty)
    }

    func worktrees(at path: String) async -> [WorktreeRef] {
        guard let gitPath else { return [] }
        let output = await runner.runAsync(gitPath, ["-C", path, "worktree", "list", "--porcelain"], cwd: path)
        return Self.parseWorktreeList(output ?? "")
    }

    /// Create a worktree on a new branch under `<root>/.worktrees/<segment>`.
    func createWorktree(at root: String, branch: String) async -> Bool {
        guard let gitPath else { return false }
        let segment = Self.safeSegment(branch)
        guard !segment.isEmpty else { return false }
        let path = "\(root)/.worktrees/\(segment)"
        let output = await runner.runAsync(
            gitPath, ["-C", root, "worktree", "add", path, "-b", branch], cwd: root
        )
        return output != nil
    }

    /// Add a worktree that checks out an EXISTING branch under
    /// `<root>/.worktrees/<segment>` (no `-b`, so git checks the branch out).
    /// Used by "Open worktree…" for branches that already exist.
    func addWorktreeForExistingBranch(at root: String, branch: String) async -> Bool {
        guard let gitPath else { return false }
        let segment = Self.safeSegment(branch)
        guard !segment.isEmpty else { return false }
        let path = "\(root)/.worktrees/\(segment)"
        let output = await runner.runAsync(
            gitPath, ["-C", root, "worktree", "add", path, branch], cwd: root
        )
        return output != nil
    }

    /// Local branch names (excluding the symbolic `HEAD`), for the
    /// "Open worktree…" picker. Empty when git is missing or the read fails.
    func localBranches(at path: String) async -> [String] {
        guard let gitPath else { return [] }
        let output = await runner.runAsync(
            gitPath, ["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: path
        )
        return Self.parseBranchList(output ?? "")
    }

    /// Pure parser for `for-each-ref … refs/heads`, extracted for unit testing.
    static func parseBranchList(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "HEAD" }
    }

    static func safeSegment(_ branch: String) -> String {
        branch
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "..~^:?*[\\"))
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Pure parser for `git worktree list --porcelain` output. Extracted from the
    /// I/O boundary so it can be unit-tested without a process.
    static func parseWorktreeList(_ output: String) -> [WorktreeRef] {
        var result: [WorktreeRef] = []
        var currentPath: String?
        var currentBranch = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                currentBranch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            } else if line.hasPrefix("detached") {
                currentBranch = "detached"
            } else if line.isEmpty, let path = currentPath {
                result.append(WorktreeRef(path: path, branch: currentBranch))
                currentPath = nil
                currentBranch = ""
            }
        }
        if let path = currentPath { result.append(WorktreeRef(path: path, branch: currentBranch)) }
        return result
    }
}
