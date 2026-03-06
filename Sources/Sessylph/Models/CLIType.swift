import Foundation

enum CLIType: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
