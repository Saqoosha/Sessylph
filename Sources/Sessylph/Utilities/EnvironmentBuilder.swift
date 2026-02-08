import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "EnvironmentBuilder")

enum EnvironmentBuilder {
    nonisolated(unsafe) private static var cachedEnvironment: [String]?
    nonisolated(unsafe) private static var cachedDict: [String: String]?

    /// Captures the user's full login shell environment.
    /// GUI apps don't inherit shell config (PATH, API keys, etc.),
    /// so we run the login shell to collect it. Result is cached.
    static func loginEnvironment() -> [String] {
        if let cached = cachedEnvironment { return cached }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "env"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.warning("Failed to capture login shell environment: \(error.localizedDescription). Using process environment as fallback.")
            let fallback = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            cachedEnvironment = fallback
            return fallback
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            logger.warning("Failed to decode login shell output. Using process environment as fallback.")
            let fallback = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            cachedEnvironment = fallback
            return fallback
        }

        let result = output
            .components(separatedBy: "\n")
            .filter { $0.contains("=") && !$0.isEmpty }
        cachedEnvironment = result
        return result
    }

    /// Returns environment as a dictionary. Result is cached.
    static func loginEnvironmentDict() -> [String: String] {
        if let cached = cachedDict { return cached }

        var dict: [String: String] = [:]
        for entry in loginEnvironment() {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }
        cachedDict = dict
        return dict
    }
}
