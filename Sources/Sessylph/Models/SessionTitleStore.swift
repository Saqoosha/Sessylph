import Foundation

/// Persists Claude Code session titles (task descriptions from terminal title)
/// so the launcher history can show descriptive titles instead of raw first prompts.
enum SessionTitleStore {
    private static let key = "sessionTitles"
    private static let maxEntries = 200

    /// Save a title for a Claude Code session ID.
    static func save(title: String, forSessionId sessionId: String) {
        guard !title.isEmpty, UUID(uuidString: sessionId) != nil else { return }
        var titles = all()
        titles[sessionId] = title
        // Trim arbitrary entries if over limit (Dictionary has no guaranteed order)
        if titles.count > maxEntries {
            let excess = titles.count - maxEntries
            for key in titles.keys.prefix(excess) {
                titles.removeValue(forKey: key)
            }
        }
        UserDefaults.standard.set(titles, forKey: key)
    }

    /// Look up a saved title for a Claude Code session ID.
    static func title(forSessionId sessionId: String) -> String? {
        all()[sessionId]
    }

    /// All stored titles.
    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
