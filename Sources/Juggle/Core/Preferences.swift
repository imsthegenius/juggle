import Foundation

/// User customisation from Settings. 0...1 sliders are mapped to
/// concrete values where applied.
struct Preferences: Codable, Equatable {
    static let defaultTerminalTheme = "Basic"
    static let defaultTerminalFontSize = 11.0
    static let terminalFontSizeRange: ClosedRange<Double> = 11 ... 24

    var titlebarTint: Double = 0.5      // 0 subtle .. 1 bold
    var windowGap: Double = 0.0         // 0 flush .. 1 airy
    var breathing: Bool = true
    var soundOnBlocked: Bool = false
    var gridColumns: Int = 2
    var gridRows: Int = 2
    var terminalTheme: String = Self.defaultTerminalTheme
    var terminalFontSize: Double = Self.defaultTerminalFontSize
    var hasOnboarded: Bool = false      // legacy tour completion, no longer launch-gating
    /// The notch HUD: an ambient attention strip that hangs from the menu bar /
    /// MacBook notch and surfaces, across every project, what needs the user
    /// (blocked, error, done, PR ready) without any window being visible. On by
    /// default — it's the push-based counterpart to the ⌘J pull-based switcher.
    var notchHUD: Bool = true

    /// Map titlebar-tint slider to the fraction of accent mixed into the header.
    var tintFraction: CGFloat { 0.18 + CGFloat(titlebarTint) * 0.34 }   // 0.18 .. 0.52
    /// Map window-gap slider to points between tiles. 0 = flush.
    var gapPoints: CGFloat { CGFloat(windowGap) * 12 }                  // 0 .. 12

    init() {}

    private enum CodingKeys: String, CodingKey {
        case titlebarTint, windowGap, breathing, soundOnBlocked
        case gridColumns, gridRows, terminalTheme, terminalFontSize
        case hasOnboarded, notchHUD
    }

    /// Decode field-by-field with defaults, so adding a preference never makes an
    /// older saved `workspace.json` fail to load (which would silently drop the
    /// user's projects along with it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titlebarTint = try c.decodeIfPresent(Double.self, forKey: .titlebarTint) ?? 0.5
        windowGap = try c.decodeIfPresent(Double.self, forKey: .windowGap) ?? 0.0
        breathing = try c.decodeIfPresent(Bool.self, forKey: .breathing) ?? true
        soundOnBlocked = try c.decodeIfPresent(Bool.self, forKey: .soundOnBlocked) ?? false
        gridColumns = try c.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 2
        gridRows = try c.decodeIfPresent(Int.self, forKey: .gridRows) ?? 2
        terminalTheme = try c.decodeIfPresent(String.self, forKey: .terminalTheme) ?? Self.defaultTerminalTheme
        let decodedTerminalFontSize = try c.decodeIfPresent(Double.self, forKey: .terminalFontSize)
            ?? TerminalTheming.defaultFontSize(named: terminalTheme)
            ?? Self.defaultTerminalFontSize
        terminalFontSize = Self.clampedTerminalFontSize(decodedTerminalFontSize)
        hasOnboarded = try c.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? false
        notchHUD = try c.decodeIfPresent(Bool.self, forKey: .notchHUD) ?? true
    }

    static func clampedTerminalFontSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultTerminalFontSize }
        return min(max(size, terminalFontSizeRange.lowerBound), terminalFontSizeRange.upperBound)
    }
}
