/// Shared display label for Claude Code permission mode identifiers.
enum PermissionMode {
    static func label(for mode: String) -> String {
        switch mode {
        case "default": "Default"
        case "plan": "Plan"
        case "acceptEdits": "Accept Edits"
        case "delegate": "Delegate"
        case "dontAsk": "Don't Ask"
        case "bypassPermissions": "Bypass Permissions"
        default: mode
        }
    }
}
