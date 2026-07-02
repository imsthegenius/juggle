import XCTest
@testable import Juggle

final class NeedsYouQueueTests: XCTestCase {
    private func project(
        id: String = "/repos/mission-control",
        name: String = "mission-control",
        color: String = "cyan",
        worktrees: [Worktree]
    ) -> Project {
        Project(id: id, displayName: name, rootPath: id, colorName: color, worktrees: worktrees)
    }

    private func worktree(
        _ branch: String,
        path: String,
        projectId: String = "/repos/mission-control",
        primary: Bool = false
    ) -> Worktree {
        Worktree(id: "\(projectId)#\(branch)", projectId: projectId, branch: branch, path: path, shade: 0, isPrimary: primary)
    }

    func testPRReadyWorktreeAppearsEvenWithoutOpenTerminal() {
        let feature = worktree("feat/merge-readiness", path: "/repos/mission-control/.worktrees/feat")
        let project = project(worktrees: [
            worktree("", path: "/repos/mission-control", primary: true),
            feature
        ])
        let status = PRStatus(availability: .available, number: 42, headOid: "abc", summary: "Merge",
                              additions: 144, deletions: 0, title: "Add scoped merge checks",
                              url: "https://github.com/example/repo/pull/42", headRefName: "feat/merge-readiness")

        let items = NeedsYouQueue.compute(
            projects: [project],
            terminals: [],
            prStatusesByPath: [feature.path: status]
        )

        XCTAssertEqual(items.map(\.reason), [.prReady])
        XCTAssertEqual(items.first?.projectName, "mission-control")
        XCTAssertEqual(items.first?.worktreeId, feature.id)
        XCTAssertEqual(items.first?.activateTerminalId, nil)
        XCTAssertEqual(items.first?.primaryAction, .mergePR)
        XCTAssertEqual(items.first?.detail, "#42 · Add scoped merge checks")
        XCTAssertEqual(items.first?.meta, "feat/merge-readiness · +144 −0")
    }

    func testQueueSortsPRsBeforeBlockedAgentsAndDeduplicatesSameWorktree() {
        let projectId = "/repos/mission-control"
        let feature = worktree("feat/merge-readiness", path: "/repos/mission-control/.worktrees/feat", projectId: projectId)
        let project = project(id: projectId, name: "mission-control", color: "cyan", worktrees: [feature])
        let terminalId = UUID()
        let terminal = OpenTerminal(id: terminalId, projectId: projectId, worktreeId: feature.id,
                                    title: "Agent is waiting for approval", attention: .blocked)
        let status = PRStatus(availability: .available, number: 42, headOid: "abc", summary: "Merge",
                              additions: 12, deletions: 2, title: "Ship queue", url: nil,
                              headRefName: "feat/merge-readiness")

        let items = NeedsYouQueue.compute(
            projects: [project],
            terminals: [terminal],
            prStatusesByPath: [feature.path: status]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.reason, .prReady)
        XCTAssertEqual(items.first?.activateTerminalId, terminalId)
        XCTAssertEqual(items.first?.primaryAction, .mergePR)
    }

    func testBlockedTerminalFallsBackToJumpActionWhenNoPRReady() {
        let projectId = "/repos/api-service"
        let main = worktree("", path: projectId, projectId: projectId, primary: true)
        let project = project(id: projectId, name: "api-service", color: "pink", worktrees: [main])
        let terminalId = UUID()
        let terminal = OpenTerminal(id: terminalId, projectId: projectId, worktreeId: main.id,
                                    title: "Agent needs approval", attention: .blocked)

        let items = NeedsYouQueue.compute(projects: [project], terminals: [terminal], prStatusesByPath: [:])

        XCTAssertEqual(items.map(\.reason), [.blocked])
        XCTAssertEqual(items.first?.activateTerminalId, terminalId)
        XCTAssertEqual(items.first?.primaryAction, .jumpToTerminal)
        XCTAssertEqual(items.first?.detail, "Agent needs approval")
    }

    func testNonMergeablePRStatusAppearsAsReviewBlockerNotMergeRow() {
        let feature = worktree("feat/merge-readiness", path: "/repos/mission-control/.worktrees/feat")
        let project = project(worktrees: [feature])
        let status = PRStatus(availability: .behind, number: 42, headOid: "abc", summary: "Behind base",
                              additions: 12, deletions: 2, title: "Ship queue",
                              url: "https://github.com/example/repo/pull/42", headRefName: "feat/merge-readiness")

        let items = NeedsYouQueue.compute(
            projects: [project],
            terminals: [],
            prStatusesByPath: [feature.path: status]
        )

        XCTAssertEqual(items.map(\.reason), [.blocked])
        XCTAssertEqual(items.first?.primaryAction, .openPR)
        XCTAssertEqual(items.first?.detail, "#42 · Behind base")
    }
}
