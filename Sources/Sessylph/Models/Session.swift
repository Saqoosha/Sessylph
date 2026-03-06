import Foundation

struct Session: Identifiable, Codable, Sendable {
    let id: UUID
    var directory: URL
    var cliType: CLIType
    var options: ClaudeCodeOptions
    var codexOptions: CodexOptions?
    var tmuxSessionName: String
    var isRunning: Bool = false
    var createdAt: Date

    var title: String { directory.lastPathComponent }

    enum CodingKeys: String, CodingKey {
        case id
        case directory
        case cliType
        case options
        case codexOptions
        case tmuxSessionName
        case createdAt
    }

    init(directory: URL, options: ClaudeCodeOptions = ClaudeCodeOptions()) {
        self.id = UUID()
        self.directory = directory
        self.cliType = .claudeCode
        self.options = options
        self.codexOptions = nil
        self.tmuxSessionName = TmuxManager.sessionName(for: id, directory: directory)
        self.isRunning = false
        self.createdAt = Date()
    }

    init(directory: URL, codexOptions: CodexOptions) {
        self.id = UUID()
        self.directory = directory
        self.cliType = .codex
        self.options = ClaudeCodeOptions()
        self.codexOptions = codexOptions
        self.tmuxSessionName = TmuxManager.sessionName(for: id, directory: directory)
        self.isRunning = false
        self.createdAt = Date()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        directory = try container.decode(URL.self, forKey: .directory)
        cliType = try container.decodeIfPresent(CLIType.self, forKey: .cliType) ?? .claudeCode
        options = try container.decode(ClaudeCodeOptions.self, forKey: .options)
        codexOptions = try container.decodeIfPresent(CodexOptions.self, forKey: .codexOptions)
        tmuxSessionName = try container.decode(String.self, forKey: .tmuxSessionName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
