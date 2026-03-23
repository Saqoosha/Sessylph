import Foundation

enum LaunchConfig {
    case claudeCode(ClaudeCodeOptions)
    case codex(CodexOptions)
    case cursorAgent(CursorAgentOptions)
    /// Attach to an existing remote tmux session
    case remoteAttach(RemoteHost, sessionName: String)
    /// Create a new session on a remote host (currently Claude Code only — Codex/Cursor Agent lack remote launch support)
    case remoteNewSession(RemoteHost, directory: String, ClaudeCodeOptions)

    static func defaultFromUserDefaults() -> LaunchConfig {
        let defaults = UserDefaults.standard
        let cliType = CLIType(rawValue: defaults.string(forKey: Defaults.defaultCLIType) ?? "") ?? .claudeCode

        switch cliType {
        case .claudeCode:
            var options = ClaudeCodeOptions()
            let model = defaults.string(forKey: Defaults.defaultModel) ?? ""
            let permissionMode = defaults.string(forKey: Defaults.defaultPermissionMode) ?? ""
            options.model = model.isEmpty ? nil : model
            options.permissionMode = permissionMode.isEmpty ? nil : permissionMode
            options.dangerouslySkipPermissions = defaults.bool(forKey: Defaults.launcherSkipPermissions)
            options.continueSession = defaults.bool(forKey: Defaults.launcherContinueSession)
            options.verbose = defaults.bool(forKey: Defaults.launcherVerbose)
            return .claudeCode(options)

        case .codex:
            var options = CodexOptions()
            let model = defaults.string(forKey: Defaults.codexModel) ?? ""
            options.model = model.isEmpty ? nil : model
            options.dangerouslyBypassApprovalsAndSandbox = defaults.bool(forKey: Defaults.codexDangerouslyBypass)
            if !options.dangerouslyBypassApprovalsAndSandbox {
                options.fullAuto = defaults.bool(forKey: Defaults.codexFullAuto)
                if !options.fullAuto {
                    let approvalMode = defaults.string(forKey: Defaults.codexApprovalMode) ?? ""
                    options.approvalMode = approvalMode.isEmpty ? nil : approvalMode
                }
            }
            return .codex(options)

        case .cursorAgent:
            var options = CursorAgentOptions()
            let model = defaults.string(forKey: Defaults.cursorAgentModel) ?? ""
            let mode = defaults.string(forKey: Defaults.cursorAgentMode) ?? ""
            let sandbox = defaults.string(forKey: Defaults.cursorAgentSandbox) ?? ""
            options.model = model.isEmpty ? nil : model
            options.mode = mode.isEmpty ? nil : mode
            options.sandbox = sandbox.isEmpty ? nil : sandbox
            options.continueSession = defaults.bool(forKey: Defaults.cursorAgentContinueSession)
            options.force = defaults.bool(forKey: Defaults.cursorAgentForce)
            return .cursorAgent(options)
        }
    }
}
