import Foundation
import os

enum ClaudeCLI {
    private struct PathCache {
        var claude: String?
        var tmux: String?
    }

    private static let pathCache = OSAllocatedUnfairLock(initialState: PathCache())

    /// Resolves the path to the `claude` executable. Result is cached.
    static func claudePath() throws -> String {
        if let cached = pathCache.withLock({ $0.claude }) { return cached }
        let path = try CLIResolver.resolve(
            name: "claude",
            knownPaths: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
        )
        pathCache.withLock { $0.claude = path }
        return path
    }

    /// Resolves the path to the `tmux` executable. Result is cached.
    static func tmuxPath() throws -> String {
        if let cached = pathCache.withLock({ $0.tmux }) { return cached }
        let path = try CLIResolver.resolve(
            name: "tmux",
            knownPaths: [
                "/opt/homebrew/bin/tmux",
                "/usr/local/bin/tmux",
                "/usr/bin/tmux",
            ]
        )
        pathCache.withLock { $0.tmux = path }
        return path
    }

    /// Returns the Claude Code version string, or nil if not available.
    static func claudeVersion() -> String? {
        CLIResolver.versionOutput(for: claudePath)
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
}
