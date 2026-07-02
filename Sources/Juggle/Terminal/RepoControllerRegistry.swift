import GhosttyTerminal

/// One `TerminalController` per project, themed by the current terminal-theme
/// preference. Changing the theme re-themes every live controller.
@MainActor
final class RepoControllerRegistry {
    private var controllers: [String: TerminalController] = [:]
    private var currentTheme = AppModel.shared.preferences.terminalTheme
    private var currentFontSize = AppModel.shared.preferences.terminalFontSize

    func controller(forKey key: String) -> TerminalController {
        if let existing = controllers[key] { return existing }
        let controller = TerminalController(configSource: .none, theme: TerminalTheming.theme(named: currentTheme))
        // Set the font size on the controller before any surface is created so
        // every terminal it spawns inherits it (no per-surface override needed).
        _ = controller.setTerminalConfiguration(Self.terminalConfiguration(themeName: currentTheme, fontSize: currentFontSize))
        controllers[key] = controller
        return controller
    }

    func applyTheme(_ name: String) {
        guard name != currentTheme else { return }
        currentTheme = name
        let theme = TerminalTheming.theme(named: name)
        let config = Self.terminalConfiguration(themeName: name, fontSize: currentFontSize)
        for controller in controllers.values {
            _ = controller.setTheme(theme)
            _ = controller.setTerminalConfiguration(config)
        }
    }

    /// Live-reconfigure every terminal's font size (Settings slider).
    func applyFontSize(_ size: Double) {
        guard size != currentFontSize else { return }
        currentFontSize = size
        let config = Self.terminalConfiguration(themeName: currentTheme, fontSize: size)
        for controller in controllers.values {
            _ = controller.setTerminalConfiguration(config)
        }
    }

    nonisolated static func terminalConfiguration(themeName: String = Preferences.defaultTerminalTheme, fontSize: Double) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            // Mirror the stock Terminal.app profile shape: SF Mono/SF Mono
            // Terminal, block cursor, no cursor blink, and native glyph
            // antialiasing. Do not enable Ghostty's font-thicken mode here:
            // Terminal.app's "Use bold fonts" affects bold text, not every
            // regular glyph. Thickening all 11–12pt SF Mono text makes it read
            // chunky/pixelated next to Terminal.app.
            //
            // SF Mono lives only inside Terminal.app's bundle, so we register it
            // and then resolve: if it still is not a real monospaced face we fall
            // back to Menlo. Emitting `font-family = SF Mono` blindly would let
            // Ghostty/CoreText draw the grid in proportional Helvetica.
            let preferredFamily = TerminalTheming.fontFamily(named: themeName)
            builder.withFontFamily(TerminalFontRegistrar.resolvedMonospacedFamily(preferred: preferredFamily))
            builder.withFontSize(Float(Preferences.clampedTerminalFontSize(fontSize)))
            builder.withFontThicken(false)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(false)
        }
    }
}
