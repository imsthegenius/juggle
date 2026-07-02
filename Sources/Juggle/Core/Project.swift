import Foundation

/// A project Juggle juggles: a named, colored repository that holds one or more
/// worktrees. The display name is the user's, set in the control panel, and is
/// what every window of the project shows (never the raw shell title).
struct Project: Identifiable, Codable, Hashable {
    let id: String          // stable; derived from the repo root path
    var displayName: String
    var rootPath: String
    var colorName: String   // a key into RepoColor.palette
    var worktrees: [Worktree]

    var primaryWorktree: Worktree? { worktrees.first(where: \.isPrimary) ?? worktrees.first }
}
