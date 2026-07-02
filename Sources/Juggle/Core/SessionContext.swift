import AppKit

/// Everything a terminal window needs to render its identity and behavior.
/// Two colors: the project hue tints the titlebar header, the worktree color is
/// the accent line under it (and the breathing surface) — so you read project
/// and worktree at once.
struct SessionContext {
    let projectId: String
    let worktreeId: String
    let displayName: String
    let worktreeDisplayName: String
    let worktreePathDisplay: String
    let cwd: String
    let headerColor: NSColor   // project hue -> titlebar header
    let lineColor: NSColor     // worktree color -> accent line + breathing
    let tintFraction: CGFloat
    let terminalThemeName: String
    let terminalThemeIsLight: Bool
    let breathingEnabled: Bool
    let soundOnBlocked: Bool
    var branch: String?
}
