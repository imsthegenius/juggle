import AppKit
import SwiftUI
import XCTest
@testable import Juggle

/// The notch HUD's aggregation is the owner's headline ask: surface what needs
/// the user — PR ready, blocked, error, done — across every project, ambiently.
/// `computeItems` is pure, so we test the policy without AppKit windows.
@MainActor
final class NotchHUDTests: XCTestCase {
    private func project(_ id: String, color: String, worktreePath: String, worktreeId: String) -> Project {
        let wt = Worktree(id: worktreeId, projectId: id, branch: "main", path: worktreePath, shade: 0, isPrimary: true)
        return Project(id: id, displayName: id, rootPath: id, colorName: color, worktrees: [wt])
    }

    private func terminal(_ id: UUID, project: String, worktree: String, _ state: AttentionState) -> OpenTerminal {
        OpenTerminal(id: id, projectId: project, worktreeId: worktree, title: "t", attention: state)
    }

    func testWorkingAndCommandFinishedAreFilteredOut() {
        let p = project("p", color: "Teal", worktreePath: "/p", worktreeId: "p#0")
        let items = NotchHUDModel.computeItems(
            terminals: [
                terminal(UUID(), project: "p", worktree: "p#0", .working),
                terminal(UUID(), project: "p", worktree: "p#0", .commandFinished),
            ],
            projects: [p], prReadyPaths: []
        )
        XCTAssertTrue(items.isEmpty, "only blocked/error/done/PR-ready want the user in the HUD")
    }

    func testIdleDotsShowOpenProjectsWithoutFalseAttention() {
        let projects = [
            project("juggle", color: "Violet", worktreePath: "/juggle", worktreeId: "j#0"),
            project("email", color: "Rose", worktreePath: "/email", worktreeId: "e#0"),
        ]
        let terminals = [
            terminal(UUID(), project: "juggle", worktree: "j#0", .working),
            terminal(UUID(), project: "email", worktree: "e#0", .working),
        ]
        XCTAssertTrue(NotchHUDModel.computeItems(terminals: terminals, projects: projects, prReadyPaths: []).isEmpty,
                      "working terminals are not alerts")

        let dots = NotchHUDModel.computeIdleDots(terminals: terminals, projects: projects)
        XCTAssertEqual(dots.count, 2, "but the dormant notch node still shows one dot per open project")
        XCTAssertTrue(dots.allSatisfy { !$0.active }, "idle dots do not breathe or imply urgency")
    }

    func testPRReadyTakesPrecedenceOverAgentState() {
        let p = project("p", color: "Teal", worktreePath: "/p", worktreeId: "p#0")
        let id = UUID()
        let status = PRStatus(availability: .available, number: 42, headOid: "abc", summary: "Merge",
                              additions: 144, deletions: 0, title: "Polish notch HUD",
                              url: "https://example.com/pr/42", headRefName: "feat/notch")
        let items = NotchHUDModel.computeItems(
            terminals: [terminal(id, project: "p", worktree: "p#0", .blocked)],
            projects: [p], prStatusesByPath: ["/p": status]
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.reason, .prReady, "a green PR is the most actionable thing, it wins the row")
        XCTAssertEqual(items.first?.activateTerminalId, id, "the row still jumps to the terminal")
        XCTAssertEqual(items.first?.detail, "#42 · Polish notch HUD")
        XCTAssertEqual(items.first?.meta, "feat/notch · +144 −0")
    }

