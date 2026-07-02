import AppKit

/// A snap-to-grid workspace. The screen is divided into a `columns` x `rows`
/// grid of cells; each window occupies a slot (cell index). Rows grow beyond the
/// chosen `rows` if there are more windows than base cells, so nothing is hidden.
@MainActor
final class WindowGridManager {
    var gap: CGFloat = 12

    /// Place each (slot, window) into its grid cell on the given screen.
    func tile(_ entries: [(slot: Int, window: NSWindow)], columns: Int, rows: Int, on screen: NSScreen?) {
        guard !entries.isEmpty, let screen = screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let cols = max(1, columns)
        let effectiveRows = effectiveRows(rows, columns: cols, maxSlot: entries.map(\.slot).max() ?? 0)
        for entry in entries {
            entry.window.setFrame(
                cellFrame(slot: entry.slot, columns: cols, rows: effectiveRows, in: frame),
                display: true, animate: false
            )
        }
    }

    /// Rows actually used: at least the chosen rows, more if the highest slot
    /// needs them.
    func effectiveRows(_ rows: Int, columns: Int, maxSlot: Int) -> Int {
        let needed = Int(ceil(Double(maxSlot + 1) / Double(max(1, columns))))
        return max(max(1, rows), needed)
    }

    func cellFrame(slot: Int, columns: Int, rows: Int, in frame: NSRect) -> NSRect {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let column = slot % columns
        let row = slot / columns
        let cellWidth = (frame.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (frame.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        let x = frame.minX + gap + CGFloat(column) * (cellWidth + gap)
        let y = frame.maxY - CGFloat(row + 1) * cellHeight - CGFloat(row + 1) * gap
        return NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
    }

    /// The slot whose cell contains (or is nearest to) a point — used for snap.
    func nearestSlot(to point: NSPoint, columns: Int, rows: Int, in frame: NSRect) -> Int {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let column = min(columns - 1, max(0, Int((point.x - frame.minX) / (frame.width / CGFloat(columns)))))
        let row = min(rows - 1, max(0, Int((frame.maxY - point.y) / (frame.height / CGFloat(rows)))))
        return row * columns + column
    }

    /// Re-snap a single window into its cell, using the same geometry `tile`
    /// would compute for it in the full arrangement (same `effectiveRows` derived
    /// from the entries' max slot). Use after a drag that didn't change the
    /// window's slot: one `setFrame` instead of re-tiling every window. The
    /// resulting rect is identical to `tile([..., (slot, window)])` for that entry.
    func snap(_ window: NSWindow, slot: Int, among entries: [(slot: Int, window: NSWindow)],
              columns: Int, rows: Int, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let cols = max(1, columns)
        let effectiveRows = effectiveRows(rows, columns: cols, maxSlot: entries.map(\.slot).max() ?? 0)
        window.setFrame(
            cellFrame(slot: slot, columns: cols, rows: effectiveRows, in: screen.visibleFrame),
            display: true, animate: false
        )
    }
}
