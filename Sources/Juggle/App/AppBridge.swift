import AppKit

/// Bridge from SwiftUI surfaces to the AppKit controller that owns the terminal
/// windows. The controller lives on the app delegate.
@MainActor
func appController() -> AppController? {
    (NSApp.delegate as? AppDelegate)?.controller
}

@MainActor
func openCommandCentre() {
    (NSApp.delegate as? AppDelegate)?.showCommandCentre(nil)
}

/// Open the ⌘J project switcher from a SwiftUI surface (the control panel).
@MainActor
func openSwitcher() {
    (NSApp.delegate as? AppDelegate)?.toggleSwitcher()
}

/// Pop the control panel out of the menu-bar popover into a full window.
@MainActor
func detachControlPanel() {
    (NSApp.delegate as? AppDelegate)?.detachControlPanel(nil)
}

/// Activate one cross-project cockpit item from SwiftUI surfaces.
@MainActor
func activateNeedsYou(_ item: NeedsYouItem) {
    (NSApp.delegate as? AppDelegate)?.activateNeedsYouItem(item)
}

/// Replay the first-run onboarding flow from Settings.
@MainActor
func replayOnboarding() {
    (NSApp.delegate as? AppDelegate)?.showOnboarding()
}
