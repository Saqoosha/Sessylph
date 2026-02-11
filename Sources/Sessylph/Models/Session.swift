import Foundation

struct Session: Identifiable, Codable, Sendable {
    let id: UUID
    var directory: URL
    var options: ClaudeCodeOptions
    var tmuxSessionName: String
    var isRunning: Bool = false
    var createdAt: Date

    var title: String { directory.lastPathComponent }

    enum CodingKeys: String, CodingKey {
        case id
        case directory
        case options
        case tmuxSessionName
        case createdAt
    }

    init(directory: URL, options: ClaudeCodeOptions = ClaudeCodeOptions()) {
        self.id = UUID()
        self.directory = directory
        self.options = options
        self.tmuxSessionName = TmuxManager.sessionName(for: id, directory: directory)
        self.isRunning = false
        self.createdAt = Date()
    }
}
