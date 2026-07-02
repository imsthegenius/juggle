import Foundation

/// Raw, host-observable signals from a terminal surface, exactly as the engine
/// delegate surfaces them. Kept separate from `AttentionState` so that revising
/// how signals are detected (the open question about reliable "blocked"
/// detection) never reaches into the presentation layer.
enum RawAgentSignal: Equatable {
    /// Terminal BEL. A common "look at me" from CLI agents.
    case bell
    /// OSC 9 / OSC 777 desktop notification. What `claude` emits when it wants
    /// the user; the primary "blocked / needs you" signal.
    case desktopNotification(title: String, body: String)
    /// OSC 133 D shell-integration command exit. `exitCode` is nil when the
    /// shell did not report one; `durationNanos` is wall-clock.
    case commandFinished(exitCode: Int?, durationNanos: UInt64)
    /// OSC 9;4 progress report entered an error state.
    case progressError
    /// The surface gained focus; the user is now looking at it.
    case focused
}
