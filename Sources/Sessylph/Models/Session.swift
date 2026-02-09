import Foundation

struct Session: Identifiable, Codable, Sendable {
    let id: UUID
    var directory: URL
    var options: ClaudeCodeOptions
    var tmuxSessionName: String
    var title: String
    var isRunning: Bool
    var createdAt: Date
    var lastActiveAt: Date

    init(directory: URL, options: ClaudeCodeOptions = ClaudeCodeOptions()) {
        self.id = UUID()
        self.directory = directory
        self.options = options
        self.tmuxSessionName = TmuxManager.sessionName(for: id, directory: directory)
        self.title = directory.lastPathComponent
        self.isRunning = false
        self.createdAt = Date()
        self.lastActiveAt = Date()
    }
}
