import Foundation

struct SlashCommand: Codable, Identifiable, Sendable {
    var id: String { command }
    let command: String
    var lastUsed: Date
    var useCount: Int

    /// Derived from SlashCommandStore.isBuiltIn() — not persisted.
    var isGlobal: Bool { SlashCommandStore.isBuiltIn(command) }

    enum CodingKeys: String, CodingKey {
        case command, lastUsed, useCount
    }
}

extension SlashCommand: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(command)
    }

    static func == (lhs: SlashCommand, rhs: SlashCommand) -> Bool {
        lhs.command == rhs.command
    }
}
