import Foundation
import os
import XCTest
@testable import Juggle

/// Measures `GhService` cold-path spawn behavior. `CountingRunner` stands in for
/// `ShellRunner`: it returns a canned `gh pr view --json` payload and (crucially)
/// sleeps so concurrent cold reads for the same path overlap before the first one
/// writes the TTL cache back. With a thread-safe counter we can observe how many
/// `gh` spawns N concurrent readers actually produce.
@MainActor
final class GhServiceCoalescingTests: XCTestCase {
    private static let payload = """
    {"state":"OPEN","number":7,"isDraft":false,"mergeStateStatus":"CLEAN",\
    "headRefOid":"abc","additions":2,"deletions":1}
    """
    private static let behindPayload = """
    {"state":"OPEN","number":7,"isDraft":false,"mergeStateStatus":"BEHIND",\
    "headRefOid":"abc","additions":2,"deletions":1}
    """

    func testConcurrentColdReadsCoalesceToOneSpawn() async {
        let spy = CountingRunner(payload: Self.payload, overlapMillis: 50)
        let gh = GhService(runner: spy, ghPath: "/fake/gh")
        let path = "/tmp/juggle-coalesce-\(UUID().uuidString)"

        // 5 concurrent cold reads for the SAME path (popover-open fan-in plus a
        // window focus racing before the first fetch lands). async-let children
        // inherit this test's @MainActor isolation, matching real callers.
        async let a = gh.status(at: path)
        async let b = gh.status(at: path)
        async let c = gh.status(at: path)
        async let d = gh.status(at: path)
        async let e = gh.status(at: path)
        let results = await [a, b, c, d, e]

        XCTAssertEqual(Set(results).count, 1, "all readers see the same status")
        XCTAssertEqual(spy.spawnCount, 1, "concurrent cold reads for one path must spawn gh exactly once")
        // METRIC consumed by the perf/audit measurement (before vs after the fix).
        print("METRIC concurrent_cold_reads=5 spawns=\(spy.spawnCount)")
    }

    func testSecondReadWithinTTLDoesNotSpawn() async {
        let spy = CountingRunner(payload: Self.payload, overlapMillis: 1)
        let gh = GhService(runner: spy, ghPath: "/fake/gh")
        let path = "/tmp/juggle-ttl-\(UUID().uuidString)"

        _ = await gh.status(at: path)          // cold: 1 spawn
        let coldSpawns = spy.spawnCount
        _ = await gh.status(at: path)          // warm: 0 spawns (TTL cache hit)
        print("METRIC warm_re-read cold_spawns=\(coldSpawns) warm_spawns=\(spy.spawnCount - coldSpawns)")
        XCTAssertEqual(coldSpawns, 1)
        XCTAssertEqual(spy.spawnCount, coldSpawns, "a within-TTL re-read must not spawn")
    }

    func testDifferentPathsEachFetchOnce() async {
        let spy = CountingRunner(payload: Self.payload, overlapMillis: 1)
        let gh = GhService(runner: spy, ghPath: "/fake/gh")
        // Coalescing is per-path: different paths don't share a task, so 3 distinct
        // paths still produce 3 spawns (one each).
        async let a = gh.status(at: "/tmp/p-a")
        async let b = gh.status(at: "/tmp/p-b")
        async let c = gh.status(at: "/tmp/p-c")
        _ = await [a, b, c]
        print("METRIC distinct_paths=3 spawns=\(spy.spawnCount)")
        XCTAssertEqual(spy.spawnCount, 3)
    }

    func testRefreshStatusBypassesWarmCacheAndReplacesIt() async {
        let spy = ScriptedRunner(outputs: [Self.payload, Self.behindPayload])
        let gh = GhService(runner: spy, ghPath: "/fake/gh")
        let path = "/tmp/juggle-refresh-\(UUID().uuidString)"

        let first = await gh.status(at: path)
        let second = await gh.status(at: path)
        XCTAssertEqual(first.availability, .available)
        XCTAssertEqual(second.availability, .available)
        XCTAssertEqual(spy.spawnCount, 1, "the second passive read should use the warm cache")

        let fresh = await gh.refreshStatus(at: path)
        XCTAssertEqual(fresh.availability, .behind, "fresh reads bypass stale warm cache entries")
        XCTAssertEqual(spy.spawnCount, 2)

        let reread = await gh.status(at: path)
        XCTAssertEqual(reread.availability, .behind,
                       "the fresh result should replace the cached available status")
        XCTAssertEqual(spy.spawnCount, 2)
    }

