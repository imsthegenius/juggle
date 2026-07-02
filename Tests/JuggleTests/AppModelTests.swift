import Foundation
import Combine
import os
import XCTest
@testable import Juggle

final class AppModelTests: XCTestCase {
    private struct LegacyWorkspace: Codable {
        var projects: [Project]
        var preferences: Preferences
        var openWindows: [OpenWindowState]?
    }

    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("juggle-test-\(UUID().uuidString).json")
    }

    private func tempProjectRoot(_ name: String, in base: URL) -> String {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func projectFixture(id: String, name: String) -> Project {
        let worktree = Worktree(id: "\(id)#0", projectId: id, branch: "main", path: id, shade: 0, isPrimary: true)
        return Project(id: id, displayName: name, rootPath: id, colorName: "Teal", worktrees: [worktree])
    }

    @MainActor
    func testPersistenceRoundTrip() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let model = AppModel(storeURL: store)
        let project = model.addProject(atRoot: FileManager.default.temporaryDirectory.path)
        model.rename(projectId: project.id, to: "My Project")
        model.recolor(projectId: project.id, colorName: "Coral")

        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.projects.first?.displayName, "My Project")
        XCTAssertEqual(model.projects.first?.colorName, "Coral")

        let reloaded = AppModel(storeURL: store)
        reloaded.load()
        XCTAssertEqual(reloaded.projects.first?.displayName, "My Project")
        XCTAssertEqual(reloaded.projects.first?.colorName, "Coral")
    }

    @MainActor
    func testAddProjectDeduplicatesByRoot() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let model = AppModel(storeURL: store)
        let root = FileManager.default.temporaryDirectory.path
        _ = model.addProject(atRoot: root)
        _ = model.addProject(atRoot: root)
        XCTAssertEqual(model.projects.count, 1, "the same root is not registered twice")
    }

    @MainActor
    func testOpeningProjectSetsActiveScopeWithoutDeletingSavedProjects() {
        let store = tempStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("juggle-scope-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: base)
        }

        let model = AppModel(storeURL: store)
        let first = model.addProject(atRoot: tempProjectRoot("alpha", in: base))
        let second = model.addProject(atRoot: tempProjectRoot("bravo", in: base))

        XCTAssertEqual(model.projects.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.activeProjectId, second.id, "opening a project makes it the default visible scope")
        XCTAssertEqual(model.visibleProjects.map(\.id), [second.id])

        let firstTerminal = UUID()
        let secondTerminal = UUID()
        model.registerTerminal(id: firstTerminal, projectId: first.id, worktreeId: first.primaryWorktree!.id, title: "alpha")
        model.registerTerminal(id: secondTerminal, projectId: second.id, worktreeId: second.primaryWorktree!.id, title: "bravo")
        XCTAssertEqual(model.visibleOpenTerminals.map(\.id), [secondTerminal])

        model.showAllProjects()
        XCTAssertNil(model.activeProjectId, "All projects is an explicit scope")
        XCTAssertEqual(model.visibleProjects.map(\.id), [first.id, second.id])
        XCTAssertEqual(Set(model.visibleOpenTerminals.map(\.id)), Set([firstTerminal, secondTerminal]))

        model.setActiveProject(first.id)
        XCTAssertEqual(model.visibleProjects.map(\.id), [first.id])
        XCTAssertEqual(model.projects.map(\.id), [first.id, second.id], "saved projects are preserved")

        let reloaded = AppModel(storeURL: store)
        reloaded.load()
        XCTAssertEqual(reloaded.projects.map(\.id), [first.id, second.id])
        XCTAssertEqual(reloaded.activeProjectId, first.id)
        XCTAssertEqual(reloaded.visibleProjects.map(\.id), [first.id])
    }

    @MainActor
    func testActiveScopeFiltersStaleTerminalsEvenWhenOnlyOneProjectIsSaved() {
        let store = tempStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("juggle-single-scope-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: base)
        }

        let model = AppModel(storeURL: store)
        let project = model.addProject(atRoot: tempProjectRoot("solo", in: base))
        let visible = UUID()
        let stale = UUID()
        model.registerTerminal(id: visible, projectId: project.id, worktreeId: project.primaryWorktree!.id, title: "visible")
        model.registerTerminal(id: stale, projectId: "removed", worktreeId: "removed#0", title: "stale")

        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.activeProjectId, project.id)
        XCTAssertEqual(model.visibleOpenTerminals.map(\.id), [visible])
    }

    @MainActor
    func testOlderMultiProjectStoreWithoutActiveScopeLoadsAsExplicitAllProjects() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let first = projectFixture(id: "/tmp/juggle-alpha-\(UUID().uuidString)", name: "alpha")
        let second = projectFixture(id: "/tmp/juggle-bravo-\(UUID().uuidString)", name: "bravo")
        let legacy = LegacyWorkspace(projects: [first, second], preferences: Preferences(), openWindows: nil)
        try JSONEncoder().encode(legacy).write(to: store)

        let model = AppModel(storeURL: store)
        model.load()

        XCTAssertNil(model.activeProjectId)
        XCTAssertEqual(model.visibleProjects.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.scopeTitle, "All projects")
    }

    @MainActor
    func testOpeningSavedProjectWindowFromAllProjectsMakesThatProjectActive() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let first = projectFixture(id: "/tmp/juggle-alpha-\(UUID().uuidString)", name: "alpha")
        let second = projectFixture(id: "/tmp/juggle-bravo-\(UUID().uuidString)", name: "bravo")
        let legacy = LegacyWorkspace(projects: [first, second], preferences: Preferences(), openWindows: nil)
        try JSONEncoder().encode(legacy).write(to: store)

        let model = AppModel(storeURL: store)
        model.load()
        XCTAssertNil(model.activeProjectId)

        var opened: SessionContext?
        model.onOpenWindow = { opened = $0 }
        model.openWindow(projectId: second.id, worktreeId: second.primaryWorktree!.id)

        XCTAssertEqual(opened?.projectId, second.id)
        XCTAssertEqual(model.activeProjectId, second.id)
        XCTAssertEqual(model.visibleProjects.map(\.id), [second.id])
        XCTAssertEqual(model.projects.map(\.id), [first.id, second.id], "saved projects are preserved")
    }

    @MainActor
    func testOpeningOneProjectFromManySavedProjectsLocksVisibleScope() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let alpha = projectFixture(id: "/tmp/juggle-alpha-\(UUID().uuidString)", name: "alpha")
        let bravo = projectFixture(id: "/tmp/juggle-bravo-\(UUID().uuidString)", name: "bravo")
        let charlie = projectFixture(id: "/tmp/juggle-charlie-\(UUID().uuidString)", name: "charlie")
        let legacy = LegacyWorkspace(projects: [alpha, bravo, charlie], preferences: Preferences(), openWindows: nil)
        try JSONEncoder().encode(legacy).write(to: store)

        let model = AppModel(storeURL: store)
        model.load()
        XCTAssertEqual(model.scopeTitle, "All projects")

        var opened: SessionContext?
        model.onOpenWindow = { opened = $0 }
        model.openWindow(projectId: bravo.id, worktreeId: bravo.primaryWorktree!.id)

        let alphaTerminal = UUID()
        let bravoTerminal = UUID()
        let charlieTerminal = UUID()
        model.registerTerminal(id: alphaTerminal, projectId: alpha.id, worktreeId: alpha.primaryWorktree!.id, title: "alpha")
        model.registerTerminal(id: bravoTerminal, projectId: bravo.id, worktreeId: bravo.primaryWorktree!.id, title: "bravo")
        model.registerTerminal(id: charlieTerminal, projectId: charlie.id, worktreeId: charlie.primaryWorktree!.id, title: "charlie")

        XCTAssertEqual(opened?.projectId, bravo.id)
        XCTAssertEqual(model.activeProjectId, bravo.id)
        XCTAssertEqual(model.scopeTitle, "bravo")
        XCTAssertEqual(model.projects.map(\.id), [alpha.id, bravo.id, charlie.id], "saved projects are preserved")
        XCTAssertEqual(model.visibleProjects.map(\.id), [bravo.id])
        XCTAssertEqual(model.visibleOpenTerminals.map(\.id), [bravoTerminal])
        XCTAssertEqual(model.prObservableWorktreePaths, [bravo.primaryWorktree!.path])
    }

    @MainActor
    func testOlderPRPollCannotOverwriteNewerFreshBlocker() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let model = AppModel(storeURL: store)
        let path = "/tmp/juggle-pr-race-\(UUID().uuidString)"
        let stalePollStartedAt = Date()
        let freshObservedAt = stalePollStartedAt.addingTimeInterval(1)
        let laterPollStartedAt = freshObservedAt.addingTimeInterval(1)
        let staleReady = PRStatus(availability: .available, number: 42, headOid: "abc", summary: "Merge")
        let freshBlocker = PRStatus(availability: .behind, number: 42, headOid: "abc", summary: "Behind base")

        model.setPRStatus(freshBlocker, for: path, observedAt: freshObservedAt)
        model.applyPRPollStatuses([path: staleReady], observedAt: stalePollStartedAt, replacing: [path])

        XCTAssertEqual(model.prStatusesByPath[path]?.availability, .behind)
        XCTAssertFalse(model.prReadyPaths.contains(path))

        model.applyPRPollStatuses([:], observedAt: stalePollStartedAt, replacing: [path])
        XCTAssertEqual(model.prStatusesByPath[path]?.availability, .behind,
                       "an older poll that sees no status must not erase the fresh blocker")

        model.applyPRPollStatuses([path: staleReady], observedAt: laterPollStartedAt, replacing: [path])
        XCTAssertEqual(model.prStatusesByPath[path]?.availability, .available,
                       "a newer poll is allowed to publish that the PR became ready again")
        XCTAssertTrue(model.prReadyPaths.contains(path))
    }

    @MainActor
    func testRecolorAndRemove() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let model = AppModel(storeURL: store)
        let project = model.addProject(atRoot: FileManager.default.temporaryDirectory.path)

        model.recolor(projectId: project.id, colorName: "Iris")
        XCTAssertEqual(model.projects.first?.colorName, "Iris")

        model.remove(projectId: project.id)
        XCTAssertTrue(model.projects.isEmpty)
    }

    @MainActor
    func testRenameIgnoresEmpty() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let model = AppModel(storeURL: store)
        let project = model.addProject(atRoot: FileManager.default.temporaryDirectory.path)
        let original = project.displayName
        model.rename(projectId: project.id, to: "   ")
        XCTAssertEqual(model.projects.first?.displayName, original, "blank rename is ignored")
    }

    /// A title callback that re-sets the *same* title (e.g. a shell re-emitting its
    /// prompt title) must not ping `objectWillChange` — that would re-render the
    /// terminal row in the control panel for no reason. Measures pings per call.
    @MainActor
    func testNoOpTitleUpdateDoesNotPublish() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let model = AppModel(storeURL: store)
        let id = UUID()
        model.registerTerminal(id: id, projectId: "p", worktreeId: "w", title: "terminal")

        let pings = OSAllocatedUnfairLock(initialState: 0)
        let cancellable = model.objectWillChange.sink { _ in pings.withLock { $0 += 1 } }
        defer { cancellable.cancel() }

        model.updateTerminalTitle(id: id, title: "new-shell")   // real change
        let realChangePings = pings.withLock { $0 }
        XCTAssertEqual(model.openTerminals.first?.title, "new-shell")

        model.updateTerminalTitle(id: id, title: "new-shell")   // identical: no-op
        let noOpPings = pings.withLock { $0 } - realChangePings

        print("METRIC title_real_change_pings=\(realChangePings) title_noop_pings=\(noOpPings)")
        XCTAssertEqual(realChangePings, 1, "a real title change publishes once")
        XCTAssertEqual(noOpPings, 0, "an identical title must not ping objectWillChange")
    }
}
