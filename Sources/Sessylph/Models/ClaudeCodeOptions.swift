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

        if let hookSettingsPath {
            parts.append("--settings")
            parts.append(shellQuote(hookSettingsPath))
        }

        return parts.joined(separator: " ")
    }

}
