import Foundation
import os
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "EnvironmentBuilder")

enum EnvironmentBuilder {
    /// Environment variables that must not be propagated to child processes.
    /// CLAUDECODE: Claude Code sets this to detect nested sessions; if propagated,
    /// it prevents launching new Claude Code instances in tmux sessions.
    private static let filteredKeys: Set<String> = ["CLAUDECODE"]

    private struct Cache {
        var environment: [String]?
        var dict: [String: String]?
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Captures the user's full login shell environment.
    /// GUI apps don't inherit shell config (PATH, API keys, etc.),
    /// so we run the login shell to collect it. Result is cached.
    static func loginEnvironment() -> [String] {
        cache.withLock { cache in
            if let cached = cache.environment { return cached }

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "env"]
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                logger.warning("Failed to capture login shell environment: \(error.localizedDescription). Using process environment as fallback.")
                let fallback = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
                cache.environment = fallback
                return fallback
            }

            // Read data BEFORE waitUntilExit to avoid pipe deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                logger.warning("Failed to decode login shell output. Using process environment as fallback.")
                let fallback = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
                cache.environment = fallback
                return fallback
            }

            let result = output
                .components(separatedBy: "\n")
                .filter { line in
                    guard !line.isEmpty, line.contains("=") else { return false }
                    guard let key = line.split(separator: "=", maxSplits: 1).first else { return false }
                    return !filteredKeys.contains(String(key))
                }
            cache.environment = result
            return result
        }
    }

    /// Returns environment as a dictionary. Result is cached.
    static func loginEnvironmentDict() -> [String: String] {
        cache.withLock { cache in
            if let cached = cache.dict { return cached }

            // Must not call loginEnvironment() here as it also acquires the lock.
            // Compute environment inline if not yet cached.
            let envArray: [String]
            if let cached = cache.environment {
                envArray = cached
            } else {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", "env"]
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                var computed: [String]
                do {
                    try process.run()
                } catch {
                    logger.warning("Failed to capture login shell environment: \(error.localizedDescription). Using process environment as fallback.")
                    computed = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
                    cache.environment = computed
                    let dict = Self.buildDict(from: computed)
                    cache.dict = dict
                    return dict
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let output = String(data: data, encoding: .utf8) {
                    computed = output
                        .components(separatedBy: "\n")
                        .filter { $0.contains("=") && !$0.isEmpty }
                } else {
                    logger.warning("Failed to decode login shell output. Using process environment as fallback.")
                    computed = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
                }
                cache.environment = computed
                envArray = computed
            }

            let dict = Self.buildDict(from: envArray)
            cache.dict = dict
            return dict
        }
    }

    private static func buildDict(from entries: [String]) -> [String: String] {
        var dict: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                guard !filteredKeys.contains(key) else { continue }
                dict[key] = String(parts[1])
            }
        }
        return dict
    }
}
