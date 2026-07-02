import Foundation

/// Process-running seam for `GhService`. The production conformance is
/// `ShellRunner` (off-main, sandbox-safe). Carrying this protocol (rather than
/// the concrete type) lets the cold-path spawn count be observed in tests
/// without spawning a real `gh` — the basis for the in-flight coalescing
/// measurement. Default construction is identical to the prior concrete path.
struct ShellRunResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitStatus: Int32?
    var timedOut: Bool = false
    var launchError: String? = nil

    var succeeded: Bool { exitStatus == 0 && !timedOut && launchError == nil }

    static func success(stdout: String) -> ShellRunResult {
        ShellRunResult(stdout: stdout, stderr: "", exitStatus: 0)
    }

    static func failure(
        stdout: String = "",
        stderr: String = "",
        exitStatus: Int32? = nil,
        timedOut: Bool = false,
        launchError: String? = nil
    ) -> ShellRunResult {
        ShellRunResult(
            stdout: stdout,
            stderr: stderr,
            exitStatus: exitStatus,
            timedOut: timedOut,
            launchError: launchError
        )
    }

    func failureMessage(tool: String) -> String {
        let output = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if timedOut {
            return output.isEmpty ? "\(tool) timed out." : "\(tool) timed out.\n\n\(output)"
        }
        if let launchError {
            return output.isEmpty ? launchError : "\(launchError)\n\n\(output)"
        }
        if let exitStatus {
            return output.isEmpty ? "\(tool) exited with status \(exitStatus)." : "\(output)\n\nExit status \(exitStatus)."
        }
        return output.isEmpty ? "\(tool) failed without output." : output
    }
}

protocol ShellRunning: Sendable {
    func runAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> String?
    func resultAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> ShellRunResult
}

extension ShellRunning {
    func resultAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> ShellRunResult {
        if let output = await runAsync(launchPath, arguments, cwd: cwd) {
            return .success(stdout: output)
        }
        return .failure()
    }
}

/// The PR / merge state of a worktree's branch, as the header should surface it.
struct PRStatus: Sendable, Equatable, Hashable {
    enum Availability: Sendable, Equatable, Hashable { case none, available, checksRunning, behind, draft, blocked }
    var availability: Availability
    var number: Int?
    var headOid: String?
    var summary: String
    var additions: Int?
    var deletions: Int?
    var title: String? = nil
    var url: String? = nil
    var headRefName: String? = nil

    static let none = PRStatus(availability: .none, number: nil, headOid: nil, summary: "")
}

struct PRMergeResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable { case merged, notMergeable, failed, cancelled }
    var outcome: Outcome
    var status: PRStatus
    var failureMessage: String? = nil
}

struct GhActionResult: Sendable, Equatable {
    var succeeded: Bool
    var failureMessage: String? = nil

    static let success = GhActionResult(succeeded: true)
    static func failure(_ message: String) -> GhActionResult {
        GhActionResult(succeeded: false, failureMessage: message)
    }
}

/// Talks to GitHub via the `gh` CLI through a shared `ShellRunner`.
///
/// `@MainActor` because every caller is UI-driven (the control panel's PRChip
/// per worktree, a window's focus refresh, the merge/alert flows). `status(at:)`
/// is backed by a short-lived cache so opening the popover or focusing a window
/// doesn't re-spawn `gh pr view` per worktree per event; PR write actions drop
/// the affected path so the next read is fresh. The subprocess itself still runs
/// off the main thread via `ShellRunner.runAsync`, so the UI never blocks on it.
@MainActor
final class GhService {
    static let shared = GhService()

    private let runner: ShellRunning
    private let ghPath: String?
    /// Short enough that CI / mergeability never feels stale, long enough to
    /// collapse a popover-open + focus burst into one fetch per worktree.
    private static let cacheTTL: TimeInterval = 15
    private var cache: [String: (value: PRStatus, setAt: Date)] = [:]
    private var cacheGeneration: [String: Int] = [:]
    /// One in-flight fetch per path so concurrent cold readers (a popover-open
    /// PRChip load and a window focus refresh racing before the cache is written
    /// back) share a single `gh pr view` instead of stampeding it. Cleared as
    /// each fetch resolves.
    private var inFlight: [String: (task: Task<PRStatus, Never>, generation: Int)] = [:]

