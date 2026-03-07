import Foundation

struct CodexOptions: Codable, Sendable {
    var model: String?
    var approvalMode: String?
    var fullAuto: Bool = false
    var dangerouslyBypassApprovalsAndSandbox: Bool = false

    init() {}

    /// Builds the full codex command string for tmux send-keys.
    func buildCommand(codexPath: String, notifierArgs: [String]? = nil) -> String {
        var parts: [String] = [shellQuote(codexPath)]

        if let model {
            parts.append("--model")
            parts.append(shellQuote(model))
        }

        if dangerouslyBypassApprovalsAndSandbox {
            parts.append("--dangerously-bypass-approvals-and-sandbox")
        } else if fullAuto {
            parts.append("--full-auto")
        } else if let approvalMode {
            parts.append("--ask-for-approval")
            parts.append(shellQuote(approvalMode))
        }

        if let notifierArgs, !notifierArgs.isEmpty {
            // Build TOML array literal: ["arg1", "arg2", ...]
            let tomlArray = notifierArgs.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("--config")
            parts.append("'notify=[\(tomlArray)]'")
        }

        return parts.joined(separator: " ")
    }
}
