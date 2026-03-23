import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "CursorAgentCLI")

/// Resolves and interacts with the `cursor-agent` CLI executable for path discovery, version checking, and option parsing.
enum CursorAgentCLI {
    /// Resolves the path to the `cursor-agent` executable.
    static func cursorAgentPath() throws -> String {
        try CLIResolver.resolve(
            name: "cursor-agent",
            knownPaths: [
                "\(NSHomeDirectory())/.local/bin/cursor-agent",
                "/opt/homebrew/bin/cursor-agent",
                "/usr/local/bin/cursor-agent",
            ]
        )
    }

    /// Returns the Cursor Agent CLI version string, or nil if not available.
    static func cursorAgentVersion() -> String? {
        CLIResolver.versionOutput(for: cursorAgentPath)
    }

    /// Used only when `cursor-agent --list-models` fails (offline, old binary, etc.).
    private static let fallbackModels = [
        "auto",
        "composer-2-fast",
        "composer-2",
        "claude-4.6-opus-high-thinking",
    ]

    // MARK: - CLI Options Discovery

    struct CLIOptions: Sendable {
        let models: [String]
        let modes: [String]
        let sandboxModes: [String]
    }

    /// Known modes as fallback.
    private static let knownModes = ["plan", "ask"]

    /// Known sandbox modes as fallback.
    private static let knownSandboxModes = ["enabled", "disabled"]

    /// Parses `cursor-agent --help` for mode/sandbox; models come from `--list-models` (user's account-specific list).
    static func discoverCLIOptions() -> CLIOptions {
        let models: [String]
        if let listText = runListModels(), !listText.isEmpty {
            let parsed = parseModelsFromListOutput(listText)
            if parsed.isEmpty {
                logger.info("cursor-agent --list-models returned unparseable output, using fallback models")
                models = fallbackModels
            } else {
                models = parsed
            }
        } else {
            logger.info("cursor-agent --list-models unavailable, using fallback models")
            models = fallbackModels
        }

        guard let helpText = runHelp() else {
            logger.info("cursor-agent --help unavailable, using fallback modes/sandbox values")
            return CLIOptions(models: models, modes: knownModes, sandboxModes: knownSandboxModes)
        }

        let modes = parseChoices(from: helpText, forFlag: "--mode") ?? knownModes
        let sandboxModes = parseChoices(from: helpText, forFlag: "--sandbox") ?? knownSandboxModes
        return CLIOptions(models: models, modes: modes, sandboxModes: sandboxModes)
    }

    /// Runs `cursor-agent --list-models` to fetch the user's available models.
    private static func runListModels() -> String? {
        guard let path = try? cursorAgentPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--list-models"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var env = EnvironmentBuilder.loginEnvironmentDict()
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        process.environment = env

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
        guard process.terminationStatus == 0 else { return nil }

        let output = stripANSIEscapeCodes(String(data: data, encoding: .utf8) ?? "")
        return output.isEmpty ? nil : output
    }

    /// Parses model list output. Lines look like `composer-2-fast - Composer 2 Fast  (current)`;
    /// only the portion before ` - ` is extracted as the model ID.
    private static func parseModelsFromListOutput(_ text: String) -> [String] {
        var models: [String] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripANSIEscapeCodes(String(line)).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed == "Available models" { continue }
            if trimmed.hasPrefix("Loading") { continue }
            guard let sep = trimmed.range(of: " - ") else { continue }
            let id = String(trimmed[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            models.append(id)
        }
        return models
    }

    // swiftlint:disable:next force_try
    private static let ansiRegex = try! NSRegularExpression(pattern: #"\u{1B}\[[0-9;]*[A-Za-z]"#, options: [])

    private static func stripANSIEscapeCodes(_ string: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return ansiRegex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: "")
    }

    private static func runHelp() -> String? {
        guard let path = try? cursorAgentPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.environment = EnvironmentBuilder.loginEnvironmentDict()

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

    /// Parses "(choices: ...)" from help text for a given flag.
    /// Cursor agent uses format: (choices: "plan", "ask")
    private static func parseChoices(from helpText: String, forFlag flag: String) -> [String]? {
        guard let flagRange = helpText.range(of: flag) else { return nil }
        let afterFlag = String(helpText[flagRange.upperBound...])

        // Look for (choices: "value1", "value2")
        guard let choicesRange = afterFlag.range(of: "choices:") else { return nil }
        let afterChoices = afterFlag[choicesRange.upperBound...]

        // Find the closing parenthesis
        guard let closeRange = afterChoices.range(of: ")") else { return nil }
        let choicesStr = String(afterChoices[..<closeRange.lowerBound])

        // Extract quoted values
        var values: [String] = []
        var scanner = choicesStr[...]
        while let quoteStart = scanner.firstIndex(of: "\"") {
            let afterQuote = scanner[scanner.index(after: quoteStart)...]
            guard let quoteEnd = afterQuote.firstIndex(of: "\"") else { break }
            values.append(String(afterQuote[..<quoteEnd]))
            scanner = afterQuote[afterQuote.index(after: quoteEnd)...]
        }

        return values.isEmpty ? nil : values
    }
}
