import Foundation

enum CLIType: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude"
    case codex = "codex"
    case cursorAgent = "cursor-agent"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursorAgent: return "Cursor"
        }
    }
}
