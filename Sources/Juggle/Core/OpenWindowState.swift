import Foundation

/// A terminal window that was open at last save: which project + worktree it was
/// driving and which grid slot it occupied. Persisted (identity + slot only, like
/// the rest of `WorkspaceState`) so a relaunch can restore the grid, colors, and
/// assignments (R17 / AE4). Live PTY processes are intentionally NOT captured —
/// a fresh shell opens in the worktree's cwd on restore.
struct OpenWindowState: Codable, Equatable {
    var projectId: String
    var worktreeId: String
    var slot: Int
    /// Stable-enough display assignment for the current connected-screen order.
    /// Defaults to the primary display for older stores written before R3 restore.
    var screenIndex: Int = 0

    init(projectId: String, worktreeId: String, slot: Int, screenIndex: Int = 0) {
        self.projectId = projectId
        self.worktreeId = worktreeId
        self.slot = slot
        self.screenIndex = screenIndex
    }

    private enum CodingKeys: String, CodingKey { case projectId, worktreeId, slot, screenIndex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(String.self, forKey: .projectId)
        worktreeId = try c.decode(String.self, forKey: .worktreeId)
        slot = try c.decode(Int.self, forKey: .slot)
        screenIndex = try c.decodeIfPresent(Int.self, forKey: .screenIndex) ?? 0
    }
}