    init() {
        let runner = ShellRunner(extraEnv: ["GH_TOKEN", "GITHUB_TOKEN"])
        self.runner = runner
        ghPath = runner.locate("gh")
    }

    /// Test seam: inject a runner and pre-resolved `gh` path so spawn counts
    /// are observable without a real `gh` binary. Production callers use `init()`.
    init(runner: ShellRunning, ghPath: String?) {
        self.runner = runner
        self.ghPath = ghPath
    }

    func status(at path: String) async -> PRStatus {
        if let entry = cache[path], Date().timeIntervalSince(entry.setAt) < Self.cacheTTL {
            return entry.value
        }
        // PR #1's TTL cache collapses *repeated* reads but not *concurrent* cold
        // reads that arrive before the first fetch writes back. Share one Task
        // per path so the first open is one spawn per worktree regardless of fan-in.
        if let existing = inFlight[path] {
            let status = await existing.task.value
            return acceptedStatus(status, for: path, generation: existing.generation)
        }
        let generation = cacheGeneration[path, default: 0]
        let task = Task { await fetch(at: path) }
        inFlight[path] = (task, generation)
        let status = await task.value
        inFlight[path] = nil
        guard cacheGeneration[path, default: 0] == generation else {
            return cache[path]?.value ?? .none
        }
        cache[path] = (status, Date())
        return status
    }

    /// Bypass the short-lived read cache for write preflights. Passive UI reads
    /// may be cached; merge actions must prove the PR is still mergeable now.
    func refreshStatus(at path: String) async -> PRStatus {
        invalidateCachedStatus(for: path)
        let status = await fetch(at: path)
        cache[path] = (status, Date())
        return status
    }

    private func acceptedStatus(_ status: PRStatus, for path: String, generation: Int) -> PRStatus {
        guard cacheGeneration[path, default: 0] == generation else {
            return cache[path]?.value ?? .none
        }
        return status
    }

    private func invalidateCachedStatus(for path: String) {
        cache[path] = nil
        cacheGeneration[path, default: 0] += 1
    }

