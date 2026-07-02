import Foundation

/// One worktree of a project: its own branch and path. By default it renders a
/// shade of the project's color (`shade` 0 = the main checkout's full hue), but
/// `colorName` overrides that with any palette color, so two worktrees of the
/// same project can be told apart by color, not just shade.
struct Worktree: Identifiable, Codable, Hashable {
    let id: String
    var projectId: String
    var branch: String
    var path: String
    var shade: Int
    var isPrimary: Bool
    var colorName: String? = nil
}

extension Worktree {
    /// Human-facing branch/worktree label. Git reports detached checkouts as
    /// `HEAD`, which made the window title read as if the user should know Git
    /// internals. Keep the raw branch for git actions, but speak plainly in UI.
    var displayBranch: String {
        if branch == "detached" { return "Detached checkout" }
        if branch.isEmpty { return isPrimary ? "Primary checkout" : "Worktree" }
        return branch
    }

    var shortPath: String {
        Self.shortPath(path)
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
