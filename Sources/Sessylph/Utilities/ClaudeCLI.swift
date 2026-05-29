import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "ClaudeCLI")

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
        let effortLevels: [String]
        if let parsed = parseEffortLevels(from: helpText) {
            effortLevels = parsed
        } else {
            // Falling back is harmless today (the known list matches reality), but a silent
            // fallback once hid a parser break when the --effort help format changed. Log it so
            // a future format change surfaces instead of quietly dropping new effort levels.
            logger.warning("Failed to parse effort levels from `claude --help`; falling back to known list \(knownEffortLevels, privacy: .public). The CLI help format may have changed.")
            effortLevels = knownEffortLevels
        }

        return CLIOptions(modelAliases: modelAliases, permissionModes: permissionModes, effortLevels: effortLevels)
    }

    /// Parses the `--effort <level>` help text to extract the comma-separated level list.
    /// The choices list may wrap onto a continuation line, e.g.:
    ///   `  --effort <level>    Effort level for the current session`
    ///   `                      (low, medium, high, xhigh, max)`
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
        // The flag's help text may wrap across continuation lines, so the choices list
        // `(low, medium, ...)` can land on a line below the description. Collect the whole
        // help block: from the text following `--effort` up to the next option entry (a line
        // starting with two spaces + a dash) or an empty line (CR/LF tolerant).
        let afterFlag = helpText[flagRange.upperBound...]
        var blockEnd = afterFlag.endIndex
        var cursor = afterFlag.startIndex
        while let nl = afterFlag[cursor...].firstIndex(of: "\n") {
            let lineStart = afterFlag.index(after: nl)
            if lineStart == afterFlag.endIndex { blockEnd = nl; break }
            let rest = afterFlag[lineStart...]
            if rest.hasPrefix("  -") || rest.first == "\n" || rest.first == "\r" {
                blockEnd = nl
                break
            }
            cursor = lineStart
        }
        let block = afterFlag[..<blockEnd]

        // Find the last `(...)` in the block — the effort level list.
        guard let openIdx = block.lastIndex(of: "("),
              let closeIdx = block.lastIndex(of: ")"),
              openIdx < closeIdx else { return nil }
        let inside = block[block.index(after: openIdx)..<closeIdx]

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
            logger.error("`claude --help` failed to launch: \(error.localizedDescription, privacy: .public)")
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
