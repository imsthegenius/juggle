import Foundation

/// The first-run "is the GitHub CLI ready?" answer. Surfaced on the permissions
/// onboarding step. Detection is honest: one local `gh auth status` (no network)
/// decides whether `gh` is absent, present-but-signed-out, or signed in — and, in
/// the signed-in case, reads the active account name from that same output.
enum GhAuthState: Sendable, Equatable {
    /// `gh` is not on the PATH Juggle searches. Step offers an install link.
    case notInstalled
    /// `gh` is installed but `gh auth status` failed (not logged in). Step offers
    /// to open a terminal running `gh auth login`.
    case notSignedIn
    /// Authenticated. The username comes from the live `gh auth status` output;
    /// `nil` means the user took the "I'm already signed in" manual override, so
    /// the row is satisfied without a name to show.
    case signedIn(username: String?)
}
