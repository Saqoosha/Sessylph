import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "SlashCommandStore")

@MainActor
enum SlashCommandStore {
    private static let maxCount = 100

    // MARK: - Built-in Classification

    private nonisolated(unsafe) static let builtInCommands: Set<String> = [
        // Core commands
        "/add-dir", "/agents", "/btw", "/chrome", "/clear", "/color",
        "/compact", "/config", "/context", "/copy", "/cost",
        "/desktop", "/diff", "/doctor", "/effort", "/exit", "/export",
        "/extra-usage", "/fast", "/feedback", "/fork", "/help",
        "/hooks", "/ide", "/init", "/insights", "/install-github-app",
        "/install-slack-app", "/keybindings", "/login", "/logout",
        "/mcp", "/memory", "/mobile", "/model", "/passes",
        "/permissions", "/plan", "/plugin", "/pr-comments",
        "/privacy-settings", "/release-notes", "/reload-plugins",
        "/remote-control", "/remote-env", "/rename", "/resume",
        "/review", "/rewind", "/sandbox", "/security-review",
        "/skills", "/stats", "/status", "/statusline", "/stickers",
        "/tasks", "/terminal-setup", "/theme", "/upgrade", "/usage", "/vim", "/voice",
        // Aliases
        "/reset", "/new", "/settings", "/app", "/bug", "/quit",
        "/allowed-tools", "/continue", "/checkpoint", "/rc",
        "/ios", "/android",
        // Bundled skills
        "/batch", "/claude-api", "/debug", "/loop", "/simplify",
    ]

    nonisolated static func isBuiltIn(_ command: String) -> Bool {
        let name = extractCommandName(command)
        return builtInCommands.contains(name)
    }

    /// Returns true if the command is a known built-in or has been previously recorded.
    static func isKnownCommand(_ command: String, directory: URL) -> Bool {
        let name = extractCommandName(command)
        if builtInCommands.contains(name) { return true }
        let all = load(for: directory)
        return all.contains { $0.command == name }
    }

    /// Extracts the command name (first word) from a full command string.
    /// e.g. "/compact some args" → "/compact"
    nonisolated static func extractCommandName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return trimmed }
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            return String(trimmed[trimmed.startIndex ..< spaceIdx])
        }
        return trimmed
    }

    // MARK: - Load

    /// Loads recorded commands for a given project directory: global entries + project-specific entries,
    /// deduplicated by command name, sorted by lastUsed descending.
    static func load(for directory: URL) -> [SlashCommand] {
        let global = loadEntries(forKey: Defaults.slashCommandHistoryGlobal)
        let projectKey = projectStorageKey(for: directory)
        let project = loadEntries(forKey: projectKey)
        // Deduplicate: prefer the entry with the higher useCount or more recent lastUsed
        var byCommand: [String: SlashCommand] = [:]
        for entry in global + project {
            if let existing = byCommand[entry.command] {
                if entry.useCount > existing.useCount || entry.lastUsed > existing.lastUsed {
                    byCommand[entry.command] = entry
                }
            } else {
                byCommand[entry.command] = entry
            }
        }
        return byCommand.values.sorted { $0.lastUsed > $1.lastUsed }
    }

    // MARK: - Record Usage

    /// Records a command usage. Determines if it's built-in (global) or project-specific.
    static func recordUsage(_ rawCommand: String, directory: URL) {
        let command = extractCommandName(rawCommand)
        guard !command.isEmpty, command != "/" else { return }

        if isBuiltIn(command) {
            var entries = loadEntries(forKey: Defaults.slashCommandHistoryGlobal)
            upsert(command: command, into: &entries)
            save(entries, forKey: Defaults.slashCommandHistoryGlobal)
        } else {
            let key = projectStorageKey(for: directory)
            var entries = loadEntries(forKey: key)
            upsert(command: command, into: &entries)
            save(entries, forKey: key)
        }
    }

    // MARK: - Add Manual

    /// Adds a command manually (not from usage tracking).
    /// Accepts slash commands (extracts name) or free-text phrases.
    /// Slash commands are stored globally if built-in, otherwise project-specific.
    /// Free-text is always project-specific.
    /// Does nothing if the command already exists.
    static func addManual(_ rawCommand: String, directory: URL) {
        var command = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        // For slash commands, extract just the command name (strip arguments)
        if command.hasPrefix("/") {
            command = extractCommandName(command)
            guard command != "/" else { return }
        }

        let key = isBuiltIn(command) ? Defaults.slashCommandHistoryGlobal : projectStorageKey(for: directory)
        var entries = loadEntries(forKey: key)
        guard !entries.contains(where: { $0.command == command }) else { return }
        entries.append(SlashCommand(command: command, lastUsed: .distantPast, useCount: 0))
        if entries.count > maxCount {
            entries.sort { $0.lastUsed > $1.lastUsed }
            entries = Array(entries.prefix(maxCount))
        }
        save(entries, forKey: key)
    }

    // MARK: - Remove

    static func remove(_ command: String, directory: URL) {
        if isBuiltIn(command) {
            var entries = loadEntries(forKey: Defaults.slashCommandHistoryGlobal)
            entries.removeAll { $0.command == command }
            save(entries, forKey: Defaults.slashCommandHistoryGlobal)
        } else {
            let key = projectStorageKey(for: directory)
            var entries = loadEntries(forKey: key)
            entries.removeAll { $0.command == command }
            save(entries, forKey: key)
        }
    }

    // MARK: - Private Helpers

    private static func upsert(command: String, into entries: inout [SlashCommand]) {
        if let idx = entries.firstIndex(where: { $0.command == command }) {
            // Dedup: skip if same command was recorded within 2 seconds
            // (input buffer + hook may both fire for the same command)
            if entries[idx].lastUsed.timeIntervalSinceNow > -2 { return }
            entries[idx].lastUsed = Date()
            entries[idx].useCount += 1
        } else {
            entries.append(SlashCommand(
                command: command,
                lastUsed: Date(),
                useCount: 1
            ))
        }
        if entries.count > maxCount {
            entries.sort { $0.lastUsed > $1.lastUsed }
            entries = Array(entries.prefix(maxCount))
        }
    }

    private static func loadEntries(forKey key: String) -> [SlashCommand] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([SlashCommand].self, from: data)
        } catch {
            logger.error("Failed to decode slash commands for key '\(key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func save(_ entries: [SlashCommand], forKey key: String) {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode slash commands for key '\(key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func projectStorageKey(for directory: URL) -> String {
        let hash = SHA256.hash(data: Data(directory.path.utf8))
        let prefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return Defaults.slashCommandHistoryPrefix + prefix
    }
}
