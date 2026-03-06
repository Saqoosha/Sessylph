import Foundation

enum CodexCLI {
    /// Resolves the path to the `codex` executable.
    static func codexPath() throws -> String {
        try CLIResolver.resolve(
            name: "codex",
            knownPaths: [
                "\(NSHomeDirectory())/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        )
    }

    /// Returns the Codex CLI version string, or nil if not available.
    static func codexVersion() -> String? {
        CLIResolver.versionOutput(for: codexPath)
    }

    /// Known model suggestions for the ComboBox.
    static let knownModels = [
        "gpt-5.3-codex",
        "gpt-5.4",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.2",
        "gpt-5.1-codex-mini",
    ]

    // MARK: - CLI Options Discovery

    struct CLIOptions: Sendable {
        var approvalModes: [String]
    }

    /// Known approval modes as fallback.
    private static let knownApprovalModes = ["untrusted", "on-failure", "on-request", "never"]

    /// Parses `codex --help` to discover available approval modes.
    static func discoverCLIOptions() -> CLIOptions {
        guard let helpText = runHelp() else {
            return CLIOptions(approvalModes: knownApprovalModes)
        }

        let approvalModes = parsePossibleValues(from: helpText, forFlag: "--ask-for-approval") ?? knownApprovalModes
        return CLIOptions(approvalModes: approvalModes)
    }

    private static func runHelp() -> String? {
        guard let path = try? codexPath() else { return nil }
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

    /// Parses "Possible values:" block after a flag in help text.
    /// Expects lines like: `- value_name: description`
    private static func parsePossibleValues(from helpText: String, forFlag flag: String) -> [String]? {
        guard let flagRange = helpText.range(of: flag) else { return nil }
        let afterFlag = String(helpText[flagRange.upperBound...])

        guard let possibleRange = afterFlag.range(of: "Possible values:") else { return nil }
        let afterPossible = afterFlag[possibleRange.upperBound...]

        var values: [String] = []
        for line in afterPossible.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                // Extract value name before the colon: "- value_name: description"
                let afterDash = trimmed.dropFirst(2)
                if let colonIdx = afterDash.firstIndex(of: ":") {
                    let value = String(afterDash[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        values.append(value)
                    }
                }
            } else if !trimmed.isEmpty && !values.isEmpty {
                // End of the possible values block (non-continuation line after we started collecting)
                // But descriptions can span multiple lines, so only break on lines that start a new flag
                if trimmed.hasPrefix("-") && !trimmed.hasPrefix("- ") {
                    break
                }
            }
        }

        return values.isEmpty ? nil : values
    }
}
