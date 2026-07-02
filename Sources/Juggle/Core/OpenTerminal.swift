import Foundation

/// A live terminal window, surfaced in the control panel under its worktree so
/// the user sees project ▸ worktree ▸ terminals, and so a blocked agent can
/// blink there and be clicked to jump straight to that window.
struct OpenTerminal: Identifiable, Equatable {
    let id: UUID
    let projectId: String
    let worktreeId: String
    var title: String
    var attention: AttentionState

    /// Whether this terminal is asking for the user (drives the blink).
    var needsAttention: Bool { attention == .blocked || attention == .done || attention == .error }
}
