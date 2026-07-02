import AppKit

/// The menu-bar glyph, drawn from Juggle's three-ball juggling logo.
///
/// Why a vector glyph instead of the raw PNG logo:
/// - The menu bar renders at ~18pt. The full-colour logo (grayscale checker
///   panels + stitching) turns to mush at that size and cannot adapt to a light
///   vs dark menu bar.
/// - A flat silhouette of the whole logo collapses into an undifferentiated
///   blob (the three balls merge), losing the identity entirely.
///
/// So we redraw the logo's *shape language* — three balls stacked 1-over-2, each
/// with the logo's carved "X" seam — as a template image. `isTemplate = true`
/// lets AppKit recolour it for light/dark automatically and lets
/// `contentTintColor` tint it in the accent when a terminal needs attention,
/// exactly like the old SF Symbol did.
enum StatusBarIcon {
    /// A template image sized for the menu bar (points; AppKit handles @2x).
    /// `filled` mirrors the old `square.grid.2x2` -> `.fill` attention swap by
    /// thickening the seams so the icon reads a touch heavier when tinted.
    static func image(filled: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawGlyph(in: rect, seamWidthScale: filled ? 0.075 : 0.05)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Juggle"
        return image
    }

    /// Draws the three-ball glyph in `rect`. Template images are evaluated as a
    /// mask, so only coverage (alpha) matters; AppKit tints the result.
    private static func drawGlyph(in rect: NSRect, seamWidthScale: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2
        let oy = rect.minY + (rect.height - s) / 2

        // Ball centres (y-up), matching the logo's 1-over-2 stack.
        let r = s * 0.235
        let balls = [
            CGPoint(x: ox + s * 0.50, y: oy + s * 0.665), // top
            CGPoint(x: ox + s * 0.305, y: oy + s * 0.335), // bottom-left
            CGPoint(x: ox + s * 0.695, y: oy + s * 0.335), // bottom-right
        ]

        NSColor.black.setFill() // template: colour is ignored, only coverage matters
        for c in balls {
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // Carve the logo's "X" seam out of each ball by clearing pixels, so the
        // seams read as the menu-bar background in both light and dark.
        ctx.setBlendMode(.clear)
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(1, s * seamWidthScale))
        for c in balls {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.clip()
            let d = r * 0.95
            ctx.move(to: CGPoint(x: c.x - d, y: c.y - d))
            ctx.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            ctx.move(to: CGPoint(x: c.x - d, y: c.y + d))
            ctx.addLine(to: CGPoint(x: c.x + d, y: c.y - d))
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setBlendMode(.normal)
    }
}
