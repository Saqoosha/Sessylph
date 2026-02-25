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
        versionOutput(for: claudePath)
    }

    /// Runs `--version` on the executable and returns the output.
    private static func versionOutput(for pathProvider: () throws -> String, firstLineOnly: Bool = false) -> String? {
        guard let path = try? pathProvider() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLineOnly ? output?.components(separatedBy: "\n").first : output
    }

    // MARK: - CLI Options Discovery

    struct CLIOptions: Sendable {
        var modelAliases: [String]
        var permissionModes: [String]
    }

    /// Known model aliases as fallback when parsing fails.
    private static let knownModelAliases = ["sonnet", "opus", "haiku", "sonnet[1m]", "opusplan"]

    /// Known permission modes as fallback when parsing fails.
    private static let knownPermissionModes = ["default", "plan", "acceptEdits", "delegate", "dontAsk", "bypassPermissions"]

    /// Parses `claude --help` to discover available permission modes and model aliases.
    static func discoverCLIOptions() -> CLIOptions {
        guard let helpText = runHelp() else {
            return CLIOptions(modelAliases: knownModelAliases, permissionModes: knownPermissionModes)
        }

        var permissionModes = parseChoices(from: helpText, forFlag: "--permission-mode") ?? knownPermissionModes
        // Ensure "default" is first
        if let idx = permissionModes.firstIndex(of: "default"), idx != 0 {
            permissionModes.remove(at: idx)
            permissionModes.insert("default", at: 0)
        }
        // Model aliases are not listed as choices in --help, use known list
        let modelAliases = knownModelAliases

        return CLIOptions(modelAliases: modelAliases, permissionModes: permissionModes)
    }

    private static func runHelp() -> String? {
        guard let path = try? claudePath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Parses `(choices: "a", "b", "c")` from help text for a given flag.
    private static func parseChoices(from helpText: String, forFlag flag: String) -> [String]? {
        // Find the line containing the flag
        guard let flagRange = helpText.range(of: flag) else { return nil }
        let afterFlag = helpText[flagRange.upperBound...]

        // Look for (choices: ...) pattern
        guard let choicesStart = afterFlag.range(of: "(choices: ") else { return nil }
        let afterChoices = afterFlag[choicesStart.upperBound...]
        guard let choicesEnd = afterChoices.range(of: ")") else { return nil }
        let choicesString = afterChoices[..<choicesEnd.lowerBound]

        // Parse quoted strings: "a", "b", "c"
        let choices = choicesString
            .components(separatedBy: ",")
            .compactMap { item -> String? in
                let trimmed = item.trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes
                if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
                    return String(trimmed.dropFirst().dropLast())
                }
                return trimmed.isEmpty ? nil : trimmed
            }

        return choices.isEmpty ? nil : choices
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
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ResolveError.notFound(name)
        }

        // Read before waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
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
