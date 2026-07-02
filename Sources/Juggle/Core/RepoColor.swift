import AppKit

/// A repo's identity color. Identity is the hue; attention (U6) is expressed as
/// behavior on top of the same hue, never a competing palette.
struct RepoColor: Hashable, Codable {
    let name: String
    let hex: String

    var nsColor: NSColor { NSColor(hex: hex) ?? .systemTeal }

    /// A curated, accessible palette. One accent per repo; high enough chroma to
    /// read at a glance on both light and dark window chrome.
    static let palette: [RepoColor] = [
        RepoColor(name: "Teal", hex: "#20C7CE"),
        RepoColor(name: "Coral", hex: "#FF6B5B"),
        RepoColor(name: "Iris", hex: "#6E8BFF"),
        RepoColor(name: "Lime", hex: "#7BD950"),
        RepoColor(name: "Amber", hex: "#F2A43A"),
        RepoColor(name: "Rose", hex: "#F25C8A"),
        RepoColor(name: "Sky", hex: "#36B5F2"),
        RepoColor(name: "Violet", hex: "#A977F0"),
        RepoColor(name: "Mint", hex: "#3FD4A0"),
        RepoColor(name: "Sand", hex: "#D9B23F"),
    ]

    /// Deterministic, launch-stable assignment by key. Uses FNV-1a rather than
    /// `hashValue` (which is per-process randomized and would re-color repos on
    /// every launch). A user override persists separately (U3 store).
    static func assign(forKey key: String) -> RepoColor {
        palette[Int(fnv1a(key) % UInt64(palette.count))]
    }

    static func named(_ name: String) -> RepoColor? {
        palette.first { $0.name == name }
    }

    /// Resolve a stored color string — either a palette name (e.g. "Teal") or a
    /// `#RRGGBB` custom hex from the color wheel — to a concrete color.
    static func nsColor(for stored: String?) -> NSColor {
        guard let stored, !stored.isEmpty else { return palette[0].nsColor }
        if stored.hasPrefix("#") { return NSColor(hex: stored) ?? palette[0].nsColor }
        return named(stored)?.nsColor ?? NSColor(hex: stored) ?? palette[0].nsColor
    }

    /// A worktree shade of this hue. Level 0 is the base; positive lightens,
    /// negative darkens, so a project's worktrees stay in one color family.
    func shaded(_ level: Int) -> NSColor {
        let base = nsColor
        guard level != 0 else { return base }
        let fraction = min(0.5, CGFloat(abs(level)) * 0.20)
        return base.blended(withFraction: fraction, of: level > 0 ? .white : .black) ?? base
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
