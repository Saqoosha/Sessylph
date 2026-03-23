import Foundation

/// Configuration options for the Cursor Agent CLI. Maps to `cursor-agent` command-line flags.
struct CursorAgentOptions: Codable, Sendable {
    var model: String?
    /// Execution mode: "plan" (read-only) or "ask" (Q&A). Nil = default agent mode.
    var mode: String?
    var continueSession: Bool = false
    var resumeSessionId: String? = nil
    /// Force-approve commands unless explicitly denied.
    var force: Bool = false
    /// Sandbox mode: "enabled" or "disabled". Nil = CLI default.
    var sandbox: String?

    init() {}

    /// Builds the full cursor-agent command string.
    func buildCommand(cursorAgentPath: String) -> String {
        var parts: [String] = [shellQuote(cursorAgentPath)]

        if let model {
            parts.append("--model")
            parts.append(shellQuote(model))
        }

        if let mode {
            parts.append("--mode")
            parts.append(shellQuote(mode))
        }

        if force {
            parts.append("--force")
        }

        if let sandbox {
            parts.append("--sandbox")
            parts.append(shellQuote(sandbox))
        }

        if let resumeSessionId {
            parts.append("--resume")
            parts.append(shellQuote(resumeSessionId))
        } else if continueSession {
            parts.append("--continue")
        }

        return parts.joined(separator: " ")
    }
}
