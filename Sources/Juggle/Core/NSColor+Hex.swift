import AppKit

extension NSColor {
    /// Parses `#RRGGBB` / `#RRGGBBAA` (with or without the leading `#`).
    convenience init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8,
              let value = UInt64(raw, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if raw.count == 6 {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        } else {
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255
            a = CGFloat(value & 0x0000_00FF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB` for persisting a custom (color-wheel) choice.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// The hue (0…1), converting to a calibrated RGB space first so catalog or
    /// pattern colours can't throw when `hueComponent` is read. Used to seed the
    /// inline hue slider from whatever colour a worktree currently shows.
    var hueComponentSafe: CGFloat {
        (usingColorSpace(.sRGB) ?? self).hueComponent
    }

    /// Lighten (level > 0) or darken (level < 0) toward white/black. Mirrors
    /// `RepoColor.shaded` so an arbitrary custom base shades the same way the
    /// palette hues do, keeping a project's worktrees in one color family.
    func shadedRepo(_ level: Int) -> NSColor {
        guard level != 0 else { return self }
        let fraction = min(0.5, CGFloat(abs(level)) * 0.20)
        return blended(withFraction: fraction, of: level > 0 ? .white : .black) ?? self
    }
}
