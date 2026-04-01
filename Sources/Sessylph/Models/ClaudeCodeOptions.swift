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
    /// When true, sets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 to strip Anthropic and cloud
    /// provider credentials from subprocess environments (Bash tool, hooks, MCP stdio servers).
    var scrubSubprocessEnv: Bool = false
    /// When true, sets CLAUDE_CODE_NO_FLICKER=1 to opt into flicker-free alt-screen rendering
    /// with virtualized scrollback. Useful when the terminal wrapper can handle the alt-screen buffer.
    var noFlicker: Bool = false

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

        let command = parts.joined(separator: " ")
        var envPrefixes: [String] = []
        if scrubSubprocessEnv { envPrefixes.append("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1") }
        if noFlicker { envPrefixes.append("CLAUDE_CODE_NO_FLICKER=1") }
        return envPrefixes.isEmpty ? command : "\(envPrefixes.joined(separator: " ")) \(command)"
    }

}