    func testPRReadyAppearsWithoutOpenTerminal() {
        let p = project("p", color: "Teal", worktreePath: "/p", worktreeId: "p#0")
        let status = PRStatus(availability: .available, number: 42, headOid: "abc", summary: "Merge",
                              additions: 8, deletions: 1, title: "Ready while closed",
                              url: nil, headRefName: "feat/closed")
        let items = NotchHUDModel.computeItems(terminals: [], projects: [p], prStatusesByPath: ["/p": status])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.reason, .prReady)
        XCTAssertEqual(items.first?.activateTerminalId, nil)
        XCTAssertEqual(items.first?.primaryAction, .mergePR)
    }

    func testUrgencySortPRThenBlockedThenErrorThenDone() {
        let projects = [
            project("a", color: "Teal", worktreePath: "/a", worktreeId: "a#0"),
            project("b", color: "Coral", worktreePath: "/b", worktreeId: "b#0"),
            project("c", color: "Iris", worktreePath: "/c", worktreeId: "c#0"),
            project("d", color: "Lime", worktreePath: "/d", worktreeId: "d#0"),
        ]
        let items = NotchHUDModel.computeItems(
            terminals: [
                terminal(UUID(), project: "d", worktree: "d#0", .done),
                terminal(UUID(), project: "c", worktree: "c#0", .error),
                terminal(UUID(), project: "b", worktree: "b#0", .blocked),
                terminal(UUID(), project: "a", worktree: "a#0", .working),   // becomes PR-ready below
            ],
            projects: projects,
            prStatusesByPath: [
                "/a": PRStatus(availability: .available, number: 7, headOid: "abc", summary: "Merge")
            ]
        )
        XCTAssertEqual(items.map(\.reason), [.prReady, .blocked, .error, .done],
                       "most actionable first: PR ready → blocked → error → done")
    }

    func testItemUsesWorktreeColorOverrideThenProjectColor() {
        var p = project("p", color: "Teal", worktreePath: "/p", worktreeId: "p#0")
        p.worktrees[0].colorName = "Coral"
        let items = NotchHUDModel.computeItems(
            terminals: [terminal(UUID(), project: "p", worktree: "p#0", .blocked)],
            projects: [p], prReadyPaths: []
        )
        XCTAssertEqual(items.first?.color.hexString.uppercased(),
                       RepoColor.nsColor(for: "Coral").hexString.uppercased(),
                       "the worktree's own colour identifies the row when set")
    }

    func testReasonOrderingIsByUrgencyRawValue() {
        XCTAssertLessThan(HUDReason.prReady, HUDReason.blocked)
        XCTAssertLessThan(HUDReason.blocked, HUDReason.error)
        XCTAssertLessThan(HUDReason.error, HUDReason.done)
    }

    func testNodeAlwaysVisibleSoOpeningTheAppNeverFeelsDead() {
        // The "I opened the app and nothing happened" report: a fresh model with
        // no projects, no terminals, no PRs must still present the ambient node.
        let model = NotchHUDModel()
        XCTAssertTrue(model.shouldShow, "the node is the app's ambient presence and is always visible")
    }

    func testHoverStillExpandsTheEmptyStateNode() {
        // Even with nothing to act on, hovering must reveal the (empty-state or
        // all-clear) detail — otherwise the node looks inert on first run.
        let model = NotchHUDModel()
        model.hoverChanged(true)
        XCTAssertTrue(model.expanded, "hovering an empty node still expands to show guidance")
    }

    func testEmptyStateSeedShowsFirstRunNodeNotAllClear() {
        // The no-repo first run must render the "Open Project" node, not the
        // calm "All clear" node. `hasProjects` is what the view branches on
        // (empty-state vs all-clear), so pin it false under the empty seed —
        // independent of whatever projects the shared AppModel happens to hold.
        let model = NotchHUDModel()
        model.seedEmptyForPreview()
        XCTAssertFalse(model.hasProjects, "no registered projects → first-run empty state, never all-clear")
        XCTAssertFalse(model.hasItems, "the empty state has nothing to act on")
    }

    func testHoverExpandsAndLeavingCollapsesAfterDebounce() async throws {
        let model = NotchHUDModel()
        model.seedForPreview([
            previewItem(project: "juggle", reason: .prReady, detail: "#7 · Ready", meta: "feat/x · +4 −1"),
        ])

        model.hoverChanged(true)
        XCTAssertTrue(model.expanded, "hovering the top island should reveal detail without a click")

        model.hoverChanged(false)
        try await Task.sleep(nanoseconds: 420_000_000)
        XCTAssertFalse(model.expanded, "leaving the island should dismiss it after a short grace period")
    }

    func testHoverOutCollapseIsCancelledByReentry() async throws {
        let model = NotchHUDModel()
        model.seedForPreview([
            previewItem(project: "juggle", reason: .blocked, detail: "waiting", meta: nil),
        ])

        model.hoverChanged(true)
        model.hoverChanged(false)
        model.hoverChanged(true)
        try await Task.sleep(nanoseconds: 420_000_000)
        XCTAssertTrue(model.expanded, "quick re-entry should cancel the pending hover-out collapse")
    }

    func testRequestMergeMarksRowAndCallsHostOnce() {
        let model = NotchHUDModel()
        let item = mergeItem(project: "juggle")
        var requested: [NeedsYouItem] = []
        model.onMerge = { requested.append($0) }

        model.requestMerge(item)
        model.requestMerge(item)

        XCTAssertEqual(requested.map(\.id), [item.id], "repeat taps while checking should not enqueue duplicate merges")
        XCTAssertTrue(model.checkingItemIDs.contains(item.id), "the row flips to Checking while the fresh preflight runs")

        model.mergeFinished(item)
        XCTAssertFalse(model.checkingItemIDs.contains(item.id), "failed merges clear the transient row state for retry")
    }

    func testPanelClickRouterOpensPRBodyAndRequestsMergeButton() {
        let model = NotchHUDModel()
        let item = mergeItem(project: "juggle")
        model.seedForPreview([item])
        model.expanded = true
        seedPanelFrames(model, item: item)
        let bounds = NSRect(x: 0, y: 0, width: 392, height: 101)
        var opened: [NeedsYouItem] = []
        var merged: [NeedsYouItem] = []
        model.onOpenPR = { opened.append($0) }
        model.onMerge = { merged.append($0) }

        let rowBodyPoint = NSPoint(x: 92, y: 58)
        let mergePoint = NSPoint(x: 345, y: 58)

        XCTAssertTrue(model.shouldHandlePanelClick(at: rowBodyPoint, in: bounds))
        XCTAssertTrue(model.handlePanelClick(from: rowBodyPoint, to: rowBodyPoint, in: bounds))
        XCTAssertEqual(opened.map(\.id), [item.id], "clicking the PR row body opens the PR")
        XCTAssertTrue(merged.isEmpty, "the row body must not merge")

        XCTAssertTrue(model.handlePanelClick(from: mergePoint, to: mergePoint, in: bounds))
        XCTAssertEqual(merged.map(\.id), [item.id], "clicking the trailing Merge chip requests the inline merge")
    }

    func testPanelClickRouterDoesNotMergeWhenMouseUpMovesToMergeButton() {
        let model = NotchHUDModel()
        let item = mergeItem(project: "juggle")
        model.seedForPreview([item])
        model.expanded = true
        seedPanelFrames(model, item: item)
        let bounds = NSRect(x: 0, y: 0, width: 392, height: 101)
        var opened: [NeedsYouItem] = []
        var merged: [NeedsYouItem] = []
        model.onOpenPR = { opened.append($0) }
        model.onMerge = { merged.append($0) }

        XCTAssertFalse(model.handlePanelClick(
            from: NSPoint(x: 92, y: 58),
            to: NSPoint(x: 345, y: 58),
            in: bounds
        ))

        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(merged.isEmpty, "inline merge requires the mouse-down and mouse-up to stay on the Merge chip")
    }

    func testPanelClickRouterKeepsMergeHitInsideVisibleCapsule() {
        let model = NotchHUDModel()
        let item = mergeItem(project: "juggle")
        model.seedForPreview([item])
        model.expanded = true
        seedPanelFrames(model, item: item)
        let bounds = NSRect(x: 0, y: 0, width: 392, height: 101)
        var opened: [NeedsYouItem] = []
        var merged: [NeedsYouItem] = []
        model.onOpenPR = { opened.append($0) }
        model.onMerge = { merged.append($0) }

        let trailingWhitespace = NSPoint(x: 379, y: 58)
        XCTAssertTrue(model.handlePanelClick(from: trailingWhitespace, to: trailingWhitespace, in: bounds))

        XCTAssertEqual(opened.map(\.id), [item.id], "trailing row whitespace still opens the PR/review target")
        XCTAssertTrue(merged.isEmpty, "only the visible Merge capsule may trigger the unconfirmed inline merge")
    }

    func testPanelClickRouterDoesNotRouteOverflowFooterToLastVisibleRow() {
        let model = NotchHUDModel()
        let one = mergeItem(project: "one")
        let two = mergeItem(project: "two")
        let three = mergeItem(project: "three")
        let four = mergeItem(project: "four")
        model.seedForPreview([one, two, three, four])
        model.expanded = true
        seedPanelFrames(model, item: one, row: NSRect(x: 12, y: 36, width: 368, height: 50))
        seedPanelFrames(model, item: two, row: NSRect(x: 12, y: 89, width: 368, height: 40))
        seedPanelFrames(model, item: three, row: NSRect(x: 12, y: 132, width: 368, height: 36))
        let bounds = NSRect(x: 0, y: 0, width: 392, height: 190)
        let footerPoint = NSPoint(x: 32, y: 180)
        var opened: [NeedsYouItem] = []
        var merged: [NeedsYouItem] = []
        model.onOpenPR = { opened.append($0) }
        model.onMerge = { merged.append($0) }

        XCTAssertFalse(model.shouldHandlePanelClick(at: footerPoint, in: bounds))
        XCTAssertFalse(model.handlePanelClick(from: footerPoint, to: footerPoint, in: bounds))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(merged.isEmpty, "overflow footer space must not activate the third visible row")
    }

    func testPanelClickRouterUsesMeasuredUnequalRowFrames() {
        let model = NotchHUDModel()
        let pr = mergeItem(project: "one")
        let blocked = previewItem(project: "two", reason: .blocked, detail: "waiting", meta: nil)
        model.seedForPreview([pr, blocked])
        model.expanded = true
        seedPanelFrames(model, item: pr, row: NSRect(x: 12, y: 36, width: 368, height: 58))
        seedPanelFrames(model, item: blocked, row: NSRect(x: 12, y: 97, width: 368, height: 34))
        let bounds = NSRect(x: 0, y: 0, width: 392, height: 148)
        var activated: [NeedsYouItem] = []
        var merged: [NeedsYouItem] = []
        model.onActivate = { activated.append($0) }
        model.onMerge = { merged.append($0) }

        XCTAssertTrue(model.handlePanelClick(from: NSPoint(x: 92, y: 104), to: NSPoint(x: 92, y: 104), in: bounds))

        XCTAssertEqual(activated.map(\.id), [blocked.id], "clicks use the measured SwiftUI row frame, not equal-height slices")
        XCTAssertTrue(merged.isEmpty)
    }

    func testPanelClickRouterHeaderSearchOpensSwitcherAndCloseCollapses() {
        let model = NotchHUDModel()
        model.seedForPreview([mergeItem(project: "juggle")])
        model.expanded = true
        let bounds = NSRect(x: 0, y: 0, width: 392, height: 101)
        var switcherOpens = 0
        model.onOpenSwitcher = { switcherOpens += 1 }

        XCTAssertTrue(model.handlePanelClick(from: NSPoint(x: 320, y: 15), to: NSPoint(x: 320, y: 15), in: bounds))
        XCTAssertEqual(switcherOpens, 1, "the visible magnifying-glass header affordance opens the switcher")
        XCTAssertTrue(model.expanded)

        XCTAssertTrue(model.handlePanelClick(from: NSPoint(x: 360, y: 15), to: NSPoint(x: 360, y: 15), in: bounds))
        XCTAssertFalse(model.expanded, "the visible x affordance collapses the HUD")
    }

    func testPanelClickRouterExpandsCollapsedNub() {
        let model = NotchHUDModel()
        model.seedForPreview([mergeItem(project: "juggle")])
        let bounds = NSRect(x: 0, y: 0, width: 72, height: 16)

        XCTAssertTrue(model.handlePanelClick(at: NSPoint(x: 36, y: 8), in: bounds))

        XCTAssertTrue(model.expanded, "the collapsed notch node expands from the AppKit click router")
    }

    func testHostAcceptsFirstMouseForNotchPanel() {
        let hosting = FirstMouseHostingView(
            rootView: Color.clear
                .allowsHitTesting(false)
                .frame(width: 80, height: 60)
        )

        XCTAssertTrue(hosting.acceptsFirstMouse(for: nil),
                      "the notch panel must deliver the first click to SwiftUI controls")
    }

    func testPRArrivalIDsIgnoreInitialBaseline() {
        let pr = previewItem(project: "juggle", reason: .prReady, detail: "#7 · Ready", meta: "feat/x · +4 −1")

        let arrivals = NotchHUDModel.prArrivalIDs(previous: [], next: [pr], baselineEstablished: false)

        XCTAssertTrue(arrivals.isEmpty, "existing ready PRs at launch should not do the arrival flourish")
    }

    func testPRArrivalIDsOnlyMarkNewReadyPRs() {
        let existing = previewItem(project: "juggle", reason: .prReady, detail: "#7 · Ready", meta: "feat/x · +4 −1")
        let new = previewItem(project: "mission-control", reason: .prReady, detail: "#42 · Ready", meta: "feat/y · +8 −1")
        let blocked = previewItem(project: "email", reason: .blocked, detail: "approval", meta: nil)

        let arrivals = NotchHUDModel.prArrivalIDs(previous: [existing], next: [existing, new, blocked], baselineEstablished: true)

        XCTAssertEqual(arrivals, [new.id], "only a newly-ready PR gets the one-shot arrival flourish")
    }

    private func previewItem(project: String, reason: HUDReason, detail: String?, meta: String?) -> NeedsYouItem {
        NeedsYouItem(
            id: "preview:\(project):\(reason)",
            projectId: "/preview/\(project)",
            worktreeId: "/preview/\(project)#0",
            worktreePath: "/preview/\(project)",
            branch: "main",
            projectName: project,
            color: .systemPurple,
            reason: reason,
            detail: detail,
            meta: meta,
            activateTerminalId: UUID(),
            primaryAction: .jumpToTerminal,
            prURL: nil
        )
    }

    private func mergeItem(project: String) -> NeedsYouItem {
        NeedsYouItem(
            id: "preview:\(project):merge",
            projectId: "/preview/\(project)",
            worktreeId: "/preview/\(project)#0",
            worktreePath: "/preview/\(project)",
            branch: "main",
            projectName: project,
            color: .systemPurple,
            reason: .prReady,
            detail: "#7 · Ready",
            meta: "feat/x · +4 −1",
            activateTerminalId: nil,
            primaryAction: .mergePR,
            prURL: "https://example.com/pr/7"
        )
    }

    private func seedPanelFrames(
        _ model: NotchHUDModel,
        item: NeedsYouItem,
        row: NSRect = NSRect(x: 12, y: 36, width: 368, height: 59),
        merge: NSRect? = NSRect(x: 318, y: 51, width: 60, height: 28)
    ) {
        model.updatePanelRowFrame(itemID: item.id, frame: row)
        if let merge {
            model.updatePanelMergeButtonFrame(itemID: item.id, frame: merge)
        }
    }
}

/// The HUD is opt-out via a persisted preference (on by default), and older
/// stores without the key still decode to on.
final class NotchHUDPreferenceTests: XCTestCase {
    func testDefaultsOn() {
        XCTAssertTrue(Preferences().notchHUD, "the ambient strip is on by default")
    }

    func testOlderStoreWithoutKeyDefaultsOn() throws {
        let json = Data(#"{"titlebarTint":0.5,"gridColumns":2,"gridRows":2,"terminalTheme":"Dracula","terminalFontSize":13}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertTrue(prefs.notchHUD, "a store predating the HUD still shows it")
    }

    func testRoundTripsWhenDisabled() throws {
        var prefs = Preferences()
        prefs.notchHUD = false
        let data = try JSONEncoder().encode(prefs)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: data).notchHUD)
    }
}
