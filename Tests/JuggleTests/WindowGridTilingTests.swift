import AppKit
import XCTest
@testable import Juggle

/// Measures `WindowGridManager` tiling cost at 8–16 windows. A counting
/// `NSWindow` subclass records `setFrame` passes so we can prove a no-op-slot
/// drag-settle can re-snap a single window (1 setFrame) instead of re-tiling
/// every window (N), while landing on the identical cell.
@MainActor
final class WindowGridTilingTests: XCTestCase {
    private let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func makeWindows(_ n: Int) -> [CountingWindow] {
        (0..<n).map { _ in CountingWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                    styleMask: .borderless, backing: .buffered, defer: false) }
    }

    func testFullTileSetFramesOncePerWindow() {
        for n in [8, 16] {
            let windows = makeWindows(n)
            let entries = windows.enumerated().map { (i, w) -> (slot: Int, window: NSWindow) in (i, w) }
            let grid = WindowGridManager()
            grid.gap = 12
            grid.tile(entries, columns: 4, rows: 2, on: NSScreen.main)

            let total = windows.reduce(0) { $0 + $1.setFrameCount }
            let perWindow = windows.map(\.setFrameCount)
            print("METRIC tile n=\(n) total_setFrames=\(total) per_window=\(perWindow)")
            XCTAssertEqual(total, n, "tile() setFrames each window exactly once")
            XCTAssertTrue(perWindow.allSatisfy { $0 == 1 })
        }
    }

    /// AFTER: a drag-settle whose target equals the window's current slot re-snaps
    /// only the dragged window (1 setFrame) onto the same cell a full tile would
    /// compute. Before this fix, `snapToGrid` called full `tileGrid()` (N setFrames).
    func testNoOpSlotSnapReSnapsOnlyTheDraggedWindow() {
        for n in [8, 16] {
            let windows = makeWindows(n)
            let entries: [(slot: Int, window: NSWindow)] = windows.enumerated().map { (i, w) in (i, w) }
            let grid = WindowGridManager()
            grid.gap = 12

            // Reference placement from a full tile, and how many setFrames it costs.
            grid.tile(entries, columns: 4, rows: 2, on: NSScreen.main)
            let fullTileCellOf0 = windows[0].frame
            let totalFull = windows.reduce(0) { $0 + $1.setFrameCount }
            windows.forEach { $0.resetCount() }

            // Simulated drag-settle with slot unchanged: snap only window 0.
            grid.snap(windows[0], slot: 0, among: entries, columns: 4, rows: 2, on: NSScreen.main)
            let totalSnap = windows.reduce(0) { $0 + $1.setFrameCount }
            let snapCellOf0 = windows[0].frame

            print("METRIC no-op_drag n=\(n) tile_setFrames=\(totalFull) snap_setFrames=\(totalSnap)")
            XCTAssertEqual(totalFull, n, "full tile: one setFrame per window")
            XCTAssertEqual(totalSnap, 1, "snap: one setFrame total (the dragged window only)")
            XCTAssertEqual(snapCellOf0, fullTileCellOf0, "geometry parity: snap lands on the full-tile cell")
        }
    }

    /// Bounds the pure CPU cost of `tile()`'s arithmetic (effectiveRows +
    /// cellFrame per entry), separate from the setFrame/display passes.
    func testTileArithmeticIsNegligibleAt16() {
        let grid = WindowGridManager()
        grid.gap = 12
        let slots = Array(0..<16)
        let iterations = 100_000
        let start = Date()
        for _ in 0..<iterations {
            let rows = grid.effectiveRows(2, columns: 4, maxSlot: slots.max() ?? 0)
            for slot in slots { _ = grid.cellFrame(slot: slot, columns: 4, rows: rows, in: screenFrame) }
        }
        let elapsed = Date().timeIntervalSince(start)
        let perTileUs = elapsed * 1_000_000 / Double(iterations)
        print("METRIC tile_arith n=16 iterations=\(iterations) per_tile_us=\(String(format: "%.2f", perTileUs))")
        XCTAssertLessThan(perTileUs, 50, "16-window tile arithmetic is sub-50µs (negligible vs setFrame)")
    }
}

/// Records how many times `setFrame(_:display:animate:)` is called and stores the
/// last applied rect, so a test can count layout passes and compare geometry.
final class CountingWindow: NSWindow {
    private(set) var setFrameCount = 0
    private var _lock = NSLock()
    func resetCount() { _lock.lock(); setFrameCount = 0; _lock.unlock() }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        _lock.lock(); setFrameCount += 1; _lock.unlock()
        super.setFrame(frameRect, display: flag, animate: animate)
    }
}