    func testMergeIfAvailableDoesNotMergeWhenFreshStatusBlocksStaleCache() async {
        let spy = ScriptedRunner(outputs: [Self.payload, Self.behindPayload])
        let gh = GhService(runner: spy, ghPath: "/fake/gh")
        let path = "/tmp/juggle-stale-merge-\(UUID().uuidString)"

        let cached = await gh.status(at: path)
        XCTAssertEqual(cached.availability, .available, "seed a stale available cache entry")
        let result = await gh.mergeIfAvailable(at: path)

        XCTAssertEqual(result.outcome, .notMergeable)
        XCTAssertEqual(result.status.availability, .behind)
        XCTAssertFalse(spy.commands.contains { Array($0.prefix(2)) == ["pr", "merge"] },
                       "fresh non-available status must stop before gh pr merge")
    }

    func testOpenDraftPRReturnsGhFailureOutput() async throws {
        let spy = ResultScriptedRunner(results: [
            .failure(stdout: "Try --base main.", stderr: "aborted: no commits between branches", exitStatus: 2)
        ])
        let gh = GhService(runner: spy, ghPath: "/fake/gh")

        let result = await gh.openDraftPR(at: "/tmp/juggle-create-failure-\(UUID().uuidString)")

        XCTAssertFalse(result.succeeded)
        let message = try XCTUnwrap(result.failureMessage)
        XCTAssertTrue(message.contains("aborted: no commits between branches"))
        XCTAssertTrue(message.contains("Try --base main."))
        XCTAssertTrue(message.contains("Exit status 2."))
        XCTAssertEqual(spy.commands, [["pr", "create", "--draft", "--fill"]])
    }

    func testOpenDraftPRReportsAlreadyExistsPlainly() async throws {
        // The exact failure the user hit: a PR already exists for the branch, so
        // `gh pr create` aborts. We must translate that into an actionable line.
        let spy = ResultScriptedRunner(results: [
            .failure(
                stdout: "",
                stderr: "a pull request for branch \"feat/x\" into branch \"main\" already exists:\nhttps://github.com/o/r/pull/7",
                exitStatus: 1
            )
        ])
        let gh = GhService(runner: spy, ghPath: "/fake/gh")

        let result = await gh.openDraftPR(at: "/tmp/juggle-exists-\(UUID().uuidString)")

        XCTAssertFalse(result.succeeded)
        let message = try XCTUnwrap(result.failureMessage)
        XCTAssertTrue(message.contains("already exists"), "message should explain a PR already exists")
        XCTAssertTrue(message.lowercased().contains("review") || message.lowercased().contains("merge"),
                      "message should point the user to Review/Merge")
        XCTAssertFalse(message.contains("Exit status"), "raw gh exit noise should be suppressed for this case")
    }

