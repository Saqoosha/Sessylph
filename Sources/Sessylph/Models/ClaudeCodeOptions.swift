import Foundation

struct ClaudeCodeOptions: Codable, Sendable {
    var model: String?
    var permissionMode: String?
    var allowedTools: [String]?
    var disallowedTools: [String]?
    var dangerouslySkipPermissions: Bool = false
    var continueSession: Bool = false
    var resumeSessionId: String? = nil
    var maxBudgetUSD: Double? = nil
    var verbose: Bool = false
    var systemPrompt: String? = nil
    var appendSystemPrompt: String? = nil
    var additionalDirs: [String]? = nil
    var mcpConfigs: [String]? = nil
    var effortLevel: String? = nil
    var bare: Bool = false
    var channels: [String]? = nil

    init() {}

    /// Builds the full claude command string for tmux send-keys.
    /// e.g. `claude --model opus --permission-mode plan`
    func buildCommand(claudePath: String, hookSettingsPath: String? = nil) -> String {
        var parts: [String] = [shellQuote(claudePath)]

        if let model {
            parts.append("--model")
            parts.append(shellQuote(model))
        }

        if let permissionMode {
            parts.append("--permission-mode")
            parts.append(shellQuote(permissionMode))
        }

        if let allowedTools, !allowedTools.isEmpty {
            for tool in allowedTools {
                parts.append("--allowedTools")
                parts.append(shellQuote(tool))
            }
        }

        if let disallowedTools, !disallowedTools.isEmpty {
            for tool in disallowedTools {
                parts.append("--disallowedTools")
                parts.append(shellQuote(tool))
            }
        }

        if dangerouslySkipPermissions {
            parts.append("--dangerously-skip-permissions")
        }

        if continueSession {
            parts.append("-c")
        }

        if let resumeSessionId {
            parts.append("-r")
            parts.append(shellQuote(resumeSessionId))
        }

        if let maxBudgetUSD {
            parts.append("--max-budget-usd")
            parts.append(String(format: "%.2f", maxBudgetUSD))
        }

        if verbose {
            parts.append("--verbose")
        }

        if let effortLevel {
            parts.append("--effort")
            parts.append(shellQuote(effortLevel))
        }

        if let systemPrompt {
            parts.append("--system-prompt")
            parts.append(shellQuote(systemPrompt))
        }

        if let appendSystemPrompt {
            parts.append("--append-system-prompt")
            parts.append(shellQuote(appendSystemPrompt))
        }

        if let additionalDirs, !additionalDirs.isEmpty {
            for dir in additionalDirs {
                parts.append("--add-dir")
                parts.append(shellQuote(dir))
            }
        }

        if let mcpConfigs, !mcpConfigs.isEmpty {
            for config in mcpConfigs {
                parts.append("--mcp-config")
                parts.append(shellQuote(config))
            }
        }

        if let channels, !channels.isEmpty {
            for channel in channels {
                parts.append("--channels")
                parts.append(shellQuote(channel))
            }
        }

        if bare {
            parts.append("--bare")
        }

        if let hookSettingsPath {
            parts.append("--settings")
            parts.append(shellQuote(hookSettingsPath))
        }

        return parts.joined(separator: " ")
    }

    /// Builds CLI arguments for --sdk-url mode (headless/native UI).
    /// Returns an array of arguments (not a shell command string).
    func buildSDKArgs(claudePath: String, sdkUrl: String, sessionId: String) -> [String] {
        var args: [String] = [
            claudePath,
            "--print",
            "--sdk-url", sdkUrl,
            "--session-id", sessionId,
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]

        if let model {
            args += ["--model", model]
        }
        if let permissionMode {
            args += ["--permission-mode", permissionMode]
        }
        if let allowedTools, !allowedTools.isEmpty {
            for tool in allowedTools {
                args += ["--allowedTools", tool]
            }
        }
        if let disallowedTools, !disallowedTools.isEmpty {
            for tool in disallowedTools {
                args += ["--disallowedTools", tool]
            }
        }
        if dangerouslySkipPermissions {
            args.append("--dangerously-skip-permissions")
        }
        if continueSession {
            args.append("-c")
        }
        if let resumeSessionId {
            args += ["-r", resumeSessionId]
        }
        if let maxBudgetUSD {
            args += ["--max-budget-usd", String(format: "%.2f", maxBudgetUSD)]
        }
        if let effortLevel {
            args += ["--effort", effortLevel]
        }
        if let systemPrompt {
            args += ["--system-prompt", systemPrompt]
        }
        if let appendSystemPrompt {
            args += ["--append-system-prompt", appendSystemPrompt]
        }
        if let additionalDirs, !additionalDirs.isEmpty {
            for dir in additionalDirs {
                args += ["--add-dir", dir]
            }
        }
        if let mcpConfigs, !mcpConfigs.isEmpty {
            for config in mcpConfigs {
                args += ["--mcp-config", config]
            }
        }
        if let channels, !channels.isEmpty {
            for channel in channels {
                args += ["--channels", channel]
            }
        }
        if bare {
            args.append("--bare")
        }

        // Empty prompt — sdk-url mode ignores it but flag is required
        args += ["-p", ""]

        return args
    }

}
