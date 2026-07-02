import AppKit
import GhosttyTerminal
import GhosttyTheme

/// Terminal color schemes Juggle offers. A catalog theme's `toTerminalTheme()`
/// sets both light and dark configs to the same scheme, so the choice is honored
/// regardless of the system appearance.
enum TerminalTheming {
    static let darkOptions = ["Clear Dark", "Catppuccin Mocha", "One Half Dark", "Dracula", "Argonaut", "Snazzy"]
    static let lightOptions = ["Basic", "Clear Light", "Catppuccin Latte", "One Half Light", "Atom One Light", "Belafonte Day"]

    static func theme(named name: String) -> TerminalTheme {
        if let profile = terminalProfiles[name] {
            return profile.theme
        }
        return GhosttyThemeCatalog.theme(named: name)?.toTerminalTheme() ?? fallback
    }

    static func isLightTheme(named name: String) -> Bool {
        if let profile = terminalProfiles[name] {
            return profile.isLight
        }
        guard let definition = GhosttyThemeCatalog.theme(named: name) else { return false }
        return !definition.isDark
    }

    static func backgroundColor(named name: String) -> NSColor {
        if let profile = terminalProfiles[name],
           let color = NSColor(hex: profile.background) {
            return color
        }
        guard let definition = GhosttyThemeCatalog.theme(named: name),
              let color = NSColor(hex: definition.background)
        else { return NSColor(calibratedWhite: 0.10, alpha: 1) }
        return color
    }

    static func defaultFontSize(named name: String) -> Double? {
        terminalProfiles[name]?.fontSize
    }

    static func fontFamily(named name: String) -> String {
        terminalProfiles[name]?.fontFamily ?? "SF Mono"
    }

    static let fallback: TerminalTheme = {
        GhosttyThemeCatalog.theme(named: "Catppuccin Mocha")?.toTerminalTheme() ?? .default
    }()

    private struct TerminalProfile {
        let background: String
        let backgroundOpacity: Double?
        let foreground: String
        let bold: String
        let selection: String
        let cursor: String
        let palette: [String]
        let fontFamily: String
        let fontSize: Double
        let isLight: Bool

        var theme: TerminalTheme {
            let config = TerminalConfiguration { builder in
                builder.withBackground(background)
                if let backgroundOpacity {
                    builder.withBackgroundOpacity(backgroundOpacity)
                }
                builder.withForeground(foreground)
                builder.withBoldColor(bold)
                builder.withSelectionBackground(selection)
                builder.withCursorColor(cursor)
                for (index, color) in palette.enumerated() {
                    builder.withPalette(index, color: "#\(color)")
                }
            }
            return TerminalTheme(light: config, dark: config)
        }
    }

    private static let clearDarkPalette = [
        "35424C", "B45648", "6CAA71", "C4AC62",
        "6D96B4", "BD7BCD", "7CCBCD", "DEE5EB",
        "465C6D", "DF6C5A", "79BE7E", "E5C872",
        "67B5ED", "D389E5", "84DDE0", "E5EFF5",
    ]

    private static let clearLightPalette = [
        "2D3840", "B45648", "6CAA71", "C4AC62",
        "5685A8", "AD64BE", "69C6C9", "C1C8CC",
        "506573", "DF6C5A", "79BE7E", "E5C872",
        "49A2E1", "D389E5", "77E1E5", "D8E1E7",
    ]

    private static let basicPalette = [
        "000000", "C23621", "25BC24", "ADAD27",
        "492EE1", "D338D3", "33BBC8", "CBCBCB",
        "818383", "FC391F", "31E722", "EAEC23",
        "5833FF", "F935F8", "14F0F0", "E9EBEB",
    ]

    private static let terminalProfiles: [String: TerminalProfile] = [
        "Basic": TerminalProfile(
            background: "FFFFFF",
            backgroundOpacity: nil,
            foreground: "000000",
            bold: "000000",
            selection: "B3D7FF",
            cursor: "8E8E8E",
            palette: basicPalette,
            fontFamily: "SF Mono",
            fontSize: 11,
            isLight: true
        ),
        "Clear Dark": TerminalProfile(
            background: "212734",
            backgroundOpacity: 0.95,
            foreground: "E6E6E6",
            bold: "F0F0F0",
            selection: "334E5E",
            cursor: "919191",
            palette: clearDarkPalette,
            fontFamily: "SF Mono Terminal",
            fontSize: 12,
            isLight: false
        ),
        "Clear Light": TerminalProfile(
            background: "FFFFFF",
            backgroundOpacity: 0.93,
            foreground: "3A4851",
            bold: "313C44",
            selection: "E5ECF1",
            cursor: "919191",
            palette: clearLightPalette,
            fontFamily: "SF Mono Terminal",
            fontSize: 12,
            isLight: true
        ),
    ]
}
