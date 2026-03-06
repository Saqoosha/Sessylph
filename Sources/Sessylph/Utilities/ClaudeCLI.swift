import Foundation

enum ClaudeCLI {
    /// Resolves the path to the `claude` executable.
    static func claudePath() throws -> String {
        try CLIResolver.resolve(
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
        try CLIResolver.resolve(
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
