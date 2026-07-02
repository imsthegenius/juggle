import XCTest
@testable import Juggle

/// R17 / AE4: the model persists which project/worktree windows were open and the
/// grid slot each held, and restores them on the next launch — layout + colors +
/// assignments, never live processes. These cover the persistence spine directly
/// (the window reopen itself is AppKit, exercised manually against AE4).
final class WindowRestoreTests: XCTestCase {
    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("juggle-restore-\(UUID().uuidString).json")
    }

    @MainActor
    func testOpenWindowsRoundTripAcrossLaunch() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let model = AppModel(storeURL: store)
        let root = FileManager.default.temporaryDirectory.path
        let project = model.addProject(atRoot: root)
        let worktreeId = project.primaryWorktree!.id

        model.saveOpenWindows([
            OpenWindowState(projectId: project.id, worktreeId: worktreeId, slot: 2),
            OpenWindowState(projectId: project.id, worktreeId: worktreeId, slot: 0),
        ])

        let reloaded = AppModel(storeURL: store)
        reloaded.load()
        XCTAssertEqual(reloaded.restoredWindows.count, 2, "open windows survive a relaunch")
        XCTAssertEqual(Set(reloaded.restoredWindows.map(\.slot)), [0, 2], "each window's grid slot is restored")
        XCTAssertTrue(reloaded.restoredWindows.allSatisfy { $0.worktreeId == worktreeId },
                      "assignments (which worktree drove which window) are restored")
    }

    /// A store written before window-restore landed (no `openWindows` key) must
    /// still decode — and just restore nothing — rather than dropping the projects.
    @MainActor
    func testOlderStoreWithoutOpenWindowsDecodes() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let json = Data(#"{"projects":[],"preferences":{}}"#.utf8)
        try json.write(to: store)

        let model = AppModel(storeURL: store)
        model.load()
        XCTAssertTrue(model.restoredWindows.isEmpty, "no saved windows → restore nothing, no crash")
    }

    /// AE4's hard rule: restoring is identity + slot only. The persisted type
    /// carries no PTY / process handle, so live agents can never be resurrected.
    func testRestoreStateCarriesNoLiveProcess() {
        let state = OpenWindowState(projectId: "p", worktreeId: "w", slot: 1)
        let mirror = Mirror(reflecting: state)
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertEqual(labels, ["projectId", "worktreeId", "slot", "screenIndex"],
                       "only identity + slot + display assignment is persisted; no process is captured")
    }

    func testOlderOpenWindowWithoutScreenIndexDefaultsToPrimaryDisplay() throws {
        let json = Data(#"{"projectId":"p","worktreeId":"w","slot":3}"#.utf8)
        let state = try JSONDecoder().decode(OpenWindowState.self, from: json)
        XCTAssertEqual(state.screenIndex, 0, "older restore entries default to the primary display")
    }
}
