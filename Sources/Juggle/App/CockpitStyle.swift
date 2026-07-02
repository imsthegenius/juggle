import AppKit
import SwiftUI

enum CockpitStyle {
    static let nsAccent = RepoColor.palette[0].nsColor
    static let accent = Color(nsColor: nsAccent)
    static let panelBackground = Color(nsColor: NSColor(calibratedWhite: 0.045, alpha: 1))
    static let headerBackground = Color(nsColor: NSColor(calibratedWhite: 0.065, alpha: 1))
    static let footerBackground = Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: 1))
    static let cardFill = Color(nsColor: NSColor(calibratedWhite: 0.082, alpha: 1))
    static let cardStroke = Color.white.opacity(0.105)
    static let controlFill = Color.white.opacity(0.085)
    static let controlStroke = Color.white.opacity(0.13)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
}
