import Foundation
import XCTest
@testable import Juggle

/// Integration tests that exercise the real `git` / `gh` boundary against the
/// repository this test file lives in. They degrade gracefully when a tool is
/// absent (the services return empty/`.none`), so they never hang the suite.
final class GitIntegrationTests: XCTestCase {
    /// The git repo root enclosing this test file.
    private var repoRoot: String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return #file
    }

    func testSnapshotReadsRealRepo() async {
        let snapshot = await GitService.shared.snapshot(at: repoRoot)
        XCTAssertTrue(snapshot.isRepo, "the enclosing directory is a git repo")
        XCTAssertNotNil(snapshot.branch)
        XCTAssertFalse(snapshot.branch?.isEmpty ?? true)
    }

    func testWorktreesIncludeRoot() async {
        let worktrees = await GitService.shared.worktrees(at: repoRoot)
        XCTAssertFalse(worktrees.isEmpty, "git worktree list returns at least the main worktree")
        XCTAssertTrue(
            worktrees.contains { repoRoot.hasSuffix($0.path) || $0.path.hasSuffix("juggle") },
            "the main worktree path is reported"
        )
    }

    func testPRStatusDoesNotHangOrCrash() async {
        // No assertion on the specific value (depends on whether a PR exists for
        // the current branch and whether gh is authed); the point is the call
        // returns a valid status within the runner's timeout rather than hanging.
        let status = await GhService.shared.status(at: repoRoot)
        XCTAssertTrue([.none, .available, .behind, .checksRunning, .draft, .blocked].contains(status.availability))
    }

    func testStatusIsStableAcrossRapidCalls() async {
        // Two back-to-back reads must agree: the short-lived cache returns the
        // same value for the same path instead of re-spawning `gh` each time.
        let first = await GhService.shared.status(at: repoRoot)
        let second = await GhService.shared.status(at: repoRoot)
        XCTAssertEqual(first, second)
    }
}
