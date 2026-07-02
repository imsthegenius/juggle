import XCTest
@testable import Juggle

/// R4 (jump to a terminal by repo) + R12 (the switcher echoes attention so a
/// blocked agent parked off-display is still catchable). Drives the pure model
/// (`SwitcherModel`) off the shared `AppModel`; the panel chrome is AppKit.
@MainActor
final class SwitcherTests: XCTestCase {
    private func resetSharedTerminals() {
        for terminal in AppModel.shared.openTerminals { AppModel.shared.removeTerminal(id: terminal.id) }
    }

    func testBlockedRowsSortFirst() {
        resetSharedTerminals()
        let model = AppModel.shared
        let calm = UUID(), blocked = UUID()
        model.registerTerminal(id: calm, projectId: "a", worktreeId: "a#0", title: "calm")
        model.registerTerminal(id: blocked, projectId: "b", worktreeId: "b#0", title: "needs you")
        model.updateTerminalAttention(id: blocked, .blocked)

        let switcher = SwitcherModel()
        XCTAssertEqual(switcher.rows.first?.id, blocked, "an attention-needing terminal floats to the top (R12)")
        XCTAssertEqual(switcher.selectedID, blocked, "selection lands on the most urgent row")
    }

    func testQueryFiltersByProjectAndTitle() {
        resetSharedTerminals()
        let model = AppModel.shared
        let one = UUID(), two = UUID()
        model.registerTerminal(id: one, projectId: "mission", worktreeId: "m#0", title: "vite dev")
        model.registerTerminal(id: two, projectId: "ledger", worktreeId: "l#0", title: "claude")

        let switcher = SwitcherModel()
        switcher.query = "claude"
        XCTAssertEqual(switcher.rows.map(\.id), [two], "filters to the matching title")

        switcher.query = "MISSION"
        XCTAssertEqual(switcher.rows.map(\.id), [one], "match is case-insensitive on project name")
    }

    func testActivateInvokesJumpWithSelectedID() {
        resetSharedTerminals()
        let id = UUID()
        AppModel.shared.registerTerminal(id: id, projectId: "a", worktreeId: "a#0", title: "only")

        let switcher = SwitcherModel()
        var jumped: UUID?
        switcher.onActivate = { jumped = $0 }
        switcher.activateSelection()
        XCTAssertEqual(jumped, id, "↩ jumps to the selected terminal (R4)")
    }

    func testArrowMovementClampsWithinBounds() {
        resetSharedTerminals()
        let model = AppModel.shared
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            model.registerTerminal(id: id, projectId: "p\(i)", worktreeId: "p\(i)#0", title: "t\(i)")
        }
        let switcher = SwitcherModel()
        switcher.move(-1)   // already at top
        XCTAssertEqual(switcher.selectedID, switcher.rows.first?.id, "↑ at the top stays put")
        switcher.move(99)   // past the end
        XCTAssertEqual(switcher.selectedID, switcher.rows.last?.id, "↓ clamps at the last row")
    }
}
