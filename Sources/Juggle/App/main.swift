import AppKit

// Pure AppKit entry point. Top-level code in main.swift runs on the main actor,
// so constructing the @MainActor delegate here is safe. Juggle owns its windows
// directly (terminal windows + the control panel / Settings), so it does
// not use the SwiftUI App lifecycle.
let appDelegate = AppDelegate()
let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
