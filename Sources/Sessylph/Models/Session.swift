import Foundation

struct Session: Identifiable, Codable, Sendable {
    let id: UUID
    var directory: URL
    var cliType: CLIType
    var options: ClaudeCodeOptions
    var codexOptions: CodexOptions?
    var remoteHost: RemoteHost?
    var tmuxSessionName: String
    var isRunning: Bool = false
    var createdAt: Date

    var isRemote: Bool { remoteHost != nil }

    var title: String {
        if let remoteHost {
            return "\(directory.lastPathComponent)@\(remoteHost.host)"
        }
        return directory.lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case id
        case directory
        case cliType
        case options
        case codexOptions
        case remoteHost
        case tmuxSessionName
        case createdAt
    }

    init(directory: URL, options: ClaudeCodeOptions = ClaudeCodeOptions()) {
        self.id = UUID()
        self.directory = directory
        self.cliType = .claudeCode
        self.options = options
        self.codexOptions = nil
        self.remoteHost = nil
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
        self.remoteHost = nil
        self.tmuxSessionName = TmuxManager.sessionName(for: id, directory: directory)
        self.isRunning = false
        self.createdAt = Date()
    }

    init(remoteHost: RemoteHost, directory: URL, options: ClaudeCodeOptions = ClaudeCodeOptions()) {
        self.id = UUID()
        self.directory = directory
        self.cliType = .claudeCode
        self.options = options
        self.codexOptions = nil
        self.remoteHost = remoteHost
        self.tmuxSessionName = TmuxManager.sessionName(for: id, directory: directory)
        self.isRunning = false
        self.createdAt = Date()
    }

    init(remoteHost: RemoteHost, tmuxSession: String, directory: URL) {
        self.id = UUID()
        self.directory = directory
        self.cliType = .claudeCode
        self.options = ClaudeCodeOptions()
        self.codexOptions = nil
        self.remoteHost = remoteHost
        self.tmuxSessionName = tmuxSession
        self.isRunning = true
        self.createdAt = Date()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        directory = try container.decode(URL.self, forKey: .directory)
        cliType = try container.decodeIfPresent(CLIType.self, forKey: .cliType) ?? .claudeCode
        options = try container.decode(ClaudeCodeOptions.self, forKey: .options)
        codexOptions = try container.decodeIfPresent(CodexOptions.self, forKey: .codexOptions)
        remoteHost = try container.decodeIfPresent(RemoteHost.self, forKey: .remoteHost)
        tmuxSessionName = try container.decode(String.self, forKey: .tmuxSessionName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
