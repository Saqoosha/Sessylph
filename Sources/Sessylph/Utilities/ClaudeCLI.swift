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
        var effortLevels: [String]
    }

    /// Known model aliases as fallback when parsing fails.
    private static let knownModelAliases = ["opus[1m]", "opus", "sonnet[1m]", "sonnet", "haiku"]

    /// Known permission modes as fallback when parsing fails.
    private static let knownPermissionModes = ["default", "plan", "auto", "acceptEdits", "dontAsk", "bypassPermissions"]

    /// Known effort levels as fallback when parsing fails. `xhigh` was added in Claude Code 2.1.111
    /// for Opus 4.7, sitting between `high` and `max`; other models fall back to `high`.
    static let knownEffortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Human-readable label for an effort level tag.
    static func effortLevelLabel(_ level: String) -> String {
        switch level {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    /// Parses `claude --help` to discover available permission modes, model aliases, and effort levels.
    static func discoverCLIOptions() -> CLIOptions {
        guard let helpText = runHelp() else {
            return CLIOptions(
                modelAliases: knownModelAliases,
                permissionModes: knownPermissionModes,
                effortLevels: knownEffortLevels
            )
        }

        var permissionModes = parseChoices(from: helpText, forFlag: "--permission-mode") ?? knownPermissionModes
        // Ensure "default" is first
        if let idx = permissionModes.firstIndex(of: "default"), idx != 0 {
            permissionModes.remove(at: idx)
            permissionModes.insert("default", at: 0)
        }
        // Model aliases are not listed as choices in --help, use known list
        let modelAliases = knownModelAliases
        // --effort uses a plain `(low, medium, high, ...)` list instead of `(choices: "...", "...")`
        let effortLevels = parseEffortLevels(from: helpText) ?? knownEffortLevels

        return CLIOptions(modelAliases: modelAliases, permissionModes: permissionModes, effortLevels: effortLevels)
    }

    /// Parses the `--effort <level>` help line to extract the comma-separated level list.
    /// Example line: `--effort <level>    Effort level for the current session (low, medium, high, xhigh, max)`
    private static func parseEffortLevels(from helpText: String) -> [String]? {
        // Require a word boundary after `--effort` so future flags like `--effort-budget` don't match.
        var searchStart = helpText.startIndex
        var flagRange: Range<String.Index>? = nil
        while let candidate = helpText.range(of: "--effort", range: searchStart..<helpText.endIndex) {
            let next = candidate.upperBound
            if next == helpText.endIndex || helpText[next] == " " || helpText[next] == "<" || helpText[next] == "\t" {
                flagRange = candidate
                break
            }
            searchStart = next
        }
        guard let flagRange else { return nil }
        // Restrict the search to the end of the --effort help line (stop at newline).
        let afterFlag = helpText[flagRange.upperBound...]
        let lineEnd = afterFlag.firstIndex(of: "\n") ?? afterFlag.endIndex
        let line = afterFlag[..<lineEnd]

        // Find the last `(...)` on the line — the effort level list.
        guard let openIdx = line.lastIndex(of: "("),
              let closeIdx = line.lastIndex(of: ")"),
              openIdx < closeIdx else { return nil }
        let inside = line[line.index(after: openIdx)..<closeIdx]

        let levels = inside
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }

        return levels.isEmpty ? nil : levels
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
