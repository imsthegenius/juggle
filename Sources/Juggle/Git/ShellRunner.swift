import Foundation

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Shared, sandbox-safe runner for `git` / `gh`. Builds an explicit child PATH
/// (so a GUI / Spotlight launch still finds Homebrew tools), locates executables
/// once, refuses interactive prompts (null stdin + `GIT_TERMINAL_PROMPT=0`), and
/// enforces a timeout so a stalled credential prompt can't hang a caller forever.
struct ShellRunner: Sendable, ShellRunning {
    private let environment: [String: String]

    init(extraEnv: [String] = []) {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "TMPDIR", "SSH_AUTH_SOCK", "LANG", "LC_ALL"] + extraEnv {
            if let value = inherited[key] { env[key] = value }
        }
        self.environment = env
    }

    func locate(_ tool: String) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func runAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> String? {
        let result = await resultAsync(launchPath, arguments, cwd: cwd)
        return result.succeeded ? result.stdout : nil
    }

    func resultAsync(_ launchPath: String, _ arguments: [String], cwd: String) async -> ShellRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runResult(launchPath, arguments, cwd: cwd))
            }
        }
    }

    private func runResult(_ launchPath: String, _ arguments: [String], cwd: String, timeout: TimeInterval = 8) -> ShellRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr

        do { try process.run() } catch {
            return .failure(launchError: error.localizedDescription)
        }

        let didTimeOut = LockedValue(false)
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler {
            if process.isRunning {
                didTimeOut.set(true)
                process.terminate()
            }
        }
        watchdog.resume()

        let group = DispatchGroup()
        let stdoutData = LockedValue(Data())
        let stderrData = LockedValue(Data())
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        return ShellRunResult(
            stdout: String(data: stdoutData.get(), encoding: .utf8) ?? "",
            stderr: String(data: stderrData.get(), encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus,
            timedOut: didTimeOut.get()
        )
    }
}