    /// Run `gh pr view --json` for one path and map it. Runs off the main thread
    /// via `ShellRunner.runAsync`; the surrounding `status(at:)` shares this work
    /// across concurrent readers and caches the result.
    private func fetch(at path: String) async -> PRStatus {
        guard let ghPath else { return .none }
        guard let output = await runner.runAsync(
            ghPath, ["pr", "view", "--json",
                     "number,state,isDraft,mergeStateStatus,headRefOid,additions,deletions,title,url,headRefName"], cwd: path
        ), let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .none
        }
        return Self.map(object)
    }

    /// Pure JSON-to-PRStatus mapping, extracted so each branch is unit-testable.
    nonisolated static func map(_ object: [String: Any]) -> PRStatus {
        guard (object["state"] as? String) == "OPEN" else { return .none }

        let number = object["number"] as? Int
        let headOid = object["headRefOid"] as? String
        let isDraft = object["isDraft"] as? Bool ?? false
        let mergeState = object["mergeStateStatus"] as? String ?? "UNKNOWN"
        let additions = object["additions"] as? Int
        let deletions = object["deletions"] as? Int
        let title = object["title"] as? String
        let url = object["url"] as? String
        let headRefName = object["headRefName"] as? String

        let availability: PRStatus.Availability
        let summary: String
        if isDraft || mergeState == "DRAFT" {
            availability = .draft; summary = "Draft"
        } else {
            switch mergeState {
            case "CLEAN": availability = .available; summary = "Merge"
            case "BEHIND": availability = .behind; summary = "Behind base"
            case "UNSTABLE": availability = .checksRunning; summary = "Checks running"
            default: availability = .blocked; summary = "Blocked"
            }
        }
        return PRStatus(availability: availability, number: number, headOid: headOid,
                        summary: summary, additions: additions, deletions: deletions,
                        title: title, url: url, headRefName: headRefName)
    }

    /// Open a draft PR for the worktree's current branch, auto-filling the title
    /// and body from its commits.
    func openDraftPR(at path: String) async -> GhActionResult {
        guard let ghPath else {
            return .failure("GitHub CLI (gh) was not found in PATH.")
        }
        invalidateCachedStatus(for: path)
        let result = await runner.resultAsync(ghPath, ["pr", "create", "--draft", "--fill"], cwd: path)
        if result.succeeded { return .success }
        // The single most common "it didn't work" case: a PR already exists for
        // this branch, so `gh pr create` aborts. Surface that as a plain,
        // actionable message (Review/Merge from the panel) instead of a raw gh
        // error the user can't act on.
        let raw = result.failureMessage(tool: "gh pr create")
        if Self.isAlreadyExistsFailure(raw) {
            return .failure("A pull request already exists for this branch — use Review or Merge instead.")
        }
        return .failure(raw)
    }

    /// Detects `gh pr create` failing because the branch already has a PR.
    /// `nonisolated` + `static` so it is unit-testable without a real `gh`.
    nonisolated static func isAlreadyExistsFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("already exists")
            || (lowered.contains("pull request") && lowered.contains("already"))
    }

    /// Explicit, guarded merge. `--match-head-commit` refuses to merge if the
    /// branch head moved since we read it.
    func merge(at path: String, number: Int, headOid: String) async -> GhActionResult {
        guard let ghPath else {
            return .failure("GitHub CLI (gh) was not found in PATH.")
        }
        invalidateCachedStatus(for: path)
        let result = await runner.resultAsync(
            ghPath, ["pr", "merge", String(number), "--squash", "--match-head-commit", headOid], cwd: path
        )
        return result.succeeded ? .success : .failure(result.failureMessage(tool: "gh pr merge"))
    }

    /// Inline merge path for already-confirmed intent (the notch button). It
    /// always refreshes first, so a stale cached "available" row cannot merge a
    /// PR that GitHub now reports as draft/behind/checks-running/blocked.
    func mergeIfAvailable(at path: String) async -> PRMergeResult {
        let status = await refreshStatus(at: path)
        guard status.availability == .available, let number = status.number, let headOid = status.headOid else {
            return PRMergeResult(outcome: .notMergeable, status: status)
        }
        let result = await merge(at: path, number: number, headOid: headOid)
        return PRMergeResult(outcome: result.succeeded ? .merged : .failed,
                             status: status,
                             failureMessage: result.failureMessage)
    }

    // MARK: - First-run GitHub CLI detection

    /// One honest check for the onboarding permissions step: is `gh` installed,
    /// and is the user signed in? Backed by `gh auth status`, which is local
    /// (reads the keyring/config — no network) and prints the account summary to
    /// stdout when authenticated. Runs through `ShellRunner.runAsync` so the
    /// subprocess never blocks the UI. Never throws — the step must not block.
    func authStatus() async -> GhAuthState {
        guard let ghPath else { return .notInstalled }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let output = await runner.runAsync(ghPath, ["auth", "status"], cwd: home) else {
            return .notSignedIn   // non-zero exit (or timeout): not logged in
        }
        if let username = Self.activeAccount(in: output) {
            return .signedIn(username: username)
        }
        return .notSignedIn
    }

    /// Pull the active account name out of `gh auth status` output. Prefers the
    /// line marked `Active account: true`; otherwise the first
    /// `Logged in to … account <name>` line. `nonisolated` so it is unit-testable
    /// without a real `gh` binary, mirroring `map(_:)`.
    nonisolated static func activeAccount(in output: String) -> String? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Prefer an explicitly-active account when several are configured.
        for i in 0..<lines.count where lines[i].contains("Active account: true") {
            // The account name is on the preceding `Logged in … account <name>` line.
            if i > 0, let name = accountName(on: lines[i - 1]) { return name }
        }
        return lines.compactMap(Self.accountName(on:)).first
    }

    /// Matches `✓ Logged in to github.com account imsthegenius (keyring)` →
    /// `imsthegenius`. Tolerates host names other than github.com.
    nonisolated static func accountName(on line: String) -> String? {
        guard line.contains("Logged in") else { return nil }
        guard let range = line.range(of: "account ") else { return nil }
        let remainder = line[range.upperBound...]
        let name = remainder
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" })
            .first
            .map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