    func testMergeIfAvailableCarriesGhFailureOutput() async throws {
        let spy = ResultScriptedRunner(results: [
            .success(stdout: Self.payload),
            .failure(stdout: "remote rejected the merge", stderr: "GraphQL: Head sha mismatch", exitStatus: 1)
        ])
        let gh = GhService(runner: spy, ghPath: "/fake/gh")

        let result = await gh.mergeIfAvailable(at: "/tmp/juggle-merge-failure-\(UUID().uuidString)")

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.status.availability, .available)
        let message = try XCTUnwrap(result.failureMessage)
        XCTAssertTrue(message.contains("GraphQL: Head sha mismatch"))
        XCTAssertTrue(message.contains("remote rejected the merge"))
        XCTAssertTrue(message.contains("Exit status 1."))
        XCTAssertEqual(spy.commands.map { Array($0.prefix(2)) }, [["pr", "view"], ["pr", "merge"]])
    }

    func testFreshStatusWinsOverOlderInFlightPassiveRead() async {
        let spy = DelayedScriptedRunner(responses: [
            .init(output: Self.payload, delayMillis: 40),
            .init(output: Self.behindPayload, delayMillis: 0)
        ])
        let gh = GhService(runner: spy, ghPath: "/fake/gh")
        let path = "/tmp/juggle-inflight-refresh-\(UUID().uuidString)"

        async let passive = gh.status(at: path)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let fresh = await gh.refreshStatus(at: path)
        let passiveResult = await passive
        let reread = await gh.status(at: path)

        XCTAssertEqual(fresh.availability, .behind)
        XCTAssertEqual(passiveResult.availability, .behind,
                       "an older passive CLEAN response must not overwrite a newer fresh blocker")
        XCTAssertEqual(reread.availability, .behind)
        XCTAssertEqual(spy.spawnCount, 2)
    }
}

private final class ResultScriptedRunner: ShellRunning, @unchecked Sendable {
    private struct State {
        var results: [ShellRunResult]
        var commands: [[String]] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(results: [ShellRunResult]) {
        state = OSAllocatedUnfairLock(initialState: State(results: results))
    }

    var commands: [[String]] { state.withLock { $0.commands } }

    func runAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> String? {
        let result = nextResult(for: arguments)
        return result.succeeded ? result.stdout : nil
    }

    func resultAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> ShellRunResult {
        nextResult(for: arguments)
    }

    private func nextResult(for arguments: [String]) -> ShellRunResult {
        state.withLock { state in
            state.commands.append(arguments)
            guard !state.results.isEmpty else { return .failure(launchError: "No scripted result.") }
            if state.results.count == 1 { return state.results[0] }
            return state.results.removeFirst()
        }
    }
}

private final class CountingRunner: ShellRunning, @unchecked Sendable {
    private let payload: String
    private let overlapMillis: UInt64
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(payload: String, overlapMillis: UInt64) {
        self.payload = payload
        self.overlapMillis = overlapMillis
    }

    var spawnCount: Int { count.withLock { $0 } }

    func runAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> String? {
        count.withLock { $0 += 1 }
        // Force overlap: a real `gh pr view` takes hundreds of ms; holding here
        // keeps every concurrent cold reader in flight before any cache write-back.
        try? await Task.sleep(nanoseconds: overlapMillis * 1_000_000)
        return payload
    }
}

private final class ScriptedRunner: ShellRunning, @unchecked Sendable {
    private struct State {
        var outputs: [String?]
        var commands: [[String]] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(outputs: [String?]) {
        state = OSAllocatedUnfairLock(initialState: State(outputs: outputs))
    }

    var spawnCount: Int { state.withLock { $0.commands.count } }
    var commands: [[String]] { state.withLock { $0.commands } }

    func runAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> String? {
        state.withLock { state in
            state.commands.append(arguments)
            guard !state.outputs.isEmpty else { return nil }
            if state.outputs.count == 1 { return state.outputs[0] }
            return state.outputs.removeFirst()
        }
    }
}

private final class DelayedScriptedRunner: ShellRunning, @unchecked Sendable {
    struct Response {
        var output: String?
        var delayMillis: UInt64
    }

    private struct State {
        var responses: [Response]
        var commands: [[String]] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(responses: [Response]) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses))
    }

    var spawnCount: Int { state.withLock { $0.commands.count } }

    func runAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> String? {
        let response = state.withLock { state in
            state.commands.append(arguments)
            guard !state.responses.isEmpty else { return Response(output: nil, delayMillis: 0) }
            if state.responses.count == 1 { return state.responses[0] }
            return state.responses.removeFirst()
        }
        if response.delayMillis > 0 {
            try? await Task.sleep(nanoseconds: response.delayMillis * 1_000_000)
        }
        return response.output
    }
}
