import Foundation

enum ClaudeCLI {
    enum ResolveError: Error, LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "\(name) not found in PATH or common locations"
            }
        }
    }

    /// Resolves the path to the `claude` executable.
    static func claudePath() throws -> String {
        try resolve(
            name: "claude",
            knownPaths: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
        )
    }

    /// Resolves the path to the `tmux` executable.
    static func tmuxPath() throws -> String {
        try resolve(
            name: "tmux",
            knownPaths: [
                "/opt/homebrew/bin/tmux",
                "/usr/local/bin/tmux",
                "/usr/bin/tmux",
            ]
        )
    }

    /// Returns the Claude Code version string, or nil if not available.
    static func claudeVersion() -> String? {
        guard let path = try? claudePath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private static func resolve(name: String, knownPaths: [String]) throws -> String {
        // Check known paths first
        for path in knownPaths {
            let resolved = resolveSymlink(path)
            if FileManager.default.isExecutableFile(atPath: resolved) {
                return path
            }
        }

        // Try `which` via the login shell environment
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "which \(name)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ResolveError.notFound(name)
        }

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty
            {
                return path
            }
        }

        throw ResolveError.notFound(name)
    }

    private static func resolveSymlink(_ path: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }
}
